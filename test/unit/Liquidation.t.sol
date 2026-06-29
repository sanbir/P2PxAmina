// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LiquidationModule} from "../../src/liquidation/LiquidationModule.sol";

/// @notice Model A liquidation (Tech Spec S8): objective signed-report trigger + cure window + two-report
///         finalize + surplus-to-borrower. NO real USDC moves on-chain (the lender is repaid off-chain
///         from AMINA's sale of the released BTC) — only cBTC release vouchers are issued.
contract LiquidationTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    bytes32 internal rid = keccak256("r");
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        id = openDeal(pid, rid, 10e8, 500000e6, uint64(block.timestamp + 90 days));
        ackFunding(id, 500000e6, bytes32("f1")); // Active
    }

    function _report(uint256 coll, uint256 debt, bytes32 ref)
        internal
        view
        returns (LiquidationModule.LiquidationReport memory)
    {
        return LiquidationModule.LiquidationReport({
            positionId: id,
            collateralValue: coll,
            debtValue: debt,
            thresholdBps: 7800,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 7 days),
            reportRef: ref
        });
    }

    function _drop(uint256 price) internal {
        feed.set(int256(price * 1e8), block.timestamp);
    }

    function test_warn_setsWarned() public {
        _drop(60000);
        vm.prank(aminaBot);
        module.warn(id);
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.Warned));
    }

    function test_request_requiresBreachOrMaturity() public {
        _drop(60000);
        LiquidationModule.LiquidationReport memory r = _report(1000000, 100000, bytes32("r0"));
        vm.prank(aminaBot);
        vm.expectRevert(Errors.StillHealthy.selector);
        module.requestLiquidation(r, signLiqReport(r));
    }

    function test_finalizeBeforeCure_reverts() public {
        _drop(60000);
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, bytes32("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        LiquidationModule.LiquidationReport memory r2 = _report(600000, 500000, bytes32("r2"));
        vm.prank(aminaBot);
        vm.expectRevert();
        module.finalizeLiquidation(r2, signLiqReport(r2));
    }

    function test_fullLiquidation_surplusToBorrower_noUsdcMoves() public {
        _drop(60000); // coll ~$600k, debt ~$500k → LTV ~83% > 78%
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, bytes32("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        vm.warp(block.timestamp + 1 days + 1);
        LiquidationModule.LiquidationReport memory r2 = _report(600000, 500000, bytes32("r2"));
        vm.prank(aminaBot);
        module.finalizeLiquidation(r2, signLiqReport(r2));

        assertTrue(engine.liqExecuted(id));
        bytes32 vSeized = engine.voucherPrimary(id);
        bytes32 vSurplus = engine.voucherSurplus(id);
        assertEq(release.getVoucher(vSeized).destination, aminaDesk, "seized -> AMINA desk");
        assertTrue(vSurplus != bytes32(0));
        assertEq(release.getVoucher(vSurplus).destination, borrower, "surplus -> borrower");

        vm.prank(custodyListener);
        engine.confirmRelease(id);
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.Liquidated));
        assertEq(cbtc.totalSupply(), 0, "all cBTC burned");
        // seized + surplus == original collateral
        assertEq(release.getVoucher(vSeized).amount + release.getVoucher(vSurplus).amount, 10e8);
    }

    function test_underwater_marksDefaulted() public {
        _drop(50000); // coll ~$500k ≈ debt → payout(1.06x) exceeds collateral
        LiquidationModule.LiquidationReport memory r1 = _report(500000, 500000, bytes32("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        vm.warp(block.timestamp + 1 days + 1);
        LiquidationModule.LiquidationReport memory r2 = _report(500000, 500000, bytes32("r2"));
        vm.prank(aminaBot);
        module.finalizeLiquidation(r2, signLiqReport(r2));
        assertTrue(engine.liqDefaulted(id));
        assertEq(engine.voucherSurplus(id), bytes32(0));
        vm.prank(custodyListener);
        engine.confirmRelease(id);
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.Defaulted));
    }

    function test_cancelAfterWindow_byAnyone() public {
        _drop(60000);
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, bytes32("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        vm.prank(stranger);
        vm.expectRevert();
        module.cancelPendingLiquidation(id); // before window
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(stranger);
        module.cancelPendingLiquidation(id);
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.Active));
    }

    function test_thresholdLadder_invariant() public view {
        Types.MarketParams memory mp = risk.getParams(marketId);
        assertLt(mp.ltvBps, mp.aminaWarningBps);
        assertLt(mp.aminaWarningBps, mp.aminaLiquidationBps);
        assertLe(mp.aminaLiquidationBps, 10000);
    }
}
