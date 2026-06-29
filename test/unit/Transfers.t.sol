// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Restricted accounting-token transfers (Model A): at least one side must be a protocol
///         address (engine); user↔user blocked; pause/freeze honored. Applies to cBTC and cUSDC.
contract TransfersTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    bytes32 internal rid = keccak256("r");

    function setUp() public override {
        super.setUp();
        setupBorrowerCbtc(pid, 10e8); // borrower holds 10 cBTC
        setupLenderCusdc(rid, 500000e6); // lender holds 500k cUSDC
    }

    function test_cbtc_userToUser_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferRestricted.selector, borrower, lender));
        cbtc.transfer(lender, 1e8);
    }

    function test_cbtc_userToEngine_ok() public {
        vm.prank(borrower);
        cbtc.transfer(address(engine), 1e8); // engine is a protocol address
        assertEq(cbtc.balanceOf(address(engine)), 1e8);
    }

    function test_cusdc_userToUser_reverts() public {
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferRestricted.selector, lender, borrower));
        cusdc.transfer(borrower, 1e6);
    }

    function test_cbtc_frozen_blocks() public {
        vm.prank(amina); // GUARDIAN
        cbtc.setFrozen(borrower, true);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferRestricted.selector, borrower, address(engine)));
        cbtc.transfer(address(engine), 1e8);
    }

    function test_cbtc_paused_blocks() public {
        vm.prank(amina);
        cbtc.pause();
        vm.prank(borrower);
        vm.expectRevert(Errors.Paused.selector);
        cbtc.transfer(address(engine), 1e8);
    }
}
