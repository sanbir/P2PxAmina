// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";

interface ICustodyAdapter {
    function verifyCustodyAttestation(bytes calldata attestation)
        external
        view
        returns (bool ok, bytes32 subjectId, uint256 amount, uint64 observedAt, bytes32 reason);

    function latestReserve(bytes32 subjectId)
        external
        view
        returns (uint256 amount, uint8 decimals, uint64 observedAt, uint64 expiresAt);

    function isControlActive(bytes32 custodyAccountRef) external view returns (bool);
}

interface ICustodyAdapterRegistry {
    function adapterOf(bytes32 custodianId) external view returns (address);
    function isCustodyAccountEligible(bytes32 custodianId, bytes32 custodyAccountRef) external view returns (bool);
}

interface IBitGoCustodyAdapter is ICustodyAdapter {
    function hashCustodyProof(TypesV2.CustodyProof calldata proof) external view returns (bytes32);
}
