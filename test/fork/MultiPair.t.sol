// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DealHelper} from "../utils/DealHelper.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";

/// @notice Multi-pair coverage: WETH-collateral against USDT-supply,
///         exercising different decimals (USDT=6, WETH=18) and different
///         Chainlink feed pairings.
contract MultiPairTest is DealHelper {
    function setUp() public {
        _setUpFork();
        // Register pair: collateral=WETH, supply=USDT.
        _registerCustodianAndPair(USDT, WETH, FEED_USDT_USD, FEED_ETH_USD, 7_000, 8_500, 9_000, 9_500);
    }

    function test_ETH_USDT_FullCycle() public {
        // 20,000 USDT against 30 WETH (so HF stays comfortably above 100%
        // even at depressed ETH prices). Numbers chosen to clear the LTV
        // ladder regardless of where ETH/USD is right now.
        uint128 principal = 20_000e6;
        uint128 collateral = 30e18;
        Types.DealIntent memory intent = _buildIntent(USDT, WETH, principal, collateral, 30 days, 800);

        deal(USDT, LENDER, principal, true);
        deal(WETH, BORROWER, collateral); // WETH doesn't fit stdStorage totalSupply
        // USDT approve: low-level
        vm.prank(LENDER);
        (bool ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max));
        require(ok, "USDT approve");
        vm.prank(BORROWER); IERC20(WETH).approve(address(vault), type(uint256).max);

        bytes memory l = _signIntent(intent, LENDER_PK);
        bytes memory b = _signIntent(intent, BORROWER_PK);
        bytes memory a = _signIntent(intent, AMINA_PK);

        uint256 borrowerUsdtBefore = IERC20(USDT).balanceOf(BORROWER);
        vm.prank(ALLOCATOR_ADDR);
        bytes32 dealId = engine.openAndActivate(intent, l, b, a, AMINA_SIGNER, bytes32(0));

        assertEq(IERC20(USDT).balanceOf(BORROWER) - borrowerUsdtBefore, principal, "borrower got USDT");
        Types.DealState memory st = engine.getDealState(dealId);
        assertEq(uint8(st.state), uint8(Types.DealStateEnum.Active));
        // HF should comfortably exceed 100% (we expected ~200%).
        uint256 hf = engine.healthFactorBps(dealId);
        assertGt(hf, 10_000, "HF > 100%");

        // Time-warp 30 days and repay.
        vm.warp(block.timestamp + 30 days);
        uint128 ow = engine.computeOutstanding(dealId);
        deal(USDT, BORROWER, ow, true);
        vm.prank(BORROWER);
        (ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max));
        require(ok, "USDT approve borrow");
        vm.prank(BORROWER); engine.repay(dealId, ow);

        Types.DealState memory stEnd = engine.getDealState(dealId);
        assertEq(uint8(stEnd.state), uint8(Types.DealStateEnum.Repaid));
        assertEq(IERC20(WETH).balanceOf(BORROWER), collateral, "WETH returned");
    }
}
