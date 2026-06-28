// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Types} from "../../src/libraries/Types.sol";
import {TrioraMath} from "../../src/libraries/TrioraMath.sol";

/// @notice Property/fuzz tests for origination LTV bound and repay accounting.
contract FuzzTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    uint256 internal maxBorrow; // USDC

    function setUp() public override {
        super.setUp();
        setupPledgeAndMint(pid, borrower, 10e8);
        // 10 BTC * $100k * 70% = $700,000 → 700_000e6 USDC
        uint256 collUsd = TrioraMath.usdValue(10e8, 8, BTC_PRICE_1E8);
        maxBorrow = (collUsd * 7000 / 1e4) / 1e2;
    }

    function testFuzz_openPosition_respectsLtv(uint256 principal) public {
        principal = bound(principal, 1, maxBorrow * 2);
        vm.prank(amina);
        if (principal <= maxBorrow) {
            bytes32 id = bridge.openPosition(
                borrower, pid, principal, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l")
            );
            assertEq(bridge.getPosition(id).principal, principal);
            assertEq(usdc.balanceOf(borrower), principal);
        } else {
            vm.expectRevert();
            bridge.openPosition(borrower, pid, principal, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l"));
        }
    }

    function testFuzz_partialRepay_reducesOutstanding(uint256 elapsed, uint256 repayAmt) public {
        elapsed = bound(elapsed, 0, 89 days);
        vm.prank(amina);
        bytes32 id =
            bridge.openPosition(borrower, pid, 500000e6, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l"));
        vm.warp(block.timestamp + elapsed);

        uint256 owed = bridge.currentOutstanding(id);
        repayAmt = bound(repayAmt, 1, owed - 1); // strictly partial
        usdc.mint(borrower, repayAmt); // ensure funds
        vm.startPrank(borrower);
        usdc.approve(address(bridge), repayAmt);
        bridge.repay(id, repayAmt);
        vm.stopPrank();

        Types.Position memory p = bridge.getPosition(id);
        assertEq(uint8(p.state), uint8(Types.PositionState.Active));
        assertEq(p.outstanding, owed - repayAmt);
        assertEq(bridge.borrowerDebt(borrower), owed - repayAmt);
    }

    function testFuzz_interest_matchesFormula(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 90 days);
        vm.prank(amina);
        bytes32 id =
            bridge.openPosition(borrower, pid, 500000e6, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l"));
        vm.warp(block.timestamp + elapsed);
        uint256 expected = 500000e6 + TrioraMath.linearInterest(500000e6, RATE_BPS, elapsed);
        assertEq(bridge.currentOutstanding(id), expected);
    }
}
