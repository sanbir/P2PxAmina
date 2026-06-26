// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ILendingEngineV2} from "../interfaces/ILendingEngineV2.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {EIP712HashesV2} from "../libraries/EIP712HashesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title SettlementAcker -- BitGo plus AMINA signed settlement acknowledgement verifier.
contract SettlementAcker is AccessManaged, EIP712, ReentrancyGuard {
    ILendingEngineV2 public immutable engine;

    address public bitgoSigner;
    address public aminaSigner;
    uint64 public maxAckAge;

    event SignersSet(address indexed bitgoSigner, address indexed aminaSigner);
    event MaxAckAgeSet(uint64 maxAckAge);
    event FundingAcked(bytes32 indexed dealId, bytes32 indexed ackNonce);
    event RepaymentAcked(bytes32 indexed dealId, bytes32 indexed ackNonce);
    event ReleaseAcked(bytes32 indexed dealId, bytes32 indexed voucherId, bytes32 indexed ackNonce);
    event FailureAcked(bytes32 indexed dealId, bytes32 indexed ackNonce, bytes32 reasonCode);

    error BadAckSigner(address expected);
    error AckTooOld(bytes32 ackNonce);
    error AckFromFuture(bytes32 ackNonce);

    constructor(address authority_, address engine_, address bitgoSigner_, address aminaSigner_)
        AccessManaged(authority_)
        EIP712("TrioraSettlementAcker", "1")
    {
        if (engine_ == address(0) || bitgoSigner_ == address(0) || aminaSigner_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        engine = ILendingEngineV2(engine_);
        bitgoSigner = bitgoSigner_;
        aminaSigner = aminaSigner_;
        maxAckAge = 1 days;
        emit SignersSet(bitgoSigner_, aminaSigner_);
        emit MaxAckAgeSet(maxAckAge);
    }

    function setSigners(address bitgoSigner_, address aminaSigner_) external restricted {
        if (bitgoSigner_ == address(0) || aminaSigner_ == address(0)) revert Errors.ZeroAddress();
        bitgoSigner = bitgoSigner_;
        aminaSigner = aminaSigner_;
        emit SignersSet(bitgoSigner_, aminaSigner_);
    }

    function setMaxAckAge(uint64 maxAckAge_) external restricted {
        maxAckAge = maxAckAge_;
        emit MaxAckAgeSet(maxAckAge_);
    }

    function ackFunding(TypesV2.FundingAck calldata ack, bytes calldata bitgoSig, bytes calldata aminaSig)
        external
        nonReentrant
    {
        _checkAckTime(ack.ackNonce, ack.observedAt);
        _checkSignatures(_hashTypedDataV4(EIP712HashesV2.hashFundingAck(ack)), bitgoSig, aminaSig);
        engine.confirmFunding(ack);
        emit FundingAcked(ack.dealId, ack.ackNonce);
    }

    function ackRepayment(TypesV2.RepaymentAck calldata ack, bytes calldata bitgoSig, bytes calldata aminaSig)
        external
        nonReentrant
    {
        _checkAckTime(ack.ackNonce, ack.observedAt);
        _checkSignatures(_hashTypedDataV4(EIP712HashesV2.hashRepaymentAck(ack)), bitgoSig, aminaSig);
        engine.confirmRepayment(ack);
        emit RepaymentAcked(ack.dealId, ack.ackNonce);
    }

    function ackRelease(TypesV2.ReleaseAck calldata ack, bytes calldata bitgoSig, bytes calldata aminaSig)
        external
        nonReentrant
    {
        _checkAckTime(ack.ackNonce, ack.observedAt);
        _checkSignatures(_hashTypedDataV4(EIP712HashesV2.hashReleaseAck(ack)), bitgoSig, aminaSig);
        engine.confirmRelease(ack);
        emit ReleaseAcked(ack.dealId, ack.voucherId, ack.ackNonce);
    }

    function ackFailure(TypesV2.FailureAck calldata ack, bytes calldata bitgoSig, bytes calldata aminaSig)
        external
        nonReentrant
    {
        _checkAckTime(ack.ackNonce, ack.observedAt);
        _checkSignatures(_hashTypedDataV4(EIP712HashesV2.hashFailureAck(ack)), bitgoSig, aminaSig);
        engine.markSettlementFailed(ack);
        emit FailureAcked(ack.dealId, ack.ackNonce, ack.reasonCode);
    }

    function hashFundingAck(TypesV2.FundingAck calldata ack) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashFundingAck(ack));
    }

    function hashRepaymentAck(TypesV2.RepaymentAck calldata ack) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashRepaymentAck(ack));
    }

    function hashReleaseAck(TypesV2.ReleaseAck calldata ack) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashReleaseAck(ack));
    }

    function hashFailureAck(TypesV2.FailureAck calldata ack) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashFailureAck(ack));
    }

    function _checkSignatures(bytes32 digest, bytes calldata bitgoSig, bytes calldata aminaSig) internal view {
        if (!SignatureChecker.isValidSignatureNow(bitgoSigner, digest, bitgoSig)) revert BadAckSigner(bitgoSigner);
        if (!SignatureChecker.isValidSignatureNow(aminaSigner, digest, aminaSig)) revert BadAckSigner(aminaSigner);
    }

    function _checkAckTime(bytes32 ackNonce, uint64 observedAt) internal view {
        if (observedAt > block.timestamp + 5 minutes) revert AckFromFuture(ackNonce);
        if (maxAckAge != 0 && block.timestamp - uint256(observedAt) > uint256(maxAckAge)) revert AckTooOld(ackNonce);
    }
}
