// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho} from "../../src/morpho/IMorpho.sol";
import {FixedRateIRM} from "../../src/morpho/FixedRateIRM.sol";

/// @notice Deterministic single-market Morpho seam for tests. Accrues SIMPLE interest on the original
///         borrow principal at the FixedRateIRM rate, so it stays in lock-step with the bridge sub-ledger.
contract MockMorpho is IMorpho {
    IERC20 public immutable cbtc;
    IERC20 public immutable usdc;
    FixedRateIRM public immutable irm;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public principalOf;
    mapping(address => uint256) public accruedOf;
    mapping(address => uint256) public lastOf;

    constructor(address cbtc_, address usdc_, address irm_) {
        cbtc = IERC20(cbtc_);
        usdc = IERC20(usdc_);
        irm = FixedRateIRM(irm_);
    }

    function loanToken() external view returns (address) {
        return address(usdc);
    }

    function collateralToken() external view returns (address) {
        return address(cbtc);
    }

    function _accrue(address u) internal {
        uint256 dt = block.timestamp - lastOf[u];
        if (dt > 0 && principalOf[u] > 0) {
            accruedOf[u] += principalOf[u] * irm.borrowRatePerYearBps() * dt / (10000 * 365 days);
        }
        lastOf[u] = block.timestamp;
    }

    function accrueInterest() external {
        _accrue(msg.sender);
    }

    function supplyCollateral(uint256 assets, address onBehalf) external {
        cbtc.transferFrom(msg.sender, address(this), assets);
        collateralOf[onBehalf] += assets;
    }

    function withdrawCollateral(uint256 assets, address onBehalf, address receiver) external {
        require(collateralOf[onBehalf] >= assets, "collateral");
        collateralOf[onBehalf] -= assets;
        cbtc.transfer(receiver, assets);
    }

    function borrow(uint256 assets, address onBehalf, address receiver) external returns (uint256) {
        _accrue(onBehalf);
        if (lastOf[onBehalf] == 0) lastOf[onBehalf] = block.timestamp;
        principalOf[onBehalf] += assets;
        require(usdc.balanceOf(address(this)) >= assets, "liquidity");
        usdc.transfer(receiver, assets);
        return assets;
    }

    function repay(uint256 assets, address onBehalf) external returns (uint256) {
        _accrue(onBehalf);
        uint256 owed = principalOf[onBehalf] + accruedOf[onBehalf];
        uint256 amt = assets > owed ? owed : assets;
        usdc.transferFrom(msg.sender, address(this), amt);
        if (amt <= accruedOf[onBehalf]) {
            accruedOf[onBehalf] -= amt;
        } else {
            uint256 rem = amt - accruedOf[onBehalf];
            accruedOf[onBehalf] = 0;
            principalOf[onBehalf] -= rem;
        }
        return amt;
    }

    function position(address user) external view returns (uint256 collateral, uint256 borrowAssets) {
        uint256 accrued = accruedOf[user];
        uint256 dt = block.timestamp - lastOf[user];
        if (dt > 0 && principalOf[user] > 0) {
            accrued += principalOf[user] * irm.borrowRatePerYearBps() * dt / (10000 * 365 days);
        }
        return (collateralOf[user], principalOf[user] + accrued);
    }
}
