// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

interface ILendingEngine {
    function getDealState(bytes32 dealId) external view returns (Types.DealState memory);
    function getEffectiveOracles(bytes32 dealId)
        external
        view
        returns (address collateralOracle, address supplyOracle);

    function computeOutstanding(bytes32 dealId) external view returns (uint128);

    function healthFactorBps(bytes32 dealId) external view returns (uint256);

    // engine→handler transitions
    function setWarned(bytes32 dealId) external;
    function applyPartialLiquidation(bytes32 dealId, uint128 debtCovered, uint128 collateralSeized) external;
    function applyFullLiquidation(bytes32 dealId, uint128 debtCovered, uint128 collateralSeized, uint128 surplusToBorrower) external;
}
