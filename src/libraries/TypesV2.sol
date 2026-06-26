// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TypesV2 -- Triora custody-backed lending data model.
library TypesV2 {
    enum AssuranceTier {
        Unknown,
        QualifiedCustody,
        SmartAccountPilot,
        Unsupported
    }

    enum PledgeStatus {
        None,
        Requested,
        Active,
        PartiallyEncumbered,
        FullyEncumbered,
        ReleasePending,
        Released,
        Liquidated,
        Frozen
    }

    enum ReserveStatus {
        None,
        Requested,
        Available,
        SettlementPending,
        Funded,
        Returned,
        Released,
        Frozen
    }

    enum DealStateV2 {
        None,
        SettlementPending,
        Active,
        Warned,
        RepaymentPending,
        Repaid,
        ReleasePending,
        Closed,
        LiquidationPending,
        Liquidated,
        Cancelled,
        Failed
    }

    enum DestinationType {
        None,
        Borrower,
        AminaDesk,
        LenderReserve
    }

    struct CustodyProof {
        bytes32 subjectId;
        bytes32 custodyAccountRef;
        address token;
        uint256 amount;
        uint8 decimals;
        uint64 observedAt;
        uint64 expiresAt;
        bytes32 evidenceHash;
    }

    struct CustodianConfig {
        address adapter;
        bool active;
        bytes32 legalHash;
        TypesV2.AssuranceTier minTier;
    }

    struct CustodyAccountRecord {
        bytes32 custodianId;
        bytes32 entityId;
        TypesV2.AssuranceTier tier;
        bool active;
        bytes32 policyHash;
    }

    struct Pledge {
        bytes32 entityId;
        bytes32 custodyAccountRef;
        bytes32 custodianId;
        address collateralToken;
        bytes32 assetId;
        uint256 pledgedAmount;
        uint256 mintedAmount;
        uint256 freeAmount;
        uint256 encumberedAmount;
        TypesV2.PledgeStatus status;
        bytes32 latestEvidenceHash;
        bytes32 controlAgreementHash;
        bytes32 activeDealId;
    }

    struct PledgeRequest {
        bytes32 pledgeId;
        bytes32 entityId;
        bytes32 custodyAccountRef;
        bytes32 custodianId;
        address collateralToken;
        bytes32 assetId;
        uint256 pledgedAmount;
        bytes32 controlAgreementHash;
    }

    struct Reserve {
        address owner;
        bytes32 entityId;
        bytes32 custodyAccountRef;
        bytes32 custodianId;
        address reserveToken;
        address asset;
        uint256 verifiedAmount;
        uint256 available;
        uint256 settlementPending;
        uint256 funded;
        TypesV2.ReserveStatus status;
        bytes32 latestEvidenceHash;
        bytes32 activeDealId;
    }

    struct ReserveRequest {
        bytes32 reserveId;
        address owner;
        bytes32 entityId;
        bytes32 custodyAccountRef;
        bytes32 custodianId;
        address reserveToken;
        address asset;
        uint256 amount;
    }

    struct DealIntentV2 {
        address lender;
        address borrower;
        address reserveToken;
        address collateralToken;
        uint128 principal;
        uint128 collateralAmount;
        uint32 rateBps;
        uint64 maturityTs;
        bytes32 pledgeId;
        bytes32 reserveId;
        bytes32 nonceLender;
        bytes32 nonceBorrower;
        bytes32 nonceAmina;
        bytes32 legalTermsHash;
        bytes32 borrowerReleaseRef;
        bytes32 lenderSettlementRef;
        bytes32 aminaLiquidationRef;
    }

    struct DealTermsV2 {
        address lender;
        address borrower;
        address reserveToken;
        address collateralToken;
        uint128 principal;
        uint128 collateralAmount;
        uint32 rateBps;
        uint64 maturityTs;
        bytes32 pledgeId;
        bytes32 reserveId;
        bytes32 legalTermsHash;
        bytes32 borrowerReleaseRef;
        bytes32 lenderSettlementRef;
        bytes32 aminaLiquidationRef;
    }

    struct DealRuntimeV2 {
        TypesV2.DealStateV2 state;
        uint128 outstanding;
        uint128 collateralLocked;
        uint64 interestStartTs;
        uint64 lastAccrualTs;
        uint64 settlementDeadline;
        uint64 lastTouchTs;
        bytes32 routeHash;
        bytes32 voucherId;
    }

    struct FundingAck {
        bytes32 dealId;
        bytes32 reserveId;
        uint256 amount;
        bytes32 routeHash;
        bytes32 settlementRef;
        bytes32 ackNonce;
        uint64 observedAt;
    }

    struct RepaymentAck {
        bytes32 dealId;
        uint256 amount;
        bytes32 routeHash;
        bytes32 settlementRef;
        bytes32 ackNonce;
        uint64 observedAt;
    }

    struct ReleaseAck {
        bytes32 voucherId;
        bytes32 dealId;
        bytes32 pledgeId;
        uint256 amount;
        bytes32 destinationRef;
        bytes32 ackNonce;
        uint64 observedAt;
    }

    struct FailureAck {
        bytes32 dealId;
        bytes32 routeHash;
        bytes32 reasonCode;
        bytes32 ackNonce;
        uint64 observedAt;
    }

    struct ReleaseVoucher {
        bytes32 voucherId;
        bytes32 dealId;
        bytes32 pledgeId;
        bytes32 assetId;
        uint256 amount;
        TypesV2.DestinationType destinationType;
        bytes32 destinationRef;
        bytes32 reason;
        uint64 sequenceNumber;
        uint64 issuedAt;
        uint64 expiresAt;
        bool consumed;
    }

    struct PriceAttestationV2 {
        bytes32 dealId;
        uint256 collateralPrice;
        uint256 reservePrice;
        uint8 collateralPriceDecimals;
        uint8 reservePriceDecimals;
        uint64 observationTs;
        bytes32 reasonCode;
    }
}
