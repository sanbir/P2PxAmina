// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Errors — protocol-wide custom errors.
library Errors {
    // L1
    error NotKybApproved(address who);
    error KybExpired(address who);
    error IssuerNotActive(address issuer);
    error TokenPaused(address token);
    error TokenNotAdmitted(address token);
    error TokenAdmissionFailed(address token, bytes32 reasonCode);
    error DualUseDisabled(address token);
    error WrongTokenKind();
    error CapExceeded(bytes32 dimension);

    // L2
    error PairNotActive(bytes32 pairKey);
    error InvalidParams(bytes32 reasonCode);
    error OracleStale(address feed);
    error ParamsSchemaUnsupported(uint16 schemaVersion);
    error ParamsHashMismatch();

    // L3
    error DealAlreadyExists(bytes32 dealId);
    error DealNotFound(bytes32 dealId);
    error DealNotActive(bytes32 dealId);
    error DealNotTerminal(bytes32 dealId);
    error DealStateForbidden(bytes32 dealId, uint8 actualState);
    error NonceUsed(address who, bytes32 nonce);
    error InvalidSignature(address expected);
    error TermsMismatch();
    error MaturityExpired();
    error MaturityNotReached();
    error PrincipalTooHigh();
    error CollateralTooLow();
    error PauseClockArithmetic();
    error EngineAlreadyBound();
    error OnlyEngine();
    error ZeroAmount();
    error InsufficientLedger();
    error ZeroAddress();
    error GloballyHalted();
    error EmergencySealed();
    error DealPausedFor(bytes32 dealId, bytes32 reason);
    error DealNotPaused(bytes32 dealId);

    // L4
    error StepOutOfOrder(uint8 currentStep, uint8 requestedStep);
    error LiquidationNotAllowedYet();
    error LiquidationBoundExceeded();
    error AttestationStale();
    error AttestationDealIdMismatch();
    error AttestationSignerMismatch(address expected, address actual);

    // L5 / general
    error InvalidCaller(address who);
}
