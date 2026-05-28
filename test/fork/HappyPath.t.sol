// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProtocolFixture} from "../utils/ProtocolFixture.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {EIP712Hashes} from "../../src/libraries/EIP712Hashes.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";

/// @notice End-to-end happy-path test against real mainnet tokens
///         (USDC supply, WBTC collateral) and live Chainlink feeds.
contract HappyPathTest is ProtocolFixture {
    bytes32 internal pairKey;
    uint32 internal paramVersion;

    function setUp() public {
        _setUpFork();
        _registerIssuer();
        _admitAndAddToken(USDC, Types.TokenKind.Supply, CUSTODIAN, 1_000_000_000e18);
        _admitAndAddToken(WBTC, Types.TokenKind.Collateral, CUSTODIAN, 1_000_000_000e18);
        _addPair();
        _setCaps();
    }

    function _registerIssuer() internal {
        vm.prank(CURATOR_ADDR);
        issuers.addIssuer(CUSTODIAN, CUSTODIAN, keccak256("legalAttestation"), 1_000_000_000e18);
    }

    function _addPair() internal {
        Types.ParamsV1 memory p = Types.ParamsV1({
            ltvBps: 7_000, // 70%
            warningBps: 8_500, // 85%
            partialLiqBps: 9_000,
            fullLiqBps: 9_500,
            maxMaturity: 365 days,
            maxRateBps: 2_000, // 20%
            liquidationBonusBps: 500, // 5%
            aminaFeeBps: 100, // 1%
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
        collateralRegistry.addPair(WBTC, USDC, p);
        pairKey = collateralRegistry.pairKey(WBTC, USDC);
        paramVersion = collateralRegistry.latestVersion(pairKey);
    }

    function _setCaps() internal {
        vm.startPrank(GOVERNOR);
        engine.setGlobalCapUsd(1_000_000_000e18);
        engine.setBorrowerCapUsd(BORROWER, 1_000_000_000e18);
        engine.setLenderCapUsd(LENDER, 1_000_000_000e18);
        vm.stopPrank();
    }

    function _buildIntent(uint128 principal, uint128 collateral, uint64 maturity)
        internal
        view
        returns (Types.DealIntent memory)
    {
        return Types.DealIntent({
            lender: LENDER,
            borrower: BORROWER,
            supplyToken: USDC,
            collateralToken: WBTC,
            principal: principal,
            collateralAmount: collateral,
            rateBps: 1_000, // 10% APR
            startTs: uint64(block.timestamp),
            maturityTs: uint64(block.timestamp + maturity),
            pairKey: pairKey,
            paramVersion: paramVersion,
            nonceLender: keccak256(abi.encode("L", block.timestamp)),
            nonceBorrower: keccak256(abi.encode("B", block.timestamp)),
            nonceAmina: keccak256(abi.encode("A", block.timestamp)),
            legalTermsHash: keccak256("legalTerms-v1")
        });
    }

    function _signIntent(Types.DealIntent memory intent, uint256 pk) internal view returns (bytes memory) {
        bytes32 typedHash = engine.hashDealIntent(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, typedHash);
        return abi.encodePacked(r, s, v);
    }

    function test_FullCycle_USDC_WBTC_repay() public {
        // 100,000 USDC against 5 WBTC. At BTC ≈ 100k USD this is ~71% LTV.
        uint128 principal = 100_000e6;
        uint128 collateral = 5e8;
        Types.DealIntent memory intent = _buildIntent(principal, collateral, 30 days);

        // Seed lender + borrower.
        deal(USDC, LENDER, principal, true);
        deal(WBTC, BORROWER, collateral, true);
        // Approvals.
        vm.prank(LENDER);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER);
        IERC20(WBTC).approve(address(vault), type(uint256).max);

        // Sign by 3 parties.
        bytes memory lSig = _signIntent(intent, LENDER_PK);
        bytes memory bSig = _signIntent(intent, BORROWER_PK);
        bytes memory aSig = _signIntent(intent, AMINA_PK);

        // ALLOCATOR submits.
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(BORROWER);
        uint256 vaultWbtcBefore = IERC20(WBTC).balanceOf(address(vault));
        vm.prank(ALLOCATOR_ADDR);
        bytes32 dealId =
            engine.openAndActivate(intent, lSig, bSig, aSig, AMINA_SIGNER, bytes32("settlementRef-1"));
        uint256 borrowerUsdcAfter = IERC20(USDC).balanceOf(BORROWER);
        uint256 vaultWbtcAfter = IERC20(WBTC).balanceOf(address(vault));

        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, principal, "borrower got USDC");
        assertEq(vaultWbtcAfter - vaultWbtcBefore, collateral, "vault got WBTC");

        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(uint8(st.state), uint8(Types.DealStateEnum.Active), "active");
        assertEq(st.outstanding, principal, "outstanding == principal");
        assertEq(st.collateralPosted, collateral, "collateral posted");

        // Time-travel mid-life: accrue interest.
        vm.warp(block.timestamp + 30 days);
        uint128 ow = engine.computeOutstanding(dealId);
        assertGt(ow, principal, "interest accrued");
        // ~10% APR over 30 days ≈ principal * 0.1 * 30/365 ≈ 821 USDC
        uint128 expected = principal + uint128(uint256(principal) * 1_000 * 30 days / (10_000 * 365 days));
        assertApproxEqAbs(ow, expected, 10, "simple interest math");

        // Borrower repays the full outstanding.
        deal(USDC, BORROWER, ow, true);
        vm.prank(BORROWER);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        uint256 lenderBefore = IERC20(USDC).balanceOf(LENDER);
        uint256 borrowerWbtcBefore = IERC20(WBTC).balanceOf(BORROWER);
        vm.prank(BORROWER);
        engine.repay(dealId, ow);
        uint256 lenderAfter = IERC20(USDC).balanceOf(LENDER);
        uint256 borrowerWbtcAfter = IERC20(WBTC).balanceOf(BORROWER);

        assertEq(lenderAfter - lenderBefore, ow, "lender received principal + interest");
        assertEq(borrowerWbtcAfter - borrowerWbtcBefore, collateral, "borrower got collateral back");
        Types.DealState memory stEnd = engine.getDealState(dealId);
        assertEq(uint8(stEnd.state), uint8(Types.DealStateEnum.Repaid), "deal repaid");
        assertEq(stEnd.outstanding, 0, "no outstanding");
        assertEq(vault.getBalance(dealId, USDC), 0, "vault supply ledger 0");
        assertEq(vault.getBalance(dealId, WBTC), 0, "vault collateral ledger 0");
    }

    function test_TopUpCollateral() public {
        uint128 principal = 50_000e6;
        uint128 collateral = 2e8;
        Types.DealIntent memory intent = _buildIntent(principal, collateral, 60 days);

        deal(USDC, LENDER, principal, true);
        deal(WBTC, BORROWER, collateral + 1e8, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);

        bytes memory lSig = _signIntent(intent, LENDER_PK);
        bytes memory bSig = _signIntent(intent, BORROWER_PK);
        bytes memory aSig = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        bytes32 dealId = engine.openAndActivate(intent, lSig, bSig, aSig, AMINA_SIGNER, bytes32(0));

        uint256 hf0 = engine.healthFactorBps(dealId);
        vm.prank(BORROWER);
        engine.topUpCollateral(dealId, 1e8);
        uint256 hf1 = engine.healthFactorBps(dealId);

        assertGt(hf1, hf0, "HF improved after top-up");
        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(st.collateralPosted, collateral + 1e8, "collateral grew");
    }

    function test_PartialRepayAccruesCorrectly() public {
        uint128 principal = 200_000e6;
        uint128 collateral = 10e8;
        Types.DealIntent memory intent = _buildIntent(principal, collateral, 90 days);

        deal(USDC, LENDER, principal, true);
        deal(WBTC, BORROWER, collateral, true);
        vm.prank(LENDER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); IERC20(WBTC).approve(address(vault), type(uint256).max);

        bytes memory lSig = _signIntent(intent, LENDER_PK);
        bytes memory bSig = _signIntent(intent, BORROWER_PK);
        bytes memory aSig = _signIntent(intent, AMINA_PK);
        vm.prank(ALLOCATOR_ADDR);
        bytes32 dealId = engine.openAndActivate(intent, lSig, bSig, aSig, AMINA_SIGNER, bytes32(0));

        // 45 days in, repay half.
        vm.warp(block.timestamp + 45 days);
        uint128 outstanding = engine.computeOutstanding(dealId);
        uint128 half = outstanding / 2;
        deal(USDC, BORROWER, half, true);
        vm.prank(BORROWER); IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.prank(BORROWER); engine.repay(dealId, half);

        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(uint8(st.state), uint8(Types.DealStateEnum.Active), "still active after partial repay");
        assertApproxEqAbs(st.outstanding, outstanding - half, 1, "outstanding decreased by half");
    }

    function test_EngineWiring_ImmutableEscrowAndDealRegistry() public view {
        // Verifies the predicted-address tricks worked: registry's engine
        // immutable matches the deployed engine, and vault.engine() is bound.
        assertEq(address(dealRegistry.engine()), address(engine), "deal registry -> engine");
        assertEq(vault.engine(), address(engine), "vault -> engine");
        assertEq(address(router.engine()), address(engine), "router engine bound");
        assertEq(address(router.handler()), address(handler), "router handler bound");
    }
}
