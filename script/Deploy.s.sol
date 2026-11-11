// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { LastlightReactive } from "../src/LastlightReactive.sol";
import { LastlightFactory } from "../src/LastlightFactory.sol";
import { LastlightVault } from "../src/LastlightVault.sol";

// Three steps across two chains (the address cycle is broken by `setFactory`):
//   1. Lasna:   forge script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --broadcast
//   2. Sepolia: REACTIVE=<addr from 1> forge script script/Deploy.s.sol:DeployFactory --rpc-url $SEPOLIA_RPC --broadcast
//   3. Lasna:   REACTIVE=<1> FACTORY=<2> forge script script/Deploy.s.sol:WireFactory --rpc-url $LASNA_RPC --broadcast
// Demo vault (Sepolia): FACTORY=<2> HEIR=<addr> forge script script/Deploy.s.sol:DemoVault --rpc-url $SEPOLIA_RPC --broadcast
// The signer key comes from the PRIVATE_KEY environment variable.

uint256 constant SEPOLIA_CHAIN_ID = 11155111;
address constant SEPOLIA_CALLBACK_PROXY = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
// Cron100 topic on Reactive Network (fires every 100 Reactive Network blocks).
uint256 constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

contract DeployReactive is Script {
    function run() external {
        uint256 fund = vm.envOr("REACTIVE_FUND", uint256(0.5 ether)); // lREACT to cover reactive tx fees
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LastlightReactive rc = new LastlightReactive{ value: fund }(SEPOLIA_CHAIN_ID, CRON100_TOPIC);
        vm.stopBroadcast();
        console.log("REACTIVE", address(rc));
    }
}

contract DeployFactory is Script {
    function run() external {
        address reactive = vm.envAddress("REACTIVE");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LastlightFactory f = new LastlightFactory(IPayable(payable(SEPOLIA_CALLBACK_PROXY)), reactive);
        vm.stopBroadcast();
        console.log("FACTORY", address(f));
    }
}

contract WireFactory is Script {
    function run() external {
        LastlightReactive rc = LastlightReactive(payable(vm.envAddress("REACTIVE")));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        rc.setFactory(vm.envAddress("FACTORY"));
        vm.stopBroadcast();
        console.log("WIRED", address(rc), rc.factory());
    }
}

/// A short-fuse vault for the demo: 30 min heartbeat, warning 15 min before the deadline, 100% to HEIR.
contract DemoVault is Script {
    function run() external {
        LastlightFactory f = LastlightFactory(vm.envAddress("FACTORY"));
        address[] memory heirs = new address[](1);
        heirs[0] = vm.envAddress("HEIR");
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10_000;
        address[] memory tokens = new address[](0);
        uint256 deposit = vm.envOr("DEPOSIT", uint256(0.02 ether));
        uint256 reserve = vm.envOr("GAS_RESERVE", uint256(0.005 ether));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LastlightVault v = f.create{ value: deposit }(30 minutes, 15 minutes, reserve, heirs, shares, tokens);
        vm.stopBroadcast();
        console.log("VAULT", address(v), v.deadline());
    }
}
