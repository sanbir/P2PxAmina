// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IParameterArchive} from "../interfaces/IParameterArchive.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title ParameterArchive — immutable, schema-versioned snapshot store (D15).
/// @notice Stores `ParamSnapshot{schemaVersion, paramsHash, encodedParams}`.
///         Decoded views (`readDecodedV1`) ABI-decode the encoded bytes
///         after verifying `paramsHash`. Future v2 schemas ship as a new
///         decoder without mutating the archive.
contract ParameterArchive is IParameterArchive {
    address public immutable collateralRegistry;

    mapping(bytes32 => mapping(uint32 => Types.ParamSnapshot)) private _archive;

    event SnapshotWritten(bytes32 indexed pair, uint32 indexed version, uint16 schemaVersion, bytes32 paramsHash);

    error OnlyCollateralRegistry();
    error SnapshotExists();
    error SnapshotMissing();

    constructor(address collateralRegistry_) {
        if (collateralRegistry_ == address(0)) revert Errors.ZeroAddress();
        collateralRegistry = collateralRegistry_;
    }

    function write(bytes32 pair, uint32 version, Types.ParamSnapshot calldata snap) external {
        if (msg.sender != collateralRegistry) revert OnlyCollateralRegistry();
        if (snap.schemaVersion != 1) revert Errors.ParamsSchemaUnsupported(snap.schemaVersion);
        if (keccak256(snap.encodedParams) != snap.paramsHash) revert Errors.ParamsHashMismatch();
        if (_archive[pair][version].schemaVersion != 0) revert SnapshotExists();
        _archive[pair][version] = snap;
        emit SnapshotWritten(pair, version, snap.schemaVersion, snap.paramsHash);
    }

    function read(bytes32 pair, uint32 version) external view returns (Types.ParamSnapshot memory) {
        Types.ParamSnapshot memory s = _archive[pair][version];
        if (s.schemaVersion == 0) revert SnapshotMissing();
        return s;
    }

    function hasSnapshot(bytes32 pair, uint32 version) external view returns (bool) {
        return _archive[pair][version].schemaVersion != 0;
    }

    function readDecodedV1(bytes32 pair, uint32 version) external view returns (Types.ParamsV1 memory) {
        Types.ParamSnapshot memory s = _archive[pair][version];
        if (s.schemaVersion == 0) revert SnapshotMissing();
        if (s.schemaVersion != 1) revert Errors.ParamsSchemaUnsupported(s.schemaVersion);
        if (keccak256(s.encodedParams) != s.paramsHash) revert Errors.ParamsHashMismatch();
        return abi.decode(s.encodedParams, (Types.ParamsV1));
    }
}
