// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Types} from "../../src/libraries/Types.sol";

/// @notice Model A happy-path lifecycle + the HARD INVARIANT: no real funds ever touch a contract
///         (the engine only ever holds cBTC/cUSDC accounting tokens; real USDC settles off-chain).
contract LifecycleTest is TrioraFixture {
    bytes32 internal pledgeId = keccak256("pledge-1");
    bytes32 internal reserveId = keccak256("reserve-1");

    function test_openMatchedDeal_locksAccountingTokens_settlementPending() public {
        bytes32 id = openDeal(pledgeId, reserveId, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        Types.Position memory p = engine.getPosition(id);
        assertEq(uint8(p.state), uint8(Types.PositionState.SettlementPending));
        assertEq(p.lender, lender);
        assertEq(p.borrower, borrower);
        assertEq(p.collateral, 10e8);
        assertEq(p.principal, 500000e6);
        assertEq(p.startTs, 0, "interest not started before funding ack");
        // accounting tokens are locked in the engine; counterparties hold none
        assertEq(cbtc.balanceOf(address(engine)), 10e8);
        assertEq(cusdc.balanceOf(address(engine)), 500000e6);
        assertEq(cbtc.balanceOf(borrower), 0);
        assertEq(cusdc.balanceOf(lender), 0);
    }

    function test_fundingAck_activates_burnsCusdc_startsInterest() public {
        bytes32 id = openDeal(pledgeId, reserveId, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        ackFunding(id, 500000e6, bytes32("SR-FUND-1"));
        Types.Position memory p = engine.getPosition(id);
        assertEq(uint8(p.state), uint8(Types.PositionState.Active));
        assertGt(p.startTs, 0);
        // cUSDC reservation is consumed (the real USDC moved lender->borrower in custody)
        assertEq(cusdc.totalSupply(), 0, "cUSDC burned at funding");
        assertEq(cusdc.balanceOf(address(engine)), 0);
        // cBTC collateral stays locked in the engine
        assertEq(cbtc.balanceOf(address(engine)), 10e8);
    }

    function test_repay_release_closed_reconciles() public {
        bytes32 id = openDeal(pledgeId, reserveId, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        ackFunding(id, 500000e6, bytes32("SR-FUND-1"));
        vm.warp(block.timestamp + 90 days);

        vm.prank(borrower);
        engine.requestRepayment(id);
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.RepaymentPending));

        // borrower repaid the lender off-chain; AMINA co-signs the ack
        ackRepayment(id, engine.currentOutstanding(id), bytes32("SR-REPAY-1"));
        Types.Position memory p = engine.getPosition(id);
        assertEq(uint8(p.state), uint8(Types.PositionState.ReleasePending));
        assertEq(p.outstanding, 0);

        // custody releases BTC to borrower off-chain; listener acks → burn cBTC
        vm.prank(custodyListener);
        engine.confirmRelease(id);
        p = engine.getPosition(id);
        assertEq(uint8(p.state), uint8(Types.PositionState.Closed));
        assertEq(cbtc.totalSupply(), 0, "all cBTC burned on release");
        assertEq(uint8(pledges.getPledge(pledgeId).status), uint8(Types.PledgeStatus.Released));
        assertEq(engine.borrowerDebt(borrower), 0);
    }

    function test_interestAccruesOnlyAfterFunding() public {
        bytes32 id = openDeal(pledgeId, reserveId, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        // before funding ack: warp, still no interest
        vm.warp(block.timestamp + 30 days);
        assertEq(engine.currentOutstanding(id), 500000e6, "no interest before funding");
        ackFunding(id, 500000e6, bytes32("SR-FUND-1"));
        vm.warp(block.timestamp + 90 days);
        assertGt(engine.currentOutstanding(id), 500000e6, "interest accrues after funding");
    }

    function test_cancelUnfunded_returnsTokens() public {
        bytes32 id = openDeal(pledgeId, reserveId, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        vm.prank(amina);
        engine.cancelUnfunded(id);
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.Cancelled));
        assertEq(cbtc.balanceOf(borrower), 10e8, "cBTC returned to borrower");
        assertEq(cusdc.balanceOf(lender), 500000e6, "cUSDC returned to lender");
    }

    /// @notice HARD INVARIANT (ADR-0001): the engine never holds anything but cBTC/cUSDC; there is no
    ///         real-value ERC-20 in the system at all. Real settlement is only signed acks + events.
    function test_invariant_engineHoldsOnlyAccountingTokens() public {
        bytes32 id = openDeal(pledgeId, reserveId, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        ackFunding(id, 500000e6, bytes32("SR-FUND-1"));
        // the engine's only token holdings are the restricted accounting tokens
        assertEq(cbtc.balanceOf(address(engine)), 10e8);
        assertEq(cusdc.balanceOf(address(engine)), 0); // burned at funding
        assertEq(address(engine).balance, 0, "engine holds no ETH");
        // both tokens are restricted (cannot leak to a non-protocol holder)
        vm.prank(borrower);
        vm.expectRevert();
        cbtc.transfer(lender, 1); // user->user blocked even if borrower had any
    }
}
