// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

interface IParameterArchive {
    function write(bytes32 pair, uint32 version, Types.ParamSnapshot calldata snap) external;

    function read(bytes32 pair, uint32 version) external view returns (Types.ParamSnapshot memory);

    function readDecodedV1(bytes32 pair, uint32 version) external view returns (Types.ParamsV1 memory);

    function hasSnapshot(bytes32 pair, uint32 version) external view returns (bool);
}
