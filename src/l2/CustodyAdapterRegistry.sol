// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ICustodyAdapterRegistry} from "../interfaces/ICustodyAdapter.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title CustodyAdapterRegistry -- custody provider, adapter, and account eligibility registry.
contract CustodyAdapterRegistry is AccessManaged, ICustodyAdapterRegistry {
    mapping(bytes32 custodianId => TypesV2.CustodianConfig) private _custodians;
    mapping(bytes32 accountRef => TypesV2.CustodyAccountRecord) private _accounts;

    event CustodianSet(bytes32 indexed custodianId, address indexed adapter, bool active, bytes32 legalHash);
    event CustodyAccountRegistered(
        bytes32 indexed custodyAccountRef,
        bytes32 indexed custodianId,
        bytes32 indexed entityId,
        TypesV2.AssuranceTier tier,
        bool active,
        bytes32 policyHash
    );
    event CustodyAccountStatusSet(bytes32 indexed custodyAccountRef, bool active);
    event CustodyAccountTierSet(bytes32 indexed custodyAccountRef, TypesV2.AssuranceTier tier);

    error UnknownCustodian(bytes32 custodianId);
    error CustodianPaused(bytes32 custodianId);
    error AccountIneligible(bytes32 custodyAccountRef);

    constructor(address authority_) AccessManaged(authority_) {}

    function addCustodian(bytes32 custodianId, TypesV2.CustodianConfig calldata cfg) external restricted {
        if (custodianId == bytes32(0) || cfg.adapter == address(0)) revert Errors.ZeroAddress();
        _custodians[custodianId] = cfg;
        emit CustodianSet(custodianId, cfg.adapter, cfg.active, cfg.legalHash);
    }

    function setAdapter(bytes32 custodianId, address adapter) external restricted {
        if (adapter == address(0)) revert Errors.ZeroAddress();
        TypesV2.CustodianConfig storage cfg = _custodians[custodianId];
        if (cfg.adapter == address(0)) revert UnknownCustodian(custodianId);
        cfg.adapter = adapter;
        emit CustodianSet(custodianId, adapter, cfg.active, cfg.legalHash);
    }

    function setCustodianActive(bytes32 custodianId, bool active) external restricted {
        TypesV2.CustodianConfig storage cfg = _custodians[custodianId];
        if (cfg.adapter == address(0)) revert UnknownCustodian(custodianId);
        cfg.active = active;
        emit CustodianSet(custodianId, cfg.adapter, active, cfg.legalHash);
    }

    function registerCustodyAccount(
        bytes32 custodyAccountRef,
        bytes32 custodianId,
        bytes32 entityId,
        TypesV2.AssuranceTier tier,
        bytes32 policyHash
    ) external restricted {
        TypesV2.CustodianConfig storage cfg = _custodians[custodianId];
        if (cfg.adapter == address(0)) revert UnknownCustodian(custodianId);
        if (!cfg.active) revert CustodianPaused(custodianId);
        _accounts[custodyAccountRef] = TypesV2.CustodyAccountRecord({
            custodianId: custodianId,
            entityId: entityId,
            tier: tier,
            active: true,
            policyHash: policyHash
        });
        emit CustodyAccountRegistered(custodyAccountRef, custodianId, entityId, tier, true, policyHash);
    }

    function setAccountActive(bytes32 custodyAccountRef, bool active) external restricted {
        _accounts[custodyAccountRef].active = active;
        emit CustodyAccountStatusSet(custodyAccountRef, active);
    }

    function setAssuranceTier(bytes32 custodyAccountRef, TypesV2.AssuranceTier tier) external restricted {
        _accounts[custodyAccountRef].tier = tier;
        emit CustodyAccountTierSet(custodyAccountRef, tier);
    }

    function adapterOf(bytes32 custodianId) external view returns (address) {
        TypesV2.CustodianConfig storage cfg = _custodians[custodianId];
        if (cfg.adapter == address(0)) revert UnknownCustodian(custodianId);
        if (!cfg.active) revert CustodianPaused(custodianId);
        return cfg.adapter;
    }

    function custodian(bytes32 custodianId) external view returns (TypesV2.CustodianConfig memory) {
        return _custodians[custodianId];
    }

    function custodyAccount(bytes32 custodyAccountRef) external view returns (TypesV2.CustodyAccountRecord memory) {
        return _accounts[custodyAccountRef];
    }

    function isCustodyAccountEligible(bytes32 custodianId, bytes32 custodyAccountRef) external view returns (bool) {
        TypesV2.CustodianConfig storage cfg = _custodians[custodianId];
        TypesV2.CustodyAccountRecord storage account = _accounts[custodyAccountRef];
        if (cfg.adapter == address(0) || !cfg.active) return false;
        if (!account.active || account.custodianId != custodianId) return false;
        if (account.tier == TypesV2.AssuranceTier.Unsupported || account.tier == TypesV2.AssuranceTier.Unknown) {
            return false;
        }
        return uint8(account.tier) >= uint8(cfg.minTier);
    }
}
