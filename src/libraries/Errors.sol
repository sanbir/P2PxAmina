// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Errors
/// @notice Protocol-wide custom errors (categorized). Cheaper + more precise than strings.
library Errors {
    // generic
    error ZeroAddress();
    error ZeroAmount();
    error ZeroValue();
    error NotAuthorized(bytes32 role, address caller);
    error Paused();
    error AlreadySet();
    error BadConfig();

    // identity / kyb
    error NotApproved(address who);

    // custody / attestation
    error BadSignature();
    error AttestationExpired();
    error AttestationFromFuture();
    error LockNotActive(bytes32 pledgeId);
    error UnknownPledge(bytes32 pledgeId);

    // reserves / secure-mint
    error ReserveStale();
    error ReserveExceeded(uint256 supplyAfter, uint256 limit);
    error ReserveSourceMissing();
    error ReserveDiscrepancy(uint256 a, uint256 b);

    // token
    error TransferRestricted(address from, address to);
    error MintExceedsPledge(uint256 mintedAfter, uint256 pledged);

    // pledge
    error PledgeNotFree(bytes32 pledgeId);
    error PledgeBound(bytes32 pledgeId);
    error BadPledgeStatus(uint8 status);

    // position / engine
    error UnknownPosition(bytes32 positionId);
    error BadPositionState(uint8 state);
    error LtvExceeded(uint256 requested, uint256 maxBorrow);
    error MarketInactive();
    error MaturityInPast();
    error RateTooHigh(uint32 rateBps);
    error CapExceeded();
    error NotMatured();
    error StillHealthy();

    // oracle
    error PriceStale();
    error BadPrice();

    // liquidation / release
    error CureWindowActive(uint64 deadline);
    error CureWindowNotElapsed(uint64 deadline);
    error NoPendingLiquidation();
    error ReportReused(bytes32 reportRef);
    error VoucherConsumed(bytes32 voucherId);
    error VoucherInvalid(bytes32 voucherId);
    error BadDestination();
}
