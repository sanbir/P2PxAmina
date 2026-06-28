// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types
/// @notice Shared structs/enums for Triora Core (Tech Spec S9 data model).
library Types {
    // ── Pledge (PledgeRegistry / S4) ──────────────────────────────────────────
    enum PledgeStatus {
        None,
        Pledged, // registered, custody-attested, before mint
        Minted, // cBTC minted against it
        Bound, // locked into an active position
        ReleasePending, // terminal deal state reached, awaiting custody ack
        Released, // BTC returned to borrower, cBTC burned
        Liquidated, // BTC sent to AMINA desk, cBTC burned
        Frozen // stale/disputed
    }

    struct Pledge {
        address owner; // borrower
        bytes32 custodyAccountRef;
        uint256 pledgedAmount; // attested locked amount (cBTC units, 8 dec)
        uint256 mintedAmount;
        uint256 encumberedAmount;
        PledgeStatus status;
        bytes32 dealId; // active position id (bytes32(0) if free)
        bytes32 controlAgreementHash;
        uint64 registeredAt;
    }

    // ── Position (CollateralBridge / S6) ──────────────────────────────────────
    enum PositionState {
        None,
        Active,
        Warned,
        RepaymentPending,
        ReleasePending,
        Closed,
        LiquidationPending,
        Liquidated,
        Defaulted
    }

    struct Position {
        address borrower;
        bytes32 pledgeId;
        uint256 collateral; // cBTC posted (8 dec)
        uint256 principal; // USDC drawn (6 dec)
        uint256 outstanding; // principal + accrued interest (6 dec)
        uint32 rateBps; // fixed APR set by AMINA
        uint64 startTs;
        uint64 maturityTs;
        uint64 lastAccrueTs;
        PositionState state;
        uint32 paramVersion;
        uint64 cureDeadline; // set when warned/liquidation requested
    }

    // ── Release voucher (ReleaseAuthorizer / S8) ──────────────────────────────
    enum DestinationType {
        Borrower,
        AminaDesk
    }

    struct ReleaseVoucher {
        bytes32 positionId;
        bytes32 pledgeId;
        uint256 amount; // cBTC to release/burn
        DestinationType destinationType;
        address destination;
        uint8 reason; // 0 REPAID, 1 LIQUIDATED, 2 SURPLUS
        uint64 issuedAt;
        bool consumed;
    }

    // ── Market risk params (RiskConfig / S9) ──────────────────────────────────
    struct MarketParams {
        uint16 ltvBps; // max borrow LTV (origination)
        uint16 aminaWarningBps; // HF-equivalent warning trigger (LTV%)
        uint16 aminaLiquidationBps; // AMINA liquidation trigger (LTV%), MUST be < morphoLltvBps
        uint16 morphoLltvBps; // the external market LLTV (backstop)
        uint32 cureWindowSecs;
        uint32 maxRateBps;
        uint64 maxMaturity;
        uint16 liquidationBonusBps;
        uint16 aminaFeeBps;
        uint256 perBorrowerCapUsdc;
        uint256 marketCapUsdc;
        bool active;
    }
}
