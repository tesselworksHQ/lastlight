// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title LastlightReactive
/// @notice Lives on Reactive Network. Learns about new vaults from the factory's `VaultCreated`, follows each
///         vault's `CheckIn` / `Released` events, and on a Cron tick sends `warn()` and then `release()` callbacks
///         to vaults whose owner has gone silent. One contract guards every vault the factory makes.
contract LastlightReactive is AbstractReactive {
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    uint256 internal constant VAULT_CREATED_TOPIC = uint256(keccak256("VaultCreated(address,address,uint256,uint256)"));
    uint256 internal constant CHECKIN_TOPIC = uint256(keccak256("CheckIn(uint256,uint256)"));
    uint256 internal constant RELEASED_TOPIC = uint256(keccak256("Released(uint256)"));

    uint64 public constant CALLBACK_GAS = 3_000_000; // covers 5 heirs x 5 tokens at the vault caps
    uint256 public constant RETRY_AFTER = 30 minutes;
    uint8 public constant MAX_TRIES = 5;

    enum Status { None, Active, Warned, ReleaseRequested, Done }

    struct Guard {
        uint64 deadline;
        uint64 warnAt;
        uint64 lastRequest;
        uint8 tries;
        Status status;
    }

    address public immutable owner;
    uint256 public immutable destChainId;
    uint256 public immutable cronTopic;
    address public factory;
    bool public paused;
    uint256 public maxPerTick = 25;
    uint256 public cursor;

    mapping(address => Guard) public guards;
    address[] public watched; // vaults not yet Done
    mapping(address => uint256) internal _pos; // 1-based index into `watched`

    event Guarding(address indexed vault, uint256 deadline);
    event Refreshed(address indexed vault, uint256 deadline);
    event WarnRequested(address indexed vault);
    event ReleaseRequested(address indexed vault, uint8 attempt);
    event Finished(address indexed vault);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 destChainId_, uint256 cronTopic_) payable {
        owner = msg.sender;
        destChainId = destChainId_;
        cronTopic = cronTopic_;
        _cron(true);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Deployment order breaks the address cycle: reactive first, then the factory, then this setter.
    function setFactory(address factory_) external onlyOwner {
        require(factory == address(0), "factory set");
        factory = factory_;
        SYSTEM.subscribe(destChainId, factory_, VAULT_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setMaxPerTick(uint256 n_) external onlyOwner {
        require(n_ > 0 && n_ <= 100, "range");
        maxPerTick = n_;
    }

    function pause() external onlyOwner {
        require(!paused, "paused");
        paused = true;
        _cron(false);
    }

    function resume() external payable onlyOwner {
        require(paused, "not paused");
        paused = false;
        _coverDebt();
        _cron(true);
    }

    function coverDebt() external {
        _coverDebt();
    }

    function watchedCount() external view returns (uint256) {
        return watched.length;
    }

    // ---------------------------------------------------------------- react

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.contractAddress == LEGACY_SYSTEM_ADDR) {
            if (log_.topic0 == cronTopic) _tick();
            return;
        }
        if (log_.chainId != destChainId) return;

        if (log_.contractAddress == factory && log_.topic0 == VAULT_CREATED_TOPIC && log_.opCode == 3) {
            address vault = address(uint160(log_.topic1));
            (uint256 d, uint256 w) = abi.decode(log_.data, (uint256, uint256));
            _watch(vault, d, w);
            return;
        }

        Guard storage g = guards[log_.contractAddress];
        if (g.status == Status.None || g.status == Status.Done) return;

        if (log_.topic0 == CHECKIN_TOPIC && log_.opCode == 1) {
            (uint256 d, uint256 w) = abi.decode(log_.data, (uint256, uint256));
            g.deadline = uint64(d);
            g.warnAt = uint64(w);
            g.status = Status.Active;
            g.tries = 0;
            emit Refreshed(log_.contractAddress, d);
        } else if (log_.topic0 == RELEASED_TOPIC) {
            _finish(log_.contractAddress);
        }
    }

    // ---------------------------------------------------------------- internals

    function _watch(address vault_, uint256 deadline_, uint256 warnAt_) internal {
        if (guards[vault_].status != Status.None) return;
        guards[vault_] = Guard(uint64(deadline_), uint64(warnAt_), 0, 0, Status.Active);
        watched.push(vault_);
        _pos[vault_] = watched.length;
        SYSTEM.subscribe(destChainId, vault_, CHECKIN_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destChainId, vault_, RELEASED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit Guarding(vault_, deadline_);
    }

    function _finish(address vault_) internal {
        guards[vault_].status = Status.Done;
        SYSTEM.unsubscribe(destChainId, vault_, CHECKIN_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(destChainId, vault_, RELEASED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        uint256 p = _pos[vault_];
        if (p != 0) {
            address last = watched[watched.length - 1];
            watched[p - 1] = last;
            _pos[last] = p;
            watched.pop();
            delete _pos[vault_];
        }
        emit Finished(vault_);
    }

    function _tick() internal {
        uint256 len = watched.length;
        if (len == 0) return;
        uint256 n = len < maxPerTick ? len : maxPerTick;
        uint256 c = cursor;
        uint256 nowTs = block.timestamp;
        for (uint256 i; i < n; ++i) {
            address vault = watched[(c + i) % len];
            Guard storage g = guards[vault];
            if (g.status == Status.Active && nowTs >= g.warnAt && nowTs < g.deadline) {
                g.status = Status.Warned;
                _callback(vault, "warn(address)");
                emit WarnRequested(vault);
            } else if ((g.status == Status.Active || g.status == Status.Warned) && nowTs >= g.deadline) {
                _requestRelease(vault, g, nowTs);
            } else if (
                g.status == Status.ReleaseRequested && nowTs >= g.lastRequest + RETRY_AFTER && g.tries < MAX_TRIES
            ) {
                // No Released event came back (clock skew, failed callback, vault in debt): try again.
                _requestRelease(vault, g, nowTs);
            }
        }
        cursor = (c + n) % len;
    }

    function _requestRelease(address vault_, Guard storage g_, uint256 nowTs_) internal {
        g_.status = Status.ReleaseRequested;
        g_.lastRequest = uint64(nowTs_);
        g_.tries += 1;
        _callback(vault_, "release(address)");
        emit ReleaseRequested(vault_, g_.tries);
    }

    function _callback(address vault_, string memory sig_) internal {
        // First argument is a placeholder: the network overwrites it with this contract's address.
        bytes memory payload = abi.encodeWithSignature(sig_, address(0));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: vault_, gasLimit: CALLBACK_GAS, payload: payload
            })
        );
    }

    function _cron(bool on_) internal {
        if (on_) {
            SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM_ADDR, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(block.chainid, LEGACY_SYSTEM_ADDR, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }
}
