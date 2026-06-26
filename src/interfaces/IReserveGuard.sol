// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IReserveGuard {
    function validateMint(address token, uint256 totalSupplyAfter) external view;
    function effectiveReserveLimit(address token) external view returns (uint256);
}
