// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title DealRegistryV2 -- immutable Triora deal terms and nonce registry.
contract DealRegistryV2 {
    address public immutable engine;

    mapping(bytes32 dealId => TypesV2.DealTermsV2) private _terms;
    mapping(bytes32 dealId => bool) private _exists;
    mapping(address signer => mapping(bytes32 nonce => bool)) private _nonceUsed;

    event DealRecorded(bytes32 indexed dealId, address indexed lender, address indexed borrower, bytes32 pledgeId, bytes32 reserveId);

    constructor(address engine_) {
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
    }

    function record(bytes32 dealId, TypesV2.DealTermsV2 calldata terms) external {
        if (msg.sender != engine) revert Errors.OnlyEngine();
        if (_exists[dealId]) revert Errors.DealAlreadyExists(dealId);
        _terms[dealId] = terms;
        _exists[dealId] = true;
        emit DealRecorded(dealId, terms.lender, terms.borrower, terms.pledgeId, terms.reserveId);
    }

    function getTerms(bytes32 dealId) external view returns (TypesV2.DealTermsV2 memory) {
        if (!_exists[dealId]) revert Errors.DealNotFound(dealId);
        return _terms[dealId];
    }

    function exists(bytes32 dealId) external view returns (bool) {
        return _exists[dealId];
    }

    function nonceUsed(address signer, bytes32 nonce) external view returns (bool) {
        return _nonceUsed[signer][nonce];
    }

    function markNonceUsed(address signer, bytes32 nonce) external {
        if (msg.sender != engine) revert Errors.OnlyEngine();
        _nonceUsed[signer][nonce] = true;
    }
}
