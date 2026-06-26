// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TrioraAccountToken} from "../../src/simple/TrioraAccountToken.sol";
import {TrioraLendingSimple} from "../../src/simple/TrioraLendingSimple.sol";

contract TrioraSimpleTest is Test {
    uint256 internal constant CHAINLINK_ORACLE_PK = 0xC0FFEE;

    address internal OWNER = makeAddr("OWNER");
    address internal ISSUER = makeAddr("CHAINLINK_ISSUER");
    address internal AMINA = makeAddr("AMINA");
    address internal CHAINLINK_ORACLE;
    address internal LENDER = makeAddr("LENDER");
    address internal BORROWER = makeAddr("BORROWER");
    address internal OUTSIDER = makeAddr("OUTSIDER");

    uint256 internal constant PRINCIPAL = 50000e6;
    uint256 internal constant LENDER_BALANCE = 100000e6;
    uint256 internal constant COLLATERAL = 1e8;
    uint32 internal constant LIQUIDATION_THRESHOLD_BPS = 8500;
    bytes32 internal constant LEGAL_TERMS_HASH = keccak256("LEGAL_TERMS");

    TrioraAccountToken internal cBTC;
    TrioraAccountToken internal cUSDC;
    TrioraLendingSimple internal engine;

    function setUp() public {
        vm.warp(1700000000);
        CHAINLINK_ORACLE = vm.addr(CHAINLINK_ORACLE_PK);

        cBTC = new TrioraAccountToken("Triora Custody BTC", "cBTC", 8, ISSUER, OWNER);
        cUSDC = new TrioraAccountToken("Triora Custody USDC", "cUSDC", 6, ISSUER, OWNER);
        engine = new TrioraLendingSimple(AMINA, CHAINLINK_ORACLE);

        vm.startPrank(OWNER);
        cBTC.setEngine(address(engine));
        cUSDC.setEngine(address(engine));
        vm.stopPrank();

        vm.startPrank(ISSUER);
        cBTC.mint(BORROWER, COLLATERAL, bytes32("BTC_EVIDENCE"));
        cUSDC.mint(LENDER, LENDER_BALANCE, bytes32("USDC_EVIDENCE"));
        vm.stopPrank();

        vm.startPrank(AMINA);
        engine.setApproved(LENDER, true, bytes32("KYB_LENDER"));
        engine.setApproved(BORROWER, true, bytes32("KYB_BORROWER"));
        vm.stopPrank();

        vm.prank(BORROWER);
        cBTC.approve(address(engine), type(uint256).max);

        vm.prank(LENDER);
        cUSDC.approve(address(engine), type(uint256).max);
    }

    function test_Lifecycle_FundingRepaymentRelease() public {
        bytes32 dealId = _openDeal();

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.SettlementPending));
        assertEq(engine.outstanding(dealId), 0, "no debt before funding ack");
        assertEq(cBTC.balanceOf(address(engine)), COLLATERAL, "collateral locked");
        assertEq(cUSDC.balanceOf(address(engine)), PRINCIPAL, "principal token locked");

        vm.warp(block.timestamp + 5 days);
        assertEq(engine.outstanding(dealId), 0, "interest must not start before funding");

        vm.prank(AMINA);
        engine.confirmFunding(dealId, bytes32("FUNDING_SETTLED"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.Active));
        assertEq(engine.outstanding(dealId), PRINCIPAL, "principal immediately after funding");

        vm.warp(block.timestamp + 30 days);
        uint256 quoteBeforeRequest = engine.outstanding(dealId);
        assertGt(quoteBeforeRequest, PRINCIPAL, "interest accrues after funding");

        vm.prank(BORROWER);
        uint256 quote = engine.requestRepayment(dealId);
        assertEq(quote, quoteBeforeRequest, "repayment quote snapshot");
        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.RepaymentRequested));

        vm.prank(AMINA);
        engine.confirmRepayment(dealId, bytes32("REPAYMENT_SETTLED"));
        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.ReleasePending));
        assertEq(cUSDC.balanceOf(LENDER), LENDER_BALANCE, "principal token returned to lender");

        vm.prank(AMINA);
        engine.confirmCollateralReleased(dealId, bytes32("COLLATERAL_RELEASED"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.Closed));
        assertEq(cBTC.totalSupply(), 0, "released collateral cToken burned");
        assertEq(cBTC.balanceOf(address(engine)), 0, "engine no longer holds collateral");
    }

    function test_CancelBeforeFunding_ReturnsLockedTokens() public {
        bytes32 dealId = _openDeal();

        vm.prank(AMINA);
        engine.cancelBeforeFunding(dealId, bytes32("NO_SETTLEMENT"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.Cancelled));
        assertEq(cBTC.balanceOf(BORROWER), COLLATERAL, "collateral returned");
        assertEq(cUSDC.balanceOf(LENDER), LENDER_BALANCE, "principal token returned");
        assertEq(engine.outstanding(dealId), 0, "cancelled deal has no debt");
    }

    function test_Liquidation_BurnsCollateralAndReturnsPrincipalToken() public {
        bytes32 dealId = _openFundedDeal();
        TrioraLendingSimple.LiquidationOracleReport memory initialReport =
            _liquidationReport(dealId, PRINCIPAL, 40000e6, bytes32("LIQ_INITIAL"));
        bytes memory initialSignature = _signReport(initialReport);

        vm.prank(AMINA);
        engine.requestLiquidation(dealId, initialReport, initialSignature);
        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.LiquidationPending));

        vm.warp(block.timestamp + engine.LIQUIDATION_DELAY());
        TrioraLendingSimple.LiquidationOracleReport memory finalReport =
            _liquidationReport(dealId, PRINCIPAL, 39000e6, bytes32("LIQ_FINAL"));
        bytes memory finalSignature = _signReport(finalReport);

        vm.prank(AMINA);
        engine.finalizeLiquidation(dealId, finalReport, finalSignature, bytes32("LIQUIDATION_SETTLED"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.Liquidated));
        assertEq(cBTC.totalSupply(), 0, "liquidated collateral cToken burned");
        assertEq(cUSDC.balanceOf(LENDER), LENDER_BALANCE, "principal token returned to lender");
        assertEq(engine.outstanding(dealId), 0, "liquidated deal is terminal");
    }

    function test_TokenRestrictions_BlockDirectTransfersAndUnauthorizedSupplyChanges() public {
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(TrioraAccountToken.TransferRestricted.selector, BORROWER, LENDER));
        cBTC.transfer(LENDER, 1);

        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraAccountToken.TransferRestricted.selector, LENDER, BORROWER));
        cUSDC.transfer(BORROWER, 1);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraAccountToken.OnlyIssuer.selector, OUTSIDER));
        cBTC.mint(OUTSIDER, 1, bytes32("NOPE"));

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraAccountToken.OnlyEngine.selector, OUTSIDER));
        cBTC.burnLocked(1, bytes32("NOPE"));
    }

    function test_Authorization_OnlyAminaCanOperateDealLifecycle() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.OnlyAmina.selector, OUTSIDER));
        engine.setApproved(OUTSIDER, true, bytes32("NOPE"));

        TrioraLendingSimple.OpenDealParams memory p = _defaultParams();
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.OnlyAmina.selector, OUTSIDER));
        engine.openDeal(p);

        bytes32 dealId = _openDeal();
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.OnlyAmina.selector, OUTSIDER));
        engine.confirmFunding(dealId, bytes32("NOPE"));

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.OnlyAmina.selector, OUTSIDER));
        engine.cancelBeforeFunding(dealId, bytes32("NOPE"));
    }

    function test_StateMachineGuards_BlockOutOfOrderActions() public {
        bytes32 dealId = _openDeal();

        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrioraLendingSimple.BadState.selector, dealId, TrioraLendingSimple.DealState.SettlementPending
            )
        );
        engine.requestRepayment(dealId);

        vm.prank(AMINA);
        engine.confirmFunding(dealId, bytes32("FUNDING_SETTLED"));

        vm.prank(AMINA);
        vm.expectRevert(
            abi.encodeWithSelector(TrioraLendingSimple.BadState.selector, dealId, TrioraLendingSimple.DealState.Active)
        );
        engine.confirmFunding(dealId, bytes32("FUNDING_AGAIN"));

        vm.prank(BORROWER);
        engine.requestRepayment(dealId);

        vm.prank(AMINA);
        engine.confirmRepayment(dealId, bytes32("REPAYMENT_SETTLED"));

        vm.prank(AMINA);
        engine.confirmCollateralReleased(dealId, bytes32("COLLATERAL_RELEASED"));

        TrioraLendingSimple.LiquidationOracleReport memory report =
            _liquidationReport(dealId, PRINCIPAL, 40000e6, bytes32("TOO_LATE"));
        bytes memory signature = _signReport(report);

        vm.prank(AMINA);
        vm.expectRevert(
            abi.encodeWithSelector(TrioraLendingSimple.BadState.selector, dealId, TrioraLendingSimple.DealState.Closed)
        );
        engine.requestLiquidation(dealId, report, signature);
    }

    function test_ParameterGuards_RejectInvalidDeals() public {
        TrioraLendingSimple.OpenDealParams memory p = _defaultParams();
        p.borrower = OUTSIDER;

        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.NotApproved.selector, OUTSIDER));
        engine.openDeal(p);

        p = _defaultParams();
        p.principalAmount = 0;
        vm.prank(AMINA);
        vm.expectRevert(TrioraLendingSimple.ZeroAmount.selector);
        engine.openDeal(p);

        p = _defaultParams();
        p.rateBps = 0;
        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.BadParams.selector, bytes32("RATE")));
        engine.openDeal(p);

        p = _defaultParams();
        p.maturityTs = uint64(block.timestamp);
        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.BadParams.selector, bytes32("MATURITY")));
        engine.openDeal(p);

        p = _defaultParams();
        p.legalTermsHash = bytes32(0);
        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.BadParams.selector, bytes32("REF")));
        engine.openDeal(p);
    }

    function test_LiquidationAllowedAfterRepaymentRequest() public {
        bytes32 dealId = _openFundedDeal();

        vm.prank(BORROWER);
        engine.requestRepayment(dealId);

        TrioraLendingSimple.LiquidationOracleReport memory report =
            _liquidationReport(dealId, PRINCIPAL, 40000e6, bytes32("FAILED_REPAYMENT"));
        bytes memory signature = _signReport(report);

        vm.prank(AMINA);
        engine.requestLiquidation(dealId, report, signature);

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.LiquidationPending));
    }

    function test_LiquidationRejectsHealthyOracleReport() public {
        bytes32 dealId = _openFundedDeal();
        TrioraLendingSimple.LiquidationOracleReport memory report =
            _liquidationReport(dealId, PRINCIPAL, 100000e6, bytes32("HEALTHY"));
        bytes memory signature = _signReport(report);

        vm.prank(AMINA);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrioraLendingSimple.InvalidOracleReport.selector, report.reportRef, bytes32("HEALTHY")
            )
        );
        engine.requestLiquidation(dealId, report, signature);

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.Active));
    }

    function test_LiquidationRejectsWrongOracleSigner() public {
        bytes32 dealId = _openFundedDeal();
        TrioraLendingSimple.LiquidationOracleReport memory report =
            _liquidationReport(dealId, PRINCIPAL, 40000e6, bytes32("BAD_SIGNER"));
        address badSigner = vm.addr(0xB0B);
        bytes memory outsiderSignature = _signReportWith(0xB0B, report);

        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.InvalidOracleSigner.selector, badSigner));
        engine.requestLiquidation(dealId, report, outsiderSignature);
    }

    function test_LiquidationCannotFinalizeBeforeCureWindow() public {
        bytes32 dealId = _requestLiquidation();
        TrioraLendingSimple.PendingLiquidation memory pending = engine.getPendingLiquidation(dealId);
        uint64 cureDeadline = pending.requestedAt + engine.LIQUIDATION_DELAY();
        TrioraLendingSimple.LiquidationOracleReport memory finalReport =
            _liquidationReport(dealId, PRINCIPAL, 39000e6, bytes32("EARLY_FINAL"));
        bytes memory finalSignature = _signReport(finalReport);

        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.LiquidationDelayLive.selector, dealId, cureDeadline));
        engine.finalizeLiquidation(dealId, finalReport, finalSignature, bytes32("TOO_EARLY"));
    }

    function test_LiquidationRequiresNewFinalOracleReportAfterCureWindow() public {
        bytes32 dealId = _requestLiquidation();
        TrioraLendingSimple.PendingLiquidation memory pending = engine.getPendingLiquidation(dealId);
        vm.warp(uint256(pending.requestedAt) + engine.LIQUIDATION_DELAY());

        TrioraLendingSimple.LiquidationOracleReport memory reusedReport =
            _liquidationReport(dealId, PRINCIPAL, 40000e6, pending.initialReportRef);
        bytes memory reusedSignature = _signReport(reusedReport);

        vm.prank(AMINA);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrioraLendingSimple.InvalidOracleReport.selector, reusedReport.reportRef, bytes32("REUSED")
            )
        );
        engine.finalizeLiquidation(dealId, reusedReport, reusedSignature, bytes32("REUSED"));
    }

    function test_LiquidationFinalReportMustStillBeLiquidatable() public {
        bytes32 dealId = _requestLiquidation();
        vm.warp(block.timestamp + engine.LIQUIDATION_DELAY());
        TrioraLendingSimple.LiquidationOracleReport memory healthyFinalReport =
            _liquidationReport(dealId, PRINCIPAL, 100000e6, bytes32("HEALTHY_FINAL"));
        bytes memory healthyFinalSignature = _signReport(healthyFinalReport);

        vm.prank(AMINA);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrioraLendingSimple.InvalidOracleReport.selector, healthyFinalReport.reportRef, bytes32("HEALTHY")
            )
        );
        engine.finalizeLiquidation(dealId, healthyFinalReport, healthyFinalSignature, bytes32("HEALTHY_FINAL_SETTLE"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.LiquidationPending));
    }

    function test_AnyoneCanCancelPendingLiquidationAfterCureWindow() public {
        bytes32 dealId = _requestLiquidation();

        vm.warp(block.timestamp + engine.LIQUIDATION_DELAY());
        vm.prank(OUTSIDER);
        engine.cancelPendingLiquidation(dealId, bytes32("AMINA_DID_NOT_FINALIZE"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TrioraLendingSimple.DealState.Active));
        assertEq(cBTC.balanceOf(address(engine)), COLLATERAL, "collateral remains locked");
        assertEq(cUSDC.balanceOf(address(engine)), PRINCIPAL, "principal token remains locked");
    }

    function test_CannotCancelPendingLiquidationBeforeCureWindow() public {
        bytes32 dealId = _requestLiquidation();
        TrioraLendingSimple.PendingLiquidation memory pending = engine.getPendingLiquidation(dealId);
        uint64 cureDeadline = pending.requestedAt + engine.LIQUIDATION_DELAY();

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.LiquidationDelayLive.selector, dealId, cureDeadline));
        engine.cancelPendingLiquidation(dealId, bytes32("EARLY_CANCEL"));
    }

    function testFuzz_FinalizationBeforeCureWindowAlwaysReverts(uint64 elapsedRaw) public {
        bytes32 dealId = _requestLiquidation();
        uint256 elapsed = bound(elapsedRaw, 0, engine.LIQUIDATION_DELAY() - 1);
        TrioraLendingSimple.PendingLiquidation memory pending = engine.getPendingLiquidation(dealId);
        uint64 cureDeadline = pending.requestedAt + engine.LIQUIDATION_DELAY();
        vm.warp(uint256(pending.requestedAt) + elapsed);
        TrioraLendingSimple.LiquidationOracleReport memory finalReport =
            _liquidationReport(dealId, PRINCIPAL, 39000e6, bytes32("FUZZ_FINAL"));
        bytes memory finalSignature = _signReport(finalReport);

        vm.prank(AMINA);
        vm.expectRevert(abi.encodeWithSelector(TrioraLendingSimple.LiquidationDelayLive.selector, dealId, cureDeadline));
        engine.finalizeLiquidation(dealId, finalReport, finalSignature, bytes32("FUZZ_SETTLEMENT"));
    }

    function _openFundedDeal() internal returns (bytes32 dealId) {
        dealId = _openDeal();
        vm.prank(AMINA);
        engine.confirmFunding(dealId, bytes32("FUNDING_SETTLED"));
    }

    function _requestLiquidation() internal returns (bytes32 dealId) {
        dealId = _openFundedDeal();
        TrioraLendingSimple.LiquidationOracleReport memory report =
            _liquidationReport(dealId, PRINCIPAL, 40000e6, bytes32("LIQ_INITIAL"));
        bytes memory signature = _signReport(report);
        vm.prank(AMINA);
        engine.requestLiquidation(dealId, report, signature);
    }

    function _openDeal() internal returns (bytes32 dealId) {
        TrioraLendingSimple.OpenDealParams memory p = _defaultParams();
        vm.prank(AMINA);
        dealId = engine.openDeal(p);
    }

    function _defaultParams() internal view returns (TrioraLendingSimple.OpenDealParams memory p) {
        p = TrioraLendingSimple.OpenDealParams({
            lender: LENDER,
            borrower: BORROWER,
            collateralToken: cBTC,
            principalToken: cUSDC,
            principalAmount: PRINCIPAL,
            collateralAmount: COLLATERAL,
            rateBps: 800,
            maturityTs: uint64(block.timestamp + 90 days),
            legalTermsHash: LEGAL_TERMS_HASH,
            collateralRef: bytes32("BITGO_BTC_ACCOUNT"),
            reserveRef: bytes32("BITGO_USDC_ACCOUNT"),
            borrowerReleaseRef: bytes32("BORROWER_BTC_DEST"),
            lenderSettlementRef: bytes32("LENDER_USDC_DEST"),
            aminaLiquidationRef: bytes32("AMINA_LIQ_DEST")
        });
    }

    function _liquidationReport(bytes32 dealId, uint256 debtValue, uint256 collateralValue, bytes32 reportRef)
        internal
        view
        returns (TrioraLendingSimple.LiquidationOracleReport memory report)
    {
        report = TrioraLendingSimple.LiquidationOracleReport({
            dealId: dealId,
            legalTermsHash: LEGAL_TERMS_HASH,
            collateralToken: address(cBTC),
            principalToken: address(cUSDC),
            debtValue: debtValue,
            collateralValue: collateralValue,
            liquidationThresholdBps: LIQUIDATION_THRESHOLD_BPS,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours),
            reportRef: reportRef
        });
    }

    function _signReport(TrioraLendingSimple.LiquidationOracleReport memory report)
        internal
        view
        returns (bytes memory)
    {
        return _signReportWith(CHAINLINK_ORACLE_PK, report);
    }

    function _signReportWith(uint256 signerPk, TrioraLendingSimple.LiquidationOracleReport memory report)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = engine.hashLiquidationReport(report);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
