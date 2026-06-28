// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice cBTC transfer-restriction tests (Tech Spec S4) — checks BOTH from and to, pause, freeze.
contract TransfersTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");

    function setUp() public override {
        super.setUp();
        setupPledgeAndMint(pid, borrower, 10e8); // bridge holds 10 cBTC
    }

    function test_transfer_bridgeToNonProtocol_reverts() public {
        vm.prank(address(bridge));
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferRestricted.selector, address(bridge), stranger));
        cbtc.transfer(stranger, 1e8);
    }

    function test_transfer_bridgeToProtocol_ok() public {
        vm.prank(address(bridge));
        cbtc.transfer(address(adapter), 1e8);
        assertEq(cbtc.balanceOf(address(adapter)), 1e8);
    }

    function test_transfer_protocolToNonProtocol_reverts() public {
        // adapter is protocol; move some cBTC there then attempt adapter→stranger
        vm.prank(address(bridge));
        cbtc.transfer(address(adapter), 1e8);
        vm.prank(address(adapter));
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferRestricted.selector, address(adapter), stranger));
        cbtc.transfer(stranger, 1e8);
    }

    function test_frozen_blocksTransfer() public {
        vm.prank(amina); // GUARDIAN
        cbtc.setFrozen(address(adapter), true);
        vm.prank(address(bridge));
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferRestricted.selector, address(bridge), address(adapter)));
        cbtc.transfer(address(adapter), 1e8);
    }

    function test_paused_blocksTransfer() public {
        vm.prank(amina); // GUARDIAN can pause
        cbtc.pause();
        vm.prank(address(bridge));
        vm.expectRevert(Errors.Paused.selector);
        cbtc.transfer(address(adapter), 1e8);
    }

    function test_setFrozen_onlyGuardian() public {
        vm.prank(stranger);
        vm.expectRevert();
        cbtc.setFrozen(address(adapter), true);
    }
}
