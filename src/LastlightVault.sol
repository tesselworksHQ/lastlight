// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title LastlightVault
/// @notice A dead-man's switch for one owner. The owner proves they are alive by calling `checkIn()` (any owner
///         action counts). If the owner stays silent past the deadline, Reactive Network calls `release()` and the
///         vault splits its ETH and listed ERC-20s between the heirs. The vault checks the deadline against its own
///         clock, so an early or replayed callback can never release funds.
contract LastlightVault is AbstractCallback {
    uint256 public constant MAX_HEIRS = 5;
    uint256 public constant MAX_TOKENS = 5;
    uint16 public constant BPS = 10_000;

    address public immutable owner;
    uint64 public heartbeat; // seconds of silence allowed
    uint64 public warnLead; // warn this many seconds before the deadline
    uint64 public lastCheckIn;
    bool public released;
    /// @notice ETH kept back on release so the vault can still pay the callback proxy for the release callback.
    uint256 public immutable gasReserve;

    address[] internal _heirs;
    uint16[] internal _shares;
    address[] internal _tokens;
    mapping(address => uint256) public owedEth; // pull fallback if a push to an heir fails

    event CheckIn(uint256 deadline, uint256 warnAt);
    event Warned(uint256 deadline);
    event ReleaseTooEarly(uint256 deadline, uint256 nowTs);
    event Released(uint256 ethTotal);
    event HeirPaid(address indexed heir, address indexed token, uint256 amount);
    event HeirPushFailed(address indexed heir, uint256 amount);
    event TokenSkipped(address indexed token);
    event Deposited(address indexed from, uint256 amount);

    error NotOwner();
    error AlreadyReleased();
    error BadConfig();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier live() {
        if (released) revert AlreadyReleased();
        _;
    }

    constructor(
        IPayable callbackProxy_,
        address reactive_,
        address owner_,
        uint64 heartbeat_,
        uint64 warnLead_,
        uint256 gasReserve_,
        address[] memory heirs_,
        uint16[] memory shares_,
        address[] memory tokens_
    ) payable AbstractCallback(callbackProxy_, reactive_) {
        owner = owner_;
        gasReserve = gasReserve_;
        _setPlan(heartbeat_, warnLead_, heirs_, shares_, tokens_);
        _checkIn();
    }

    // ---------------------------------------------------------------- owner (every call is proof of life)

    function checkIn() external onlyOwner live {
        _checkIn();
    }

    function setPlan(
        uint64 heartbeat_,
        uint64 warnLead_,
        address[] calldata heirs_,
        uint16[] calldata shares_,
        address[] calldata tokens_
    ) external onlyOwner live {
        _setPlan(heartbeat_, warnLead_, heirs_, shares_, tokens_);
        _checkIn();
    }

    function withdraw(address payable to_, uint256 amount_) external onlyOwner live {
        _checkIn();
        (bool ok,) = to_.call{ value: amount_ }("");
        require(ok, "withdraw failed");
    }

    function withdrawToken(address token_, address to_, uint256 amount_) external onlyOwner live {
        _checkIn();
        require(IERC20Min(token_).transfer(to_, amount_), "token withdraw failed");
    }

    /// @notice Settles any debt to the callback proxy from the vault balance. Anyone may call it.
    function coverDebt() external {
        _coverDebt();
    }

    receive() external payable override {
        emit Deposited(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------- Reactive callbacks

    function warn(address rvm_) external onlyServiceProvider onlyCallbackSender(rvm_) {
        if (released) return;
        uint256 d = deadline();
        if (block.timestamp + warnLead < d) return; // stale: the owner checked in since the request
        emit Warned(d);
    }

    function release(address rvm_) external onlyServiceProvider onlyCallbackSender(rvm_) {
        if (released) return;
        uint256 d = deadline();
        if (block.timestamp < d) {
            emit ReleaseTooEarly(d, block.timestamp);
            return;
        }
        released = true;
        _distribute();
    }

    /// @notice Heirs collect ETH here if the push at release time failed.
    function claim() external {
        uint256 amt = owedEth[msg.sender];
        owedEth[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{ value: amt }("");
        require(ok, "claim failed");
    }

    // ---------------------------------------------------------------- views

    function deadline() public view returns (uint256) {
        return uint256(lastCheckIn) + heartbeat;
    }

    function plan() external view returns (address[] memory, uint16[] memory, address[] memory) {
        return (_heirs, _shares, _tokens);
    }

    // ---------------------------------------------------------------- internals

    function _checkIn() internal {
        lastCheckIn = uint64(block.timestamp);
        uint256 d = deadline();
        emit CheckIn(d, d - warnLead);
    }

    function _setPlan(
        uint64 heartbeat_,
        uint64 warnLead_,
        address[] memory heirs_,
        uint16[] memory shares_,
        address[] memory tokens_
    ) internal {
        uint256 n = heirs_.length;
        if (n == 0 || n > MAX_HEIRS || n != shares_.length || tokens_.length > MAX_TOKENS) revert BadConfig();
        if (heartbeat_ == 0 || warnLead_ >= heartbeat_) revert BadConfig();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (heirs_[i] == address(0)) revert BadConfig();
            sum += shares_[i];
        }
        if (sum != BPS) revert BadConfig();
        heartbeat = heartbeat_;
        warnLead = warnLead_;
        _heirs = heirs_;
        _shares = shares_;
        _tokens = tokens_;
    }

    function _distribute() internal {
        uint256 bal = address(this).balance;
        uint256 pot = bal > gasReserve ? bal - gasReserve : 0;
        uint256 n = _heirs.length;
        for (uint256 i; i < n; ++i) {
            address heir = _heirs[i];
            uint256 amt = (pot * _shares[i]) / BPS;
            if (amt == 0) continue;
            (bool ok,) = payable(heir).call{ value: amt, gas: 30_000 }("");
            if (ok) {
                emit HeirPaid(heir, address(0), amt);
            } else {
                owedEth[heir] += amt;
                emit HeirPushFailed(heir, amt);
            }
        }
        for (uint256 t; t < _tokens.length; ++t) {
            address token = _tokens[t];
            (bool okb, bytes memory rb) =
                token.staticcall{ gas: 50_000 }(abi.encodeCall(IERC20Min.balanceOf, (address(this))));
            if (!okb || rb.length < 32) {
                emit TokenSkipped(token);
                continue;
            }
            uint256 tbal = abi.decode(rb, (uint256));
            for (uint256 i; i < n; ++i) {
                uint256 amt = (tbal * _shares[i]) / BPS;
                if (amt == 0) continue;
                (bool okt, bytes memory rt) =
                    token.call{ gas: 60_000 }(abi.encodeCall(IERC20Min.transfer, (_heirs[i], amt)));
                if (okt && (rt.length == 0 || abi.decode(rt, (bool)))) emit HeirPaid(_heirs[i], token, amt);
                else emit TokenSkipped(token);
            }
        }
        emit Released(pot);
    }
}
