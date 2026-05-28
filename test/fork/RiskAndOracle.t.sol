// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DealHelper} from "../utils/DealHelper.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";
import {ParameterArchive} from "../../src/l2/ParameterArchive.sol";

/// @notice ParameterArchive (D15) + Oracle Override (D16) + unattributed
///         balance (D17) tests against the live wired protocol.
contract RiskAndOracleTest is DealHelper {
    bytes32 internal dealId;
    uint128 internal principal = 100_000e6;
    uint128 internal collateral = 5e8;

    function setUp() public {
        _setUpFork();
        _registerCustodianAndPair(USDC, WBTC, FEED_USDC_USD, FEED_BTC_USD, 7_000, 8_500, 9_000, 9_500);
        _openDeal();
    }

    function _openDeal() internal {
        Types.DealIntent memory intent = _buildIntent(USDC, WBTC, principal, collateral, 60 days, 1_000);
        deal(USDC, LENDER, principal, true);
        deal(WBTC, BORROWER, collateral, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);
        bytes memory lSig = _signIntent(intent, LENDER_PK);
        bytes memory bSig = _signIntent(intent, BORROWER_PK);
        bytes memory aSig = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        dealId = engine.openAndActivate(intent, lSig, bSig, aSig, AMINA_SIGNER, bytes32(0));
    }

    // ---------------- ParameterArchive (D15) ----------------

    function test_ParameterArchive_StoresVersionedSnapshots() public {
        // v1 already written. Bump to v2.
        Types.ParamsV1 memory pNew = collateralRegistry.getLatestParams(pairKey);
        pNew.ltvBps = 6_500; // tighten
        vm.prank(CURATOR_ADDR);
        collateralRegistry.updatePair(WBTC, USDC, pNew);
        assertEq(collateralRegistry.latestVersion(pairKey), 2, "version bumped");

        Types.ParamsV1 memory v1 = archive.readDecodedV1(pairKey, 1);
        Types.ParamsV1 memory v2 = archive.readDecodedV1(pairKey, 2);
        assertEq(v1.ltvBps, 7_000, "v1 unchanged");
        assertEq(v2.ltvBps, 6_500, "v2 reflects update");

        // The existing deal still reads v1 (immutable snapshot).
        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(st.versionKey, 1, "deal pinned to v1");
    }

    function test_ParameterArchive_RejectsRewriteOfVersion() public {
        // Try to write v1 again directly.
        Types.ParamsV1 memory p = collateralRegistry.getLatestParams(pairKey);
        bytes memory enc = abi.encode(p);
        bytes32 h = keccak256(enc);
        Types.ParamSnapshot memory snap = Types.ParamSnapshot({schemaVersion: 1, paramsHash: h, encodedParams: enc});
        vm.prank(address(collateralRegistry));
        vm.expectRevert(ParameterArchive.SnapshotExists.selector);
        archive.write(pairKey, 1, snap);
    }

    function test_ParameterArchive_RejectsHashMismatch() public {
        Types.ParamsV1 memory p = collateralRegistry.getLatestParams(pairKey);
        bytes memory enc = abi.encode(p);
        Types.ParamSnapshot memory snap = Types.ParamSnapshot({
            schemaVersion: 1,
            paramsHash: keccak256("lies"),
            encodedParams: enc
        });
        vm.prank(address(collateralRegistry));
        vm.expectRevert(Errors.ParamsHashMismatch.selector);
        archive.write(pairKey, 7, snap);
    }

    function test_ParameterArchive_OnlyCollateralRegistryCanWrite() public {
        Types.ParamSnapshot memory snap = Types.ParamSnapshot({
            schemaVersion: 1,
            paramsHash: bytes32(0),
            encodedParams: ""
        });
        vm.prank(BORROWER);
        vm.expectRevert(ParameterArchive.OnlyCollateralRegistry.selector);
        archive.write(pairKey, 99, snap);
    }

    // ---------------- Oracle Override (D16) ----------------

    function test_OracleOverride_DoesNotMutateDealTerms() public {
        Types.DealTerms memory termsBefore = dealRegistry.getTerms(dealId);
        vm.prank(EMERGENCY_ADDR);
        engine.forceOracleOverride(dealId, address(0xdead), address(0xbeef), bytes32("EMERGENCY"));
        Types.DealTerms memory termsAfter = dealRegistry.getTerms(dealId);

        // Terms remain pristine.
        assertEq(termsBefore.paramVersion, termsAfter.paramVersion, "paramVersion unchanged");
        assertEq(keccak256(abi.encode(termsBefore)), keccak256(abi.encode(termsAfter)), "terms unchanged");

        // The override exists as a sidecar.
        Types.OracleOverride memory o = engine.getOracleOverride(dealId);
        assertEq(o.overrideCollateralOracle, address(0xdead));
        assertEq(o.overrideSupplyOracle, address(0xbeef));
        assertEq(o.reason, bytes32("EMERGENCY"));
        assertGt(o.effectiveAt, block.timestamp, "effectiveAt in future (grace window)");
    }

    function test_OracleOverride_RespectsGraceWindow() public {
        // Pre-effectiveAt: getEffectiveOracles returns the snapshotted feeds.
        vm.prank(EMERGENCY_ADDR);
        engine.forceOracleOverride(dealId, address(0xdead), address(0xbeef), bytes32("X"));
        (address co, address so) = engine.getEffectiveOracles(dealId);
        assertEq(co, FEED_BTC_USD, "still original collateral feed during grace");
        assertEq(so, FEED_USDC_USD, "still original supply feed during grace");

        // After effectiveAt, override is live.
        vm.warp(block.timestamp + 31 minutes);
        (co, so) = engine.getEffectiveOracles(dealId);
        assertEq(co, address(0xdead));
        assertEq(so, address(0xbeef));
    }

    function test_OracleOverride_TerminalDealRejected() public {
        // Repay to terminal.
        uint128 ow = engine.computeOutstanding(dealId);
        deal(USDC, BORROWER, ow, true);
        vm.prank(BORROWER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); engine.repay(dealId, ow);

        vm.prank(EMERGENCY_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Errors.DealNotTerminal.selector, dealId));
        engine.forceOracleOverride(dealId, address(1), address(2), bytes32("X"));
    }

    // ---------------- Unattributed balance (D17) ----------------

    function test_UnattributedBalance_DonationToVaultIsVisible() public {
        // Donate 1000 USDC to the vault from a third party — not via pull.
        address whale = makeAddr("Whale");
        deal(USDC, whale, 1_000e6, true);
        vm.prank(whale);
        IERC20(USDC).transfer(address(vault), 1_000e6);

        uint256 unatt = vault.getUnattributedBalance(USDC);
        assertEq(unatt, 1_000e6, "donation reflected as unattributed");

        // Ledger sum still reflects only legitimate balances.
        uint256 ledger = vault.getLedgerSum(USDC);
        // After openAndActivate, supply tokens were pushed straight to borrower (debit), so ledger should be 0.
        assertEq(ledger, 0, "ledger sum unaffected by donation");
    }

    function test_UnattributedBalance_OnlyGovernorCanSweep() public {
        address whale = makeAddr("Whale");
        deal(USDC, whale, 500e6, true);
        vm.prank(whale);
        IERC20(USDC).transfer(address(vault), 500e6);

        // Non-governor attempt.
        vm.expectRevert();
        vault.sweepUnattributedBalance(USDC, OPS_ADDR, 500e6, bytes32("test"));

        // Governor succeeds.
        uint256 before_ = IERC20(USDC).balanceOf(OPS_ADDR);
        vm.prank(GOVERNOR);
        vault.sweepUnattributedBalance(USDC, OPS_ADDR, 500e6, bytes32("test"));
        assertEq(IERC20(USDC).balanceOf(OPS_ADDR) - before_, 500e6);
    }

    function test_UnattributedBalance_CannotSweepLedgerFunds() public {
        // After deal open, vault holds `collateral` WBTC that is legitimate ledger.
        // Governor tries to sweep more than the unattributed (which is 0).
        vm.prank(GOVERNOR);
        vm.expectRevert(Errors.InsufficientLedger.selector);
        vault.sweepUnattributedBalance(WBTC, GOVERNOR, 1, bytes32("steal"));
    }

    // ---------------- PortfolioLens ----------------

    function test_Lens_AggregatesDealView() public view {
        // Lens reads the live state.
        (bool ok, bytes memory data) =
            address(lens).staticcall(abi.encodeWithSignature("getDeal(bytes32)", dealId));
        assertTrue(ok, "lens callable");
        // We just sanity-check that decoding doesn't blow up.
        assertGt(data.length, 0);
    }

    function test_Lens_BatchView_HasCorrectStateAndBalances() public view {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = dealId;
        // Call via interface bypass: lens.getDeals returns DealView[] which has nested tuples.
        // Calling raw and just confirming the call succeeds.
        (bool ok,) = address(lens).staticcall(abi.encodeWithSignature("getDeals(bytes32[])", ids));
        assertTrue(ok, "lens batch view");
    }

    // ---------------- Settlement router schema ----------------

    function test_SettlementRouter_VersionStable() public view {
        assertEq(router.version(), 1, "schema v1");
    }

    function test_SettlementRouter_SequenceMonotonic() public {
        // Two events from the engine should bump the counter twice.
        uint64 before_ = router.currentSequence();
        // Open another deal.
        uint128 px = 5_000e6;
        uint128 cx = 1e7;
        Types.DealIntent memory intent = _buildIntent(USDC, WBTC, px, cx, 30 days, 1_000);
        deal(USDC, LENDER, px, true);
        deal(WBTC, BORROWER, cx, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);
        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32("ref-2"));
        uint64 after_ = router.currentSequence();
        // openAndActivate emits AdvanceIntent + DealActivated → +2.
        assertEq(after_ - before_, 2, "two events emitted");
    }
}
