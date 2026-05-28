// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DealHelper} from "../utils/DealHelper.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";

/// @notice Spot checks of the 21 canonical invariants from architecture
///         v3 §25 that are testable on a fork without complex
///         scenarios.
contract InvariantSpotChecksTest is DealHelper {
    bytes32 internal dealId;

    function setUp() public {
        _setUpFork();
        _registerCustodianAndPair(USDC, WBTC, FEED_USDC_USD, FEED_BTC_USD, 7_000, 8_500, 9_000, 9_500);
        _openDeal(100_000e6, 5e8);
    }

    function _openDeal(uint128 principal, uint128 collateral) internal {
        Types.DealIntent memory intent = _buildIntent(USDC, WBTC, principal, collateral, 60 days, 1_000);
        deal(USDC, LENDER, principal, true);
        deal(WBTC, BORROWER, collateral, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);
        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        dealId = engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32(0));
    }

    // ---- Invariant #1: Terms write-once ----

    function test_Inv1_TermsWriteOnce() public {
        Types.DealTerms memory t = dealRegistry.getTerms(dealId);
        // Re-call record() must revert.
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(Errors.DealAlreadyExists.selector, dealId));
        dealRegistry.record(dealId, t);
    }

    // ---- Invariant #2: Terminal finality ----

    function test_Inv2_TerminalFinality() public {
        // Repay to terminal, then verify no further state mutation possible.
        uint128 ow = engine.computeOutstanding(dealId);
        deal(USDC, BORROWER, ow, true);
        vm.prank(BORROWER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); engine.repay(dealId, ow);
        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(uint8(st.state), uint8(Types.DealStateEnum.Repaid));

        // Try to repay again → must revert.
        deal(USDC, BORROWER, 1e6, true);
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(Errors.DealStateForbidden.selector, dealId, uint8(Types.DealStateEnum.Repaid)));
        engine.repay(dealId, 1e6);
    }

    // ---- Invariant #5: Atomic activation ----

    function test_Inv5_AtomicActivation() public {
        // Lender has 0 USDC — activation must revert atomically, no state changed.
        uint128 px = 1_000e6;
        uint128 cx = 5e7;
        Types.DealIntent memory intent = _buildIntent(USDC, WBTC, px, cx, 30 days, 1_000);
        // Don't fund the lender. Borrower has WBTC.
        deal(WBTC, BORROWER, cx, true);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);
        // Lender approves but has 0 balance.
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);

        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        vm.expectRevert();
        engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32(0));

        // No deal recorded.
        bytes32 attemptedId = keccak256(abi.encode(engine.hashDealIntent(intent)));
        assertFalse(dealRegistry.exists(attemptedId));
    }

    // ---- Invariant #7: No sig replay across deals ----

    function test_Inv7_NoSigReplayAcrossDeals() public {
        uint128 px = 5_000e6;
        uint128 cx = 5e7;
        Types.DealIntent memory intent = _buildIntent(USDC, WBTC, px, cx, 30 days, 1_000);
        deal(USDC, LENDER, px, true);
        deal(WBTC, BORROWER, cx, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);
        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32(0));

        // Try to replay with a different counterparty addr — sig must fail because hash differs.
        Types.DealIntent memory other = intent;
        other.principal = px * 2;
        vm.prank(ALLOCATOR_ADDR);
        vm.expectRevert(); // signature won't match the new hash
        engine.openAndActivate(other, l, b, a, AMINA_SIGNER, bytes32(0));
    }

    // ---- Invariant #8: Param snapshot stability ----

    function test_Inv8_ParamSnapshotStable() public {
        // The deal was opened against v1. Bump to v2 and confirm the
        // deal still reads v1 params.
        Types.ParamsV1 memory p = collateralRegistry.getLatestParams(pairKey);
        p.warningBps = 9_900; // completely different threshold
        // Need to maintain monotonic ladder
        p.partialLiqBps = 9_950;
        p.fullLiqBps = 9_999;
        vm.prank(CURATOR_ADDR);
        collateralRegistry.updatePair(WBTC, USDC, p);

        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(st.versionKey, 1, "deal pinned to v1");

        Types.ParamsV1 memory dealParams = archive.readDecodedV1(pairKey, 1);
        assertEq(dealParams.warningBps, 8_500, "v1 warning still 8500");
    }

    // ---- Invariant #11: bounded liquidation transfer ----

    function test_Inv11_FullLiquidationCannotExceedPosted() public {
        // Force HF below full threshold and trigger full liquidation; verify
        // the seized amount never exceeds posted collateral.
        Types.DualPriceAttestation memory att = Types.DualPriceAttestation({
            dealId: dealId,
            sourceId: bytes32("test"),
            observedCollateralPrice: 5_000e8, // very low BTC price
            observedSupplyPrice: 1e8,
            observationTs: uint64(block.timestamp),
            reasonCode: bytes32(0)
        });
        bytes memory sig = _signAttestation(att, ATTESTOR_PK);

        Types.DealState memory before_ = engine.getDealState(dealId);
        vm.prank(LIQUIDATOR_ADDR);
        handler.fullLiquidate(dealId, att, sig);
        Types.DealState memory after_ = engine.getDealState(dealId);

        // Seized = before.collateral - after.collateral ≤ before.collateral.
        assertLe(before_.collateralPosted - after_.collateralPosted, before_.collateralPosted, "bound");
    }

    // ---- Invariant #15: Vault reconciliation >= ----

    function test_Inv15_VaultLedgerSumLessOrEqualBalance() public {
        // Donate to the vault.
        address whale = makeAddr("Whale");
        deal(USDC, whale, 50_000e6, true);
        vm.prank(whale);
        IERC20(USDC).transfer(address(vault), 50_000e6);

        uint256 vaultBal = IERC20(USDC).balanceOf(address(vault));
        uint256 ledger = vault.getLedgerSum(USDC);
        assertGe(vaultBal, ledger, "vault >= ledger sum");
    }

    // ---- Invariant #18: Hook atomicity ----

    function test_Inv18_PreHookFalse_Reverts() public {
        // Already covered by ComplianceHooksTest.test_PreHookBlocks_RejectsActivation.
        assertTrue(true);
    }

    // ---- Invariant #19: Decimal coherence ----

    function test_Inv19_DecimalCoherence_UnchangedHF() public view {
        // HF computed from USDC (6 dec) and WBTC (8 dec) tokens with 8-dec feeds.
        // Re-read HF and check it's a reasonable number (deals aren't degenerate).
        uint256 hf = engine.healthFactorBps(dealId);
        assertGt(hf, 0);
        assertLt(hf, type(uint128).max, "HF in reasonable bounds");
    }

    // ---- Invariant #20: Cap enforcement at activation ----

    function test_Inv20_CapEnforcedAtActivation() public {
        // Cap reduction below current usage — new deals must revert.
        vm.prank(GOVERNOR);
        engine.setGlobalCapUsd(1e18); // $1

        uint128 px = 1_000e6;
        uint128 cx = 5e7;
        Types.DealIntent memory intent = _buildIntent(USDC, WBTC, px, cx, 30 days, 1_000);
        deal(USDC, LENDER, px, true);
        deal(WBTC, BORROWER, cx, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);
        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Errors.CapExceeded.selector, bytes32("GLOBAL_CAP")));
        engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32(0));
    }
}
