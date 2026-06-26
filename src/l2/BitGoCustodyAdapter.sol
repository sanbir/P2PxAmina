// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ICustodyAdapter, IBitGoCustodyAdapter} from "../interfaces/ICustodyAdapter.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {EIP712HashesV2} from "../libraries/EIP712HashesV2.sol";

/// @title BitGoCustodyAdapter -- typed BitGo plus AMINA custody evidence adapter.
/// @notice Models BitGo custody details as signed, on-chain attestations. It never calls BitGo APIs.
contract BitGoCustodyAdapter is AccessManaged, EIP712, IBitGoCustodyAdapter {
    address public bitgoSigner;
    address public aminaSigner;
    uint64 public maxClockSkew;

    mapping(bytes32 subjectId => TypesV2.CustodyProof) private _latestProof;
    mapping(bytes32 custodyAccountRef => bool) private _controlActive;

    event SignersSet(address indexed bitgoSigner, address indexed aminaSigner);
    event MaxClockSkewSet(uint64 seconds_);
    event CustodyProofAccepted(
        bytes32 indexed subjectId,
        bytes32 indexed custodyAccountRef,
        address indexed token,
        uint256 amount,
        uint64 observedAt,
        uint64 expiresAt,
        bytes32 evidenceHash
    );

    error BadSigner(address expected);
    error StaleProof();
    error FutureProof();
    error ZeroSigner();

    constructor(address authority_, address bitgoSigner_, address aminaSigner_)
        AccessManaged(authority_)
        EIP712("TrioraBitGoAdapter", "1")
    {
        if (bitgoSigner_ == address(0) || aminaSigner_ == address(0)) revert ZeroSigner();
        bitgoSigner = bitgoSigner_;
        aminaSigner = aminaSigner_;
        maxClockSkew = 5 minutes;
        emit SignersSet(bitgoSigner_, aminaSigner_);
        emit MaxClockSkewSet(5 minutes);
    }

    function setSigners(address bitgoSigner_, address aminaSigner_) external restricted {
        if (bitgoSigner_ == address(0) || aminaSigner_ == address(0)) revert ZeroSigner();
        bitgoSigner = bitgoSigner_;
        aminaSigner = aminaSigner_;
        emit SignersSet(bitgoSigner_, aminaSigner_);
    }

    function setMaxClockSkew(uint64 seconds_) external restricted {
        maxClockSkew = seconds_;
        emit MaxClockSkewSet(seconds_);
    }

    function submitProof(TypesV2.CustodyProof calldata proof, bytes calldata bitgoSig, bytes calldata aminaSig)
        external
        returns (bytes32 subjectId)
    {
        _verifyProof(proof, bitgoSig, aminaSig);
        _latestProof[proof.subjectId] = proof;
        _controlActive[proof.custodyAccountRef] = true;
        emit CustodyProofAccepted(
            proof.subjectId,
            proof.custodyAccountRef,
            proof.token,
            proof.amount,
            proof.observedAt,
            proof.expiresAt,
            proof.evidenceHash
        );
        return proof.subjectId;
    }

    function hashCustodyProof(TypesV2.CustodyProof calldata proof) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashCustodyProof(proof));
    }

    function verifyCustodyAttestation(bytes calldata attestation)
        external
        view
        returns (bool ok, bytes32 subjectId, uint256 amount, uint64 observedAt, bytes32 reason)
    {
        (TypesV2.CustodyProof memory proof, bytes memory bitgoSig, bytes memory aminaSig) =
            abi.decode(attestation, (TypesV2.CustodyProof, bytes, bytes));
        bool valid = _isProofValid(proof, bitgoSig, aminaSig);
        if (!valid) return (false, proof.subjectId, proof.amount, proof.observedAt, bytes32("BAD_PROOF"));
        return (true, proof.subjectId, proof.amount, proof.observedAt, bytes32(0));
    }

    function latestReserve(bytes32 subjectId)
        external
        view
        returns (uint256 amount, uint8 decimals_, uint64 observedAt, uint64 expiresAt)
    {
        TypesV2.CustodyProof storage proof = _latestProof[subjectId];
        return (proof.amount, proof.decimals, proof.observedAt, proof.expiresAt);
    }

    function latestProof(bytes32 subjectId) external view returns (TypesV2.CustodyProof memory) {
        return _latestProof[subjectId];
    }

    function isControlActive(bytes32 custodyAccountRef) external view returns (bool) {
        return _controlActive[custodyAccountRef];
    }

    function _verifyProof(TypesV2.CustodyProof calldata proof, bytes calldata bitgoSig, bytes calldata aminaSig)
        internal
        view
    {
        if (proof.observedAt > block.timestamp + maxClockSkew) revert FutureProof();
        if (proof.expiresAt <= block.timestamp) revert StaleProof();
        bytes32 digest = _hashTypedDataV4(EIP712HashesV2.hashCustodyProof(proof));
        if (!SignatureChecker.isValidSignatureNow(bitgoSigner, digest, bitgoSig)) revert BadSigner(bitgoSigner);
        if (!SignatureChecker.isValidSignatureNow(aminaSigner, digest, aminaSig)) revert BadSigner(aminaSigner);
    }

    function _isProofValid(TypesV2.CustodyProof memory proof, bytes memory bitgoSig, bytes memory aminaSig)
        internal
        view
        returns (bool)
    {
        if (proof.observedAt > block.timestamp + maxClockSkew) return false;
        if (proof.expiresAt <= block.timestamp) return false;
        bytes32 digest = _hashTypedDataV4(EIP712HashesV2.hashCustodyProof(proof));
        return SignatureChecker.isValidSignatureNow(bitgoSigner, digest, bitgoSig)
            && SignatureChecker.isValidSignatureNow(aminaSigner, digest, aminaSig);
    }
}
