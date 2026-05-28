// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types — canonical structs / enums shared across P2PxAmina.
/// @notice Mirrors the data model documented in
///         `docs/Claude-architechture-3.md` §8. Centralised here so
///         every contract sees the same layout.
library Types {
    // ------------------------------------------------------------------
    // L1 Identity
    // ------------------------------------------------------------------

    enum KybStatus {
        None, // 0
        Pending, // 1
        Approved, // 2
        Suspended, // 3
        Expired // 4
    }

    struct KybRecord {
        KybStatus status;
        uint64 approvedAt;
        uint64 expiryTs;
        bytes32 documentsHash;
        address approvedBy;
        bytes32 jurisdictionCode;
    }

    enum IssuerStatus {
        Unknown, // 0
        Active, // 1
        Paused, // 2
        Deactivated // 3
    }

    enum TokenKind {
        Unknown, // 0
        Supply, // 1
        Collateral, // 2
        DualUse_DisabledByDefault // 3
    }

    struct IssuerInfo {
        address custodian;
        IssuerStatus status;
        bytes32 legalAttestationHash;
        uint256 globalCapUsd;
        uint256 usedCapUsd;
    }

    struct TokenInfo {
        address issuer;
        TokenKind kind;
        bool dualUseEnabled;
        uint8 decimals;
        bool paused;
        uint256 capUsd;
        uint256 usedCapUsd;
        bytes32 redemptionAttestationHash;
        bool nonStandardChecked;
    }

    // ------------------------------------------------------------------
    // L2 Risk
    // ------------------------------------------------------------------

    /// @notice Risk parameters for a (collateral, supply) pair.
    /// @dev    bp = basis points (1e4 = 100%).
    struct ParamsV1 {
        uint16 ltvBps; // initial LTV
        uint16 warningBps; // health-factor warning threshold
        uint16 partialLiqBps; // partial-liquidation threshold
        uint16 fullLiqBps; // full-liquidation threshold
        uint32 maxMaturity; // seconds
        uint16 maxRateBps; // maximum allowed deal rate
        uint16 liquidationBonusBps;
        uint16 aminaFeeBps;
        uint256 pairCapUsd;
        address priceSourceCollateral;
        address priceSourceSupply;
        uint32 heartbeatCollateral; // max staleness in seconds
        uint32 heartbeatSupply;
        uint8 oracleDecimalsCollateral;
        uint8 oracleDecimalsSupply;
        bool active;
    }

    struct ParamSnapshot {
        uint16 schemaVersion;
        bytes32 paramsHash;
        bytes encodedParams;
    }

    // ------------------------------------------------------------------
    // L3 Deal Engine
    // ------------------------------------------------------------------

    enum DealStateEnum {
        None, // 0
        PendingActivation, // 1 (intent recorded, awaiting transfers)
        Active, // 2
        Warned, // 3
        PartialLiquidated, // 4
        Repaid, // 5
        Repaid_PendingCollateralRelease, // 6
        Liquidated, // 7
        Defaulted, // 8
        Paused // 9 overlay sentinel (overlay flag carried in DealState)
    }

    struct DealTerms {
        address lender;
        address borrower;
        address supplyToken;
        address collateralToken;
        uint128 principal;
        uint128 collateralAmount;
        uint32 rateBps;
        uint64 startTs;
        uint64 maturityTs;
        bytes32 pairKey;
        uint32 paramVersion;
        bytes32 nonceLender;
        bytes32 nonceBorrower;
        bytes32 nonceAmina;
        bytes32 legalTermsHash;
    }

    struct DealState {
        DealStateEnum state;
        uint128 outstanding;
        uint128 collateralPosted;
        uint64 lastTouchTs;
        uint8 liquidationStep; // 0/warned, 1/partial, 2/full
        uint64 pauseStartedAt;
        uint64 totalPausedTime;
        bytes32 lastPauseReason;
        uint32 versionKey; // mirrors DealTerms.paramVersion at activation
    }

    struct OracleOverride {
        address overrideCollateralOracle;
        address overrideSupplyOracle;
        uint64 effectiveAt;
        bytes32 reason;
    }

    /// @notice EIP-712 typed-data payload used by lender / borrower / AMINA
    ///         to authorise a `record + openAndActivate` ceremony.
    struct DealIntent {
        address lender;
        address borrower;
        address supplyToken;
        address collateralToken;
        uint128 principal;
        uint128 collateralAmount;
        uint32 rateBps;
        uint64 startTs;
        uint64 maturityTs;
        bytes32 pairKey;
        uint32 paramVersion;
        bytes32 nonceLender;
        bytes32 nonceBorrower;
        bytes32 nonceAmina;
        bytes32 legalTermsHash;
    }

    struct DualPriceAttestation {
        bytes32 dealId;
        bytes32 sourceId;
        uint256 observedCollateralPrice;
        uint256 observedSupplyPrice;
        uint64 observationTs;
        bytes32 reasonCode;
    }
}
