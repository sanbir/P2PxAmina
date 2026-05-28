// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDealRegistry} from "../interfaces/IDealRegistry.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title DealRegistry — immutable, write-once book of deals.
/// @notice Stores `DealTerms` keyed by `dealId`. Once recorded, terms
///         are never mutated. Engine binding is set-once in the
///         constructor.
contract DealRegistry is IDealRegistry {
    address public immutable engine;

    mapping(bytes32 => Types.DealTerms) private _terms;
    mapping(bytes32 => bool) private _exists;
    mapping(address => mapping(bytes32 => bool)) private _nonceUsed;

    event DealRecorded(bytes32 indexed dealId, address indexed lender, address indexed borrower);

    constructor(address engine_) {
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
    }

    function record(bytes32 dealId, Types.DealTerms calldata terms) external {
        if (msg.sender != engine) revert Errors.OnlyEngine();
        if (_exists[dealId]) revert Errors.DealAlreadyExists(dealId);
        _terms[dealId] = terms;
        _exists[dealId] = true;
        emit DealRecorded(dealId, terms.lender, terms.borrower);
    }

    function getTerms(bytes32 dealId) external view returns (Types.DealTerms memory) {
        if (!_exists[dealId]) revert Errors.DealNotFound(dealId);
        return _terms[dealId];
    }

    function exists(bytes32 dealId) external view returns (bool) {
        return _exists[dealId];
    }

    function nonceUsed(address who, bytes32 nonce) external view returns (bool) {
        return _nonceUsed[who][nonce];
    }

    function markNonceUsed(address who, bytes32 nonce) external {
        if (msg.sender != engine) revert Errors.OnlyEngine();
        _nonceUsed[who][nonce] = true;
    }
}
