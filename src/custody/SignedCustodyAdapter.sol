// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {ICustodyAdapter} from "../interfaces/ITriora.sol";

/// @title SignedCustodyAdapter
/// @notice Brings off-chain custody facts on-chain as **dual (custodian + AMINA) EIP-712 attestations**
///         (Tech Spec S3). No contract calls a custodian API; facts arrive as signed evidence.
///         Implements {ICustodyAdapter}/{IReserveSource} → feeds {ReserveGuard} and {PledgeRegistry}.
/// @dev Two proof types: per-pledge proofs (lock + amount + control-agreement hash) and a token-level
///      reserve proof (the Proof-of-Reserve figure). Both require BOTH signers. ERC-1271 supported.
contract SignedCustodyAdapter is ICustodyAdapter, TrioraAccess, EIP712 {
    bytes32 private constant PLEDGE_PROOF_TYPEHASH = keccak256(
        "PledgeProof(bytes32 pledgeId,bytes32 custodyAccountRef,address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt,bytes32 controlAgreementHash)"
    );
    bytes32 private constant RESERVE_PROOF_TYPEHASH =
        keccak256("ReserveProof(address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt)");

    uint64 public constant MAX_CLOCK_SKEW = 5 minutes;

    address public custodianSigner;
    address public aminaSigner;

    struct PledgeProof {
        bytes32 custodyAccountRef;
        address token;
        uint256 amount;
        uint8 decimals;
        uint64 observedAt;
        uint64 expiresAt;
        bytes32 controlAgreementHash;
    }

    struct ReserveProof {
        uint256 amount;
        uint8 decimals;
        uint64 observedAt;
        uint64 expiresAt;
    }

    mapping(bytes32 => PledgeProof) public pledgeProof; // pledgeId => proof
    mapping(address => ReserveProof) public reserveProof; // token => proof

    event SignersSet(address custodianSigner, address aminaSigner);
    event PledgeProofSubmitted(bytes32 indexed pledgeId, address token, uint256 amount, uint64 expiresAt);
    event ReserveProofSubmitted(address indexed token, uint256 amount, uint64 expiresAt);

    constructor(address roleManager_, address custodianSigner_, address aminaSigner_)
        TrioraAccess(roleManager_)
        EIP712("TrioraCustodyAdapter", "1")
    {
        if (custodianSigner_ == address(0) || aminaSigner_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        custodianSigner = custodianSigner_;
        aminaSigner = aminaSigner_;
        emit SignersSet(custodianSigner_, aminaSigner_);
    }

    function setSigners(address custodianSigner_, address aminaSigner_) external restricted(Roles.CURATOR) {
        if (custodianSigner_ == address(0) || aminaSigner_ == address(0)) revert Errors.ZeroAddress();
        custodianSigner = custodianSigner_;
        aminaSigner = aminaSigner_;
        emit SignersSet(custodianSigner_, aminaSigner_);
    }

    // ── attestation submission (dual signed) ──────────────────────────────────

    function submitPledgeProof(
        bytes32 pledgeId,
        PledgeProof calldata p,
        bytes calldata custodianSig,
        bytes calldata aminaSig
    ) external {
        _checkFreshness(p.observedAt, p.expiresAt);
        if (p.amount == 0) revert Errors.ZeroAmount();
        // monotonic: never accept an older observation than the stored one
        if (p.observedAt <= pledgeProof[pledgeId].observedAt) revert Errors.AttestationExpired();

        bytes32 structHash = keccak256(
            abi.encode(
                PLEDGE_PROOF_TYPEHASH,
                pledgeId,
                p.custodyAccountRef,
                p.token,
                p.amount,
                p.decimals,
                p.observedAt,
                p.expiresAt,
                p.controlAgreementHash
            )
        );
        _verifyDual(structHash, custodianSig, aminaSig);

        pledgeProof[pledgeId] = p;
        emit PledgeProofSubmitted(pledgeId, p.token, p.amount, p.expiresAt);
    }

    function submitReserveProof(
        address token,
        uint256 amount,
        uint8 decimals,
        uint64 observedAt,
        uint64 expiresAt,
        bytes calldata custodianSig,
        bytes calldata aminaSig
    ) external {
        _checkFreshness(observedAt, expiresAt);
        if (observedAt <= reserveProof[token].observedAt) revert Errors.AttestationExpired();

        bytes32 structHash =
            keccak256(abi.encode(RESERVE_PROOF_TYPEHASH, token, amount, decimals, observedAt, expiresAt));
        _verifyDual(structHash, custodianSig, aminaSig);

        reserveProof[token] = ReserveProof(amount, decimals, observedAt, expiresAt);
        emit ReserveProofSubmitted(token, amount, expiresAt);
    }

    // ── ICustodyAdapter / IReserveSource ──────────────────────────────────────

    function attestedReserves(address token) external view returns (uint256 amount, uint64 asOf, uint8 decimals) {
        ReserveProof storage r = reserveProof[token];
        // expired reserve proof reports asOf=0 so the guard treats it as stale (fail-closed).
        if (r.expiresAt <= block.timestamp) return (r.amount, 0, r.decimals);
        return (r.amount, r.observedAt, r.decimals);
    }

    function isLockActive(bytes32 pledgeId) external view returns (bool) {
        PledgeProof storage p = pledgeProof[pledgeId];
        return p.amount > 0 && p.expiresAt > block.timestamp;
    }

    function verifyPledge(bytes32 pledgeId, address token, uint256 amount) external view returns (bool) {
        PledgeProof storage p = pledgeProof[pledgeId];
        return p.token == token && p.amount >= amount && p.expiresAt > block.timestamp;
    }

    // ── internals ─────────────────────────────────────────────────────────────

    function _checkFreshness(uint64 observedAt, uint64 expiresAt) internal view {
        if (observedAt > block.timestamp + MAX_CLOCK_SKEW) revert Errors.AttestationFromFuture();
        if (expiresAt <= block.timestamp) revert Errors.AttestationExpired();
    }

    function _verifyDual(bytes32 structHash, bytes calldata custodianSig, bytes calldata aminaSig) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(custodianSigner, digest, custodianSig)) revert Errors.BadSignature();
        if (!SignatureChecker.isValidSignatureNow(aminaSigner, digest, aminaSig)) revert Errors.BadSignature();
    }
}
