// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";

interface ILendingEngineAcks {
    function confirmFunding(bytes32 positionId, bytes32 settlementRef) external;
    function confirmRepayment(bytes32 positionId, bytes32 settlementRef) external;
}

/// @title SettlementAcker
/// @notice The on-chain analogue of "AMINA mandatory co-signer" for the OFF-CHAIN real-USDC transfer
///         (Model A, ADR-0001 / Tech Spec S8). It consumes **dual (custodian + AMINA) EIP-712 acks**
///         attesting that the single custody→custody USDC transfer happened, then advances the deal
///         (`confirmFunding` / `confirmRepayment`). It moves NO funds; it only verifies signatures and
///         drives the engine. The engine accepts these calls ONLY from this contract.
contract SettlementAcker is TrioraAccess, EIP712 {
    bytes32 private constant FUNDING_ACK_TYPEHASH = keccak256(
        "FundingAck(bytes32 positionId,uint256 amount,bytes32 settlementRef,uint64 observedAt,uint64 expiresAt)"
    );
    bytes32 private constant REPAYMENT_ACK_TYPEHASH = keccak256(
        "RepaymentAck(bytes32 positionId,uint256 amount,bytes32 settlementRef,uint64 observedAt,uint64 expiresAt)"
    );
    uint64 public constant MAX_CLOCK_SKEW = 5 minutes;

    ILendingEngineAcks public immutable engine;
    address public custodianSigner;
    address public aminaSigner;
    mapping(bytes32 => bool) public usedRef; // settlementRef => consumed

    struct Ack {
        bytes32 positionId;
        uint256 amount;
        bytes32 settlementRef;
        uint64 observedAt;
        uint64 expiresAt;
    }

    event SignersSet(address custodianSigner, address aminaSigner);
    event FundingAcked(bytes32 indexed positionId, bytes32 settlementRef);
    event RepaymentAcked(bytes32 indexed positionId, bytes32 settlementRef);

    constructor(address roleManager_, address engine_, address custodianSigner_, address aminaSigner_)
        TrioraAccess(roleManager_)
        EIP712("TrioraSettlementAcker", "1")
    {
        if (engine_ == address(0) || custodianSigner_ == address(0) || aminaSigner_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        engine = ILendingEngineAcks(engine_);
        custodianSigner = custodianSigner_;
        aminaSigner = aminaSigner_;
    }

    function setSigners(address custodianSigner_, address aminaSigner_) external restricted(Roles.CURATOR) {
        if (custodianSigner_ == address(0) || aminaSigner_ == address(0)) revert Errors.ZeroAddress();
        custodianSigner = custodianSigner_;
        aminaSigner = aminaSigner_;
        emit SignersSet(custodianSigner_, aminaSigner_);
    }

    function ackFunding(Ack calldata a, bytes calldata custodianSig, bytes calldata aminaSig) external {
        _verify(FUNDING_ACK_TYPEHASH, a, custodianSig, aminaSig);
        usedRef[a.settlementRef] = true;
        engine.confirmFunding(a.positionId, a.settlementRef);
        emit FundingAcked(a.positionId, a.settlementRef);
    }

    function ackRepayment(Ack calldata a, bytes calldata custodianSig, bytes calldata aminaSig) external {
        _verify(REPAYMENT_ACK_TYPEHASH, a, custodianSig, aminaSig);
        usedRef[a.settlementRef] = true;
        engine.confirmRepayment(a.positionId, a.settlementRef);
        emit RepaymentAcked(a.positionId, a.settlementRef);
    }

    function _verify(bytes32 typeHash, Ack calldata a, bytes calldata custodianSig, bytes calldata aminaSig)
        internal
        view
    {
        if (a.observedAt > block.timestamp + MAX_CLOCK_SKEW) revert Errors.AttestationFromFuture();
        if (a.expiresAt <= block.timestamp) revert Errors.AttestationExpired();
        if (usedRef[a.settlementRef]) revert Errors.VoucherConsumed(a.settlementRef);
        bytes32 structHash =
            keccak256(abi.encode(typeHash, a.positionId, a.amount, a.settlementRef, a.observedAt, a.expiresAt));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(custodianSigner, digest, custodianSig)) revert Errors.BadSignature();
        if (!SignatureChecker.isValidSignatureNow(aminaSigner, digest, aminaSig)) revert Errors.BadSignature();
    }
}
