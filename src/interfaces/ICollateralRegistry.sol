// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

interface ICollateralRegistry {
    function pairKey(address collateral, address supply) external pure returns (bytes32);

    function latestVersion(bytes32 pair) external view returns (uint32);

    function getLatestParams(bytes32 pair) external view returns (Types.ParamsV1 memory);

    function getParams(bytes32 pair, uint32 version) external view returns (Types.ParamsV1 memory);

    function isPairActive(bytes32 pair) external view returns (bool);
}
