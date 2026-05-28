// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DealHelper} from "../utils/DealHelper.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";
import {FrozenToken} from "../../src/test_hooks/FrozenToken.sol";

/// @notice Tests the recovery state `Repaid_PendingCollateralRelease`
///         (D18) — the engine attempts a non-reverting collateral
///         release; if the issuer has frozen transfers, the deal goes
///         into the recovery state and the borrower can later call
///         `claimUnreleasedCollateral` once the freeze lifts.
contract RecoveryFlowTest is DealHelper {
    FrozenToken internal frozenCollateral;

    function setUp() public {
        _setUpFork();

        // Deploy a controllable collateral token. USDC stays as supply.
        frozenCollateral = new FrozenToken("Frozen Collateral", "FCL");
        // Pre-mint some so admission transfer probes can pass.
        frozenCollateral.mint(CURATOR_ADDR, 2e9);
        frozenCollateral.mint(BORROWER, 100e18);

        vm.prank(CURATOR_ADDR);
        issuers.addIssuer(CUSTODIAN, CUSTODIAN, keccak256("legal"), 1_000_000_000e18);
        _admitAndAddToken(USDC, Types.TokenKind.Supply, CUSTODIAN, 1_000_000_000e18);
        _admitFrozenToken();
        _addPair();
        _setCaps();
    }

    function _admitFrozenToken() internal {
        // The token has 18 decimals. Approve issuer and run checks.
        vm.startPrank(CURATOR_ADDR);
        frozenCollateral.approve(address(issuers), type(uint256).max);
        (bool pass,) = issuers.runAdmissionChecks(address(frozenCollateral), 18);
        require(pass, "admit");
        Types.TokenInfo memory info = Types.TokenInfo({
            issuer: CUSTODIAN,
            kind: Types.TokenKind.Collateral,
            dualUseEnabled: false,
            decimals: 18,
            paused: false,
            capUsd: 1_000_000_000e18,
            usedCapUsd: 0,
            redemptionAttestationHash: keccak256("rdm"),
            nonStandardChecked: false
        });
        issuers.addToken(address(frozenCollateral), info);
        vm.stopPrank();
    }

    function _addPair() internal {
        // Use the BTC/USD feed for both prices (test only — at the price
        // the feed reports, 1 FCL = $BTC, which is fine for math).
        Types.ParamsV1 memory p = Types.ParamsV1({
            ltvBps: 5_000,
            warningBps: 7_000,
            partialLiqBps: 8_000,
            fullLiqBps: 9_000,
            maxMaturity: 365 days,
            maxRateBps: 2_000,
            liquidationBonusBps: 500,
            aminaFeeBps: 100,
            pairCapUsd: 1_000_000_000e18,
            priceSourceCollateral: FEED_BTC_USD,
            priceSourceSupply: FEED_USDC_USD,
            heartbeatCollateral: 24 hours,
            heartbeatSupply: 24 hours,
            oracleDecimalsCollateral: 8,
            oracleDecimalsSupply: 8,
            active: true
        });
        vm.prank(CURATOR_ADDR);
        collateralRegistry.addPair(address(frozenCollateral), USDC, p);
        pairKey = collateralRegistry.pairKey(address(frozenCollateral), USDC);
        paramVersion = collateralRegistry.latestVersion(pairKey);
    }

    function _setCaps() internal {
        vm.startPrank(GOVERNOR);
        engine.setGlobalCapUsd(1_000_000_000e18);
        engine.setBorrowerCapUsd(BORROWER, 1_000_000_000e18);
        engine.setLenderCapUsd(LENDER, 1_000_000_000e18);
        vm.stopPrank();
    }

    function test_FrozenCollateral_RoutesToRecoveryState() public {
        // Open a deal: 1k USDC against 1 FCL.
        uint128 principal = 1_000e6;
        uint128 collateral = 1e18;
        Types.DealIntent memory intent = _buildIntent(USDC, address(frozenCollateral), principal, collateral, 30 days, 1_000);
        deal(USDC, LENDER, principal, true);
        // Borrower already has FCL minted in setUp.
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(address(frozenCollateral)).approve(address(vault), type(uint256).max);
        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        bytes32 dealId = engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32(0));

        // FREEZE the collateral token (simulating issuer freeze).
        frozenCollateral.setFrozen(true);

        // Borrower repays in full. The collateral release will fail.
        uint128 ow = engine.computeOutstanding(dealId);
        deal(USDC, BORROWER, ow, true);
        vm.prank(BORROWER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); engine.repay(dealId, ow);

        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(uint8(st.state), uint8(Types.DealStateEnum.Repaid_PendingCollateralRelease), "recovery state");
        assertEq(st.outstanding, 0, "debt cleared");
        // Vault still holds the collateral.
        assertEq(vault.getBalance(dealId, address(frozenCollateral)), collateral, "vault still holds collateral");

        // borrower tries to claim while frozen → reverts.
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenAdmissionFailed.selector, address(frozenCollateral), bytes32("ISSUER_FREEZE")));
        engine.claimUnreleasedCollateral(dealId);

        // unfreeze, then borrower can claim
        frozenCollateral.setFrozen(false);
        uint256 borrowerBefore = frozenCollateral.balanceOf(BORROWER);
        vm.prank(BORROWER);
        engine.claimUnreleasedCollateral(dealId);
        uint256 borrowerAfter = frozenCollateral.balanceOf(BORROWER);
        assertEq(borrowerAfter - borrowerBefore, collateral, "claimed collateral");
        Types.DealState memory stEnd = engine.getDealState(dealId);
        assertEq(uint8(stEnd.state), uint8(Types.DealStateEnum.Repaid), "now Repaid");
    }
}
