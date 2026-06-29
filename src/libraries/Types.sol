// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types
/// @notice Shared structs/enums for Triora Core — **Model A** (pure tri-party ledger; see
///         docs/ADR-0001-no-real-funds-in-contracts.md). The engine operates ONLY accounting tokens
///         (cBTC, cUSDC); real BTC/USDC stay in custody and settle off-chain under AMINA co-signature.
library Types {
    // ── Pledge (cBTC collateral claim — PledgeRegistry / S4) ───────────────────
    enum PledgeStatus {
        None,
        Pledged, // custody-attested, before mint
        Minted, // cBTC minted to the borrower
        Bound, // locked into an active deal
        ReleasePending, // terminal deal state reached, awaiting custody ack
        Released, // BTC returned to borrower in custody, cBTC burned
        Liquidated, // BTC sent to AMINA desk, cBTC burned
        Frozen
    }

    struct Pledge {
        address owner; // borrower
        bytes32 custodyAccountRef;
        uint256 pledgedAmount; // cBTC units (8 dec)
        uint256 mintedAmount;
        uint256 encumberedAmount;
        PledgeStatus status;
        bytes32 dealId;
        bytes32 controlAgreementHash;
        uint64 registeredAt;
    }

    // ── Reserve (cUSDC lender liquidity reservation — ReserveRegistry) ─────────
    enum ReserveStatus {
        None,
        Available, // custody-attested USDC, cUSDC minted to lender, free
        Bound, // locked into an active deal (pre-funding)
        Funded, // real USDC moved lender->borrower; cUSDC burned
        Returned, // repaid; reservation closed
        Frozen
    }

    struct Reserve {
        address owner; // lender
        bytes32 custodyAccountRef;
        uint256 reservedAmount; // cUSDC units (6 dec)
        uint256 mintedAmount;
        uint256 encumberedAmount;
        ReserveStatus status;
        bytes32 dealId;
        bytes32 controlAgreementHash;
        uint64 registeredAt;
    }

    // ── Position (deal — LendingEngine / S6 Model A) ───────────────────────────
    enum PositionState {
        None,
        SettlementPending, // matched; real USDC NOT yet moved; interest NOT started
        Active, // funding ack received; interest accrues
        Warned,
        RepaymentPending, // borrower requested repayment quote / repaying off-chain
        ReleasePending, // repaid; collateral release voucher issued, awaiting custody ack
        Closed,
        LiquidationPending,
        Liquidated,
        Defaulted,
        Cancelled
    }

    struct Position {
        address lender;
        address borrower;
        bytes32 pledgeId; // cBTC
        bytes32 reserveId; // cUSDC
        uint256 collateral; // cBTC posted (8 dec)
        uint256 principal; // USDC amount that moves in custody (6 dec)
        uint256 outstanding; // principal + accrued interest (6 dec) — the repay quote
        uint32 rateBps; // fixed APR set by AMINA
        uint64 startTs;
        uint64 maturityTs;
        uint64 lastAccrueTs;
        PositionState state;
        uint32 paramVersion;
        uint64 cureDeadline;
    }

    // ── Release voucher (ReleaseAuthorizer / S8) ───────────────────────────────
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

    // ── Market risk params (RiskConfig / S9) ───────────────────────────────────
    // Model A ladder (no Morpho LLTV): ltv < warning < liquidation <= 100%.
    struct MarketParams {
        uint16 ltvBps; // max borrow LTV (origination)
        uint16 aminaWarningBps; // warning trigger (current LTV%)
        uint16 aminaLiquidationBps; // liquidation trigger (current LTV%)
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
