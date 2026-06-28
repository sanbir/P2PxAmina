// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title KYBGateway
/// @notice Wallet/entity approval gate. AMINA (CURATOR) owns approval decisions; the gate
///         only stores the resulting status. Every state-changing user action consults it.
/// @dev Tech Spec S1. Status carries an expiry → forces periodic re-attestation.
contract KYBGateway is TrioraAccess {
    enum Status {
        Unknown,
        Approved,
        Suspended,
        Revoked
    }

    struct Record {
        Status status;
        uint64 approvedAt;
        uint64 expiryTs;
        bytes32 jurisdiction;
        bytes32 docsHash;
    }

    mapping(address => Record) private _records;

    event StatusSet(address indexed who, Status status, uint64 expiryTs, bytes32 jurisdiction, bytes32 docsHash);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    /// @notice AMINA sets KYB status for a wallet. Off-chain KYB decision is imported here.
    function setStatus(address who, Status status, uint64 expiryTs, bytes32 jurisdiction, bytes32 docsHash)
        external
        restricted(Roles.CURATOR)
    {
        if (who == address(0)) revert Errors.ZeroAddress();
        _records[who] = Record({
            status: status,
            approvedAt: uint64(block.timestamp),
            expiryTs: expiryTs,
            jurisdiction: jurisdiction,
            docsHash: docsHash
        });
        emit StatusSet(who, status, expiryTs, jurisdiction, docsHash);
    }

    function isApproved(address who) public view returns (bool) {
        Record storage r = _records[who];
        return r.status == Status.Approved && (r.expiryTs == 0 || r.expiryTs > block.timestamp);
    }

    /// @notice Reverts if `who` is not currently approved. Called by the engine before any deal action.
    function requireApproved(address who) external view {
        if (!isApproved(who)) revert Errors.NotApproved(who);
    }

    function getRecord(address who) external view returns (Record memory) {
        return _records[who];
    }
}
