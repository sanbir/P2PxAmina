// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {ProtocolFixture} from "../utils/ProtocolFixture.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {IssuerRegistry} from "../../src/l1/IssuerRegistry.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Token admission (D22) + dual-use (D20) tests against real
///         mainnet tokens.
contract AdmissionTest is ProtocolFixture {
    function setUp() public {
        _setUpFork();
        vm.prank(CURATOR_ADDR);
        issuers.addIssuer(CUSTODIAN, CUSTODIAN, keccak256("legal"), 1_000_000_000e18);
    }

    function test_AdmitsStandardToken_USDC() public {
        // Fund CURATOR and run checks against real USDC.
        deal(USDC, CURATOR_ADDR, 2e9, true);
        vm.startPrank(CURATOR_ADDR);
        IERC20(USDC).approve(address(issuers), type(uint256).max);
        (bool pass, bytes32 reason) = issuers.runAdmissionChecks(USDC, 6);
        vm.stopPrank();
        assertTrue(pass, "USDC admitted");
        assertEq(reason, bytes32(0), "no reason code on success");
    }

    function test_AdmitsStandardToken_USDT() public {
        deal(USDT, CURATOR_ADDR, 2e9, true);
        vm.startPrank(CURATOR_ADDR);
        // USDT's approve does not return a bool — use raw call.
        (bool ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(issuers), type(uint256).max));
        require(ok, "approve failed");
        (bool pass,) = issuers.runAdmissionChecks(USDT, 6);
        vm.stopPrank();
        assertTrue(pass, "USDT admitted (mainnet fee=0)");
    }

    function test_AdmitsStandardToken_WBTC() public {
        deal(WBTC, CURATOR_ADDR, 2e9, true);
        vm.startPrank(CURATOR_ADDR);
        IERC20(WBTC).approve(address(issuers), type(uint256).max);
        (bool pass,) = issuers.runAdmissionChecks(WBTC, 8);
        vm.stopPrank();
        assertTrue(pass, "WBTC admitted");
    }

    function test_AdmissionRejectsWrongDecimals() public {
        deal(USDC, CURATOR_ADDR, 2e9, true);
        vm.startPrank(CURATOR_ADDR);
        IERC20(USDC).approve(address(issuers), type(uint256).max);
        // USDC has 6 decimals; lie and tell registry 18.
        (bool pass, bytes32 reason) = issuers.runAdmissionChecks(USDC, 18);
        vm.stopPrank();
        assertFalse(pass, "decimals mismatch rejected");
        assertEq(reason, bytes32("DECIMALS_MISMATCH"), "reason code");
    }

    function test_AddToken_RevertsBeforeAdmission() public {
        // Try to add token without running admission.
        Types.TokenInfo memory info = Types.TokenInfo({
            issuer: CUSTODIAN,
            kind: Types.TokenKind.Supply,
            dualUseEnabled: false,
            decimals: 6,
            paused: false,
            capUsd: 0,
            usedCapUsd: 0,
            redemptionAttestationHash: bytes32(0),
            nonStandardChecked: false
        });
        vm.prank(CURATOR_ADDR);
        vm.expectRevert(IssuerRegistry.AdmissionNotRun.selector);
        issuers.addToken(USDC, info);
    }

    function test_DualUseToken_DisabledByDefault() public {
        // Admit USDC as DualUse, then check it's not active until enabled.
        deal(USDC, CURATOR_ADDR, 2e9, true);
        vm.startPrank(CURATOR_ADDR);
        IERC20(USDC).approve(address(issuers), type(uint256).max);
        issuers.runAdmissionChecks(USDC, 6);
        Types.TokenInfo memory info = Types.TokenInfo({
            issuer: CUSTODIAN,
            kind: Types.TokenKind.DualUse_DisabledByDefault,
            dualUseEnabled: false,
            decimals: 6,
            paused: false,
            capUsd: 0,
            usedCapUsd: 0,
            redemptionAttestationHash: keccak256("rdm"),
            nonStandardChecked: false
        });
        issuers.addToken(USDC, info);
        vm.stopPrank();

        // Token is admitted but isTokenActive() must return false because dualUseEnabled = false.
        assertFalse(issuers.isTokenActive(USDC), "dual-use disabled by default");

        // Enabling requires CURATOR (we bound it in fixture).
        vm.prank(CURATOR_ADDR);
        issuers.enableDualUse(USDC);
        assertTrue(issuers.isTokenActive(USDC), "enabled after dual-use flag");
    }

    function test_AdmissionRequiresAuthorisedCaller() public {
        deal(USDC, BORROWER, 2e9, true);
        vm.startPrank(BORROWER);
        IERC20(USDC).approve(address(issuers), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, BORROWER));
        issuers.runAdmissionChecks(USDC, 6);
        vm.stopPrank();
    }

    function test_TokenAdmissionEventEmitted() public {
        deal(USDC, CURATOR_ADDR, 2e9, true);
        vm.startPrank(CURATOR_ADDR);
        IERC20(USDC).approve(address(issuers), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(issuers));
        emit IssuerRegistry.TokenAdmissionChecked(USDC, false, false, 6, true);
        issuers.runAdmissionChecks(USDC, 6);
        vm.stopPrank();
    }
}
