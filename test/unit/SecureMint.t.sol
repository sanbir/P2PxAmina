// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Secure-mint guards for BOTH accounting tokens (cBTC pledge side, cUSDC reserve side).
contract SecureMintTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    bytes32 internal rid = keccak256("r");

    function test_cbtc_mint_happy_toBorrower() public {
        attestReserve(address(cbtc), 100e8, 8);
        attestPledge(pid, address(cbtc), 10e8, 8);
        vm.prank(amina);
        pledges.registerPledge(pid, borrower, bytes32("acct"), 10e8, bytes32("ctrl"));
        vm.prank(issuer);
        cbtc.mintForPledge(borrower, pid, 10e8);
        assertEq(cbtc.balanceOf(borrower), 10e8);
    }

    function test_cbtc_mint_exceedsReserve_reverts() public {
        attestReserve(address(cbtc), 5e8, 8);
        attestPledge(pid, address(cbtc), 10e8, 8);
        vm.prank(amina);
        pledges.registerPledge(pid, borrower, bytes32("acct"), 10e8, bytes32("ctrl"));
        vm.prank(issuer);
        vm.expectRevert(); // ReserveExceeded (6 > 5 - margin)
        cbtc.mintForPledge(borrower, pid, 6e8);
    }

    function test_cbtc_mint_staleReserve_failClosed() public {
        attestReserve(address(cbtc), 100e8, 8);
        attestPledge(pid, address(cbtc), 10e8, 8);
        vm.prank(amina);
        pledges.registerPledge(pid, borrower, bytes32("acct"), 10e8, bytes32("ctrl"));
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(issuer);
        vm.expectRevert(Errors.ReserveStale.selector);
        cbtc.mintForPledge(borrower, pid, 10e8);
    }

    function test_cbtc_mint_onlyIssuer() public {
        attestReserve(address(cbtc), 100e8, 8);
        attestPledge(pid, address(cbtc), 10e8, 8);
        vm.prank(amina);
        pledges.registerPledge(pid, borrower, bytes32("acct"), 10e8, bytes32("ctrl"));
        vm.prank(stranger);
        vm.expectRevert();
        cbtc.mintForPledge(borrower, pid, 10e8);
    }

    function test_cusdc_mint_happy_toLender_andReserveGuarded() public {
        attestReserve(address(cusdc), 1000000e6, 6);
        attestPledge(rid, address(cusdc), 500000e6, 6);
        vm.prank(amina);
        reserves.registerReserve(rid, lender, bytes32("acct"), 500000e6, bytes32("ctrl"));
        vm.prank(issuer);
        cusdc.mintForReserve(lender, rid, 500000e6);
        assertEq(cusdc.balanceOf(lender), 500000e6);
    }

    function test_cusdc_mint_exceedsReserve_reverts() public {
        attestReserve(address(cusdc), 100000e6, 6); // reserve only 100k
        attestPledge(rid, address(cusdc), 500000e6, 6);
        vm.prank(amina);
        reserves.registerReserve(rid, lender, bytes32("acct"), 500000e6, bytes32("ctrl"));
        vm.prank(issuer);
        vm.expectRevert(); // ReserveExceeded
        cusdc.mintForReserve(lender, rid, 200000e6);
    }
}
