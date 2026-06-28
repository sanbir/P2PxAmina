// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LiquidationModule} from "../../src/liquidation/LiquidationModule.sol";

/// @notice Liquidation tests (Tech Spec S8): objective trigger, fixed cure window, two-report finalize,
///         surplus-to-borrower, default shortfall, permissionless cancel, AMINA-threshold < Morpho LLTV.
contract LiquidationTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    bytes32 internal positionId;

    function setUp() public override {
        super.setUp();
        setupPledgeAndMint(pid, borrower, 10e8);
        vm.prank(amina);
        positionId = bridge.openPosition(
            borrower, pid, 500000e6, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("legal")
        );
        // fund AMINA treasury to repay Morpho on liquidation
        usdc.mint(aminaTreasury, 2000000e6);
        vm.prank(aminaTreasury);
        usdc.approve(address(bridge), type(uint256).max);
    }

    function _report(uint256 coll, uint256 debt, bytes32 ref)
        internal
        view
        returns (LiquidationModule.LiquidationReport memory)
    {
        return LiquidationModule.LiquidationReport({
            positionId: positionId,
            collateralValue: coll,
            debtValue: debt,
            thresholdBps: 7800,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 7 days),
            reportRef: ref
        });
    }

    function _dropPrice(uint256 price) internal {
        feed.set(int256(price * 1e8), block.timestamp);
    }

    function test_invariant_aminaThresholdBelowMorphoLltv() public view {
        Types.MarketParams memory mp = risk.getParams(marketId);
        assertLt(mp.aminaLiquidationBps, mp.morphoLltvBps);
        assertLt(mp.aminaWarningBps, mp.aminaLiquidationBps);
        assertLt(mp.ltvBps, mp.aminaWarningBps);
    }

    function test_warn_setsWarnedState() public {
        _dropPrice(60000); // LTV ~83% > warning 75%
        vm.prank(aminaBot);
        module.warn(positionId);
        assertEq(uint8(bridge.getPosition(positionId).state), uint8(Types.PositionState.Warned));
    }

    function test_warn_revertsWhenHealthy() public {
        vm.prank(aminaBot);
        vm.expectRevert(Errors.StillHealthy.selector);
        module.warn(positionId);
    }

    function test_request_requiresObjectiveBreach() public {
        _dropPrice(60000);
        // not-a-breach report (debt/coll below threshold) -> StillHealthy
        LiquidationModule.LiquidationReport memory r = _report(1000000, 100000, keccak256("r0"));
        bytes memory sig = signLiqReport(r);
        vm.prank(aminaBot);
        vm.expectRevert(Errors.StillHealthy.selector);
        module.requestLiquidation(r, sig);
    }

    function test_request_badSignature_reverts() public {
        _dropPrice(60000);
        LiquidationModule.LiquidationReport memory r = _report(600000, 500000, keccak256("r1"));
        bytes memory badSig = signLiqReport(r);
        // tamper: change debtValue after signing
        r.debtValue = 510000;
        vm.prank(aminaBot);
        vm.expectRevert(Errors.BadSignature.selector);
        module.requestLiquidation(r, badSig);
    }

    function test_finalizeBeforeCure_reverts() public {
        _dropPrice(60000);
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, keccak256("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));

        LiquidationModule.LiquidationReport memory r2 = _report(600000, 500000, keccak256("r2"));
        vm.prank(aminaBot);
        vm.expectRevert(); // CureWindowNotElapsed
        module.finalizeLiquidation(r2, signLiqReport(r2));
    }

    function test_finalize_reusedReport_reverts() public {
        _dropPrice(60000);
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, keccak256("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        vm.warp(block.timestamp + 1 days + 1);
        // reuse same ref -> ReportReused (also already-used)
        vm.prank(aminaBot);
        vm.expectRevert();
        module.finalizeLiquidation(r1, signLiqReport(r1));
    }

    function test_fullLiquidation_surplusToBorrower() public {
        _dropPrice(60000); // coll ~$600k, debt ~$500k
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, keccak256("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        assertEq(uint8(bridge.getPosition(positionId).state), uint8(Types.PositionState.LiquidationPending));

        vm.warp(block.timestamp + 1 days + 1);
        LiquidationModule.LiquidationReport memory r2 = _report(600000, 500000, keccak256("r2"));
        vm.prank(aminaBot);
        module.finalizeLiquidation(r2, signLiqReport(r2));

        // executed: collateral withdrawn, vouchers issued, Morpho debt repaid by AMINA
        assertTrue(bridge.liqExecuted(positionId));
        (, uint256 morphoDebt) = morpho.position(address(adapter));
        assertEq(morphoDebt, 0, "morpho debt cleared by AMINA");

        bytes32 vSurplus = bridge.voucherSurplus(positionId);
        assertTrue(vSurplus != bytes32(0), "surplus voucher issued");
        assertEq(release.getVoucher(vSurplus).destination, borrower, "surplus -> borrower");

        bytes32 vPrimary = bridge.voucherPrimary(positionId);
        assertEq(release.getVoucher(vPrimary).destination, aminaDesk, "seized -> AMINA desk");

        // settlement ack burns cBTC and finalizes
        vm.prank(custodyListener);
        bridge.confirmRelease(positionId);
        assertEq(uint8(bridge.getPosition(positionId).state), uint8(Types.PositionState.Liquidated));
        assertEq(cbtc.totalSupply(), 0, "all cBTC burned");

        // surplus + seized sum to the original collateral
        uint256 seized = release.getVoucher(vPrimary).amount;
        uint256 surplus = release.getVoucher(vSurplus).amount;
        assertEq(seized + surplus, 10e8, "seized + surplus == collateral");
        assertGt(surplus, 0, "borrower keeps surplus");
    }

    function test_underwater_marksDefaulted_noSurplus() public {
        _dropPrice(50000); // coll $500k ~= debt -> payout(1.06x) exceeds collateral
        LiquidationModule.LiquidationReport memory r1 = _report(500000, 500000, keccak256("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));
        vm.warp(block.timestamp + 1 days + 1);
        LiquidationModule.LiquidationReport memory r2 = _report(500000, 500000, keccak256("r2"));
        vm.prank(aminaBot);
        module.finalizeLiquidation(r2, signLiqReport(r2));

        assertTrue(bridge.liqDefaulted(positionId));
        assertEq(bridge.voucherSurplus(positionId), bytes32(0), "no surplus voucher");
        vm.prank(custodyListener);
        bridge.confirmRelease(positionId);
        assertEq(uint8(bridge.getPosition(positionId).state), uint8(Types.PositionState.Defaulted));
    }

    function test_cancelPendingLiquidation_afterWindow_byAnyone() public {
        _dropPrice(60000);
        LiquidationModule.LiquidationReport memory r1 = _report(600000, 500000, keccak256("r1"));
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1));

        // before window: cannot cancel
        vm.prank(stranger);
        vm.expectRevert();
        module.cancelPendingLiquidation(positionId);

        // after window, not finalized -> anyone can cancel back to Active
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(stranger);
        module.cancelPendingLiquidation(positionId);
        assertEq(uint8(bridge.getPosition(positionId).state), uint8(Types.PositionState.Active));
    }

    function test_maturity_allowsLiquidation() public {
        // healthy price but matured -> liquidation eligible
        vm.warp(block.timestamp + 91 days); // past 90-day maturity
        feed.set(int256(BTC_PRICE_1E8), block.timestamp); // refresh feed
        LiquidationModule.LiquidationReport memory r1 = _report(1000000, 500000, keccak256("r1")); // not a breach
        vm.prank(aminaBot);
        module.requestLiquidation(r1, signLiqReport(r1)); // allowed because matured
        assertEq(uint8(bridge.getPosition(positionId).state), uint8(Types.PositionState.LiquidationPending));
    }
}
