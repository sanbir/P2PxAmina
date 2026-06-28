// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FixedRateIRM
/// @notice AMINA-curated fixed-rate interest model for the isolated Triora Morpho market (Tech Spec S6/S7).
/// @dev Preserves fixed-rate-repo fidelity while still using Morpho's collateral/borrow/liquidation
///      machinery: the borrower's Morpho debt accrues at the same fixed APR the bridge charges, so the
///      bridge sub-ledger and the Morpho position stay in lock-step.
contract FixedRateIRM {
    uint256 public immutable borrowRatePerYearBps;

    constructor(uint256 borrowRatePerYearBps_) {
        borrowRatePerYearBps = borrowRatePerYearBps_;
    }

    /// @notice Per-year borrow rate in basis points (constant).
    function borrowRateView() external view returns (uint256) {
        return borrowRatePerYearBps;
    }
}
