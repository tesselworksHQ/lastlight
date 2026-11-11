// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @dev Stand-in for the Omni system contract at 0x8888…: keeps subscriptions, queues callback requests.
contract MockSystem {
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    struct Sub {
        address subscriber;
        uint256 chainId;
        address origin;
        uint256 topic0;
        bool active;
    }

    struct Req {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] public subs;
    Req[] internal _queue;

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 c, address o, uint256 t0, uint256, uint256, uint256) external {
        subs.push(Sub(msg.sender, c, o, t0, true));
    }

    function unsubscribe(uint256 c, address o, uint256 t0, uint256, uint256, uint256) external {
        for (uint256 i; i < subs.length; ++i) {
            Sub storage s = subs[i];
            if (s.active && s.subscriber == msg.sender && s.chainId == c && s.origin == o && s.topic0 == t0) {
                s.active = false;
            }
        }
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external {
        _queue.push(Req(msg.sender, cfg.chainId, cfg.recipient, cfg.gasLimit, cfg.payload));
    }

    function activeSubs() external view returns (uint256 n) {
        for (uint256 i; i < subs.length; ++i) if (subs[i].active) ++n;
    }

    function matches(address subscriber, uint256 c, address o, uint256 t0) external view returns (bool) {
        for (uint256 i; i < subs.length; ++i) {
            Sub storage s = subs[i];
            if (!s.active || s.subscriber != subscriber) continue;
            if (s.chainId != 0 && s.chainId != c) continue;
            if (s.origin != address(0) && s.origin != o) continue;
            if (s.topic0 != IGNORE && s.topic0 != t0) continue;
            return true;
        }
        return false;
    }

    function drain() external returns (Req[] memory out) {
        out = _queue;
        delete _queue;
    }
}

/// @dev Stand-in for the destination-chain callback proxy: overwrites the first argument with the requester.
contract MockProxy {
    event CallbackFailure(address recipient, bytes reason);

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function deliver(address recipient, uint64 gasLimit, bytes memory payload, address sender)
        external
        returns (bool ok)
    {
        assembly {
            mstore(add(payload, 36), sender) // 32 (length) + 4 (selector)
        }
        bytes memory ret;
        (ok, ret) = recipient.call{ gas: gasLimit }(payload);
        if (!ok) emit CallbackFailure(recipient, ret);
    }
}

/// @dev Simulates the loop: origin logs -> react() -> callback -> destination logs -> react() ...
abstract contract Harness is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    MockSystem internal sys;
    MockProxy internal proxy;
    uint256 internal delivered;
    uint256 internal cbFailed;

    function _setUpMocks() internal {
        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM, address(impl).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockProxy();
        vm.recordLogs();
    }

    /// Feed every recorded destination-chain log to `rc`, deliver the callbacks it asks for, repeat until quiet.
    function _relay(address rc) internal {
        for (uint256 round; round < 10; ++round) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool any;
            for (uint256 i; i < logs.length; ++i) {
                Vm.Log memory l = logs[i];
                if (l.topics.length == 0 || l.emitter == SYSTEM) continue;
                if (!sys.matches(rc, SEPOLIA, l.emitter, uint256(l.topics[0]))) continue;
                vm.prank(SYSTEM);
                IReactive(payable(rc)).react(_rec(SEPOLIA, l));
                any = true;
            }
            if (_deliverAll()) any = true;
            if (!any) return;
        }
    }

    function _cron(address rc) internal {
        IReactive.LogRecord memory r;
        r.chainId = block.chainid;
        r.contractAddress = LEGACY;
        r.topic0 = CRON100;
        r.data = abi.encode(block.number);
        r.blockNumber = block.number;
        r.opCode = 1;
        vm.prank(SYSTEM);
        IReactive(payable(rc)).react(r);
        _deliverAll();
        _relay(rc);
    }

    function _deliverAll() internal returns (bool any) {
        MockSystem.Req[] memory q = sys.drain();
        for (uint256 i; i < q.length; ++i) {
            bool ok = proxy.deliver(q[i].recipient, q[i].gasLimit, q[i].payload, q[i].sender);
            ok ? ++delivered : ++cbFailed;
            any = true;
        }
    }

    function _rec(uint256 chainId, Vm.Log memory l) internal view returns (IReactive.LogRecord memory r) {
        r.chainId = chainId;
        r.contractAddress = l.emitter;
        r.topic0 = uint256(l.topics[0]);
        if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
        if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
        if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
        r.data = l.data;
        r.blockNumber = block.number;
        r.opCode = l.topics.length;
    }
}
