// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Harness, MockProxy } from "./Harness.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { LastlightVault } from "../src/LastlightVault.sol";
import { LastlightFactory } from "../src/LastlightFactory.sol";
import { LastlightReactive } from "../src/LastlightReactive.sol";

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract Refuser {
    receive() external payable {
        revert("no");
    }
}

contract LastlightTest is Harness {
    LastlightReactive rc;
    LastlightFactory factory;
    LastlightVault vault;
    Token token;

    address alice = makeAddr("alice"); // vault owner
    address heirA = makeAddr("heirA");
    address heirB = makeAddr("heirB");

    uint64 constant HEARTBEAT = 30 days;
    uint64 constant LEAD = 3 days;
    uint256 constant RESERVE = 0.01 ether;

    function setUp() public {
        vm.warp(1_800_000_000);
        _setUpMocks();
        rc = new LastlightReactive{ value: 1 ether }(SEPOLIA, CRON100);
        factory = new LastlightFactory(IPayable(payable(address(proxy))), address(rc));
        rc.setFactory(address(factory));
        token = new Token();
        vault = _create(alice, 10 ether);
    }

    function _create(address who, uint256 value) internal returns (LastlightVault v) {
        address[] memory heirs = new address[](2);
        heirs[0] = heirA;
        heirs[1] = heirB;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.deal(who, value);
        vm.prank(who);
        v = factory.create{ value: value }(HEARTBEAT, LEAD, RESERVE, heirs, shares, tokens);
        _relay(address(rc));
    }

    function test_factoryVaultIsGuarded() public view {
        assertEq(rc.watchedCount(), 1);
        (uint64 d, uint64 w,,, LastlightReactive.Status s) = rc.guards(address(vault));
        assertEq(d, vault.deadline());
        assertEq(w, vault.deadline() - LEAD);
        assertEq(uint8(s), uint8(LastlightReactive.Status.Active));
        // cron + factory + CheckIn + Released
        assertEq(sys.activeSubs(), 4);
    }

    function test_quietBeforeWarnWindow() public {
        vm.warp(block.timestamp + 10 days);
        _cron(address(rc));
        assertEq(delivered, 0);
        assertFalse(vault.released());
    }

    function test_fullLoop_warnThenReleaseThenStop() public {
        token.mint(address(vault), 1000e18);

        vm.warp(vault.deadline() - LEAD + 1);
        _cron(address(rc));
        assertEq(delivered, 1);
        assertEq(cbFailed, 0);
        assertFalse(vault.released());

        // A second tick inside the warn window does nothing more.
        _cron(address(rc));
        assertEq(delivered, 1);

        vm.warp(vault.deadline());
        _cron(address(rc));
        assertEq(delivered, 2);
        assertTrue(vault.released());

        uint256 pot = 10 ether - RESERVE;
        assertEq(heirA.balance, pot * 6000 / 10_000);
        assertEq(heirB.balance, pot * 4000 / 10_000);
        assertEq(address(vault).balance, RESERVE);
        assertEq(token.balanceOf(heirA), 600e18);
        assertEq(token.balanceOf(heirB), 400e18);

        // Released event made the reactive side stop watching and drop the vault's subscriptions.
        (,,,, LastlightReactive.Status s) = rc.guards(address(vault));
        assertEq(uint8(s), uint8(LastlightReactive.Status.Done));
        assertEq(rc.watchedCount(), 0);
        assertEq(sys.activeSubs(), 2);

        vm.warp(block.timestamp + 365 days);
        _cron(address(rc));
        assertEq(delivered, 2);
    }

    function test_checkInAfterWarningResetsTheClock() public {
        vm.warp(vault.deadline() - LEAD + 1);
        _cron(address(rc));
        assertEq(delivered, 1);

        vm.prank(alice);
        vault.checkIn();
        _relay(address(rc));
        (uint64 d,,,, LastlightReactive.Status s) = rc.guards(address(vault));
        assertEq(d, block.timestamp + HEARTBEAT);
        assertEq(uint8(s), uint8(LastlightReactive.Status.Active));

        vm.warp(block.timestamp + 5 days);
        _cron(address(rc));
        assertEq(delivered, 1);
        assertFalse(vault.released());
    }

    function test_ownerActionsCountAsProofOfLife() public {
        vm.warp(block.timestamp + 20 days);
        vm.prank(alice);
        vault.withdraw(payable(alice), 1 ether);
        _relay(address(rc));
        assertEq(vault.deadline(), block.timestamp + HEARTBEAT);
        (uint64 d,,,,) = rc.guards(address(vault));
        assertEq(d, vault.deadline());
    }

    function test_vaultRejectsEarlyRelease_clockSkew() public {
        // A correctly-authenticated release that arrives before the vault's own deadline does nothing.
        vm.warp(vault.deadline() - 1);
        bytes memory p = abi.encodeWithSignature("release(address)", address(0));
        assertTrue(proxy.deliver(address(vault), 1_000_000, p, address(rc)));
        assertFalse(vault.released());
        assertEq(heirA.balance, 0);
    }

    function test_retryAfterFailedCallback() public {
        uint256 d = vault.deadline();
        vm.warp(d);
        // Tick fires, but the callback is dropped (e.g. destination outage): drain without delivering.
        {
            vm.prank(SYSTEM);
            rc.react(_cronRec());
            sys.drain();
        }
        assertFalse(vault.released());
        (,,, uint8 tries, LastlightReactive.Status s) = rc.guards(address(vault));
        assertEq(tries, 1);
        assertEq(uint8(s), uint8(LastlightReactive.Status.ReleaseRequested));

        vm.warp(d + 10 minutes);
        _cron(address(rc));
        assertFalse(vault.released()); // too soon to retry

        vm.warp(d + 31 minutes);
        _cron(address(rc));
        assertTrue(vault.released());
    }

    function test_forgedCallsRejected() public {
        vm.warp(vault.deadline() + 1);
        // Not via the proxy.
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy))
        );
        vault.release(address(rc));

        // Via the proxy, but requested by some other reactive contract.
        address evil = makeAddr("evil");
        bytes memory p = abi.encodeWithSignature("release(address)", address(0));
        assertFalse(proxy.deliver(address(vault), 1_000_000, p, evil));
        assertFalse(vault.released());
    }

    function test_reactOnlyFromSystem() public {
        vm.expectRevert();
        rc.react(_cronRec());
    }

    function test_strangerCannotCheckIn() public {
        vm.expectRevert(LastlightVault.NotOwner.selector);
        vault.checkIn();
    }

    function test_pauseStopsCronBilling() public {
        uint256 before = sys.activeSubs();
        rc.pause();
        assertEq(sys.activeSubs(), before - 1);
        rc.resume();
        assertEq(sys.activeSubs(), before);
    }

    function test_manyVaults_roundRobin() public {
        rc.setMaxPerTick(2);
        for (uint256 i; i < 4; ++i) {
            _create(makeAddr(string(abi.encodePacked("o", i))), 1 ether);
        }
        assertEq(rc.watchedCount(), 5);
        vm.warp(block.timestamp + HEARTBEAT + 1);
        _cron(address(rc));
        _cron(address(rc));
        _cron(address(rc));
        assertEq(rc.watchedCount(), 0);
    }

    function test_refusingHeirCanStillBeOwed() public {
        Refuser r = new Refuser();
        address[] memory heirs = new address[](2);
        heirs[0] = heirA;
        heirs[1] = address(r);
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;
        vm.prank(alice);
        vault.setPlan(HEARTBEAT, LEAD, heirs, shares, new address[](0));
        _relay(address(rc));
        vm.warp(vault.deadline());
        _cron(address(rc));
        assertTrue(vault.released());
        assertEq(vault.owedEth(address(r)), (10 ether - RESERVE) / 2);
    }

    function test_badPlansRejected() public {
        address[] memory heirs = new address[](1);
        heirs[0] = heirA;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 9999;
        vm.prank(alice);
        vm.expectRevert(LastlightVault.BadConfig.selector);
        vault.setPlan(HEARTBEAT, LEAD, heirs, shares, new address[](0));
    }

    function _cronRec() internal view returns (LastlightReactive.LogRecord memory r) {
        r.chainId = block.chainid;
        r.contractAddress = LEGACY;
        r.topic0 = CRON100;
        r.opCode = 1;
    }
}
