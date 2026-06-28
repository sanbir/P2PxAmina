// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {IProtocolAdapter} from "../interfaces/ITriora.sol";
import {IMorpho} from "./IMorpho.sol";

/// @title MorphoAdapter
/// @notice Thin {IProtocolAdapter} over one isolated Morpho market (Tech Spec S7). The adapter is the
///         single Morpho actor (`onBehalf = address(this)`); per-borrower attribution lives in the
///         {CollateralBridge} sub-ledger. Only the bridge (ENGINE) may drive it.
/// @dev Reversibility: a future AaveAdapter implements the same {IProtocolAdapter} with no bridge change.
contract MorphoAdapter is IProtocolAdapter, TrioraAccess {
    using SafeERC20 for IERC20;

    IMorpho public immutable morpho;
    IERC20 public immutable cbtc;
    IERC20 public immutable usdc;

    constructor(address roleManager_, address morpho_, address cbtc_, address usdc_) TrioraAccess(roleManager_) {
        if (morpho_ == address(0) || cbtc_ == address(0) || usdc_ == address(0)) revert Errors.ZeroAddress();
        morpho = IMorpho(morpho_);
        cbtc = IERC20(cbtc_);
        usdc = IERC20(usdc_);
    }

    function supplyCollateral(uint256 cbtcAmount) external restricted(Roles.ENGINE) {
        cbtc.safeTransferFrom(msg.sender, address(this), cbtcAmount);
        cbtc.forceApprove(address(morpho), cbtcAmount);
        morpho.supplyCollateral(cbtcAmount, address(this));
    }

    function withdrawCollateral(uint256 cbtcAmount, address receiver) external restricted(Roles.ENGINE) {
        morpho.withdrawCollateral(cbtcAmount, address(this), receiver);
    }

    function borrow(uint256 usdcAmount, address receiver) external restricted(Roles.ENGINE) {
        morpho.borrow(usdcAmount, address(this), receiver);
    }

    function repay(uint256 usdcAmount) external restricted(Roles.ENGINE) {
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdc.forceApprove(address(morpho), usdcAmount);
        morpho.repay(usdcAmount, address(this));
    }

    function accrue() external {
        morpho.accrueInterest();
    }

    function borrowBalance() external view returns (uint256) {
        (, uint256 borrowAssets) = morpho.position(address(this));
        return borrowAssets;
    }

    function collateralBalance() external view returns (uint256) {
        (uint256 collateral,) = morpho.position(address(this));
        return collateral;
    }
}
