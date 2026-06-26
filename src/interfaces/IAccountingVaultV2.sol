// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAccountingVaultV2 {
    function bindEngine(address engine) external;
    function pull(bytes32 dealId, address token, address from, uint256 amount) external;
    function release(bytes32 dealId, address token, address to, uint256 amount) external;
    function burnReserve(bytes32 dealId, address token, uint256 amount) external;
    function burnCollateralForRelease(bytes32 dealId, address token, bytes32 pledgeId, uint256 amount, bytes32 voucherId)
        external;
    function balanceOfDeal(bytes32 dealId, address token) external view returns (uint256);
    function ledgerSum(address token) external view returns (uint256);
}
