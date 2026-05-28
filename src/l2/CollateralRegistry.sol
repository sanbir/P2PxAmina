// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessManagedUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IParameterArchive} from "../interfaces/IParameterArchive.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title CollateralRegistry — pair definitions + version-bumping params.
/// @notice Bumping the version snapshots the *prior* params into
///         `ParameterArchive`. Live deals continue to read their
///         snapshotted version (immutable) via `IParameterArchive`.
contract CollateralRegistry is Initializable, UUPSUpgradeable, AccessManagedUpgradeable, ICollateralRegistry {
    /// @custom:storage-location erc7201:p2pxamina.collateralregistry.v1
    struct Storage {
        IParameterArchive archive;
        mapping(bytes32 => uint32) latestVer; // pairKey => latest version
        mapping(bytes32 => Types.ParamsV1) latestParams; // pairKey => live (latest) decoded params
        mapping(bytes32 => bool) paused;
    }

    bytes32 private constant STORAGE_SLOT =
        0x5f7e3b8a9c2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e00;

    event PairAdded(bytes32 indexed pair, uint32 version, Types.ParamsV1 params);
    event PairUpdated(bytes32 indexed pair, uint32 oldVersion, uint32 newVersion);
    event PairPaused(bytes32 indexed pair, bool paused);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address authority_, address archive_) external initializer {
        __AccessManaged_init(authority_);
        __UUPSUpgradeable_init();
        if (archive_ == address(0)) revert Errors.ZeroAddress();
        _store().archive = IParameterArchive(archive_);
    }

    // --------------- pair admin ---------------

    function pairKey(address collateral, address supply) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(collateral, supply));
    }

    function addPair(address collateral, address supply, Types.ParamsV1 calldata params) external restricted {
        bytes32 key = pairKey(collateral, supply);
        Storage storage $ = _store();
        if ($.latestVer[key] != 0) revert Errors.InvalidParams(bytes32("EXISTS"));
        _validate(params);
        uint32 v = 1;
        $.latestVer[key] = v;
        $.latestParams[key] = params;
        _writeArchive(key, v, params);
        emit PairAdded(key, v, params);
    }

    function updatePair(address collateral, address supply, Types.ParamsV1 calldata params) external restricted {
        bytes32 key = pairKey(collateral, supply);
        Storage storage $ = _store();
        uint32 old = $.latestVer[key];
        if (old == 0) revert Errors.PairNotActive(key);
        _validate(params);
        uint32 next = old + 1;
        $.latestVer[key] = next;
        $.latestParams[key] = params;
        _writeArchive(key, next, params);
        emit PairUpdated(key, old, next);
    }

    function pausePair(bytes32 key, bool p) external restricted {
        _store().paused[key] = p;
        emit PairPaused(key, p);
    }

    // --------------- views ---------------

    function latestVersion(bytes32 pair) external view returns (uint32) {
        return _store().latestVer[pair];
    }

    function getLatestParams(bytes32 pair) external view returns (Types.ParamsV1 memory) {
        return _store().latestParams[pair];
    }

    function getParams(bytes32 pair, uint32 version) external view returns (Types.ParamsV1 memory) {
        return _store().archive.readDecodedV1(pair, version);
    }

    function isPairActive(bytes32 pair) external view returns (bool) {
        Storage storage $ = _store();
        if ($.paused[pair]) return false;
        if ($.latestVer[pair] == 0) return false;
        return $.latestParams[pair].active;
    }

    function archive() external view returns (address) {
        return address(_store().archive);
    }

    // --------------- internals ---------------

    function _writeArchive(bytes32 key, uint32 version, Types.ParamsV1 memory params) internal {
        bytes memory enc = abi.encode(params);
        bytes32 h = keccak256(enc);
        Types.ParamSnapshot memory snap = Types.ParamSnapshot({schemaVersion: 1, paramsHash: h, encodedParams: enc});
        _store().archive.write(key, version, snap);
    }

    function _validate(Types.ParamsV1 calldata p) internal pure {
        if (!p.active) revert Errors.InvalidParams(bytes32("INACTIVE"));
        if (p.ltvBps == 0 || p.ltvBps >= 10_000) revert Errors.InvalidParams(bytes32("LTV"));
        // Liquidation thresholds: warning < partial < full
        if (!(p.warningBps > p.ltvBps && p.partialLiqBps > p.warningBps && p.fullLiqBps > p.partialLiqBps && p.fullLiqBps <= 10_000)) {
            revert Errors.InvalidParams(bytes32("LIQ_LADDER"));
        }
        if (p.maxRateBps == 0 || p.maxRateBps > 10_000) revert Errors.InvalidParams(bytes32("RATE"));
        if (p.maxMaturity == 0) revert Errors.InvalidParams(bytes32("MATURITY"));
        if (p.priceSourceCollateral == address(0) || p.priceSourceSupply == address(0)) {
            revert Errors.InvalidParams(bytes32("ORACLES"));
        }
        if (p.oracleDecimalsCollateral == 0 || p.oracleDecimalsSupply == 0) {
            revert Errors.InvalidParams(bytes32("ORACLE_DECIMALS"));
        }
        if (p.heartbeatCollateral == 0 || p.heartbeatSupply == 0) {
            revert Errors.InvalidParams(bytes32("HEARTBEAT"));
        }
        if (p.liquidationBonusBps > 2_000 || p.aminaFeeBps > 2_000) {
            revert Errors.InvalidParams(bytes32("FEES"));
        }
    }

    function _authorizeUpgrade(address) internal override restricted {}

    function _store() private pure returns (Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
