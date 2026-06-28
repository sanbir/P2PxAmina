// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMorpho (simplified, single-market seam)
/// @notice The subset of an isolated Morpho Blue market that {MorphoAdapter} consumes.
/// @dev This is the integration seam. The PRODUCTION adapter binds the real Morpho Blue
///      `MarketParams` (loanToken, collateralToken, oracle, irm, lltv) and calls the canonical
///      Morpho interface (with shares + Id). The test harness implements this same seam with a
///      deterministic mock so the full lifecycle + invariants can be verified without a fork.
///      `onBehalf` is always the adapter (the bridge owns the position via the adapter).
interface IMorpho {
    function supplyCollateral(uint256 assets, address onBehalf) external;
    function withdrawCollateral(uint256 assets, address onBehalf, address receiver) external;
    function borrow(uint256 assets, address onBehalf, address receiver) external returns (uint256);
    function repay(uint256 assets, address onBehalf) external returns (uint256);
    function position(address user) external view returns (uint256 collateral, uint256 borrowAssets);
    function accrueInterest() external;
    function loanToken() external view returns (address);
    function collateralToken() external view returns (address);
}
