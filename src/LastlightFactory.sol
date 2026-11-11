// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { LastlightVault } from "./LastlightVault.sol";

/// @title LastlightFactory
/// @notice Anyone deploys their own vault here. The Lastlight reactive contract watches `VaultCreated` and starts
///         guarding the new vault on its own: no registration, no keeper, no server.
contract LastlightFactory {
    IPayable public immutable callbackProxy;
    address public immutable reactive;

    event VaultCreated(address indexed vault, address indexed owner, uint256 deadline, uint256 warnAt);

    constructor(IPayable callbackProxy_, address reactive_) {
        callbackProxy = callbackProxy_;
        reactive = reactive_;
    }

    function create(
        uint64 heartbeat_,
        uint64 warnLead_,
        uint256 gasReserve_,
        address[] calldata heirs_,
        uint16[] calldata shares_,
        address[] calldata tokens_
    ) external payable returns (LastlightVault vault) {
        vault = new LastlightVault{ value: msg.value }(
            callbackProxy, reactive, msg.sender, heartbeat_, warnLead_, gasReserve_, heirs_, shares_, tokens_
        );
        uint256 d = vault.deadline();
        emit VaultCreated(address(vault), msg.sender, d, d - warnLead_);
    }
}
