// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title PositionRegistry
/// @notice Write-once immutable record of each position's economic + legal terms (Tech Spec S9).
///         The {CollateralBridge} holds mutable runtime state; the terms here never change — the
///         immutable audit of the obligation.
contract PositionRegistry is TrioraAccess {
    struct Terms {
        address borrower;
        bytes32 pledgeId;
        uint256 principal;
        uint32 rateBps;
        uint64 startTs;
        uint64 maturityTs;
        bytes32 marketId;
        bytes32 legalTermsHash;
    }

    mapping(bytes32 => Terms) private _terms;

    event TermsRecorded(bytes32 indexed positionId, address indexed borrower, uint256 principal);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    function record(bytes32 positionId, Terms calldata t) external restricted(Roles.ENGINE) {
        if (_terms[positionId].startTs != 0) revert Errors.AlreadySet();
        _terms[positionId] = t;
        emit TermsRecorded(positionId, t.borrower, t.principal);
    }

    function getTerms(bytes32 positionId) external view returns (Terms memory) {
        return _terms[positionId];
    }
}
