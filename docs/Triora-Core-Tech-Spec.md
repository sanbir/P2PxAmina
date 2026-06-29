# Triora — Core Technical Specification (build-from-scratch)

> **Author:** Plamen
> **Date:** 2026-06-28
> **Status:** Implementation-guiding specification for the **Core** (minimal-yet-prod-safe) Triora.
> **Companion:** `Triora-Core-vs-Optional-3.md` (the Core/Optional decision and rationale this spec implements).
> **Scope:** This document specifies **only the Core**. Every component here is justified
> with **"Why Core"** and **"What breaks if omitted."** Optional/v2 features are referenced
> only where a Core boundary must be drawn against them. Assume **nothing is provided by a
> third party except the named external dependencies** (Morpho, Chainlink, the custodian,
> OpenZeppelin). Everything else is built from scratch.

---

> ## ⚠️ AMENDMENT (2026-06-29) — Core is now MODEL A. See `ADR-0001-no-real-funds-in-contracts.md`.
> A **hard invariant** now governs the Core: **real assets (BTC, ETH, USDC) never touch any contract.**
> The protocol is a pure ledger of accounting tokens (cBTC, cUSDC); real USDC moves exactly once,
> directly custody→custody, OFF-CHAIN under AMINA's mandatory co-signature. This **supersedes the
> Model-B (`CollateralBridge` over Morpho) decision** recorded below — wherever this spec describes
> Model B (notably **S0.2 D-1/D-2/D-3, S6 CollateralBridge, S7 Morpho integration**), treat it as the
> **OPTIONAL on-chain-liquidity connector**, NOT the Core. **Core = Model A:** a `LendingEngine`
> settlement-instruction state machine over cBTC + a new `cUSDC` reserve token, with a
> `SettlementAcker` consuming dual-signed (custodian + AMINA) funding/repayment acks; real settlement
> is off-chain. The custody-tokenization safety spine (S1–S5 secure-mint/attestations/pledge-binding,
> S8 liquidation/release-vouchers) is unchanged and still mandatory.

## S0. Foundations (read this first — it is the contract every later section obeys)

### S0.1 What Triora Core is

Triora Core lets an **AMINA-approved institution borrow USDC against Bitcoin it keeps in a
qualified custodian, without selling the BTC.** The BTC never enters a smart contract; it
is locked in a segregated custody account under a tri-party **control agreement** where
AMINA is the collateral agent and mandatory co-signer. On-chain, the protocol holds only a
**1:1 restricted accounting token (cBTC)**, mints it **only against verified reserves**,
posts it as collateral into a **single isolated Morpho market**, **borrows real USDC**
from that market and routes it to the borrower, and releases the BTC **only where the deal
state dictates**. Liquidation eligibility is an **objective oracle predicate** operated by
AMINA with a **cure window**, backstopped by Morpho's permissionless liquidation.

The product preserves the four-party separation of duties:

| Party | Role | Never does |
|-------|------|-----------|
| **P2P** | Technology: contracts, UI, indexer, routing. | Custody, credit decisions, KYB approval, minting, matching outside AMINA's licence. |
| **AMINA** (FINMA-licensed) | Broker, collateral agent, risk curator, mandatory co-signer, liquidation operator. Owns KYB, LTV, rate. | Hold client funds; determine liquidation *eligibility* unilaterally (it is objective). |
| **Chainlink CRE / PoR** | Reserve attestation source; (later) the mint orchestrator. | Decide acceptability — Triora's on-chain guard decides. |
| **Custodian** (one for Core) | Hold segregated BTC; execute redemption/transfer under control agreement + AMINA co-sign. | Move pledged assets unilaterally. |

### S0.2 The locked architectural decisions (do not deviate without changing this section)

These are decided in `Triora-Core-vs-Optional-3.md` and are **binding** for this spec:

- **D-1 Loan rail = Model B.** The Core loan mechanism is the **`CollateralBridge` over one
  isolated, immutable Morpho market** (cBTC collateral / USDC loan). The bespoke bilateral
  OTC engine + `cUSDC` + matching + off-chain USDC settlement (Model A) is **Optional/v2**.
- **D-2 Cash settlement is on-chain.** USDC moves atomically when the bridge calls Morpho
  `borrow`/`repay` (real DvP). There is **no off-chain USDC settlement** and **no cUSDC** in Core.
- **D-3 Fixed-rate fidelity.** The isolated market uses an **AMINA-curated fixed-rate IRM**
  (`FixedRateIRM`), so the borrower's outstanding accrues at a fixed APR set by AMINA, while
  still using Morpho's collateral/borrow/liquidation/accounting machinery. The bridge keeps a
  **per-borrower sub-ledger** because Morpho sees only the bridge's single aggregate position.
- **D-4 Backing is enforced on-chain.** `ReserveGuard` secure-mint (`supply + amount ≤
  min(freshPoR, freshAttestation) − positiveMargin`, fail-closed) sits **in the mint path**.
- **D-5 Custody facts arrive as signed evidence.** No contract calls a custodian API. Facts
  arrive as **dual (custodian + AMINA) EIP-712 attestations** via `SignedCustodyAdapter`
  (an `ICustodyAdapter`/`IReserveSource`). Chainlink PoR / CRE is a drop-in alternative source.
- **D-6 Release is state-derived.** `ReleaseAuthorizer` issues one-use vouchers whose
  destination is **derived from on-chain state** (Repaid → borrower, Liquidated → AMINA desk),
  never supplied by the caller.
- **D-7 Liquidation is objective + AMINA-first + Morpho-backstopped.** Eligibility is an
  oracle predicate; AMINA operates it after a fixed cure window; AMINA's internal threshold
  is **strictly tighter than the Morpho market LLTV** so AMINA acts first and Morpho
  permissionless liquidation is only the last-resort backstop.
- **D-8 One asset (BTC), one custodian, behind adapters.** ETH/SOL/RWA and additional
  custodians are Optional; the `ICustodyAdapter`/`IProtocolAdapter`/`IReserveSource`
  interfaces keep them non-breaking to add.
- **D-9 Immutable spine, upgradeable engine behind timelock.** Token, registries, vault of
  record, vouchers, settlement router, parameter archive are **immutable**; the
  `CollateralBridge` engine is UUPS behind a timelock.
- **D-10 Role separation.** No single role both moves collateral **and** sets risk params;
  hot keys may only *reduce* risk; P2P=GOVERNOR (infra/upgrades), AMINA=CURATOR/ALLOCATOR/
  LIQUIDATOR, joint EMERGENCY.

### S0.3 On-chain component inventory (Core)

> Every contract below gets a full section later. Layers L1–L5 mirror the existing repo.

| # | Contract | Layer | Mutability | One-line responsibility | If omitted |
|---|----------|-------|-----------|--------------------------|-----------|
| 1 | `RoleManager` | L1 | Immutable (OZ AccessManager) | Single source of every permission + timelock. | Any role check is ad-hoc; one key drains everything. |
| 2 | `KYBGateway` | L1 | UUPS+TL | Entity/wallet approval + expiry + jurisdiction. | Unscreened/sanctioned entities transact; AMLA breach. |
| 3 | `TokenizationRegistry` | L2 | UUPS+TL | Per-cToken config (adapter, reserve source, margins, ages, policy hashes). | No single place binds a token to its reserve/pledge policy; misconfig at mint. |
| 4 | `ReserveGuard` | L2 | UUPS+TL | Secure-mint: `supply ≤ min(sources) − margin`, fail-closed. | Unbacked cBTC can be minted — total loss of the 1:1 invariant. |
| 5 | `ICustodyAdapter` + `SignedCustodyAdapter` | L2 | Immutable per custodian | Dual-signed custody facts: reserves, lock-active, pledge verify, release ack. | Custody facts enter unauthenticated; reserve inflation; vendor lock-in. |
| 6 | `PledgeRegistry` | L2 | UUPS+TL | Pledge↔cBTC↔custody↔deal; `minted ≤ pledged`; one deal per pledge; encumbrance. | Double-mint against one deposit; one pledge in two deals. |
| 7 | `PermissionedCollateralToken` (cBTC) | L2/tokens | Immutable | Restricted ERC-20 (8 dec); pledge-bound+reserve-guarded mint; voucher-gated burn. | A freely transferable, possibly-unbacked token leaks into DeFi; no freeze/KYB. |
| 8 | `OracleAdapter` | L2 | UUPS+TL | Chainlink BTC/USD read + staleness + decimals + peg cap (value ≤ attested reserve). | No objective liquidation trigger; depeg/stale mis-values collateral. |
| 9 | `PositionRegistry` | L3 | Immutable | Write-once per-borrower position terms (borrower, pledge, principal, APR, maturity, market, legal hash). | Terms can be silently mutated; no immutable audit of the obligation. |
| 10 | `CollateralBridge` | L3 | UUPS+TL | The engine: owns the Morpho position, per-borrower sub-ledger, mint/deposit/borrow/repay/withdraw/liquidate orchestration. | There is no loan product. |
| 11 | `IProtocolAdapter` + `MorphoAdapter` | L3 | Immutable | Thin wrapper over Morpho supply/borrow/repay/withdraw/liquidate. | Bridge welded to Morpho's ABI; can't swap/add a venue without rewrite. |
| 12 | `FixedRateIRM` | L3 | Immutable | Morpho IRM returning the AMINA-curated fixed rate for the market. | Borrower faces variable DeFi rate — breaks fixed-rate-repo fidelity. |
| 13 | `LiquidationModule` | L4 | UUPS+TL | Objective-trigger + cure window + surplus; drives the bridge liquidation path (LIQUIDATOR). | Liquidation is discretionary (interested-party abuse) or impossible. |
| 14 | `ReleaseAuthorizer` | L4 | UUPS+TL | State-derived, one-use release vouchers (repay→borrower, liq→AMINA desk). | An operator can redirect collateral; a repaid borrower can be held hostage. |
| 15 | `SettlementRouter` | L4 | Immutable, versioned | Append-only, sequence-numbered instruction/voucher event stream for off-chain ops. | Off-chain custody ops have no authenticated, gap-detectable instruction feed. |
| 16 | `RiskConfig` + `ParameterArchive` | L2 | Config UUPS+TL / Archive immutable | Versioned per-market risk params; live positions pinned to their version. | Param changes mutate live deals; caps can't be added without migration. |
| 17 | `PortfolioLens` / `BridgeLens` | L5 | Immutable | Read-only aggregation for UI/indexer. | UI/indexer must hand-assemble state; reconciliation is harder (not a safety cut). |
| — | Libraries: `Types`, `Errors`, `Roles`, `Math`, `EIP712Hashes` | — | — | Shared structs/enums/typehashes/fixed-point. | Duplication + decimal/sig bugs. |

**Reserve data source at launch** = `SignedCustodyAdapter` (an `IReserveSource`). `CREReportReceiver` / `ChainlinkPoRSource` are alternative `IReserveSource` implementations added in v1.1 **behind the same `ReserveGuard` interface** (no mint-path re-audit).

### S0.4 Off-chain service inventory (Core)

| # | Service | Responsibility | If omitted |
|---|---------|----------------|-----------|
| O1 | **Web app (frontend)** | Borrower/lender surfaces: Tokenize, Markets/Borrow, Position, Account/evidence. | No usable product. |
| O2 | **AMINA Operator Console** | KYB approve/reject, set risk params, warn/liquidate, oracle override, pause. | AMINA cannot operate the protocol safely. |
| O3 | **Backend API + Indexer** | Ingest chain events; serve positions/evidence/portfolio; store KYB intake + evidence hashes. | No read model, no audit trail, no reconciliation. |
| O4 | **KYB intake service** | Collect docs, hash, route to AMINA decision; write status on-chain. | No regulatory entry control surface. |
| O5 | **Custody attestation signer** | Build custody proof packets; gather custodian + AMINA EIP-712 sigs; submit attestations; watch deposits + 6-conf finality. | No authenticated reserve/lock evidence reaches chain. |
| O6 | **Custody listener / settlement service** | Act on `SettlementRouter` vouchers only; require AMINA co-sign; execute custody movement; acknowledge on-chain (idempotent). | On-chain decisions never execute, or execute unauthorized; ledger/custody desync. |
| O7 | **Reserve / PoR publisher** (or CRE workflow) | Publish attested reserve quantity consumed by `ReserveGuard`. | No backing data → mints blocked (fail-closed) → product halts. |
| O8 | **Risk / liquidation bot (AMINA OPS)** | Monitor HF, run cure window, execute gated liquidation via `LiquidationModule`. | Margin calls never fire; bad debt sits unliquidated. |
| O9 | **Monitoring & alerting** | Page on every invariant breach (supply>reserve, stale data, lock inactive, voucher gaps, ledger drift). | Invariant breaks discovered after loss, not before. |

### S0.5 Frontend surface inventory (Core)

| # | Surface | Purpose | If omitted |
|---|---------|---------|-----------|
| F1 | **Tokenize collateral** | Connect custody address → AMINA tri-party → mint cBTC 1:1. | No entry to the product. |
| F2 | **Markets / Borrow** | Show rate (AMINA's parameter) + LTV/threshold ladder; place + sign borrow. | No loan can be originated by a user. |
| F3 | **Position / Portfolio** | One consolidated position; correct HF; threshold ladder; repay; top-up; withdraw margin. | Borrower can't manage the loan or respond to margin calls. |
| F4 | **Account / Evidence hub** | Entity, AMINA client id, control-agreement hash, pledge id, PoR report id+freshness, reserve ratio, token addr, transfer policy, settlement route, approval state. | Institutions cannot audit/trust the position. |
| F5 | **Margin-call / cure / liquidation lifecycle** | Warning banner, 48h countdown, top-up CTA, partial/full liquidation result, surplus. | Borrower cannot see or respond to liquidation risk. |
| F6 | **KYB onboarding (thin)** | Status display + (optional UI) intake; the on-chain gate is Core, the portal is minimal. | Borderline; the on-chain gate is Core, the UI can be manual at launch. |
| F7 | **AMINA Operator Console (UI)** | Operate everything in O2. | AMINA runs the protocol by raw scripts with no guardrails. |

### S0.6 Roles (locked)

| Role | Holder | Powers | Constraint |
|------|--------|--------|-----------|
| `GOVERNOR` | P2P 3-of-5 Safe | Upgrades (timelocked), role grants, contract wiring. | Cannot move collateral or set risk values; timelock on upgrades. |
| `CURATOR` | AMINA 2-of-3 Safe | Risk params, KYB config, market/token admission, cap *increases* (timelocked). | Cannot mint or move collateral directly. |
| `ALLOCATOR` | AMINA ops hot wallet | Open/record positions (the matching authority of record). | Rate-limited; bounded by caps + signatures. |
| `LIQUIDATOR` | AMINA bot wallets (rotatable) | `warn`, `requestLiquidation`, `finalizeLiquidation`. | Eligibility is objective (oracle report), not discretionary; per-wallet daily cap. |
| `ISSUER_MINTER` | Custodian/CRE mint key | `mintForPledge` on cBTC. | Gated by `ReserveGuard` + `PledgeRegistry`; cannot exceed reserves. |
| `GUARDIAN` | AMINA OPS | Pause (token/market/position), cap *decreases*. | Hot key — may only reduce risk. |
| `EMERGENCY` | Joint P2P+AMINA 2-of-2 | Global halt, oracle override (delayed), emergency-sealed mode. | Override is sidecar (never mutates terms); grace delay. |
| `ORACLE_ADMIN` | AMINA + Chainlink 2-of-3 | New oracle/param versions. | Timelocked. |

### S0.7 Canonical lifecycle (Core, Model B)

```
 0. KYB (off-chain) → KYBGateway.approve(entity, wallet)
 1. Borrower deposits BTC into segregated custody account; signs control agreement (AMINA tri-party).
 2. Custody attestation: custodian + AMINA dual EIP-712 → SignedCustodyAdapter.submitProof
       → PledgeRegistry.registerPledge  [status: Pledged]
 3. Mint: ISSUER_MINTER → cBTC.mintForPledge(bridge, pledgeId, amount)
       → ReserveGuard.checkMint (supply ≤ min(PoR,attestation) − margin)
       → PledgeRegistry.recordMint   [cBTC minted to CollateralBridge]
 4. Borrow: Borrower → CollateralBridge.borrow(pledgeId, usdcAmount)
       → MorphoAdapter.supplyCollateral(cBTC) (first time) + borrow(USDC, onBehalf=bridge, receiver=borrower)
       → PledgeRegistry.lockForDeal ; PositionRegistry.record (immutable terms)
       → SettlementRouter.PositionOpened ; bridge sub-ledger updated
 5. Accrue: fixed APR via FixedRateIRM; bridge mirrors per-borrower outstanding.
 6a. Repay: Borrower/AMINA → CollateralBridge.repayWithdrawAndBurn(pledgeId, amount)
       → MorphoAdapter.repay(USDC) + withdrawCollateral(cBTC)
       → ReleaseAuthorizer.issueRepaymentRelease (dest=borrower) → SettlementRouter.ReleaseVoucher
       → [off-chain] custody listener + AMINA co-sign → BTC to borrower → ack on-chain
       → cBTC.burnForRelease(voucher) ; PledgeRegistry.markReleased  [Closed]
 6b. Margin/Liquidation: OracleAdapter price < AMINA threshold (tighter than Morpho LLTV)
       → LIQUIDATOR.warn (cure window) → if not cured/ matured:
       → LiquidationModule.requestLiquidation(oracle report) → finalize after cure
       → CollateralBridge.liquidateWithdrawAndBurn (atomic: repay Morpho, withdraw cBTC)
       → ReleaseAuthorizer.issueLiquidationRelease (dest=AMINA desk)
       → [off-chain] BTC to AMINA → sell → repay Morpho/lender, take bonus+fee, surplus→borrower
       → cBTC.burnForRelease(voucher) ; PledgeRegistry.markLiquidated  [Liquidated]
       (Backstop: if AMINA never acts and HF reaches Morpho LLTV, any liquidator may
        liquidate the bridge position on Morpho permissionlessly.)
```

### S0.8 Position state machine (Core)

```
None
  → PledgePending        (registerPledge, before mint)
  → Collateralized       (cBTC minted to bridge, not yet borrowed)
  → Active               (borrow drawn; interest accrues)
  → Warned               (HF < AMINA warning; cure clock) ↔ Active (cured / top-up)
  → RepaymentPending     (repay initiated, awaiting Morpho repay + withdraw)
  → ReleasePending       (voucher issued, awaiting custody ack)
  → Closed               (BTC released to borrower, cBTC burned)        [terminal]
  → LiquidationPending   (objective trigger + cure elapsed)
  → Liquidated           (BTC to AMINA desk, surplus to borrower, cBTC burned) [terminal]
  → Defaulted            (liquidation proceeds < debt; shortfall booked off-chain to AMINA) [terminal]
Overlay: Paused (boolean), does not advance state; pauses the interest clock.
Invariant: interest accrues only in Active/Warned/RepaymentPending; never before Active.
```

### S0.9 Core invariants (every section must preserve these; full catalog in S12)

1. `cBTC.totalSupply() ≤ min(freshPoR, freshAttestation) − margin` at all times.
2. For every pledge: `mintedAmount ≤ pledgedAmount`; `encumbered ≤ minted`; one active position per pledge.
3. cBTC transfers allowed **only** on protocol paths (mint, burn, bridge↔Morpho-adapter), checked on **both** `from` and `to`.
4. A position is `Active` **iff** the Morpho borrow succeeded and USDC reached the borrower; interest accrues only from `Active`.
5. Release destination is **derived from state** (Repaid→borrower, Liquidated→AMINA desk), never caller-supplied; each voucher is **one-use**.
6. AMINA liquidation threshold **<** Morpho market LLTV (AMINA acts strictly before the permissionless backstop).
7. Liquidation surplus (proceeds − debt − bonus − fee) → borrower; ungovernance-seizable.
8. No role both moves collateral/USDC **and** sets risk params (privilege separation).
9. Position terms in `PositionRegistry` are write-once; risk params are version-pinned per position.
10. Every off-chain custody movement is authorized by exactly one consumed voucher **and** an AMINA co-signature.

### S0.10 Spec conventions (binding on every later section)

- **Every component section MUST contain a `### Why Core / What breaks if omitted` block.**
  State which test it passes (Solvency / Liability / Reversibility) and the concrete failure mode.
- Contracts: give **purpose, storage, external functions (with signatures + access role),
  events, errors, the invariants it upholds, and its external dependencies.** Use Solidity
  ^0.8.28, OZ v5, ERC-7201 namespaced storage for upgradeables, `SafeERC20`, custom errors.
- Services: give **responsibility, inputs, outputs, interfaces consumed/produced, data it
  persists, failure handling (fail-closed where solvency-relevant), and idempotency rules.**
- Frontend: give **purpose, layout, components, data shown (and its source contract/endpoint),
  user actions, states (empty/loading/error/warning), and copy/wording constraints**
  (e.g., rate is "AMINA's parameter," never "platform offer"; no "Chainlink mints"; no
  "instant liquidation guarantee").
- Decimals: **cBTC = 8**, USDC = 6. Never 18 for BTC. All cross-asset math normalizes decimals explicitly.
- Money never sits in a Triora contract except in-flight inside an atomic bridge call.
- Cross-reference other sections by their `S` number.

---


## S1. Identity, Access Control & Governance

This section specifies the contracts that decide **who may do what** in Triora Core. It is the
on-chain encoding of the four-party separation of duties (S0.1) and of the locked role table
(S0.6). Three contracts live here: **`RoleManager`** (the single authority every other contract
defers to), **`KYBGateway`** (the per-counterparty regulatory entry gate), and the **pause /
EMERGENCY surface** that the engine and registries consult before they act. The defining
property this section must uphold is invariant **S0.9 #8 — privilege separation: no role both
moves collateral/USDC and sets risk params** — plus the locked rule **D-10 / S0.6 — hot keys may
only reduce risk, never inflate it.**

This section does **not** re-decide roles, decimals, or names; it instantiates the locked S0.6
table verbatim and shows the selector-level grants, timelock policy, and storage that make it
real. The engine (`CollateralBridge`, S10/S-bridge), the mint path (`ReserveGuard` / cBTC),
liquidation (`LiquidationModule`), and release (`ReleaseAuthorizer`) all gate their privileged
functions on roles defined here and check KYB and pause state here. Cross-references use S-numbers.

---

### S1.1 RoleManager — the single source of every permission

#### Purpose

`RoleManager` is an immutable wrapper over OpenZeppelin v5 `AccessManager`. It is the **one**
authority address passed to every `AccessManaged`/UUPS contract in the system. Every `restricted`
function anywhere in Triora resolves its caller's permission by asking this contract
`canCall(caller, target, selector)`. There is no `onlyOwner`, no per-contract admin, and no
ad-hoc role check anywhere else — that centralization is the point: one auditable place defines
the entire permission surface, and one place defines the timelock that protects it.

It is **immutable** (D-9): deployed directly, not behind a proxy. The contract that controls
*upgrade authority for everything else* must not itself be casually upgradeable. Replacing it is a
deliberate, timelocked authority-migration ceremony (re-point every managed contract's authority),
never a UUPS swap. This matches the existing repo (`src/l1/RoleManager.sol`).

#### Storage layout

`RoleManager` holds **no Triora-specific storage of its own**. All role membership, per-role
admin, per-role grant delay, per-(target,selector)→role assignment, and per-target/per-function
execution delay live inside OZ `AccessManager`'s own storage. Triora must not add namespaced
storage to this contract (it is non-upgradeable; added storage would be a maintenance hazard and
defeats the "thin wrapper" intent).

```solidity
// src/l1/RoleManager.sol  — IMMUTABLE, deployed directly (no proxy)
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

contract RoleManager is AccessManager {
    /// @param initialAdmin bootstrap admin; production immediately transfers
    ///        ADMIN to the P2P GOVERNOR Safe and revokes the deployer EOA.
    constructor(address initialAdmin) AccessManager(initialAdmin) {}
}
```

#### Canonical roles (locked — S0.6)

Role IDs are the deterministic constants already in `src/libraries/Roles.sol` (OZ reserves role
`0` for `ADMIN`; application roles start at 1). The spec binds them to holders and powers exactly
as S0.6 dictates:

| ID | Role | Holder (S0.6) | May call (selector-level) | Hard constraint |
|----|------|---------------|---------------------------|-----------------|
| 0 | `ADMIN` (OZ) | P2P GOVERNOR Safe | grant/revoke roles, set delays, `updateAuthority` | The only role that edits the permission graph; timelocked |
| 1 | `GOVERNOR` | P2P 3-of-5 Safe | UUPS `upgradeToAndCall` on every UUPS target; contract wiring/`setX` of immutable refs at bootstrap | **Cannot** move collateral or set risk *values*; all upgrades timelocked |
| 2 | `EMERGENCY` | Joint P2P+AMINA 2-of-2 Safe | `globalHalt`, market/token/position pause, `forceOracleOverride` (sidecar), `setEmergencySealed` | Override never mutates terms; grace delay applies |
| 3 | `CURATOR` | AMINA 2-of-3 Safe | `RiskConfig` setters, `KYBGateway.setStatus`, market/token admission, `TokenizationRegistry` config, cap **increases** | **Cannot** mint or move collateral directly; cap increases timelocked |
| 4 | `ALLOCATOR` | AMINA ops hot wallet | `CollateralBridge` position open/record (the matching authority of record) | Rate-limited; bounded by caps + signatures |
| 5 | `LIQUIDATOR` | AMINA bot wallets (rotatable) | `LiquidationModule.warn` / `requestLiquidation` / `finalizeLiquidation` | Eligibility is objective (oracle report), not discretion; per-wallet daily cap |
| 6 | `GUARDIAN` | AMINA OPS | pause (token/market/position), cap **decreases** | Hot key — **reduce risk only** |
| 7 | `OPS` (a.k.a. ISSUER_MINTER context) | Custodian/CRE mint key | `cBTC.mintForPledge` | Gated by `ReserveGuard` (S2) + `PledgeRegistry` (S2); cannot exceed reserves |
| 8 | `ORACLE_ADMIN` | AMINA + Chainlink 2-of-3 | new `OracleAdapter` / param versions | Timelocked |

> **Naming note (binding):** S0.6 names the minter role `ISSUER_MINTER`. The existing
> `Roles.sol` exposes slot 7 as `OPS`. The Core spec resolves this by treating the minter as a
> dedicated role: implementations MUST register a distinct `ISSUER_MINTER` role ID for the cBTC
> mint selector and MUST NOT fold minting into a general `OPS` hot-key role, because the minter
> holds a money-printing selector and must be revocable independently of cap-decrease/feed-rotation
> duties. Where `Roles.sol` is extended, add `ISSUER_MINTER` as an explicit constant; do not reuse
> `OPS` for `cBTC.mintForPledge`. This preserves privilege separation (S0.9 #8): the minter never
> also sets risk params.

#### Selector-level grants (how the table becomes real)

`RoleManager` is wired at bootstrap by the GOVERNOR (via `ADMIN`) with one
`setTargetFunctionRole(target, selectors[], roleId)` call per privileged surface. Grants are
**per (target, selector)**, never per contract — this is what lets the same physical AMINA Safe be
`CURATOR` for risk setters while a separate hot wallet is `ALLOCATOR` for position opening, with no
overlap. Illustrative bootstrap wiring:

```solidity
// executed by ADMIN (GOVERNOR Safe) at deployment, each behind the ADMIN grant delay
rm.setTargetFunctionRole(address(riskConfig),  sel(RiskConfig.setMarketParams.selector),        Roles.CURATOR);
rm.setTargetFunctionRole(address(kyb),         sel(KYBGateway.setStatus.selector),              Roles.CURATOR);
rm.setTargetFunctionRole(address(bridge),      sel(CollateralBridge.openPosition.selector),     Roles.ALLOCATOR);
rm.setTargetFunctionRole(address(cBTC),        sel(cBTC.mintForPledge.selector),                ISSUER_MINTER);
rm.setTargetFunctionRole(address(liqModule),   sel(LiquidationModule.finalizeLiquidation.selector), Roles.LIQUIDATOR);
rm.setTargetFunctionRole(address(bridge),      sel(UUPSUpgradeable.upgradeToAndCall.selector),  Roles.GOVERNOR);
rm.setTargetFunctionRole(address(pauser),      sel(PauseHub.pauseMarket.selector),              Roles.GUARDIAN);
rm.setTargetFunctionRole(address(pauser),      sel(PauseHub.globalHalt.selector),               Roles.EMERGENCY);
```

A managed contract's `restricted` modifier (from `AccessManagedUpgradeable`) calls back into
`RoleManager.canCall`; if the caller lacks the role for that exact selector, OZ reverts with
`AccessManagedUnauthorized(caller)`.

#### Timelock policy (what is timelocked vs fast vs hot-key)

OZ `AccessManager` supports **two independent delays**: a per-role **grant delay**
(`setGrantDelay`) on becoming a member, and a per-(target,function) **execution delay**
(`setTargetFunctionRole` + `scheduleOp`/`execute`). Triora uses both to encode S0.6:

| Class | Operations | Mechanism | Delay |
|-------|-----------|-----------|-------|
| **Timelocked (slow)** | UUPS upgrades; new role grants; risk-param *increases* / loosening; cap *increases*; new oracle/param version; token/market admission | execution delay on the selector + grant delay on the role | **24h default**, emergency-shortenable to **1h** (per `EMERGENCY` schedule path) |
| **Fast (medium)** | Position open/record (`ALLOCATOR`); feed rotation; unpause | role with no execution delay | ~seconds (one tx), but **rate-limited** by caps/daily limits in the target |
| **Hot-key (instant, reduce-only)** | pause (token/market/position); cap *decreases*; `warn` | `GUARDIAN`/`OPS`/`LIQUIDATOR` with zero delay | immediate |

The **hot-keys-reduce-risk-only rule (D-10 / S0.9 #8)** is enforced structurally, not by
convention. It is **not** a property `RoleManager` can express alone (OZ has no "this call only
lowers a number" predicate), so it is enforced at **two layers**:

1. **Selector partitioning.** The risk-reducing direction and the risk-increasing direction are
   *different selectors on different contracts*. `RiskConfig` exposes `decreaseCap(market, newCap)`
   (granted to `GUARDIAN`/`OPS`, zero delay) and `increaseCap(market, newCap)` (granted to
   `CURATOR`, timelocked) as separate functions. A hot key is granted *only* the decrease selector.
2. **In-contract monotonicity guard.** Each reduce-only setter additionally `require`s the new
   value is strictly less risky than the live value (e.g. `if (newCap >= current) revert
   NotRiskReducing();`). This makes "reduce-only" true even if a future mis-grant hands a hot key
   the wrong selector.

This is the on-chain expression of S0.9 #8: GOVERNOR (P2P) can upgrade but cannot set a single risk
number or move a single token; CURATOR (AMINA) sets every risk number but cannot upgrade, mint, or
move collateral; the minter mints but sets nothing.

#### External functions (Triora-facing usage)

`RoleManager` exposes the standard OZ `AccessManager` surface; Triora adds none. The functions the
rest of the spec relies on:

| Function | Caller | Effect |
|----------|--------|--------|
| `canCall(caller, target, selector) → (bool, uint32)` | every managed contract (view) | the universal permission check |
| `grantRole(roleId, account, executionDelay)` | `ADMIN` (GOVERNOR) | add a holder; subject to grant delay |
| `revokeRole(roleId, account)` | `ADMIN` / role admin | remove a holder (instant — this is the kill switch for a compromised key) |
| `setTargetFunctionRole(target, selectors, roleId)` | `ADMIN` | bind a selector to a role |
| `setGrantDelay(roleId, delay)` / `setTargetFunctionDelay(...)` | `ADMIN` | timelock configuration |
| `schedule(target, data, when)` / `execute(target, data)` | role holder | the timelocked-op two-step |

#### Events / errors

Events and errors are OZ `AccessManager`'s (`RoleGranted`, `RoleRevoked`, `TargetFunctionRoleUpdated`,
`OperationScheduled`, `OperationExecuted`; `AccessManagerUnauthorizedAccount`,
`AccessManagedUnauthorized`). Triora's off-chain monitoring (S0.4 O9) MUST page on
`RoleRevoked(EMERGENCY|GOVERNOR …)` and any `RoleGranted` to a non-Safe address — "AMINA removed
from quorum" is a named invariant alert.

#### Invariants upheld

- **S0.9 #8 (privilege separation):** enforced by selector partitioning — no single role is granted
  both a fund/collateral-moving selector and a risk-param selector.
- **D-10 hot-keys-reduce-only:** enforced by reduce-only selector grants + in-contract monotonicity.
- **Upgrade authority is timelocked and single-sourced** (D-9): only `GOVERNOR` holds upgrade
  selectors, all behind execution delay.

#### External dependencies

OpenZeppelin v5 `AccessManager` (immutable, deployed directly). No other dependency.

#### Why Core / What breaks if omitted

**Test: Liability (S0.9 #8).** `RoleManager` is the on-chain encoding of the P2P-vs-AMINA duty
split and the blast-radius bound on any single key. **If omitted:** every contract invents its own
access check; there is no single place that guarantees no role both moves collateral and sets risk;
one compromised key drains or mis-prices everything (the exact failure C-20 in
`Triora-Core-vs-Optional-3.md` names). Without the reduce-only structure, a hot key compromise lets
an attacker *raise* caps or *loosen* LTV — turning an operational key into a solvency weapon. It is
cheap (a ~15-line wrapper plus wiring) and is the cheapest possible insurance against single-key
catastrophe, so it is Core under any model.

---

### S1.2 KYBGateway — regulatory entry control

#### Purpose

`KYBGateway` is the on-chain gate that records **which entities and which wallets** AMINA has
approved to transact, when that approval expires, and under which jurisdiction. It is the on-chain
projection of AMINA's FINMA-licensed KYB/AML decision (only AMINA may decide; P2P never does). It
exposes a single hot-path view, `requireApproved(wallet)`, that **every state-changing user action
in the protocol calls before it does anything else.** The contract decides nothing about identity;
it stores AMINA's decision and lets the rest of the system enforce it uniformly.

It is **UUPS behind a timelock** (D-9: registries are upgradeable-engine, not immutable-spine),
with `RoleManager` as authority and `setStatus` gated to `CURATOR`. This matches the existing
`src/l1/KYBGateway.sol`, which the Core spec extends with an explicit **entity record** alongside
the existing **wallet record**.

#### Storage layout (ERC-7201)

The existing contract stores only a `wallet → KybRecord` map. The Core spec adds an **entity
dimension** (S0.5 F4 / S0.3 #2 require "entity + wallet"): an entity is the legal counterparty;
wallets are the addresses that entity controls. Approval is checked at the wallet level but
attributed to an entity, so revoking an entity revokes all its wallets at once.

```solidity
/// @custom:storage-location erc7201:p2pxamina.kybgateway.v2
struct Storage {
    // wallet => its record (status/expiry/jurisdiction/docs/approver), as today
    mapping(address => Types.KybRecord) walletRecords;
    // entityId (keccak of legal identity ref) => entity-level record
    mapping(bytes32 => Types.KybEntity) entities;
    // wallet => entityId it belongs to (0 = unaffiliated, legacy single-wallet path)
    mapping(address => bytes32) walletEntity;
}

// keccak256(abi.encode(uint256(keccak256("p2pxamina.kybgateway.v2")) - 1)) & ~bytes32(uint256(0xff))
bytes32 private constant STORAGE_SLOT = 0x...; // computed per ERC-7201
```

Record/enum shapes (the wallet record already exists in `Types`; the entity is added):

```solidity
enum KybStatus { None, Pending, Approved, Suspended, Revoked }   // expanded from {None,Approved,...}

struct KybRecord {        // per wallet (existing)
    KybStatus status;
    uint64    approvedAt;
    uint64    expiryTs;        // 0 = no expiry; else approval invalid once block.timestamp >= expiryTs
    bytes32   documentsHash;   // hash of the off-chain KYB packet (evidence hub, S0.5 F4)
    address   approvedBy;      // the CURATOR signer that set it
    bytes32   jurisdictionCode;// ISO-3166 / internal jurisdiction tag
}

struct KybEntity {        // per legal entity (new in Core)
    KybStatus status;         // entity-level status; gates ALL its wallets
    uint64    expiryTs;
    bytes32   legalNameHash;   // hash of legal entity name (shown in evidence hub)
    bytes32   aminaClientId;   // AMINA's internal client identifier (evidence hub datum)
    bytes32   jurisdictionCode;
    bytes32   controlAgreementHash; // the tri-party control-agreement hash (S0.9 #10 context)
}
```

#### External functions

```solidity
// --- mutators (CURATOR only) ---

/// @notice Approve/suspend/revoke an ENTITY. Cascades to every wallet bound to it.
function setEntityStatus(
    bytes32 entityId, KybStatus status, uint64 expiryTs,
    bytes32 legalNameHash, bytes32 aminaClientId,
    bytes32 jurisdictionCode, bytes32 controlAgreementHash
) external restricted;                              // role: CURATOR (AMINA)

/// @notice Bind a wallet to an entity and set its wallet-level record.
function setStatus(
    address who, bytes32 entityId, KybStatus status,
    uint64 expiryTs, bytes32 documentsHash, bytes32 jurisdictionCode
) external restricted;                              // role: CURATOR (AMINA)

// --- views (hot path: called by every user-facing state change) ---

/// @notice The single gate. Reverts NotApproved unless BOTH the wallet AND
///         its entity are Approved and unexpired. Pure-ish, cheap, no external calls.
function requireApproved(address wallet) external view;

function isApproved(address wallet) external view returns (bool);
function getRecord(address wallet) external view returns (Types.KybRecord memory);
function getEntity(bytes32 entityId) external view returns (Types.KybEntity memory);
function entityOf(address wallet) external view returns (bytes32 entityId);
```

`requireApproved` is the canonical form the rest of the spec references; `isApproved` is the
non-reverting boolean for UI. Resolution logic:

```solidity
function requireApproved(address wallet) external view {
    Storage storage $ = _store();
    KybRecord storage w = $.walletRecords[wallet];
    if (w.status != KybStatus.Approved) revert Errors.NotApproved(wallet);
    if (w.expiryTs != 0 && w.expiryTs <= block.timestamp) revert Errors.KybExpired(wallet);
    bytes32 eid = $.walletEntity[wallet];
    if (eid != bytes32(0)) {                         // entity-bound wallet
        KybEntity storage e = $.entities[eid];
        if (e.status != KybStatus.Approved) revert Errors.EntityNotApproved(eid);
        if (e.expiryTs != 0 && e.expiryTs <= block.timestamp) revert Errors.EntityExpired(eid);
    }
}
```

#### How every state-changing user action consults it (binding wiring)

KYB is **fail-closed and ubiquitous**. Each user-reachable state transition calls
`KYBGateway.requireApproved(msg.sender)` (and, where a transfer has a counterparty, the
counterparty) as its first statement:

| Action | Contract / fn (S-ref) | Whom it checks |
|--------|----------------------|----------------|
| Borrow | `CollateralBridge.borrow` (S10) | borrower (`msg.sender`) |
| Repay | `CollateralBridge.repayWithdrawAndBurn` (S10) | caller (so a sanctioned party cannot even repay-to-rescue without passing) |
| Top-up margin | `CollateralBridge.topUp` (S10) | borrower |
| Withdraw margin / collateral | `CollateralBridge.withdraw` (S10) | borrower |
| cBTC restricted transfer | cBTC `_update` (S7) | **both** `from` and `to` via the allowlist (S0.9 #3); protocol addresses are pre-approved, end users must be KYB-approved |

The cBTC token (S7) consults KYB through its protocol allowlist rather than calling
`requireApproved` on every internal hop, but the *binding rule* is the same: **no user balance
ever moves to or from a non-approved party.** KYB suspension mid-deal still permits a borrower to
*repay/top-up to self-rescue* only if policy allows; the Core default is that `Suspended` blocks
new borrowing but the engine MAY still accept full repayment from a suspended borrower to avoid
trapping the asset (a deliberate liveness-over-strictness choice; documented at the call site).

#### Events / errors

```solidity
event EntitySet(bytes32 indexed entityId, KybStatus status, uint64 expiryTs,
                bytes32 legalNameHash, bytes32 aminaClientId, bytes32 jurisdictionCode, address by);
event KybSet(address indexed who, bytes32 indexed entityId, KybStatus status,
             uint64 expiryTs, bytes32 documentsHash, address by, bytes32 jurisdictionCode);

error NotApproved(address wallet);
error KybExpired(address wallet);
error EntityNotApproved(bytes32 entityId);
error EntityExpired(bytes32 entityId);
```

#### Invariants upheld

- **Every state-changing user action is KYB-gated** (the regulatory entry control; S0.6 / C-19).
- **Expiry forces re-attestation:** an approval with `expiryTs <= now` is inert with no further
  action — this is the on-chain enforcement of periodic AML refresh.
- **Only `CURATOR` (AMINA) writes status** — P2P (GOVERNOR) cannot approve a counterparty, encoding
  "only AMINA's FINMA licence authorizes onboarding" (S0.1).
- Feeds **S0.9 #3** (transfer allowlist on cBTC checks both `from` and `to`).

#### External dependencies

`RoleManager` (authority), `Types`/`Errors` libs. No external protocol. The off-chain KYB intake
(S0.4 O4) produces `documentsHash`/`aminaClientId`/`controlAgreementHash`; this contract only
records AMINA's decision.

#### Why Core / What breaks if omitted

**Test: Liability (regulatory).** The on-chain KYB gate is what keeps onboarding decisions AMINA's
(licensed) and out of P2P's hands, and what keeps unscreened/sanctioned entities from transacting.
**If omitted:** unscreened entities borrow against tokenized BTC; P2P risks reclassification as an
unlicensed broker; an AMLA breach becomes possible. The *UI* portal (S0.5 F6) is borderline and may
be manual at launch, but the **on-chain gate is unconditionally Core** — it is the single choke
point every other contract trusts, and retrofitting a gate into a live mint/borrow path later is a
re-audit of the most sensitive code.

---

### S1.3 Pause hierarchy & EMERGENCY powers

The third piece of this section is the **circuit-breaker surface**: the scoped pause levels that
stop bad activity at the narrowest possible blast radius, plus the joint-controlled EMERGENCY
powers (oracle override sidecar, sealed mode) that handle the worst case. These are not a single
contract but a **shared pause module** (`PauseHub`, an immutable-or-UUPS library-style contract the
engine/registries read) whose flags the engine and mint/liquidation/release paths consult.

#### Pause hierarchy (4 scopes — narrowest first)

| Level | Scope | What it blocks | Holder | Delay |
|-------|-------|----------------|--------|-------|
| L3 | **Position pause** | new actions on one borrower position; **pauses that position's interest clock** (S0.8 overlay) | `GUARDIAN` | instant (reduce-only) |
| L2 | **Token pause** | all mint/transfer/burn of one cToken (e.g. cBTC) | `GUARDIAN` | instant |
| L1 | **Market pause** | all new borrows/positions on one Morpho-backed market; repay/top-up/withdraw still allowed | `GUARDIAN` | instant |
| L0 | **Global halt** | everything except self-rescue (repay, top-up, claim surplus, release-ack) | `EMERGENCY` (joint 2-of-2) | instant, but joint |

Pause is a **boolean overlay** (S0.8): it never advances or rewrites position state, and it stops
the interest clock for whatever it covers (S0.8: "interest accrues only in Active/Warned/
RepaymentPending; a Paused position does not accrue"). Each privileged path calls a guard at entry:

```solidity
function _whenNotHalted() internal view { if ($.globalHalt) revert Errors.GlobalHalt(); }
function _marketLive(bytes32 mkt) internal view { if ($.marketPaused[mkt]) revert Errors.MarketPaused(mkt); }
function _tokenLive(address t) internal view { if ($.tokenPaused[t]) revert Errors.TokenPaused(t); }
function _positionLive(bytes32 pid) internal view { if ($.positionPaused[pid]) revert Errors.PositionPaused(pid); }
```

`PauseHub` external surface:

```solidity
function pausePosition(bytes32 pid, bool on) external restricted;   // GUARDIAN  (reduce-only: on=true instant; off=true is "unpause" => fast, not hot)
function pauseToken(address token, bool on) external restricted;    // GUARDIAN
function pauseMarket(bytes32 market, bool on) external restricted;  // GUARDIAN
function globalHalt(bool on) external restricted;                   // EMERGENCY
function setEmergencySealed(bool on) external restricted;           // EMERGENCY (see below)

event Paused(uint8 indexed level, bytes32 indexed scopeKey, bool on, address by);
```

> **Asymmetry rule (D-10):** *turning a pause ON* is risk-reducing → hot key, instant. *Turning a
> pause OFF* (unpause) is risk-increasing → it is granted to `CURATOR`/`EMERGENCY` (not the bare
> `GUARDIAN` hot key) and may carry an execution delay. A compromised `GUARDIAN` hot key can only
> ever *freeze* the protocol, never *un-freeze* it — the safe failure direction.

#### EMERGENCY power 1 — oracle override **sidecar**

When the Chainlink feed (S8 `OracleAdapter`) is stale, manipulated, or wrong during an incident,
`EMERGENCY` can supply an override price — but **never by mutating any position's terms or risk
params.** The override is written to a *separate* mapping consulted by valuation, and it takes
effect only after a grace delay so the market can react.

```solidity
struct OracleOverride { uint256 priceWad; uint64 effectiveAt; bytes32 reason; }
mapping(bytes32 => OracleOverride) internal _override;   // keyed by market or feed id

function forceOracleOverride(bytes32 key, uint256 priceWad, bytes32 reason)
    external restricted {                                // role: EMERGENCY
    _override[key] = OracleOverride(priceWad, uint64(block.timestamp) + EMERGENCY_GRACE, reason);
    emit OracleOverridden(key, priceWad, block.timestamp + EMERGENCY_GRACE, reason, msg.sender);
}
// EMERGENCY_GRACE = 30 minutes (locked default, mirrors existing repo)
```

Valuation (the engine / `LiquidationModule`, S8/S13) reads `getEffectivePrice(key)`: if an override
exists and `block.timestamp >= effectiveAt`, use it; otherwise use the live `OracleAdapter`. The
override **cannot** push cBTC value above its attested reserve (the S8 peg cap still applies) and
**cannot** touch `PositionRegistry` terms (S0.9 #9: terms are write-once). This is the on-chain
expression of "override is sidecar, never mutates terms" (D-7 context / S0.6 EMERGENCY constraint).

#### EMERGENCY power 2 — sealed mode

`setEmergencySealed(true)` is the highest tier: it blocks **everything, including the rescue paths
that global halt leaves open** (no repay, no release, no upgrade execution). It exists for the
single worst case — a discovered exploit being actively drained — where freezing all motion is
safer than allowing even self-rescue. It is joint-controlled (`EMERGENCY` 2-of-2), loud, and
expected to be used at most once in the protocol's life. Exiting sealed mode requires the same joint
quorum and is treated as risk-increasing (delayed).

#### The privilege-separation invariant (S0.9 #8) restated for EMERGENCY

EMERGENCY is powerful but **structurally cannot move value or change economics**: it can *stop*
motion (halt/seal), it can *substitute a price into a sidecar* (which only ever makes collateral
look *less* valuable, never more, because the peg cap bounds it), but it holds **no** selector that
transfers collateral/USDC and **no** selector that sets a risk parameter or position term. P2P and
AMINA must *both* sign every EMERGENCY action (2-of-2). This is what keeps the break-glass power
from being a backdoor around S0.9 #8: it is a brake, never a steering wheel.

| Power | Holder | Can it move funds? | Can it set risk params? | Can it change terms? |
|-------|--------|--------------------|-------------------------|----------------------|
| Pause (L0–L3) | GUARDIAN / EMERGENCY | No | No | No (overlay only) |
| Oracle override | EMERGENCY (joint) | No | No | No (sidecar, peg-capped, delayed) |
| Sealed mode | EMERGENCY (joint) | No | No | No |

#### Errors

```solidity
error GlobalHalt();
error EmergencySealed();
error MarketPaused(bytes32 market);
error TokenPaused(address token);
error PositionPaused(bytes32 positionId);
error NotRiskReducing();
```

#### Invariants upheld

- **S0.9 #8 (privilege separation)** for the break-glass surface: EMERGENCY brakes, never moves
  value or sets economics; both orgs must sign.
- **D-7 / S0.6:** oracle override is a *sidecar* with a grace delay, never mutates terms; peg-capped
  so it cannot inflate collateral value.
- **S0.8 overlay rule:** pause never advances state and freezes the interest clock for its scope.
- **D-10:** pause-ON is hot/instant; unpause/seal-exit are risk-increasing and gated/delayed.

#### External dependencies

`RoleManager` (authority), `OracleAdapter` (S8) for the override read path, `Types`/`Errors`. The
engine and mint/liquidation/release paths depend on `PauseHub`'s flags but `PauseHub` depends on
none of them (one-directional, to avoid cyclic wiring).

#### Why Core / What breaks if omitted

**Test: Solvency + Liability.** The pause hierarchy is the incident-response circuit breaker
(C-21); EMERGENCY is the worst-case brake. **If omitted:** a live exploit or a stale/manipulated
oracle cannot be stopped — there is no way to halt a drain, and the only oracle remedy would be to
mutate live terms (which would break S0.9 #9). Without the *scoping*, the only tool is a global
halt, which is needlessly destructive for a single bad token or position. Without the **sidecar +
peg-cap + joint-control** structure, the oracle override itself becomes a centralization backdoor
that could mis-value collateral or be wielded by one party — defeating the very separation this
section exists to guarantee. The pause flags are a few storage slots and the override is one mapping;
both are cheap and both are unconditionally Core.

---

### S1.4 Section invariants summary (contributions to S0.9)

| S0.9 # | Invariant | How this section upholds it |
|--------|-----------|------------------------------|
| #3 | cBTC transfers only on protocol paths (both `from`/`to`) | `KYBGateway` + the protocol allowlist feed the cBTC `_update` check (S7) |
| #8 | No role both moves collateral/USDC **and** sets risk params | `RoleManager` selector partitioning; EMERGENCY holds no value/param selector; reduce-only hot keys |
| #9 | Terms write-once; risk params version-pinned | EMERGENCY oracle override is a sidecar that never touches `PositionRegistry`/`RiskConfig` versions |
| #10 | Every custody movement = one voucher + AMINA co-sign | `LIQUIDATOR`/release roles defined here are objective-gated (S13/S14 consume them); minter role is isolated |

All role IDs, holders, and constraints are the locked S0.6 set; this section specifies their
selector-level grants, timelock classes, storage, and the structural enforcement of privilege
separation and the reduce-only hot-key rule. Downstream sections (S2 mint/reserve, S7 cBTC, S8
oracle, S10 bridge, S13 liquidation, S14 release) gate their privileged functions on these roles
and consult `KYBGateway` and `PauseHub` as specified above.


## S2. Reserve Backing & Secure-Mint (Proof of Reserve)

This section specifies the **on-chain backing layer** — the machinery that mechanically prevents
cBTC from ever existing without a corresponding, freshly-attested, exclusively-controlled real
BTC reserve. It implements decisions **D-4** (backing enforced on-chain), **D-5** (custody facts
arrive as signed evidence), and **D-9** (immutable spine) from S0.2, and it is the single
mechanical guarantor of invariant **S0.9 #1**:

> `cBTC.totalSupply() ≤ min(freshPoR, freshAttestation) − margin` at all times.

The layer is three contracts plus one interface. The **interface (`IReserveSource`) is the audit
boundary**: the mint path depends only on the interface, never on a concrete source. The launch
source is `SignedCustodyAdapter` (S3); the v1.1 swap-ins (`CREReportReceiver`,
`ChainlinkPoRSource`) implement the same interface and so slot in **without re-auditing the mint
path** (S2.5).

```
                        ┌──────────────────────────────────────────────┐
   mint() on cBTC  ───► │ ReserveGuard.checkMint(token, amount)          │
   (S5, ISSUER_MINTER)  │   reads TokenizationRegistry config            │
                        │   reads N × IReserveSource.attestedReserves()  │
                        │   rule: supply+amount ≤ min(sources) − margin  │
                        │   FAIL-CLOSED on stale/negative/missing        │
                        └───────────────┬──────────────────────────────┘
                                        │ (audit boundary = IReserveSource)
              ┌─────────────────────────┼─────────────────────────────┐
              ▼                         ▼                              ▼
   SignedCustodyAdapter        CREReportReceiver            ChainlinkPoRSource
   (S3, launch source)         (v1.1, behind same iface)    (v1.1, AggregatorV3)
```

---

### S2.1 `IReserveSource` — the reserve-data interface (the audit boundary)

#### Purpose

`IReserveSource` is the **only** thing `ReserveGuard` knows about a reserve provider. It returns,
for a given collateral token, the **attested reserve quantity** (a BTC amount in the source's own
decimals), the **timestamp** that quantity was observed (`asOf`), and the source's **decimals**.
Every reserve provider — the signed-custody adapter today, a Chainlink PoR feed or CRE receiver
later — implements this single read function. Because the mint path is written against this
interface and nothing else, swapping or adding a source is a `TokenizationRegistry` config change
(S2.3), not a code change to the guarded mint path.

This is a **deliberate split between the secure-mint *control* (Core, here) and the reserve *data
source* (Core-ready interface, swappable launch source)**, per D-9 and `Triora-Core-vs-Optional-3.md`
§2.2: "the security boundary is the consumer-side guard, not the producer."

#### Interface

```solidity
/// @notice Reserve-quantity provider. A source attests how much real collateral
///         backs `token`, when it observed that, and in what decimals.
/// @dev This is the audit boundary for the mint path. Implementations MUST NOT
///      return a USD price here — `amount` is a RESERVE QUANTITY (BTC units),
///      never a market price. Price valuation lives in OracleAdapter (S6), a
///      separate plane that never shares config with this one (S0.9-aligned).
interface IReserveSource {
    /// @return amount   attested reserve quantity for `token`, in `decimals`
    /// @return asOf     unix seconds the attestation was observed/signed
    /// @return decimals decimals of `amount` (≤ 18; cBTC uses 8)
    function attestedReserves(address token)
        external
        view
        returns (uint256 amount, uint64 asOf, uint8 decimals);

    /// @return human-readable source identity for events/monitoring (e.g. "SIGNED_CUSTODY")
    function sourceKind() external view returns (bytes32);
}
```

**Implementations (Core + v1.1):**

| Implementation | Status | `attestedReserves` derivation |
|---|---|---|
| `SignedCustodyAdapter` (S3) | **Core / launch** | Latest dual-signed (custodian + AMINA) EIP-712 attestation; `asOf = observedAt`; `decimals = 8`. |
| `ChainlinkPoRSource` | v1.1 | `AggregatorV3Interface.latestRoundData()` → `answer` (reserve qty), `updatedAt`; rejects `answer<=0` and `answeredInRound < roundId` before returning. |
| `CREReportReceiver` | v1.1 | Latest DON-signed report delivered via KeystoneForwarder `onReport`, authenticated on full workflow ID + owner (never the 40-bit name prefix), stored and exposed read-only. |

#### Why Core / What breaks if omitted

**Test: Solvency (and Reversibility).** Without a single interface fronting reserve data, the
secure-mint guard would hard-wire one provider. Then swapping the launch signed-attestation source
for a production Chainlink PoR / CRE feed would force a re-audit of the **most sensitive contract in
the system** (the mint path) — exactly the "PoR theater retrofit" failure the corpus warns against.
The interface makes the producer swappable and pins the audited security perimeter to the consumer
side. Omitting it converts a config change into a spine re-audit (fails Reversibility) and risks
shipping a guard welded to an Early-Access producer (CRE) that "announced ≠ provably live."

---

### S2.2 `ReserveGuard` — the secure-mint enforcer

#### Purpose

`ReserveGuard` is the **on-chain mechanical defence against the infinite-mint failure class**
(PYUSD's 300T accidental mint; uniBTC's mispriced mint). It sits **in the actual cBTC mint path**
(called by `PermissionedCollateralToken.mintForPledge`, S5) — never as a UI or backend pre-check —
and enforces, atomically with the mint, the rule:

```
supply(token) + amount  ≤  min over active sources of ( scaleToTokenDecimals(source.amount) )  −  positiveMargin(token)
```

evaluated against the token's **current `totalSupply()` before `_mint`**, with **fail-closed**
behaviour: any stale, negative, missing, or excessively-divergent reserve data **blocks the new
mint** (and only the new mint).

It is **UUPS + timelock** (D-9: upgradeable engine, but only via GOVERNOR through the timelock; no
hot-key path can weaken it). It holds **no funds and no risk parameters of its own** — all per-token
config lives in `TokenizationRegistry` (S2.3), preserving privilege separation (S0.9 #8): the guard
*reads* config set by CURATOR-through-timelock and *enforces* it; it cannot set its own limits.

#### Storage (ERC-7201 namespaced — upgradeable)

```solidity
/// @custom:storage-location erc7201:triora.reserveguard.v1
struct ReserveGuardStorage {
    ITokenizationRegistry registry;        // source of per-token config (S2.3)
    // No per-token limits stored here — config is read live from `registry`.
    // No reserve cache — sources are read live to avoid stale snapshots.
}
// keccak256(abi.encode(uint256(keccak256("triora.reserveguard.v1")) - 1)) & ~bytes32(uint256(0xff))
```

The guard is intentionally near-stateless: it derives the limit live from the registry config and
the sources on every `checkMint`. There is **no cached reserve value** that could go stale between
attestation and mint.

#### External functions

```solidity
/// @notice Reverts unless minting `amount` of `token` keeps supply within the
///         secure-mint limit. Called BY the cBTC token, IN the mint path, with
///         the token's pre-mint totalSupply.
/// @dev Access: restricted to the token contract registered for `token` in the
///      TokenizationRegistry (RoleManager check + identity check). No other
///      caller — including ISSUER_MINTER directly — may invoke a passing path.
function checkMint(address token, uint256 amount) external view;

/// @notice Non-reverting status read for monitoring/console (O9, F4, F7).
function reserveStatus(address token)
    external
    view
    returns (
        bool   ok,                 // would a 0-amount checkMint pass freshness?
        uint256 effectiveLimit,    // min(sources) − margin, in token decimals
        uint256 currentSupply,     // token.totalSupply()
        uint256 headroom,          // effectiveLimit − currentSupply (0 if underwater)
        bytes32 blockingReason     // 0 if ok, else STALE/NEGATIVE/MISSING/DISCREPANCY
    );

/// @notice The largest `amount` checkMint(token, amount) would currently allow.
///         Powers the UI's "max mintable" without trial reverts (F1).
function previewMintLimit(address token) external view returns (uint256 maxMintable);
```

> **`checkMint` is a `view`.** It reverts on violation but performs no state change; the actual
> supply increment happens in the token's `_mint` immediately after. The token contract is
> `nonReentrant` over the `checkMint → recordMint → _mint` sequence (S5), so the supply the guard
> reads cannot be inflated between check and mint.

#### The secure-mint rule, in detail

For a token with config `cfg = registry.getConfig(token)`:

1. **Gather sources.** For each `src` in `cfg.reserveSources` (1 in Core, ≤2 in v1.1):
   `(amt, asOf, dec) = IReserveSource(src).attestedReserves(token)`.
2. **Freshness gate (per source).** Require `asOf != 0` and
   `block.timestamp − asOf ≤ cfg.maxAges[src]`; else this source is **STALE** → fail-closed.
   Require `asOf ≤ block.timestamp + MAX_CLOCK_SKEW` (default 5 min) to reject future-dated
   attestations.
3. **Validity gate (per source).** Require `amt > 0` (a zero/negative reserve quantity blocks new
   mints — **NEGATIVE/MISSING** → fail-closed).
4. **Decimal scaling.** `scaled = ReserveMath.scaleToTokenDecimals(amt, dec, TOKEN_DECIMALS)`
   where `TOKEN_DECIMALS = 8` for cBTC. Scaling **rounds down** (conservative — never overstates
   reserves). `dec` and `TOKEN_DECIMALS` are both required `≤ 18`.
5. **Discrepancy gate (only when ≥2 sources).** Let `lo = min(scaled_i)`, `hi = max(scaled_i)`.
   If `hi == 0` revert MISSING. If `(hi − lo) * 10_000 / hi > cfg.maxDiscrepancyBps` → **DISCREPANCY**
   → fail-closed (the two attestations disagree beyond tolerance; do not guess which is right).
   Otherwise the effective reserve is `lo` (always take the **lower** of disagreeing sources).
6. **Margin.** Compute `margin`:
   - `MarginMode.PositivePercentage`: `margin = effectiveReserve * cfg.marginAmount / 10_000`
   - `MarginMode.PositiveAbsolute`: `margin = cfg.marginAmount` (token-decimals quantity)
   - `MarginMode.None`: `margin = 0` (permitted only by explicit timelocked config; discouraged)
   - `NegativePercentage` / `NegativeAbsolute`: **REJECTED at config time** (S2.3) — a negative
     margin would intentionally permit under-collateralized supply, which is wrong for regulated
     repo collateral. The guard never sees a negative-margin config because the registry setter
     reverts it.
7. **Effective limit.** `effectiveLimit = effectiveReserve − margin` (revert/underflow-safe; if
   `margin ≥ effectiveReserve` the limit is `0`).
8. **The check.** Require `token.totalSupply() + amount ≤ effectiveLimit`; else revert
   `ReserveExceeded(token, totalSupply()+amount, effectiveLimit)`.

`ReserveMath` (a library in the shared `Math` set, S0.3) provides:

```solidity
library ReserveMath {
    /// scale `amount` from `fromDec` to `toDec`, rounding DOWN; reverts if either > 18.
    function scaleToTokenDecimals(uint256 amount, uint8 fromDec, uint8 toDec)
        internal pure returns (uint256);
}
```

#### Fail-closed semantics (precise scope)

Fail-closed means **reserve uncertainty blocks the creation of NEW liability, never the discharge
of existing liability.** Concretely:

| Path | Reserve stale / negative / missing / discrepant? |
|---|---|
| **`mintForPledge`** (new cBTC) | **BLOCKED** (this is the whole point). |
| `borrow` (S10) — draws against already-minted cBTC | Not gated by `ReserveGuard` (no new cBTC). Gated by the bridge/Morpho HF, not backing freshness. |
| `repayWithdrawAndBurn` (S10) | **ALLOWED.** Burning reduces supply; never worsens the backing ratio. |
| `liquidateWithdrawAndBurn` (S13/S10) | **ALLOWED.** A stale PoR is an *operational* fault, not evidence the collateral vanished; blocking liquidation on stale data would strand bad debt. |
| `burnForRelease` (S5) | **ALLOWED.** Same rationale — burns only shrink liability. |

This asymmetry is invariant-preserving by construction: every allowed-while-stale path **monotonically
decreases** `totalSupply()`, so it can never violate `supply ≤ min(sources) − margin`. The principle
(from the PoR plan): *"never respond to reserve uncertainty by allowing fresh mints; never let it
brick the exits."*

#### Events

```solidity
event RegistrySet(address indexed registry);
event MintChecked(address indexed token, uint256 amount, uint256 supplyAfter, uint256 effectiveLimit);
event ReserveShortfallObserved(address indexed token, uint256 supply, uint256 effectiveLimit); // monitoring hook (O9)
```

`MintChecked` is emitted by the token on a passing mint (the guard is `view`); `ReserveGuard`
exposes `reserveStatus`/`previewMintLimit` for the off-chain monitor (S0.4 O9) to detect a breach
of `supply > effectiveLimit` even when no mint is attempted (e.g. reserves dropped after mint).

#### Errors

```solidity
error ReserveExceeded(address token, uint256 wouldBeSupply, uint256 effectiveLimit);
error ReserveStale(address token, address source, uint64 asOf, uint64 maxAge);
error ReserveNonPositive(address token, address source);
error ReserveSourceMissing(address token);
error ReserveDiscrepancy(address token, uint256 lo, uint256 hi, uint16 maxBps);
error ReserveClockSkew(address token, address source, uint64 asOf);
error NotRegisteredToken(address caller, address token);
```

#### Invariants upheld

- **S0.9 #1** — the sole on-chain enforcer of `totalSupply ≤ min(sources) − margin`.
- Conservatism: decimal scaling rounds down; the lower of two disagreeing sources is used; margin
  is always subtracted (never added).
- Privilege separation (S0.9 #8): the guard enforces but never sets limits; config comes from
  CURATOR-through-timelock via `TokenizationRegistry`.

#### External dependencies

`TokenizationRegistry` (S2.3, for config), `IReserveSource` implementations (S2.1/S3),
`RoleManager` (S0.3 #1, for the UUPS upgrade gate and caller authorization), `ReserveMath`.

#### Why Core / What breaks if omitted

**Test: Solvency.** This is *the* launch blocker. Without `ReserveGuard` in the mint path, an
`ISSUER_MINTER` key (or a buggy CRE workflow, or a compromised custodian signer) can mint cBTC with
no backing; that unbacked cBTC is posted to Morpho and borrowed against real USDC — the 1:1
invariant dies and the entire product premise ("every token is backed by a locked real asset")
becomes a lie. An issuer-only access check is the control PYUSD and uniBTC *already had* and that
*did not save them*; the mechanical reserve ceiling is what does. Omitting it is the single most
dangerous cut in the system.

---

### S2.3 `TokenizationRegistry` — per-cToken config

#### Purpose

`TokenizationRegistry` is the **single place that binds a collateral token to its reserve policy**:
which sources back it, their decimals and staleness windows, the discrepancy tolerance, the margin
mode/amount, and the hashes of the off-chain policy documents (custody lock policy, legal control
agreement) the on-chain config corresponds to. It exists as a **separate contract** from
`KYBGateway`/`PledgeRegistry` (rather than overloading another registry) specifically to **reduce
UUPS storage-layout risk** and to keep token-admission concerns isolated from reserve/pledge
semantics (per the PoR-plan decision).

It is **UUPS + timelock**. All risk-relevant setters are `restricted` to **CURATOR through the
timelock** (S0.6 — AMINA sets risk params, but never instantly); a **GUARDIAN may pause a token's
mintability immediately** (hot key, risk-reducing only, per S0.6 / S0.9 #8). This split is the
on-chain encoding of D-10: no role both moves collateral and sets risk values; hot keys may only
reduce risk.

#### Storage (ERC-7201 namespaced)

```solidity
enum MarginMode { None, PositivePercentage, PositiveAbsolute } // negative modes are unrepresentable → cannot be configured
enum SourceMode { AdapterOnly, ChainlinkOnly, MinOfSources }   // Core launch = AdapterOnly

struct TokenizationConfig {
    bool        active;            // master mint-enable; GUARDIAN can flip false instantly
    uint8       decimals;          // token decimals (8 for cBTC) — must equal token.decimals()
    address[]   reserveSources;    // IReserveSource addresses (1 in Core, ≤2 in v1.1)
    SourceMode  sourceMode;
    mapping(address => uint64) maxAges;  // per-source staleness window (seconds)
    MarginMode  marginMode;
    uint256     marginAmount;      // bps if PositivePercentage, token-units if PositiveAbsolute
    uint16      maxDiscrepancyBps; // tolerance when ≥2 sources (e.g. 50–100)
    bytes32     lockPolicyHash;    // hash of the off-chain custody-lock policy (S3)
    bytes32     controlAgreementHash; // hash of the AMINA tri-party control agreement (S0.1)
    uint64      configVersion;     // bumped on any setter; positions/monitoring pin this
}

/// @custom:storage-location erc7201:triora.tokenizationregistry.v1
struct TokenizationRegistryStorage {
    mapping(address token => TokenizationConfig) configs;
}
```

#### External functions

```solidity
// ---- Admin (CURATOR via timelock) ----
function registerToken(address token, TokenizationConfigInput calldata cfg) external; // restricted; one-time bind
function setReserveSources(address token, address[] calldata sources, SourceMode mode) external; // restricted
function setMaxAge(address token, address source, uint64 maxAge) external; // restricted; maxAge != 0
function setMargin(address token, MarginMode mode, uint256 amount) external; // restricted
function setMaxDiscrepancyBps(address token, uint16 bps) external; // restricted; bps ≤ 10_000
function setPolicyHashes(address token, bytes32 lockPolicyHash, bytes32 controlAgreementHash) external; // restricted

// ---- Guardian (hot key, risk-reducing only) ----
function pauseToken(address token) external;   // GUARDIAN; sets active=false, blocks new mints
function unpauseToken(address token) external; // CURATOR via timelock ONLY (un-pausing is risk-adding)

// ---- Reads (used by ReserveGuard, lenses, console) ----
function getConfig(address token) external view returns (TokenizationConfigView memory);
function isMintActive(address token) external view returns (bool);
function configVersion(address token) external view returns (uint64);
```

> **Asymmetry of pause/unpause is deliberate.** `pauseToken` is a hot-key, instant, risk-*reducing*
> action (GUARDIAN). `unpauseToken` re-enables minting — a risk-*adding* action — so it is
> CURATOR-through-timelock only. This enforces S0.6's "hot keys may only reduce risk."

#### Validation rules (enforced in setters — fail at config time, not mint time)

- `decimals == IERC20Metadata(token).decimals()` and `decimals ≤ 18`.
- `reserveSources.length ≥ 1`; every source returns non-reverting `sourceKind()` (sanity probe).
- `SourceMode.MinOfSources` requires `reserveSources.length == 2` (Core uses `AdapterOnly`, length 1).
- `setMaxAge`: `maxAge != 0` (a zero staleness window would disable freshness — forbidden for live
  tokens, per the PoR-plan rejection of `maxStaleness == 0`).
- `setMargin`: only the three representable modes; there is **no enum value for a negative margin**,
  so under-collateralized configs are unrepresentable, not merely discouraged.
- `setMaxDiscrepancyBps`: `bps ≤ 10_000`.
- `registerToken` is one-time per token (no silent re-bind); changing the bound token requires a new
  registration with a new config version.

#### Events

```solidity
event TokenRegistered(address indexed token, uint64 configVersion);
event ReserveSourcesSet(address indexed token, address[] sources, SourceMode mode, uint64 configVersion);
event MaxAgeSet(address indexed token, address indexed source, uint64 maxAge, uint64 configVersion);
event MarginSet(address indexed token, MarginMode mode, uint256 amount, uint64 configVersion);
event MaxDiscrepancySet(address indexed token, uint16 bps, uint64 configVersion);
event PolicyHashesSet(address indexed token, bytes32 lockPolicyHash, bytes32 controlAgreementHash, uint64 configVersion);
event TokenPaused(address indexed token, address indexed guardian);
event TokenUnpaused(address indexed token);
```

Every setter bumps `configVersion` and emits it — the off-chain indexer (O3) and Account/Evidence
hub (F4) display the live config version alongside the token so institutions can audit exactly which
policy a mint was checked against.

#### Errors

```solidity
error TokenAlreadyRegistered(address token);
error DecimalsMismatch(address token, uint8 cfg, uint8 actual);
error TooManyDecimals(uint8 decimals);
error EmptyReserveSources();
error MinOfSourcesRequiresTwo();
error ZeroMaxAge();
error DiscrepancyBpsTooHigh(uint16 bps);
error SourceProbeFailed(address source);
```

#### Invariants upheld

- Negative margin is **unrepresentable** (enum has no negative value) → contributes to S0.9 #1.
- Each live token always has `maxAge != 0` (no disabled freshness) and `decimals` matching the token.
- Config changes are version-stamped; `pauseToken` can instantly halt new mints (incident response,
  S0.4 O9 / S0.5 F7).

#### External dependencies

`RoleManager` (CURATOR/GUARDIAN gating + timelock), `IReserveSource` (probe at config time),
`IERC20Metadata` (decimals check).

#### Why Core / What breaks if omitted

**Test: Solvency (and Reversibility).** Without a single binding registry, the secure-mint guard
has nowhere to read *which* source backs a token, *how fresh* it must be, or *how much margin* to
hold — the policy would be hardcoded per deployment, and adding the v1.1 second source or tightening
a staleness window would be a contract change rather than a timelocked config change. It is also the
place the on-chain config is bound to the **off-chain policy hashes** (custody lock, control
agreement) that make the backing legally real (S0.1, Liability). Omitting it means misconfiguration
at the mint boundary with no auditable version trail, and turns every policy tweak into a migration
(fails Reversibility).

---

### S2.4 Launch source: `SignedCustodyAdapter` (detailed in S3)

At launch the **only** `IReserveSource` is `SignedCustodyAdapter` (S3, `SourceMode.AdapterOnly`).
For S2's purposes the contract guarantees, per S2.1:

- `attestedReserves(cBTC)` returns the BTC quantity (8 decimals) from the **latest dual-signed
  (custodian + AMINA) EIP-712 attestation**, with `asOf = observedAt`.
- It is **immutable per custodian** (D-8): no setter can mutate a stored attestation's quantity; a
  new fact is a new signed attestation, not an edit. (This closes the "unauthenticated `setAmount`
  reserve-inflation footgun" the corpus flags.)
- The dual signature requirement means neither the custodian alone nor AMINA alone can move the
  reserve number the guard reads — it takes both, matching the off-chain tri-party "no movement
  without the agent."

The full attestation struct, EIP-712 typehashes, freshness/skew handling, and the
`isLockActive`/`verifyPledge`/`releaseAcknowledged` methods of `ICustodyAdapter` are specified in
**S3**. S2 depends only on `attestedReserves`/`sourceKind` from that contract.

---

### S2.5 The interface is the audit boundary (swapping sources without mint-path re-audit)

This subsection makes the central claim of the section concrete.

**Claim:** moving from the launch signed-attestation source to a production Chainlink PoR feed or a
CRE-delivered report requires **no change to, and no re-audit of, `ReserveGuard` or
`PermissionedCollateralToken.mintForPledge`** — the most sensitive code in the system.

**Why it holds:**

1. `ReserveGuard.checkMint` and the token's mint path reference reserve data **exclusively** through
   `IReserveSource` (S2.1). They contain no provider-specific logic — no Chainlink ABI, no EIP-712
   verification, no KeystoneForwarder decoding. All of that lives *inside* the source implementation,
   behind `attestedReserves`.
2. Adding/swapping a source is a `TokenizationRegistry.setReserveSources(token, [...], mode)` call
   (CURATOR through timelock, S2.3). The guard re-reads the new source set on the next `checkMint`.
3. The v1.1 sources each only have to satisfy the S2.1 contract:
   - **`ChainlinkPoRSource`** wraps `AggregatorV3Interface.latestRoundData()`, rejecting `answer<=0`,
     `answeredInRound < roundId`, and exposing `(answer, updatedAt, decimals())` as
     `(amount, asOf, decimals)`. It is read identically to a price feed but the value is a **reserve
     quantity**, not a USD price — it is registered as a reserve source, never wired into
     `OracleAdapter` (S6), preserving the S0.9 oracle/reserve separation.
   - **`CREReportReceiver`** implements `onReport(metadata, report)` for the KeystoneForwarder,
     authenticating on the **full workflow ID + owner** (never the 40-bit name-hash prefix), storing
     the latest `(amount, asOf)`, and serving it through `attestedReserves`. It carries a chain
     selector/domain in the payload to defeat cross-chain report replay, and is idempotent on
     re-delivered reports (inclusion ≠ finality).
4. The audited security property — *"a mint cannot exceed `min(fresh sources) − margin`, fail-closed
   on staleness"* — is enforced one level **above** the source, so it is invariant under which
   concrete source is plugged in. New sources are audited **in isolation** (does this implementation
   return an honest, fresh quantity?) without re-opening the guarded mint path.

**Migration path (v1.1):** deploy `ChainlinkPoRSource`/`CREReportReceiver` → register and fork-test
it as a *second* source with `SourceMode.MinOfSources` and a `maxDiscrepancyBps` tolerance (so the
new feed must agree with the proven signed-attestation source within tolerance before it can ever
*lower* the limit) → once confidence is established, optionally retire the original source via a
timelocked `setReserveSources`. At no point is the mint path touched.

> **Copy/UI constraint (for S2-derived data on F4 evidence hub):** the reserve source is shown as
> *"reserve attestation (signed custody)"* or *"reserve attestation (Chainlink PoR)"* with a
> freshness timestamp and the reserve ratio. Never render mint mechanics as *"Chainlink mints"* —
> Chainlink/CRE is a **data source**; the on-chain `ReserveGuard` is the control that authorizes a
> mint. The displayed reserve ratio uses `min(sources) / totalSupply`, not a single source.

#### Why Core / What breaks if omitted

**Test: Reversibility.** This boundary is what lets Triora launch *safely* on dual signed
attestations **today** (CRE is Early Access and "announced ≠ provably live") while keeping the
production Chainlink PoR/CRE feed a **non-breaking** drop-in. Omit the boundary and you must either
(a) wait for CRE to be production-proven before launching, or (b) launch with the guard welded to one
producer and pay a full mint-path re-audit when you swap it. Both are unacceptable for a "minimal yet
production-safe" Core; the interface boundary is precisely the cheap structural decision that avoids
them.

---

### S2.6 Cross-references and invariant summary

- **S0.9 #1** is enforced here (`ReserveGuard`, S2.2) and nowhere else on-chain.
- The mint *caller* and `mintForPledge` mechanics are in **S5** (`PermissionedCollateralToken`); the
  `pledged ≥ minted` half of the backing story is in the **`PledgeRegistry`** section.
- The launch source internals (dual EIP-712 attestations, lock-active, release-ack) are in **S3**.
- Reserve quantity (this section) and USD price (**S6** `OracleAdapter`) are **separate planes**:
  they never share config structs or heartbeat fields, per S0.9. A reserve source feeds
  `ReserveGuard`; a price feed feeds collateral valuation and the liquidation trigger.
- Off-chain, the **Reserve/PoR publisher** (S0.4 O7) produces the attestations consumed here, and
  **Monitoring** (O9) pages on `supply > effectiveLimit`, stale attestations, and source discrepancy
  using `ReserveGuard.reserveStatus`.


## S3. Custody Integration & Attestation

This section specifies the boundary where off-chain custody facts become on-chain
truth. Triora never holds Bitcoin; the BTC sits in a qualified custodian's
segregated account under a tri-party **control agreement** (S0.1, D-3, D-5). The
contracts can only *mirror* and *account* — they cannot read a custodian API. So
every custody fact (reserves exist, the lock is active, a pledge is real, a
release was executed) must arrive **as signed evidence** and be authenticated
on-chain. S3 defines that evidence channel: the `ICustodyAdapter` interface, the
`SignedCustodyAdapter` dual-EIP-712 implementation, the control-agreement
binding that legally perfects the security interest, and how this adapter feeds
`ReserveGuard` (S4-class concern, mint-path) and is consumed by `PledgeRegistry`
(S5) and `ReleaseAuthorizer` (S7).

Locked decisions this section obeys: **D-5** (custody facts arrive as dual
custodian+AMINA EIP-712 attestations; no contract calls a custodian API; PoR/CRE
is a drop-in alternative source behind the same `ReserveGuard` interface),
**D-8** (one asset BTC, one custodian for Core, behind adapters), **D-10** (role
separation — the custodian signer that mints cannot also authorize release).
Decimals: cBTC = 8, USDC = 6 (S0.10). Cross-asset value math is in `OracleAdapter`
(S6), not here — S3 deals only in **reserve quantities** (sats), never USD.

---

### S3.1 Why no contract calls a custodian API (the design axiom)

A smart contract is deterministic and offline: it cannot make an authenticated
HTTPS call to Anchorage/BitGo, cannot present a bearer token, cannot parse a TLS
response, and cannot agree across validators on a single API result. Any pattern
where "the contract checks custody" is therefore really "a privileged off-chain
relayer pushes a number the contract trusts." The corpus's recurring failure
class — reserve inflation via an unauthenticated `setAmount(uint)` footgun — is
exactly that pattern done badly.

Triora inverts it: custody facts are produced off-chain as **structured,
hashed, dual-signed evidence packets** and *submitted* to the chain, where the
contract verifies two independent EIP-712 signatures before storing anything. The
authority is the signature set, not the caller. This makes the data path
*verifiable* rather than *trusted*, makes the custodian *swappable* (a second
custodian is a second adapter + signer set, not a code rewrite), and keeps a
permanent on-chain audit trail of who attested what, when.

The Chainlink Proof-of-Reserve / CRE model is the same shape with a different
signer: a DON publishes a DON-signed report instead of a custodian EOA/multisig.
Because both reduce to "a verified `(reserveQuantity, asOf)` behind the
`IReserveSource` view," a PoR feed slots in later **without re-auditing the mint
path** (D-5). S3 builds the signed-attestation source for Core; `ChainlinkPoRSource`
is the v1.1 alternative (S3.9).

#### Why Core / What breaks if omitted

**Test: Solvency + Liability.** Without an authenticated custody-evidence
channel, custody facts enter through a trusted setter — the reserve-inflation
footgun (PYUSD's 300T mint, uniBTC's mispriced mint are the market's tombstones).
A single relayer key could then assert reserves that do not exist, and
`ReserveGuard` would happily authorize unbacked cBTC, collapsing the 1:1 invariant
(S0.9 #1). Omitting the *dual* signature additionally re-creates single-key
custody control: the custodian alone (or a compromised custodian relayer) could
inflate reserves with no AMINA check — defeating D-3/D-5 and pushing custody
liability onto P2P.

---

### S3.2 `ICustodyAdapter` — the interface every custodian hides behind

`ICustodyAdapter` is the uniform, custodian-agnostic surface the rest of the
protocol speaks. It exposes exactly four read/verify operations and the
`IReserveSource` view; it performs **no** custody movement (movement is off-chain,
gated by `ReleaseAuthorizer` vouchers + AMINA co-sign — S7, S8/S9 services).
Adding a custodian = deploying a new adapter that implements this interface; no
caller changes.

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice Reserve-quantity source consumed by ReserveGuard (S4). One adapter
///         per (custodian, asset). Quantities are in the cToken's own decimals
///         (cBTC = 8). NEVER a USD value.
interface IReserveSource {
    /// @return amount  attested reserve quantity (token decimals, e.g. sats)
    /// @return asOf    observation timestamp the off-chain world vouched for
    /// @return expiresAt  hard expiry of this evidence (fail-closed past it)
    function attestedReserves(address cToken)
        external view returns (uint256 amount, uint64 asOf, uint64 expiresAt);
}

/// @notice The custody bridge. All facts are derived from stored signed evidence.
interface ICustodyAdapter is IReserveSource {
    /// @notice Verify a pledge attestation matches stored, freshly-signed evidence.
    ///         Pure-ish view: PledgeRegistry (S5) calls this before registering a pledge.
    /// @dev Reverts on signature/freshness failure; returns false only for a
    ///      well-formed-but-unbacked claim. Implementations SHOULD revert, not
    ///      return false, for malformed/forged input (callers treat false == reject).
    function verifyPledge(bytes32 subjectId, PledgeAttestation calldata att)
        external view returns (bool ok, bytes32 reasonCode);

    /// @notice Is the tri-party control lock currently active for this custody account?
    ///         True iff the latest stored proof flipped controlActive AND is fresh.
    function isLockActive(bytes32 custodyAccountRef) external view returns (bool);

    /// @notice Has an off-chain release for this voucher been acknowledged on-chain?
    ///         Set by the settlement service ack (S8/S9) via a separate ack proof.
    function releaseAcknowledged(bytes32 pledgeId, bytes32 voucherRef)
        external view returns (bool);
}
```

The split is deliberate: `attestedReserves` answers "how much is backed"
(quantity, for `ReserveGuard`); `verifyPledge` answers "is *this specific
deposit* real" (binding, for `PledgeRegistry`); `isLockActive` answers "is the
legal lock live right now" (control, gating mint and binding); `releaseAcknowledged`
closes the loop after custody actually moves the BTC (gating burn-for-release in
S7).

#### Why Core / What breaks if omitted

**Test: Reversibility + Liability.** Without the adapter abstraction, the bridge
(S5/S7) and `ReserveGuard` (S4) weld directly to one custodian's attestation
format and signer scheme. Adding a second custodian (D-8 future), or swapping to
a Chainlink PoR feed (D-5), then forces a rewrite + re-audit of the most
solvency-sensitive contracts. The interface is ~30 lines; the cut it prevents is
a spine re-audit.

---

### S3.3 The custody evidence model — `CustodyProof` / `PledgeAttestation`

Two structs cross the boundary. They are defined in the `Types` library (S0.3)
and their EIP-712 typehashes in `EIP712Hashes`. Both are **dual-signed**
(custodian signer + AMINA signer) and carry the hashes that bind the on-chain
claim to off-chain legal and custody facts.

`PledgeAttestation` is per-deposit: it asserts "this much of this asset sits in
this custody account, locked under this policy, and is the basis for this much
cBTC."

```solidity
struct PledgeAttestation {
    bytes32 subjectId;            // borrower/entity identity hash (KYB-bound, S2)
    bytes32 custodyAccountRef;    // hash of the segregated custody account id
    address asset;                // the cToken this backs (cBTC address)
    uint256 amount;               // reserve quantity in token decimals (sats; cBTC=8)
    uint8   decimals;             // 8 — echoed for cross-check vs cToken.decimals()
    uint64  observedAt;           // when custody observed the balance/lock
    uint64  expiresAt;            // hard expiry; past it the proof is dead
    bytes32 evidenceHash;         // keccak256 of the off-chain CollateralProofPacket
    bytes32 lockPolicyHash;       // hash of the withdrawal/lock policy in force
    bytes32 controlAgreementHash; // hash of the executed tri-party control agreement (S3.4)
    uint256 nonce;                // per-subject monotonic anti-replay
}
```

`CustodyProof` is the periodic account-level heartbeat that drives reserves and
the control-active flag. It is what an off-chain reserve publisher (S0.4 O5/O7)
re-submits on a cadence so `attestedReserves` stays fresh and `ReserveGuard`
stays open.

```solidity
struct CustodyProof {
    bytes32 subjectId;
    bytes32 custodyAccountRef;
    address asset;                // cBTC
    uint256 reserveAmount;        // total locked quantity in this account (sats)
    uint8   decimals;             // 8
    uint64  observedAt;
    uint64  expiresAt;
    bytes32 evidenceHash;
    bytes32 lockPolicyHash;
    bytes32 controlAgreementHash;
    bool    controlActive;        // is the tri-party lock asserted active?
    uint256 nonce;
}
```

Invariants the structs encode: `amount`/`reserveAmount` are **quantities, never
USD** (the price plane is S6 and must never share fields with the reserve plane);
`decimals` is echoed so the adapter can revert on a decimals mismatch against
`IERC20Metadata(asset).decimals()` (the uniBTC class bug — valuing the wrong unit);
`controlAgreementHash` and `lockPolicyHash` make the legal lock part of the signed
payload (S3.4); `nonce` is monotonic per `subjectId` to stop replay of an old,
higher-reserve proof.

#### Why Core / What breaks if omitted

**Test: Solvency.** These fields are the mechanical join between the real asset
and the token. Drop `evidenceHash`/`lockPolicyHash`/`controlAgreementHash` and the
on-chain claim no longer commits to any off-chain document — there is nothing to
reconcile in a dispute, and "1:1 backed" becomes unfalsifiable. Drop `decimals`
and a decimals-mismatched feed mis-sizes the mint. Drop `expiresAt`/`nonce` and a
stale or replayed proof keeps `ReserveGuard` open after the real reserves have
moved.

---

### S3.4 The control-agreement binding (what actually perfects the lock)

The token does **not** secure the lender; the **tri-party control agreement**
does (corpus C-2; UCC Art. 8/9 "control"; the Lehman/MF-Global unsecured-creditor
failure mode). In Anchorage's Atlas/ACA model this is the Account Control
Agreement that flips the custody account from *joint control* (borrower cannot
withdraw unilaterally; secured party cannot move without cause) to *exclusive
control* on a default Notice. Triora's on-chain layer cannot store or enforce the
legal document — but it **commits to it cryptographically** so that every minted
token, every pledge, and every release is provably tied to a specific executed
agreement.

Mechanism:

1. The executed control agreement is a legal document held off-chain. Its
   canonical serialization is hashed → `controlAgreementHash`.
2. Every `CustodyProof` and `PledgeAttestation` **includes** `controlAgreementHash`
   in the EIP-712-signed payload (S3.3). The custodian and AMINA, by signing,
   each attest "the account is governed by the agreement whose hash is X."
3. `SignedCustodyAdapter` stores the `controlAgreementHash` alongside the latest
   proof and exposes it for the evidence hub (S0.5 F4 / frontend). It is part of
   `isLockActive`'s precondition: the lock is "active" only while the stored proof
   asserts `controlActive == true` *and* is fresh *and* its `controlAgreementHash`
   matches the account's registered agreement (set once at adapter
   configuration).
4. A change of agreement hash is a privileged, timelocked config action
   (`ORACLE_ADMIN`/`CURATOR` per S0.6), never something a heartbeat can silently
   alter — a proof carrying an unexpected `controlAgreementHash` is **rejected**,
   not auto-adopted.

This gives the protocol a falsifiable, on-chain anchor for the one thing that
makes the collateral legally seizable: if the off-chain agreement is not the one
the chain committed to, the mismatch is detectable and mints freeze.

#### Why Core / What breaks if omitted

**Test: Liability (+ Solvency).** Without binding the control-agreement hash into
the signed evidence, the on-chain "lock" is decorative: tokens could be minted
against an account that is *not* under an enforceable control agreement, leaving
AMINA/the lender as an unsecured creditor exactly when enforcement is needed
(default). This is the corpus's single most load-bearing legal control; the
on-chain hash binding is the cheap, non-breaking way to make it auditable and to
fail-close when it is absent or wrong.

---

### S3.5 `SignedCustodyAdapter` — purpose, storage, behavior

`SignedCustodyAdapter` is the Core `ICustodyAdapter`/`IReserveSource`
implementation: one deployment per `(custodian, asset)` (e.g. the Core BTC
custodian's cBTC adapter). It is **immutable per custodian** (S0.3 row 5): its
trusted signer set and bound agreement hash are set at construction/config and
changed only by timelocked role action — never by a heartbeat. It verifies two
EIP-712 signatures on every submitted proof, enforces freshness and clock-skew,
and stores the latest authenticated proof + the control-active flag.

Storage uses ERC-7201 namespacing only if deployed as an upgradeable proxy; for
Core it is a plain immutable contract, so a single struct suffices. Layout:

```solidity
contract SignedCustodyAdapter is ICustodyAdapter, EIP712 {
    // ---- immutable / config (set at construction or via timelocked setters) ----
    address public immutable cToken;            // the cBTC this adapter backs
    uint8   public immutable cTokenDecimals;    // 8, cached from cToken.decimals()
    address public custodianSigner;             // custodian attestation key (EOA or 1271 contract)
    address public aminaSigner;                 // AMINA attestation key (separate from release signer, D-10)
    bytes32 public controlAgreementHash;        // the executed tri-party agreement bound to this account
    bytes32 public custodyAccountRef;           // the single segregated account this adapter mirrors
    uint64  public maxStaleness;                // max(now - asOf) tolerated, e.g. 10 min
    uint64  public maxClockSkew;                // max(observedAt - now) tolerated, e.g. 5 min

    // ---- mutable authenticated state ----
    struct StoredProof {
        uint256 reserveAmount;
        uint64  observedAt;
        uint64  expiresAt;
        bytes32 lockPolicyHash;
        bool    controlActive;
        uint256 nonce;            // last accepted nonce (monotonic)
    }
    StoredProof internal _latest;                          // per (this) = per account/asset
    mapping(bytes32 => mapping(bytes32 => bool)) internal _releaseAcked; // pledgeId => voucherRef => acked
}
```

Submission entry point (called by the reserve/attestation publisher service,
S0.4 O5/O7 — permissionless to *relay*, but only valid dual-signed proofs are
accepted; the relayer is untrusted):

```solidity
function submitProof(
    CustodyProof calldata p,
    bytes calldata custodianSig,
    bytes calldata aminaSig
) external; // emits ProofSubmitted; reverts on any check below
```

`submitProof` checks, in order (fail-closed — any failure reverts and stores
nothing):

1. **Asset & decimals**: `p.asset == cToken` and `p.decimals == cTokenDecimals`
   (revert `AssetMismatch` / `DecimalsMismatch`).
2. **Account & agreement**: `p.custodyAccountRef == custodyAccountRef` and
   `p.controlAgreementHash == controlAgreementHash`
   (revert `AccountMismatch` / `ControlAgreementMismatch`).
3. **Freshness**: `p.observedAt <= block.timestamp + maxClockSkew` (revert
   `ClockSkew`), `block.timestamp - p.observedAt <= maxStaleness` (revert
   `StaleProof`), `p.expiresAt > block.timestamp` (revert `Expired`).
4. **Monotonic nonce**: `p.nonce > _latest.nonce` (revert `NonceReplay`).
5. **Dual signatures**: recover/verify the EIP-712 digest of `p` against
   `custodianSigner` **and** `aminaSigner` via
   `SignatureChecker.isValidSignatureNow` (supports EOA + ERC-1271 multisig).
   Either failure reverts `BadCustodianSig` / `BadAminaSig`.
6. **Store**: write `_latest` from `p`; emit `ProofSubmitted(subjectId,
   reserveAmount, observedAt, expiresAt, controlActive, nonce)`.

Reads:

```solidity
function attestedReserves(address asset_)
    external view returns (uint256 amount, uint64 asOf, uint64 expiresAt)
{
    if (asset_ != cToken) revert AssetMismatch();
    StoredProof storage s = _latest;
    if (s.observedAt == 0) revert NoProof();                  // fail-closed: never attested
    if (block.timestamp - s.observedAt > maxStaleness) revert StaleProof();
    if (s.expiresAt <= block.timestamp) revert Expired();
    return (s.reserveAmount, s.observedAt, s.expiresAt);
}

function isLockActive(bytes32 ref) external view returns (bool) {
    if (ref != custodyAccountRef) return false;
    StoredProof storage s = _latest;
    return s.controlActive
        && s.observedAt != 0
        && block.timestamp - s.observedAt <= maxStaleness
        && s.expiresAt > block.timestamp;
}
```

**Fail-closed semantics (critical):** `attestedReserves` *reverts* on
missing/stale/expired data rather than returning 0. This is deliberate —
`ReserveGuard` (S4) must distinguish "reserves are zero" (which would block mint
anyway) from "we don't know" (which must block mint loudly and page ops, per
S0.4 O9). A view that silently returned `(0, …)` would let a buggy guard treat
"unknown" as "empty but valid." Reverting forces the guard to treat data
uncertainty as a hard mint block.

`verifyPledge` (called by `PledgeRegistry`, S5) re-derives the EIP-712 digest of
the supplied `PledgeAttestation`, checks both signatures, and checks the same
asset/decimals/account/agreement/freshness conditions; on success it returns
`(true, 0)`, otherwise `(false, reasonCode)` for well-formed-but-unbacked claims
and reverts for malformed/forged input.

```solidity
function verifyPledge(bytes32 subjectId, PledgeAttestation calldata att)
    external view returns (bool ok, bytes32 reasonCode)
{
    if (att.asset != cToken)                  return (false, "ASSET");
    if (att.decimals != cTokenDecimals)       return (false, "DECIMALS");
    if (att.custodyAccountRef != custodyAccountRef) return (false, "ACCOUNT");
    if (att.controlAgreementHash != controlAgreementHash) return (false, "AGREEMENT");
    if (att.expiresAt <= block.timestamp)     return (false, "EXPIRED");
    if (att.observedAt > block.timestamp + maxClockSkew) return (false, "SKEW");
    bytes32 digest = _hashPledge(att);
    if (!SignatureChecker.isValidSignatureNow(custodianSigner, digest, att.custodianSig)) return (false, "CUSTODIAN_SIG");
    if (!SignatureChecker.isValidSignatureNow(aminaSigner,     digest, att.aminaSig))     return (false, "AMINA_SIG");
    return (true, 0);
}
```

(`PledgeAttestation` carries `custodianSig`/`aminaSig` as trailing `bytes` in the
calldata struct, or they are passed as separate args; the typehash covers only
the signed fields, never the signatures themselves.)

The release acknowledgement is written by a separate, equally-dual-signed path so
that the loop closes only when custody really moved the BTC (S7/S8/S9):

```solidity
function ackRelease(
    bytes32 pledgeId, bytes32 voucherRef,
    bytes calldata custodianSig, bytes calldata aminaSig
) external; // verifies both sigs over (pledgeId, voucherRef); sets _releaseAcked; emits ReleaseAcked

function releaseAcknowledged(bytes32 pledgeId, bytes32 voucherRef)
    external view returns (bool) { return _releaseAcked[pledgeId][voucherRef]; }
```

#### Events

```solidity
event ProofSubmitted(bytes32 indexed subjectId, uint256 reserveAmount,
                     uint64 observedAt, uint64 expiresAt, bool controlActive, uint256 nonce);
event ReleaseAcked(bytes32 indexed pledgeId, bytes32 indexed voucherRef, uint64 ackedAt);
event SignerRotated(string indexed which, address oldSigner, address newSigner); // timelocked
event ControlAgreementUpdated(bytes32 oldHash, bytes32 newHash);                  // timelocked
```

#### Errors

```solidity
error AssetMismatch(); error DecimalsMismatch(); error AccountMismatch();
error ControlAgreementMismatch(); error ClockSkew(); error StaleProof();
error Expired(); error NonceReplay(); error BadCustodianSig(); error BadAminaSig();
error NoProof(); error NotAcked();
```

#### Invariants upheld

- I-S3.1 No state changes from an unverified caller: every stored fact passed
  **both** EIP-712 signature checks (custodian + AMINA). Directly upholds S0.9 #10
  (every custody movement authorized by an AMINA co-signature — here the
  *evidence* leg of it).
- I-S3.2 Monotonic nonce per account: a strictly increasing `nonce` is required,
  so an old (possibly higher-reserve) proof cannot be replayed.
- I-S3.3 Fail-closed reads: `attestedReserves` reverts on stale/missing/expired;
  `isLockActive` returns false on the same conditions. Supports S0.9 #1 by
  preventing mint on uncertain backing.
- I-S3.4 Decimals are pinned to the cToken (8) and cross-checked on every proof,
  preventing unit/scale mis-sizing of reserves (the uniBTC class).
- I-S3.5 Signer separation: the attestation signers configured here are
  distinct from the release-execution signer used by the settlement service
  (D-10) — the key that vouches reserves is not the key that moves BTC.

#### External dependencies

OZ `EIP712`, `SignatureChecker` (EOA + ERC-1271), `IERC20Metadata` (for the
decimals cross-check). No external calls to any custodian. Trusts only the two
configured signer addresses and the timelocked config.

#### Why Core / What breaks if omitted

**Test: Solvency + Liability.** This contract *is* the authenticated reserve and
lock source for the whole product. Omit it and reserves enter via a trusted
setter (S3.1 footgun) → unbacked mint → 1:1 invariant collapse. Omit the *dual*
signature and you have single-key custody control (custodian or a compromised
custodian relayer can inflate reserves without AMINA) → D-3/D-5 violated, custody
liability falls to P2P. Omit fail-closed reads and a stale heartbeat keeps mint
open after the BTC has left the account.

---

### S3.6 How `SignedCustodyAdapter` feeds `ReserveGuard` (the mint path)

`SignedCustodyAdapter` implements `IReserveSource`. `ReserveGuard` (S4) holds a
per-cToken policy `{source: IReserveSource, margin, maxStaleness, active}` and,
in the **actual mint path** (not a UI/backend pre-check), enforces:

```
supply_after_mint  ≤  min(freshPoR, freshAttestation)  −  positiveMargin
```

For Core there is one source (the signed attestation), so the rule reduces to
`supply_after ≤ attestedReserves − margin`, fail-closed. The call sequence on a
mint of cBTC (S5/S7 own the surrounding logic; shown here for the adapter's role):

```
ISSUER_MINTER → cBTC.mintForPledge(bridge, pledgeId, amount)
  → PledgeRegistry.canMint(pledgeId, amount)        // minted+amount ≤ pledged (S5)
  → adapter.isLockActive(custodyAccountRef)         // S3 — lock must be live
  → ReserveGuard.validateMint(cBTC, totalSupply()+amount)
        → (amt, asOf, exp) = adapter.attestedReserves(cBTC)   // S3, reverts if stale
        → require totalSupplyAfter ≤ scale(amt) − margin       // S4
  → _mint(...)                                       // only now
  → PledgeRegistry.recordMint(pledgeId, amount)      // S5
```

The guard reads the adapter **before** `_mint` so it sees the true current supply
(no TOCTOU window — the check and mint are one transaction). `attestedReserves`
reverting on stale data turns "reserve uncertainty" into a hard mint failure, and
ops gets paged on the revert/alarm (S0.4 O9). When a real Chainlink PoR feed is
added, `ReserveGuard` takes the `min()` of both sources — and because the adapter
already conforms to `IReserveSource`, that is a config change, not a mint-path
re-audit (D-5).

#### Why Core / What breaks if omitted

**Test: Solvency.** This wiring is the single mechanical defence against the
infinite-mint failure class. If the adapter did not feed the guard *in the mint
path*, the reserve check would be advisory only (off-chain "PoR theater"), and a
mint could exceed real backing — total loss of S0.9 #1.

---

### S3.7 How `PledgeRegistry` and `ReleaseAuthorizer` consume the adapter

`PledgeRegistry` (S5) and `ReleaseAuthorizer` (S7) are the two consumers besides
the guard.

**`PledgeRegistry` → `verifyPledge` + `isLockActive`.** At pledge registration
(lifecycle S0.7 step 2), the registry calls
`adapter.verifyPledge(subjectId, attestation)` and rejects unless `(ok == true)`,
then records the `Pledge` with its `pledgeId`, `custodyAccountRef`,
`pledgedAmount`, `evidenceHash`, and `controlAgreementHash` copied from the
attestation. The registry enforces `mintedAmount ≤ pledgedAmount` (S0.9 #2) and
"one active position per pledge"; the adapter supplies the *authenticity* of the
deposit those accounting rules sit on top of. On every mint the registry (or the
token) re-checks `adapter.isLockActive(custodyAccountRef)` so a deposit whose lock
went inactive cannot back new tokens (this is the "NO_CONTROL" reject in the
implemented V2 code).

**`ReleaseAuthorizer` → `releaseAcknowledged`.** When a position reaches a
terminal state, `ReleaseAuthorizer` (S7) issues a one-use voucher whose
destination is **derived from state** (Repaid→borrower, Liquidated→AMINA desk;
S0.9 #5, D-6) — the adapter is *not* consulted to choose the destination. After
the off-chain settlement service moves the BTC and dual-signs the ack
(`adapter.ackRelease`), the burn-for-release path checks
`adapter.releaseAcknowledged(pledgeId, voucherRef)` so cBTC is burned only once
custody has *actually* released the underlying. This closes S0.9 #10: each
off-chain movement maps to exactly one consumed voucher and an AMINA co-signed ack
recorded here.

The adapter never *initiates* anything: it answers questions
(reserves/lock/pledge-validity/ack-status). All authority to mint, lock, or
release lives in the registries/authorizer/guard that ask. This keeps the adapter
a pure evidence boundary.

#### Why Core / What breaks if omitted

**Test: Solvency + Liability.** `verifyPledge`/`isLockActive` are what make the
pledge accounting (S5) rest on a *real* locked deposit rather than an unverified
claim; `releaseAcknowledged` is what prevents burning cBTC before the BTC has
left custody (a desync where the token is gone but the asset is stuck, or vice
versa). Omitting these consumption points re-introduces exactly the ledger/custody
drift the design exists to prevent.

---

### S3.8 Freshness, clock-skew, and replay — the time model

Custody facts are time-sensitive: a reserve number is only meaningful "as of"
some instant. The adapter enforces a two-sided time gate plus replay protection.

- **Staleness (lower bound on freshness):** `block.timestamp − observedAt ≤
  maxStaleness`. Core pilot value: `maxStaleness = 10 min` (corpus pilot config),
  matched to the attestation re-publish cadence. Past it, `attestedReserves`
  reverts and `isLockActive` returns false → mints freeze (fail-closed).
- **Clock-skew (upper bound):** `observedAt ≤ block.timestamp + maxClockSkew`,
  `maxClockSkew = 5 min`. Rejects a proof claiming a future observation (a
  mis-set signer clock or an attempt to extend effective freshness).
- **Hard expiry:** `expiresAt > block.timestamp`. The signer commits to a death
  time for each proof independent of `maxStaleness`, so even a generous staleness
  window cannot resurrect an explicitly-expired proof.
- **Replay:** per-`subjectId` monotonic `nonce`; `submitProof` requires
  `p.nonce > _latest.nonce`. An attacker cannot re-submit yesterday's
  higher-reserve proof to re-open mint capacity. (Cross-chain replay is moot in
  Core — single chain — but the EIP-712 domain still binds `chainId`, so a proof
  signed for Triora's chain cannot be replayed on another, which matters when a
  PoR/CRE source is added: per the corpus, CRE reports do not bind destination
  chain unless the payload carries the chain selector.)

**Liquidation exception (cross-reference S6/S7):** stale *reserve* data blocks new
mints, but it does **not** block liquidation. A stale heartbeat is an operational
fault, not evidence the collateral vanished; refusing to liquidate on stale
reserves would let bad debt sit. Liquidation eligibility is driven by the price
oracle predicate (S6) + cure window (S7), not by reserve freshness.

#### Why Core / What breaks if omitted

**Test: Solvency.** Without the staleness/expiry gate, the guard would trust a
number from an unknown time — the BTC could have moved and mint would stay open.
Without the nonce, an old favourable proof could be replayed to inflate effective
reserves. These are the cheapest possible guards against "the data was true once."

---

### S3.9 One custodian for Core; how a second is added later

Core launches with **one custodian behind the adapter** (D-8). The reference
target is the **Anchorage Atlas / Account-Control-Agreement + Chainlink-PoR**
model — the closest public analogue (Anchorage Digital Bank qualified custody +
Atlas collateral management + ACA joint→exclusive control, the exact pattern
Kamino uses), with **BitGo** as the strongest BTC-PoR alternative and the
custodian the implemented V2 code already models (`BitGoCustodyAdapter`,
dual BitGo+AMINA signed `CustodyProof`). Either is a concrete instantiation of
`SignedCustodyAdapter` configured with that custodian's attestation signer and the
executed control-agreement hash for the segregated account. For Core, only one is
wired and audited end-to-end.

**Adding a second custodian (Optional, non-breaking):**

1. Deploy a new `SignedCustodyAdapter` (or a custodian-specific adapter
   implementing `ICustodyAdapter`) configured with the new custodian's
   `custodianSigner`, the new `custodyAccountRef`, and the new
   `controlAgreementHash`.
2. Register it in `TokenizationRegistry` (S0.3 #3) against a cToken — either a
   *new* per-`(custodian, asset)` cBTC contract (the corpus's "fungible per
   `(custodian, asset)`" rule) or, if a single fungible cBTC is desired across
   custodians, behind an aggregating `IReserveSource` that `min()`s sources.
3. No change to `ReserveGuard`, `PledgeRegistry`, `ReleaseAuthorizer`, the bridge,
   or the token — they speak only the interface (S3.2). The new custodian's
   control-agreement parity is verified off-chain (legal) before its adapter is
   activated by timelocked role action.

**Adding a Chainlink PoR / CRE source (v1.1, D-5):** deploy `ChainlinkPoRSource`
(an `IReserveSource` reading `AggregatorV3Interface.latestRoundData()` — rejecting
`answer ≤ 0`, stale `updatedAt`, incomplete round `answeredInRound < roundId`,
scaling feed decimals → 8) and set `ReserveGuard` to `min(adapter, chainlinkPoR)`.
Because both are `IReserveSource`, the mint path is untouched — the promised
no-re-audit property. (Per the corpus, CRE-as-orchestrator is announced-but-not-
provably-live; Core therefore runs on dual signed attestations and treats the PoR
feed as the drop-in upgrade, never a launch prerequisite.)

#### Why Core / What breaks if omitted

**Test: Reversibility.** One custodian end-to-end is the *minimal* safe surface;
the adapter pattern is what makes "one now, more later" a config change instead of
a spine migration. If Core hard-wired one custodian's format, the second custodian
(or the PoR feed) would force a re-audit of the mint/release path — the exact
non-reversible cost the interface exists to avoid.

---

### S3.10 Section invariant catalog (feeds S12)

| ID | Invariant | Enforced by | Supports S0.9 |
|----|-----------|-------------|---------------|
| I-S3.1 | Every stored custody fact carries valid custodian **and** AMINA EIP-712 sigs | `submitProof` / `verifyPledge` / `ackRelease` | #1, #10 |
| I-S3.2 | Proof nonce strictly increases per account (no replay) | `submitProof` | #1 |
| I-S3.3 | `attestedReserves` reverts (never returns 0) on stale/missing/expired | `attestedReserves` | #1 |
| I-S3.4 | `decimals == 8` cross-checked vs `cToken.decimals()` on every proof | `submitProof` / `verifyPledge` | #1 |
| I-S3.5 | Attestation signer ≠ release-execution signer (key separation) | config + S8/S9 | #8, #10 |
| I-S3.6 | `isLockActive` true only while control-active AND fresh AND agreement-hash matches | `isLockActive` | #2 |
| I-S3.7 | `controlAgreementHash` change is timelocked; mismatched proofs rejected | config setters / `submitProof` | #9 |
| I-S3.8 | cBTC burn-for-release requires `releaseAcknowledged == true` | `ackRelease` + S7 | #5, #10 |

These are exercised by the negative-test gates in S0-vs-Optional Part 6: stale/
negative/missing attestation blocks new mint; a proof with a wrong
`controlAgreementHash` is rejected; an unauthorized (single-signer or no-signer)
proof is rejected; a replayed nonce is rejected; a burn-for-release without a
matching dual-signed ack reverts.


## S4. Collateral Token (cBTC) & Pledge Registry

This section specifies the two L2 contracts that, together with `ReserveGuard` (S5),
`SignedCustodyAdapter` (S6), and `ReleaseAuthorizer` (S10), form the **collateral-tokenization
spine** — the irreducible novelty of Triora Core. `PermissionedCollateralToken` (cBTC) is the
on-chain 1:1 claim against real BTC in custody; `PledgeRegistry` is the source of truth that
binds every minted satoshi-unit of cBTC to a specific locked custody deposit and to at most one
active deal. Per S0.2 D-5 and D-9 both contracts live in Model B (CollateralBridge over one
isolated Morpho market); cBTC is the *immutable* spine token, and PledgeRegistry is UUPS behind
the GOVERNOR timelock so its accounting logic can be repaired without re-minting tokens.

These two contracts jointly uphold S0.9 invariants **#1** (`totalSupply ≤ min(sources) − margin`,
via the `ReserveGuard` call in the mint path), **#2** (`minted ≤ pledged`, `encumbered ≤ minted`,
one active position per pledge), and **#3** (transfers allowed only on protocol paths, checked on
**both** `from` and `to`).

---

### S4.1 `PermissionedCollateralToken` (cBTC)

#### Purpose

A restricted ERC-20 representing locked BTC 1:1. **8 decimals** (1 unit = 1 satoshi, per S0.10;
never 18). It is the collateral leg of the isolated Morpho market. It is deliberately *not* a
generic security token: it carries **no public transferability, no generic mint/burn, no
forced-transfer**. Every supply change is gated by the pledge↔reserve↔voucher controls so the token
can never represent more BTC than is provably locked, and can never leave the protocol's three
allowed transfer paths. This is the D-5 / S0.2 decision to build a **custom-minimal token base
rather than full CMTAT** (see S4.1.7).

#### Mutability and base

Immutable (S0.2 D-9 — the spine is non-upgradeable; "immutability is the strongest user-facing
promise", S0.9). Solidity `^0.8.28`, OZ v5 `ERC20` + `AccessManaged` (authority = `RoleManager`,
S1), `SafeERC20` for any incidental token interactions (none in Core; cBTC itself is never pulled
via `transferFrom` by users). Custom errors only. Because the contract is immutable it uses plain
storage, **not** ERC-7201 (ERC-7201 is mandated only for upgradeables per S0.10).

#### Storage layout

```solidity
contract PermissionedCollateralToken is ERC20, AccessManaged {
    // --- wiring (set once in constructor, immutable) ---
    IPledgeRegistry public immutable pledgeRegistry;   // S4.2
    IReserveGuard   public immutable reserveGuard;     // S5
    IReleaseAuthorizer public immutable releaseAuthorizer; // S10 (voucher validity)

    // --- transfer policy allowlist (S0.9 #3) ---
    mapping(address account => bool) public isProtocol;   // bridge, MorphoAdapter
    // --- per-account freeze (compliance/KYB revocation) ---
    mapping(address account => bool) public isFrozen;
    // --- global pause (GUARDIAN may pause; only reduces risk) ---
    bool public paused;
}
```

`decimals()` is overridden to return `8`. The constructor pins `name="Triora Custody BTC"`,
`symbol="cBTC"`, the three immutable wiring addresses, and the `RoleManager` authority. The
`isProtocol` allowlist is initialized to contain the `CollateralBridge` (S9) and the
`MorphoAdapter` (S11) and nothing else; it is mutable only by `RoleManager`-gated functions held
by GOVERNOR so the allowed counterparties are fixed by governance, not by an operator.

#### The allowlist transfer policy — the recurring bug to avoid

The single most important correctness property of this contract (S0.9 #3) is that **cBTC moves
only on protocol paths, and the policy is checked on BOTH `from` and `to`, with explicit
`address(0)` carve-outs for mint and burn.** The recurring real-world bug (Vultisig / multiple
Code4rena findings, flagged in the tokenization digest) is a transfer hook that checks only one
side — e.g. only `to` is required to be allowlisted — which silently permits a frozen or
non-protocol holder to *send* tokens out, or permits draining *from* a protocol address to an
arbitrary recipient. We override OZ v5's single `_update` hook (which handles mint, burn, and
transfer uniformly) and branch explicitly:

```solidity
function _update(address from, address to, uint256 value) internal override {
    if (paused) revert TokenPaused();

    bool isMint = (from == address(0));
    bool isBurn = (to == address(0));

    if (!isMint) {
        // sender side: must not be frozen; must be an allowed source
        if (isFrozen[from]) revert AccountFrozen(from);
    }
    if (!isBurn) {
        // recipient side: must not be frozen; must be an allowed destination
        if (isFrozen[to]) revert AccountFrozen(to);
    }

    // Path policy (only enforced for true transfers, NOT mint/burn):
    if (!isMint && !isBurn) {
        // Exactly the three allowed live paths (S4.1.4):
        //   mint -> bridge        (covered by isMint carve-out above)
        //   bridge <-> MorphoAdapter
        //   burn                  (covered by isBurn carve-out above)
        // A plain transfer is allowed iff BOTH endpoints are protocol addresses.
        if (!isProtocol[from] || !isProtocol[to]) revert TransferNotAllowed(from, to);
    }

    super._update(from, to, value);
}
```

Rationale for the carve-outs and the `&&` (both-sides) condition:

- **Mint (`from == address(0)`)**: skips the `from` freeze/path check because there is no sender;
  the `to` side is *not* freeze-checked-out but `to` **must** be the bridge — this is enforced not
  here but in `mintForPledge` (which only ever mints to the bridge), keeping the hook simple and
  the destination authority in the gated mint function. The `to` freeze check still applies so a
  frozen bridge cannot receive (defense in depth).
- **Burn (`to == address(0)`)**: skips the `to` path check; the `from` side is freeze-checked so a
  frozen holder's tokens cannot be silently burned out from under a dispute — burns happen only via
  `burnForRelease` from the bridge, and the bridge is never frozen in normal operation.
- **Transfer**: requires **both** `isProtocol[from]` AND `isProtocol[to]`. Because the only
  protocol addresses are `{bridge, MorphoAdapter}`, the only legal transfer is bridge↔adapter. A
  user, a frozen account, or any external address on *either* side reverts.

> **Invariant test (must pass, S0 Part 6 negative tests):** a transfer to a non-allowlisted
> address reverts, AND a transfer *from* a non-allowlisted address reverts. Both directions are
> separately tested. This is the exact double-sided check the digest flags as the recurring miss.

#### S4.1.4 The exact allowed transfer paths

| Path | `from` | `to` | Gate |
|------|--------|------|------|
| **Mint** | `address(0)` | `CollateralBridge` | `mintForPledge` (ISSUER_MINTER + ReserveGuard + PledgeRegistry) |
| **Supply collateral** | `CollateralBridge` | `MorphoAdapter` | `_update` both-protocol check; initiated by bridge in `borrow` (S9) |
| **Withdraw collateral** | `MorphoAdapter` | `CollateralBridge` | `_update` both-protocol check; initiated by bridge in repay/liquidate (S9) |
| **Burn** | `CollateralBridge` | `address(0)` | `burnForRelease` (ReleaseAuthorizer voucher) |

There is **no** path that moves cBTC to a borrower, a lender, an EOA, or any external DeFi
contract. cBTC never leaves `{bridge, MorphoAdapter}` while it exists. This is what keeps a
"freely transferable, possibly-unbacked token" out of public DeFi (S0.3 row 7 "If omitted").

#### S4.1.5 External functions

```solidity
/// @notice Mint cBTC against a verified, locked pledge. Only ever mints to the bridge.
/// @dev Three gates in order: PledgeRegistry.canMint -> ReserveGuard.checkMint -> mint -> recordMint.
function mintForPledge(address to, bytes32 pledgeId, uint256 amount) external restricted;
    // access: ISSUER_MINTER (S0.6) via RoleManager `restricted`
    // reverts:
    //   ZeroAmount()                         if amount == 0
    //   MintRecipientNotBridge(to)           if to != configured CollateralBridge
    //   PledgeCannotMint(pledgeId, reason)   if pledgeRegistry.canMint == false
    //                                        (status != Pledged/Minted, minted+amount > pledged,
    //                                         pledge frozen, lock not active)
    //   ReserveExceeded(...)                 if reserveGuard.checkMint fails
    //                                        (totalSupply()+amount > min(PoR,attest) - margin, or stale)
    //   (any revert leaves no state change — fail-closed)

/// @notice Burn cBTC on a state-derived release. Only callable on the burn path.
function burnForRelease(address from, bytes32 pledgeId, uint256 amount, bytes32 voucherId)
    external restricted;
    // access: ISSUER_MINTER or BRIDGE role (held by CollateralBridge) via RoleManager
    // reverts:
    //   ZeroAmount()
    //   BurnSourceNotBridge(from)            if from != CollateralBridge
    //   InvalidVoucher(voucherId)            if releaseAuthorizer.isVoucherValidForBurn(
    //                                          voucherId, pledgeId, amount) == false
    //   InsufficientBalance(...)             standard ERC20
    // effects: _burn(from, amount); pledgeRegistry.recordBurn(pledgeId, amount); emits Burned

/// @notice Governance allowlist management (the only mutators of the transfer policy).
function setProtocol(address account, bool allowed) external restricted; // GOVERNOR
function setFrozen(address account, bool frozen) external restricted;     // GUARDIAN (risk-reducing)
function setPaused(bool p) external restricted;                           // GUARDIAN (risk-reducing)
```

Notes:

- `mintForPledge` enforces `to == bridge` so the ISSUER_MINTER key cannot mint to an arbitrary
  address even if the key is compromised; combined with the ReserveGuard and PledgeRegistry gates,
  a compromised minter key still cannot exceed reserves or mint against an unbound/over-minted
  pledge. This is the multi-gate defense that "an issuer-only access check is the control PYUSD/
  uniBTC already had and that did not save them" (S0 / digest) is designed to surpass.
- `burnForRelease` is **voucher-gated** (S0.9 #5). The `voucherId` is checked against
  `ReleaseAuthorizer` (S10): the voucher must be valid, un-consumed, match the `pledgeId`, and
  cover at least `amount`. Burn never happens on a bare bridge call — only as the on-chain tail of
  a state-derived release. The bridge consumes the voucher in the same atomic call (S9).
- There is **no** `mint(to,amount)`, no `burn(amount)`, no `forceTransfer`, no `batchMint`. Their
  absence is deliberate (S4.1.7).

#### S4.1.6 Events and errors

```solidity
event MintedForPledge(bytes32 indexed pledgeId, address indexed to, uint256 amount);
event Burned(bytes32 indexed pledgeId, address indexed from, uint256 amount, bytes32 indexed voucherId);
event ProtocolSet(address indexed account, bool allowed);
event FrozenSet(address indexed account, bool frozen);
event PausedSet(bool paused);

error ZeroAmount();
error MintRecipientNotBridge(address to);
error BurnSourceNotBridge(address from);
error PledgeCannotMint(bytes32 pledgeId, bytes32 reason);
error ReserveExceeded(uint256 supplyAfter, uint256 limit);
error InvalidVoucher(bytes32 voucherId);
error TransferNotAllowed(address from, address to);
error AccountFrozen(address account);
error TokenPaused();
```

`MintedForPledge` and `Burned` are the canonical supply-change audit trail consumed by the
off-chain monitoring service (O9) and the Account/Evidence hub (F4). Every supply change carries
its `pledgeId`, so reserve↔supply reconciliation is per-pledge attributable.

#### S4.1.7 Why a custom-minimal token base, not CMTAT (D-5)

Per S0.2 D-5 and the CMTAT ADR (tokenization digest §"Design decisions"), Core uses a **custom
minimal restricted ERC-20** rather than CMTAT or ERC-3643 for cBTC. The reasons are
solvency-load-bearing, not stylistic:

1. **Generic mint/burn are footguns.** CMTAT's `mint`/`burn`/`batchMint`/`burnAndMint` bypass the
   `PledgeRegistry.canMint` + `ReserveGuard.checkMint` + voucher hooks. A custom token has *no*
   un-gated supply function to bypass.
2. **`forcedTransfer` is a ledger-desync risk.** CMTAT's forced transfer moves a balance without
   touching Triora's pledge/encumbrance accounting, breaking S0.9 #2/#3. Core has no forced
   transfer at all — liquidation moves the *real BTC* off-chain (voucher → AMINA desk), and the
   cBTC is *burned*, never force-moved.
3. **Access-control mismatch.** Triora uses OZ `AccessManager` (`RoleManager`, S1);
   CMTAT uses `AccessControl`. A custom `AccessManaged` token wires cleanly into the single
   permission source (S0.9 #8).
4. **Unaudited local CMTAT.** The local CMTAT v3.1/v3.2 are unaudited (only v3.0.0 was Halborn-
   audited); the spine must be auditable from scratch with minimal surface.
5. **Decimals.** CMTAT defaults to 0 decimals for Swiss-law securities; cBTC needs exactly 8.

CMTAT *concepts* (can-transfer views, richer freeze reasons, ERC-1404/7943 introspection) are
deferred to v1.1 and full CMTAT is reserved for future *transferable* instruments (lender notes,
fund shares) — never for the restricted custody receipt.

#### S4.1.8 Invariants upheld

- **I-T1 (S0.9 #1, in concert with ReserveGuard):** after any `mintForPledge`,
  `totalSupply() ≤ min(freshPoR, freshAttestation) − margin`. cBTC never calls mint without the
  `ReserveGuard.checkMint` gate passing (fail-closed on stale/missing/negative data).
- **I-T2 (S0.9 #3):** cBTC balances move only along the four paths in S4.1.4; every transfer is
  checked on both `from` and `to`; mint/burn use `address(0)` carve-outs.
- **I-T3:** every supply change is recorded in `PledgeRegistry` (`recordMint`/`recordBurn`) in the
  same transaction, so `Σ mintedAmount` across pledges equals `totalSupply()` at all times
  (reconciliation invariant; monitored by O9).
- **I-T4:** no path mints cBTC to, or transfers cBTC to, a non-protocol address; cBTC cannot enter
  public DeFi.

#### S4.1.9 External dependencies

`RoleManager` (S1, authority), `PledgeRegistry` (S4.2, `canMint`/`recordMint`/`recordBurn`),
`ReserveGuard` (S5, `checkMint`), `ReleaseAuthorizer` (S10, voucher validity). Consumed by
`CollateralBridge` (S9) which holds and supplies/withdraws cBTC.

#### Why Core / What breaks if omitted

**Test: Solvency + Liability.** cBTC is the on-chain claim on locked BTC; the restricted transfer
policy is what keeps an unbacked-looking, freely-transferable token out of public DeFi and enforces
KYB/freeze. **If omitted:** there is no tokenized collateral to post into Morpho — there is no loan
product. If the *restriction* were omitted (a plain ERC-20), a possibly-unbacked token leaks into
DeFi where its backing and freeze status are invisible, P2P looks like the issuer of a public
asset (Liability failure), and the both-sides allowlist bug class re-opens the door to draining
frozen balances (Solvency failure). The custom-minimal base specifically prevents the
generic-mint / forced-transfer / batch footguns that would let a single key violate S0.9 #1–#3.

---

### S4.2 `PledgeRegistry`

#### Purpose

The single source of truth binding **pledge ↔ cBTC ↔ custody account ↔ deal**. It is the contract
that makes "tokenize once, borrow once" mechanically true: it gates every mint
(`minted ≤ pledged`), enforces encumbrance (`encumbered ≤ minted`), and guarantees **one active
deal per pledge** (S0.9 #2). It records the dual-signed custody attestation reference for each
pledge (the on-chain audit handle into off-chain evidence) and drives the pledge through its status
machine across the whole lifecycle (S0.7 / S0.8).

#### Mutability and base

UUPS upgradeable behind the GOVERNOR timelock (S0.3 row 6, S0.2 D-9 — registries are "UUPS+TL").
Solidity `^0.8.28`, OZ v5 `UUPSUpgradeable` + `AccessManagedUpgradeable` (authority =
`RoleManager`), **ERC-7201 namespaced storage** (mandatory for upgradeables, S0.10), custom errors.

#### S4.2.1 The `Pledge` struct and status machine

```solidity
enum PledgeStatus {
    None,        // 0 - never registered
    Pledged,     // 1 - custody attestation accepted, no cBTC minted yet
    Minted,      // 2 - cBTC minted to bridge (>=1 sat), not yet bound to a deal
    Bound,       // 3 - locked into exactly one active deal (encumbered > 0)
    Releasing,   // 4 - release/liquidation pending (voucher issued, awaiting custody ack)
    Released,    // 5 - terminal: repaid -> BTC to borrower, cBTC burned
    Liquidated,  // 6 - terminal: liquidated -> BTC to AMINA desk, cBTC burned
    Frozen       // 7 - overlay-terminal for disputes; blocks mint/lock/release
}

struct Pledge {
    bytes32 pledgeId;             // canonical id (keccak of custody evidence + nonce, set by adapter)
    bytes32 entityId;             // KYB'd borrower entity (S2 KYBGateway subject)
    bytes32 custodyAccountRef;    // opaque ref to the segregated custody account
    bytes32 custodianId;          // which custodian (one in Core; behind ICustodyAdapter, S6)
    address asset;                // the cBTC token address this pledge backs
    uint256 pledgedAmount;        // locked BTC, in cBTC units (8 dec); from attestation
    uint256 mintedAmount;         // cBTC minted against this pledge so far
    uint256 encumberedAmount;     // cBTC locked into the active deal
    // freeAmount is derived: mintedAmount - encumberedAmount (see freeAmount())
    PledgeStatus status;
    bytes32 latestProofRef;       // hash/ref of the latest custody attestation (S6)
    bytes32 controlAgreementHash; // hash of the tri-party control agreement (C-2)
    bytes32 dealId;               // the one active deal (0x0 when not Bound)
}
```

Status transitions (each gated by the role in parentheses; aligns with S0.8):

```
None      --registerPledge(ALLOCATOR)-->            Pledged
Pledged   --recordMint(cBTC token)-->               Minted        (when mintedAmount becomes > 0)
Minted    --lockForDeal(CollateralBridge)-->        Bound         (encumberedAmount := deal slice)
Bound     --unlockFromDeal(CollateralBridge)-->     Minted        (cure / partial unwind; encumbered -> 0)
Bound     --markReleasePending(ReleaseAuthorizer)-> Releasing     (repay terminal)
Bound     --markLiquidationPending(LiquidationMod)->Releasing     (liquidation terminal)
Releasing --markReleased(CollateralBridge)-->       Released [T]  (repay: cBTC burned, BTC->borrower)
Releasing --markLiquidated(CollateralBridge)-->     Liquidated [T](liq: cBTC burned, BTC->AMINA desk)
any (non-terminal) --freezePledge(GUARDIAN)-->      Frozen        (dispute; blocks mint/lock/release)
```

> S0.8 names a single `ReleasePending` for both repay and liquidation; this registry uses one
> `Releasing` status and distinguishes the terminal outcome (`Released` vs `Liquidated`) by which
> finalizer is called, matching S0.7 6a/6b. `markReleasePending` and `markLiquidationPending` both
> move `Bound → Releasing` but stamp the reason so the off-chain settlement service (O6) and the
> `ReleaseAuthorizer` (S10) derive the correct destination from state (S0.9 #5).

#### S4.2.2 ERC-7201 storage

```solidity
/// @custom:storage-location erc7201:triora.storage.PledgeRegistry
struct PledgeRegistryStorage {
    mapping(bytes32 pledgeId => Pledge) pledges;
    mapping(address token => uint256) totalPledged;     // Σ pledgedAmount per cBTC token
    mapping(bytes32 entityId => uint256) activePledges;  // count of non-terminal pledges per entity (lens)
    address collateralToken;     // the cBTC token allowed to call record* (one in Core)
    address collateralBridge;    // S9
    address releaseAuthorizer;   // S10
    address liquidationModule;   // S13
    address custodyAdapter;      // S6 (for re-verification of attestation freshness on registerPledge)
}

// keccak256(abi.encode(uint256(keccak256("triora.storage.PledgeRegistry")) - 1)) & ~bytes32(uint256(0xff))
bytes32 private constant STORAGE_SLOT = 0x...; // computed per ERC-7201
```

`freeAmount(pledgeId)` is a pure-derived view: `mintedAmount − encumberedAmount`. It is never
stored, eliminating a desync class (the field that must equal `minted − encumbered` cannot drift
from it).

#### S4.2.3 External functions

```solidity
/// @notice Register a verified pledge from a dual-signed custody attestation.
/// @dev Re-verifies attestation freshness against the custody adapter (S6) at registration.
function registerPledge(Pledge calldata p) external restricted;
    // access: ALLOCATOR (S0.6) — the matching/record authority
    // preconditions:
    //   pledges[p.pledgeId].status == None        else PledgeExists
    //   p.pledgedAmount > 0                        else ZeroAmount
    //   p.asset == storage.collateralToken        else UnknownToken
    //   custodyAdapter.verifyPledge(p) == ok       else CustodyUnverified(reason)
    //   custodyAdapter.isLockActive(p.pledgeId)    else LockNotActive
    //   KYBGateway.isApproved(p.entityId)          else EntityNotApproved (S2)
    // effects: stores p with mintedAmount=0, encumberedAmount=0, dealId=0,
    //          status=Pledged; totalPledged[asset] += pledgedAmount; emits PledgeRegistered

/// @notice Mint authorization check — called by cBTC.mintForPledge BEFORE minting.
function canMint(bytes32 pledgeId, uint256 amount) external view returns (bool ok, bytes32 reason);
    // ok iff: status is Pledged or Minted; not Frozen;
    //         mintedAmount + amount <= pledgedAmount;     (I-P1)
    //         custodyAdapter.isLockActive(pledgeId);      (lock still live)
    //         amount > 0
    // reason codes: "STATUS","FROZEN","EXCEEDS_PLEDGED","LOCK_INACTIVE","ZERO"

/// @notice Record a completed mint — called by cBTC ONLY, after a successful mint.
function recordMint(bytes32 pledgeId, uint256 amount) external;
    // access: msg.sender == storage.collateralToken else NotCollateralToken
    // re-checks canMint internally (defense in depth) else MintNotAllowed(reason)
    // effects: mintedAmount += amount; if status==Pledged -> Minted; emits MintRecorded

/// @notice Record a completed burn — called by cBTC ONLY, after a successful burnForRelease.
function recordBurn(bytes32 pledgeId, uint256 amount) external;
    // access: msg.sender == storage.collateralToken else NotCollateralToken
    // effects: require amount <= mintedAmount else BurnExceedsMinted;
    //          mintedAmount -= amount; emits BurnRecorded
    //          (status is advanced separately by markReleased/markLiquidated)

/// @notice Lock the pledge into exactly one active deal.
function lockForDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external;
    // access: msg.sender == storage.collateralBridge else NotBridge
    // preconditions:
    //   status == Minted                           else NotMintable/WrongStatus
    //   pledge.dealId == 0                          else AlreadyBound       (I-P3: one deal per pledge)
    //   amount > 0 && amount <= freeAmount          else InsufficientFree   (I-P2: encumbered<=minted)
    //   not Frozen
    // effects: encumberedAmount += amount; dealId = dealId; status -> Bound; emits LockedForDeal

/// @notice Unwind the deal lock (cure, top-up reorganization, or pre-terminal cancel).
function unlockFromDeal(bytes32 pledgeId, bytes32 dealId) external;
    // access: msg.sender == storage.collateralBridge else NotBridge
    // preconditions: status == Bound; pledge.dealId == dealId else WrongDeal
    // effects: encumberedAmount = 0; dealId = 0; status -> Minted; emits UnlockedFromDeal

/// @notice Mark a repayment release pending (voucher issued, awaiting custody ack).
function markReleasePending(bytes32 pledgeId) external;
    // access: msg.sender == storage.releaseAuthorizer else NotReleaseAuthorizer
    // precondition: status == Bound else WrongStatus
    // effects: status -> Releasing; stamps reason=REPAY; emits ReleasePending(pledgeId, REPAY)

/// @notice Mark a liquidation release pending.
function markLiquidationPending(bytes32 pledgeId) external;
    // access: msg.sender == storage.liquidationModule else NotLiquidationModule
    // precondition: status == Bound else WrongStatus
    // effects: status -> Releasing; stamps reason=LIQUIDATE; emits ReleasePending(pledgeId, LIQUIDATE)

/// @notice Finalize a repayment release (BTC delivered to borrower, cBTC burned).
function markReleased(bytes32 pledgeId) external;
    // access: msg.sender == storage.collateralBridge else NotBridge
    // preconditions: status == Releasing (reason REPAY); mintedAmount == 0 else BurnIncomplete
    // effects: encumberedAmount = 0; dealId = 0; status -> Released [terminal];
    //          totalPledged[asset] -= pledgedAmount; activePledges[entityId]--; emits Released

/// @notice Finalize a liquidation (BTC to AMINA desk, cBTC burned).
function markLiquidated(bytes32 pledgeId) external;
    // access: msg.sender == storage.collateralBridge else NotBridge
    // preconditions: status == Releasing (reason LIQUIDATE); mintedAmount == 0 else BurnIncomplete
    // effects: encumberedAmount = 0; dealId = 0; status -> Liquidated [terminal];
    //          totalPledged[asset] -= pledgedAmount; activePledges[entityId]--; emits Liquidated

/// @notice Freeze a disputed pledge (risk-reducing; GUARDIAN hot key).
function freezePledge(bytes32 pledgeId, bytes32 reasonHash) external restricted;
    // access: GUARDIAN; only from a non-terminal status; blocks canMint/lockForDeal/release
    // effects: status -> Frozen; emits PledgeFrozen(pledgeId, reasonHash)

// --- views (for PledgeRegistry consumers and lenses, S17) ---
function getPledge(bytes32 pledgeId) external view returns (Pledge memory);
function freeAmount(bytes32 pledgeId) external view returns (uint256); // minted - encumbered
function totalPledged(address token) external view returns (uint256);
function isActive(bytes32 pledgeId) external view returns (bool);      // status in {Minted,Bound,Releasing}
```

Access-control summary (S0.9 #8 privilege separation — no role both moves collateral *and* sets
risk params; here the registry only *records*, the bridge *moves*):

| Function | Caller | Why |
|----------|--------|-----|
| `registerPledge` | ALLOCATOR | matching/record authority of record |
| `canMint` | (view) | called by cBTC inline |
| `recordMint`, `recordBurn` | cBTC token only | supply changes are authored by the token, mirrored here atomically |
| `lockForDeal`, `unlockFromDeal`, `markReleased`, `markLiquidated` | CollateralBridge only | the bridge is the single collateral-mover |
| `markReleasePending` | ReleaseAuthorizer only | release pending is a voucher-issuance side effect |
| `markLiquidationPending` | LiquidationModule only | liquidation pending follows the objective trigger |
| `freezePledge` | GUARDIAN | hot key, risk-reducing only |

#### S4.2.4 Events and errors

```solidity
event PledgeRegistered(bytes32 indexed pledgeId, bytes32 indexed entityId, address indexed asset,
                       uint256 pledgedAmount, bytes32 controlAgreementHash, bytes32 latestProofRef);
event MintRecorded(bytes32 indexed pledgeId, uint256 amount, uint256 mintedAmountAfter);
event BurnRecorded(bytes32 indexed pledgeId, uint256 amount, uint256 mintedAmountAfter);
event LockedForDeal(bytes32 indexed pledgeId, bytes32 indexed dealId, uint256 amount);
event UnlockedFromDeal(bytes32 indexed pledgeId, bytes32 indexed dealId);
event ReleasePending(bytes32 indexed pledgeId, bytes32 reason); // REPAY | LIQUIDATE
event Released(bytes32 indexed pledgeId);
event Liquidated(bytes32 indexed pledgeId);
event PledgeFrozen(bytes32 indexed pledgeId, bytes32 reasonHash);

error PledgeExists(bytes32 pledgeId);
error ZeroAmount();
error UnknownToken(address asset);
error CustodyUnverified(bytes32 reason);
error LockNotActive(bytes32 pledgeId);
error EntityNotApproved(bytes32 entityId);
error NotCollateralToken(address caller);
error NotBridge(address caller);
error NotReleaseAuthorizer(address caller);
error NotLiquidationModule(address caller);
error MintNotAllowed(bytes32 reason);
error BurnExceedsMinted(uint256 amount, uint256 minted);
error AlreadyBound(bytes32 pledgeId, bytes32 existingDeal);
error InsufficientFree(uint256 requested, uint256 free);
error WrongStatus(bytes32 pledgeId, PledgeStatus have);
error WrongDeal(bytes32 pledgeId, bytes32 dealId);
error BurnIncomplete(bytes32 pledgeId, uint256 mintedRemaining);
error PledgeFrozenError(bytes32 pledgeId);
```

#### S4.2.5 Invariants upheld (S0.9 #2)

- **I-P1 (`minted ≤ pledged`):** `canMint` and `recordMint` both require
  `mintedAmount + amount ≤ pledgedAmount`. `pledgedAmount` is set once at `registerPledge` from the
  dual-signed attestation and is never increased in Core (a top-up creates a *new* pledge). Mint
  can therefore never exceed the locked deposit.
- **I-P2 (`encumbered ≤ minted`):** `lockForDeal` requires `amount ≤ freeAmount = minted −
  encumbered`; `encumberedAmount` only increases via `lockForDeal` and is zeroed on
  `unlockFromDeal` / terminal. It can never exceed `mintedAmount`.
- **I-P3 (one active deal per pledge):** `lockForDeal` requires `pledge.dealId == 0`; a second
  `lockForDeal` reverts `AlreadyBound`. `dealId` is cleared only on `unlockFromDeal` or terminal.
  A pledge can never be encumbered by two deals simultaneously.
- **I-P4 (supply mirror):** `recordMint`/`recordBurn` are callable only by the cBTC token and run
  in the same transaction as the mint/burn, so `Σ pledges.mintedAmount == cBTC.totalSupply()` is an
  always-true reconciliation invariant (monitored by O9; any drift pages immediately).
- **I-P5 (terminal completeness):** `markReleased`/`markLiquidated` require `mintedAmount == 0`
  (`BurnIncomplete` otherwise), so a pledge cannot reach a terminal state with live cBTC
  outstanding — the on-chain claim is always fully burned before the BTC is recorded as released.
- **I-P6 (no mint on inactive lock):** `canMint` re-checks `custodyAdapter.isLockActive`, so a mint
  cannot proceed if the control agreement / custody lock has lapsed (defense against minting
  against an unlocked deposit).

#### S4.2.6 External dependencies

`RoleManager` (S1, authority), `KYBGateway` (S2, `isApproved` on `registerPledge`),
`SignedCustodyAdapter`/`ICustodyAdapter` (S6, `verifyPledge`/`isLockActive`), `cBTC`
(S4.1, the only caller of `recordMint`/`recordBurn`), `CollateralBridge` (S9, lock/unlock/
finalize), `ReleaseAuthorizer` (S10, `markReleasePending`), `LiquidationModule` (S13,
`markLiquidationPending`). Read by `PortfolioLens`/`BridgeLens` (S17) and the Account/Evidence hub
(F4).

#### Why Core / What breaks if omitted

**Test: Solvency.** PledgeRegistry ties each minted cBTC unit to a specific locked custody deposit
and to at most one active deal — it is the mechanical enforcement of "tokenize once, borrow once."
**If omitted:** (a) the issuer could **double-mint** against one deposit (`minted ≤ pledged` is
unchecked) — the infinite-mint failure class (PYUSD, uniBTC) re-opens even with ReserveGuard,
because ReserveGuard bounds *aggregate* supply against reserves but only PledgeRegistry binds each
mint to a *specific* deposit; (b) **one pledge could be bound to two deals** (I-P3 lost), so two
borrowers' loans could claim the same BTC and a single liquidation could not be attributed; (c)
encumbrance could exceed minted (I-P2 lost), letting a deal lock collateral that was never minted.
All three are direct Solvency failures — the on-chain claim would no longer correspond 1:1 to a
uniquely-locked real asset. This is why PledgeRegistry is L2 spine, not an optional add-on (it sits
in the Optional column in the leaner 2-contract design that S0's companion document explicitly
rejects for production, Part 7.1).

---

### S4.3 Interaction summary (mint and burn call ordering)

For implementers, the exact on-chain ordering across S4.1/S4.2/S5/S10 (per S0.7 steps 3, 6a):

**Mint (lifecycle step 3):**
```
ISSUER_MINTER -> cBTC.mintForPledge(bridge, pledgeId, amount)
  1. require to == bridge
  2. (ok,reason) = PledgeRegistry.canMint(pledgeId, amount)         // I-P1, lock active, status
     require ok
  3. ReserveGuard.checkMint(cBTC, totalSupply()+amount)             // S0.9 #1, fail-closed
  4. _mint(bridge, amount)                                          // _update: from==0 carve-out
  5. PledgeRegistry.recordMint(pledgeId, amount)                    // status Pledged->Minted, I-P4
  6. emit MintedForPledge
```

**Burn on repayment (lifecycle step 6a tail), driven by CollateralBridge:**
```
CollateralBridge.repayWithdrawAndBurn(pledgeId, amount):
  ... Morpho repay + withdrawCollateral (cBTC adapter->bridge) ...
  ReleaseAuthorizer.issueRepaymentRelease(pledgeId)  // dest=borrower (S0.9 #5)
    -> PledgeRegistry.markReleasePending(pledgeId)    // Bound->Releasing
  ... off-chain custody ack arrives, then bridge finalizes ...
  cBTC.burnForRelease(bridge, pledgeId, amount, voucherId)
    1. require from == bridge
    2. ReleaseAuthorizer.isVoucherValidForBurn(voucherId, pledgeId, amount)  // one-use
    3. _burn(bridge, amount)                                                  // to==0 carve-out
    4. PledgeRegistry.recordBurn(pledgeId, amount)                            // mintedAmount->0
  PledgeRegistry.markReleased(pledgeId)               // require mintedAmount==0 (I-P5), terminal
```

Liquidation (step 6b) is identical except `issueLiquidationRelease` (dest=AMINA desk),
`markLiquidationPending` (by LiquidationModule, S13), and `markLiquidated` as the terminal.

This ordering guarantees the four spine invariants hold *atomically*: no window exists where cBTC
is minted without a pledge record (steps 4–5 same tx), where supply exceeds reserves (step 3 gates
step 4), where a pledge is bound twice (I-P3 in `lockForDeal`), or where a pledge goes terminal
with live cBTC (I-P5 in `markReleased`/`markLiquidated`).


## S5. Oracle, Valuation & Health Factor

This section specifies how Triora Core turns a raw Chainlink BTC/USD price into (a) a
**defensible USD valuation of the cBTC collateral** that can never exceed the asset's real
backing, and (b) the **internal Health Factor (HF)** that drives AMINA's warning and
liquidation lifecycle. It also specifies the relationship between Triora's internal HF and
the Morpho market's own price scale / LLTV, and the fail behavior under stale data.

Two contracts and one library carry this section:

- `OracleAdapter` (component #8, L2, UUPS+TL) — the price source, peg cap, and valuation math.
- `LiquidationModule` (component #13, L4) — consumes the predicate; the stale-feed
  attestation override lives here and is specified fully in S6. S5 specifies the *math and
  the inputs* `LiquidationModule` reads.
- `Math` / `Errors` libraries — fixed-point and decimal normalization (S0.3 "Libraries").

The single governing rule of this section, restated from S0.9 #1 and `Triora-Core-vs-Optional-3.md`
C-13: **cBTC is valued at `min(market_price * amount, attested_reserve_value)`.** A price
feed answers "what is a BTC worth"; it does **not** answer "how much BTC backs this cBTC."
S5 fuses the price feed (a *quality/price* oracle) with the reserve attestation (a *quantity*
fact from S2/`ReserveGuard` / `SignedCustodyAdapter`) so that an upward market move can never
let the protocol lend against value that does not exist behind the token.

---

### S5.1 `OracleAdapter` — purpose and scope

**Purpose.** Provide every other contract a single, authenticated, decimal-normalized,
freshness-checked USD valuation of a given cBTC amount, with the peg cap applied. It reads
**Chainlink BTC/USD** via `AggregatorV3Interface.latestRoundData()` and combines that price
with the **attested reserve value** for the same pledge/token (read from the
`IReserveSource` exposed by `SignedCustodyAdapter`, per S0.3 / S2).

`OracleAdapter` is the only place Chainlink is read for valuation. The Morpho market has its
*own* oracle (an immutable `IOracle` at `1e36` scale — S5.5); `OracleAdapter` is Triora's
*internal* valuation used to drive AMINA's **tighter** thresholds. The two are deliberately
distinct (S0.9 #6).

**This is a price/quality oracle, not a reserve/quantity feed.** It reports BTC↔USD. The
*quantity* of BTC backing the token comes exclusively from the reserve attestation path
(`min(freshPoR, freshAttestation)`, S0.9 #1) — never inferred from price. The peg cap (S5.3)
is exactly the join point where the price oracle is subordinated to the quantity fact.

#### Why Core / What breaks if omitted

**Test passed: Solvency** (and a Liability corollary). Without `OracleAdapter`:

- There is **no objective liquidation trigger** — D-7 collapses; AMINA would liquidate on
  discretion (interested-party abuse) or not at all.
- A **stale or depegged feed mis-values collateral**: an inflated price lets the protocol
  carry an undercollateralized loan as "healthy," producing bad debt that surfaces only at
  the Morpho permissionless backstop, by which point AMINA has lost the orderly redemption.
- Without the **peg cap**, cBTC could be valued *above its real backing* on a market spike,
  re-creating the `uniBTC` mint-price failure class (digest: ETH valued 1:1 as BTC → $2M
  loss). The cap is the mechanical defense against valuing the claim above the asset.

`OracleAdapter` is one contract plus a reserve read — cheap — and it is the single defense
against carrying loans that the real collateral cannot cover.

---

### S5.2 `OracleAdapter` — storage, signatures, errors, events

ERC-7201 namespaced storage (UUPS, S0.10). One feed config per cBTC token (Core has one:
cBTC), plus the reserve source binding (which in practice resolves through
`TokenizationRegistry`, S2; stored here as a cached pointer set by `CURATOR`).

```solidity
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "chainlink/interfaces/AggregatorV3Interface.sol";
import {IReserveSource} from "../interfaces/IReserveSource.sol";

/// @custom:storage-location erc7201:triora.storage.OracleAdapter
struct OracleAdapterStorage {
    // Per-cBTC-token price feed configuration.
    mapping(address => FeedConfig) feeds;          // cBTC token => Chainlink config
    mapping(address => address)   reserveSource;   // cBTC token => IReserveSource (S2)
    uint256 paramVersion;                          // pinned by RiskConfig (S7)
}

struct FeedConfig {
    AggregatorV3Interface aggregator; // Chainlink BTC/USD
    uint32  heartbeatSeconds;         // max age before "stale" (e.g. 3600 for a 1h feed)
    uint8   feedDecimals;             // cached aggregator.decimals() (BTC/USD = 8)
    bool    active;                   // CURATOR can disable a misbehaving feed (fail-closed)
}
```

**Constants (in `Math`/`Errors` or here):**

- `USD_VALUE_DECIMALS = 18` — Triora's internal USD valuation scale (chosen for headroom;
  every USD value returned by `OracleAdapter` is `1e18`-scaled).
- `CBTC_DECIMALS = 8`, `USDC_DECIMALS = 6` (S0.10). Cross-asset math normalizes explicitly.
- `BPS = 1e4`.

**External functions.**

```solidity
// ---- Views (no access role; read by anyone, used by Bridge / LiquidationModule / Lens) ----

/// Raw, validated BTC/USD price normalized to 1e18, plus the round's updatedAt.
/// Reverts on any validation failure (S5.4). Callers that must tolerate staleness
/// (liquidation attestation path) use peekPrice() instead.
function getBtcUsdPrice(address cbtc) external view returns (uint256 price1e18, uint256 updatedAt);

/// Non-reverting variant: returns ok=false instead of reverting on staleness/zero.
/// Used by LiquidationModule to DECIDE whether to demand a signed attestation (S5.6).
function peekPrice(address cbtc)
    external view returns (bool ok, uint256 price1e18, uint256 updatedAt, uint8 reason);

/// THE peg-capped collateral valuation. amount is in cBTC native units (8 dec).
/// value1e18 = min( marketValue1e18 , attestedReserveValue1e18 ).
/// Reverts if the price is stale/invalid (new borrows must block — S5.6).
function collateralValueUsd(address cbtc, uint256 amount, uint256 pledgeId)
    external view returns (uint256 value1e18, bool pegCapApplied);

/// Internal Triora HF for a position, 1e18-scaled (1e18 == HF of 1.0). See S5.4.
function healthFactor(
    address cbtc,
    uint256 collateralAmount,
    uint256 pledgeId,
    uint256 debtUsd1e18,
    uint16  ltvBps
) external view returns (uint256 hf1e18);

// ---- Admin (ORACLE_ADMIN / CURATOR per S0.6; all version-bumping ops timelocked) ----

function setFeed(address cbtc, FeedConfig calldata cfg) external;        // ORACLE_ADMIN, TL
function setReserveSource(address cbtc, address src) external;           // CURATOR, TL
function setFeedActive(address cbtc, bool active) external;              // GUARDIAN may set false (risk-reducing, S0.6)
```

**Events.**

```solidity
event FeedSet(address indexed cbtc, address aggregator, uint32 heartbeat, uint8 decimals);
event ReserveSourceSet(address indexed cbtc, address src);
event FeedActiveSet(address indexed cbtc, bool active);
event PegCapApplied(address indexed cbtc, uint256 pledgeId, uint256 marketValue1e18, uint256 reserveValue1e18);
```

`PegCapApplied` is emitted by the *non-view* callers (the Bridge / LiquidationModule wrap the
view and emit), because `collateralValueUsd` is a `view`. Monitoring (S0.4 O9) pages when
`PegCapApplied` fires repeatedly — it means market price has run above attested backing, a
depeg or attestation-lag signal.

**Errors (custom, `Errors` library).**

```solidity
error StalePrice(uint256 updatedAt, uint256 nowTs, uint32 heartbeat);
error NonPositivePrice(int256 answer);
error IncompleteRound(uint80 answeredInRound, uint80 roundId);
error FeedInactive(address cbtc);
error FeedNotConfigured(address cbtc);
error ReserveSourceNotSet(address cbtc);
error StaleReserve(uint256 asOf, uint256 nowTs);
```

---

### S5.3 The PEG CAP rule (the heart of valuation)

> `collateralValueUsd = min( market_price * amount , attested_reserve_value )`

**Why `min`, and what each operand means.**

- `market_price * amount` is what the collateral is worth *if the token is fully backed* —
  the open-market USD value of `amount` BTC. This is the number a naive lender would use.
- `attested_reserve_value` is the USD value the **custody attestation / PoR** actually
  vouches for: the satoshis provably locked and exclusively controlled behind this pledge,
  valued at the same BTC/USD price. It is derived from the quantity fact in S2, not the
  price feed.
- Taking the **minimum** means a market spike can never let Triora value cBTC above what is
  genuinely behind it. If attestation says 25.0 BTC is locked but the token momentarily
  represents more (lag, partial release in flight, an attestation that has not yet caught
  up), the cap pins value to the *real* backing. This is the on-chain expression of "1 token
  = 1 real asset" at the *valuation* layer, complementing `ReserveGuard`'s enforcement at the
  *mint* layer (S0.9 #1).

**How `attested_reserve_value` is computed.** The reserve source (`IReserveSource`, S2)
exposes the attested BTC *quantity* for the pledge (`attestedReserves(pledgeId) → (sats, asOf)`).
`OracleAdapter` values that quantity at the **same** validated price used for the market leg,
so the two operands of the `min` are in the same units and the cap is a pure
quantity-vs-claim comparison:

```
attestedReserveValue1e18 = btcUsd1e18 * attestedSats / 1e8
marketValue1e18          = btcUsd1e18 * amount        / 1e8     // amount also in sats (8 dec)
collateralValueUsd       = min(marketValue1e18, attestedReserveValue1e18)
```

Because both legs share `btcUsd1e18`, the cap reduces to `min(amount, attestedSats)` scaled by
price — i.e. **value follows the smaller of "tokens posted" and "BTC actually attested,"** then
priced. A price error scales both legs identically and cannot defeat the cap; only a
*quantity* discrepancy triggers it. This is exactly the "value ≤ attested reserve" property of
S0.9 #1 carried into valuation.

**How this differs from a reserve (quantity) feed.** A *reserve feed* answers "how many BTC
exist in custody" (a count). A *price feed* answers "what is one BTC worth in USD." Chainlink
BTC/USD is the latter. Triora deliberately does **not** trust the price feed for quantity and
does **not** trust the attestation for price:

| Question | Source | Used for |
|----------|--------|----------|
| What is 1 BTC worth (USD)? | Chainlink BTC/USD price feed (`OracleAdapter`) | both legs of the `min` |
| How many BTC back this pledge? | Reserve attestation / PoR (`SignedCustodyAdapter`, S2) | the cap operand + `ReserveGuard` mint (S0.9 #1) |

Conflating them is the documented failure mode (digest: "PoR theater," `uniBTC` mint-price
bug). The peg cap keeps the two facts orthogonal and takes the conservative join.

`StaleReserve` is raised if the attestation's `asOf` is older than the reserve staleness
window (configured in S7 `RiskConfig`, read via the reserve source). A stale attestation
**blocks new borrows** (same fail-closed posture as a stale price, S5.6) because the cap
operand would be unverifiable.

---

### S5.4 Price read & validation (Chainlink `latestRoundData`)

`getBtcUsdPrice` performs the canonical Chainlink hardening before any value is returned.
Validation order (all must pass or it reverts; `peekPrice` returns the failure `reason`
instead):

```solidity
function _readValidated(FeedConfig storage f)
    internal view returns (uint256 price1e18, uint256 updatedAt)
{
    if (!f.active) revert FeedInactive(/*cbtc*/);
    if (address(f.aggregator) == address(0)) revert FeedNotConfigured(/*cbtc*/);

    (uint80 roundId, int256 answer, /*startedAt*/, uint256 ts, uint80 answeredInRound)
        = f.aggregator.latestRoundData();

    // 1. answer must be strictly positive (rejects 0 and negative sentinels).
    if (answer <= 0) revert NonPositivePrice(answer);
    // 2. round must be complete and not carried over from a prior round.
    if (answeredInRound < roundId) revert IncompleteRound(answeredInRound, roundId);
    if (ts == 0) revert IncompleteRound(answeredInRound, roundId); // unfinished round
    // 3. staleness: must be within the configured heartbeat.
    if (block.timestamp - ts > f.heartbeatSeconds)
        revert StalePrice(ts, block.timestamp, f.heartbeatSeconds);

    // Normalize feed decimals (BTC/USD = 8) to 1e18.
    price1e18 = _scaleTo18(uint256(answer), f.feedDecimals);
    updatedAt = ts;
}
```

The three guards are exactly the checks named in the section brief and in
`Triora-Core-vs-Optional-3.md` C-13 / digests: **staleness (heartbeat)**, **`answer > 0`**,
**`answeredInRound >= roundId`** (here written `answeredInRound < roundId → revert`, the
equivalent). `_scaleTo18` multiplies/divides by the decimal gap (`feedDecimals` is cached at
`setFeed` to avoid an external `decimals()` call per read).

**Decimal normalization, worked.** BTC/USD feed reports 8 decimals. A price of
`$98,400.00000000` arrives as `answer = 9_840_000_000_000` (i.e. `98_400 * 1e8`).
`_scaleTo18` multiplies by `1e10` → `98_400 * 1e18`. Collateral `amount` is in sats (`1e8`):
25 BTC = `2_500_000_000`. So `marketValue1e18 = 98_400e18 * 2_500_000_000 / 1e8 =
2_460_000e18` = **$2,460,000** — matching the digest's worked example.

---

### S5.5 Internal Health Factor and the Morpho price-scale relationship

**Triora's internal HF (the number AMINA acts on and the UI shows):**

```
HF = collateralValueUsd * ltvBps / debtUsd / 1e4
   = (collateralValueUsd1e18 * ltvBps) / (debtUsd1e18 * BPS)      // 1e18-scaled result
```

where:
- `collateralValueUsd1e18` is the **peg-capped** value from S5.3 (already `min`'d).
- `ltvBps` is the AMINA-curated liquidation/threshold LTV for the position's pinned param
  version (S7). For the *liquidation* HF, `ltvBps = liquidationThresholdBps`; for the
  *warning* HF, `ltvBps = warningThresholdBps`. Both are **strictly below** Morpho's LLTV
  (S0.9 #6, S5.5 below).
- `debtUsd1e18` is the borrower's outstanding from the bridge sub-ledger (S6 `CollateralBridge`):
  principal + accrued fixed-rate interest, in USDC (6 dec) scaled to 1e18.

`HF >= 1e18` means healthy at that threshold; `HF < 1e18` means the threshold is breached.
`healthFactor()` returns `type(uint256).max` when `debtUsd1e18 == 0` (no debt → infinitely
healthy) to avoid division by zero.

**Why this is "LIQ/currentLTV" (the UI math, S0.5 F3 / copy constraint).** Equivalent form:
`HF = liquidationThreshold / currentLTV`, where `currentLTV = debtUsd / collateralValueUsd`.
Both are the same expression; the frontend (S9/S0.5 F3) MUST present it as
**`LIQ / currentLTV`** and must NOT present a raw Morpho number. The threshold ladder
(warning → liquidation) shown to the borrower is built from `warningThresholdBps` and
`liquidationThresholdBps`, never from the Morpho LLTV.

#### Relationship to Morpho's market price scale (`1e36`) and LLTV

Morpho Blue computes its *own* health on the bridge's single aggregate position using its
*own* immutable oracle and LLTV (digest: Morpho liquidation math). Morpho's convention:

```
COLLATERAL_VALUE_morpho = collateralAmount * morphoOraclePrice / ORACLE_PRICE_SCALE   // SCALE = 1e36
HF_morpho               = COLLATERAL_VALUE_morpho * LLTV / borrowedAssets             // liquidatable when < 1
```

The Morpho oracle price is scaled so that `ORACLE_PRICE_SCALE = 1e36` (specifically
`1e36 * 10^(loanDecimals - collateralDecimals)` adjusted for feed decimals; for cBTC(8)/USDC(6)
the deployed `IOracle` returns BTC/USD already normalized to that scale). Triora does **not**
re-implement Morpho's HF; the `FixedRateIRM` market reuses Morpho's accounting, liquidation
incentive (β=0.3, M=1.15), and oracle wholesale (S6). Triora's `OracleAdapter` exists to drive
the **tighter AMINA predicate that fires first**.

**The strict-tighter invariant (S0.9 #6), made concrete.** Triora must guarantee:

```
warningThresholdBps  <  liquidationThresholdBps  <  morphoLLTVBps
```

so that AMINA's warning, then AMINA's objective liquidation (after the cure window, S6), both
trigger **before** the bridge position ever becomes liquidatable on Morpho permissionlessly.
Morpho's permissionless liquidation remains only as the last-resort backstop (D-7, S0.7 final
note).

**Worked numbers (digest values, cBTC/USDC, BTC start $98,400):**

| Item | Value | Source |
|------|-------|--------|
| Posted collateral | 25 cBTC (`2_500_000_000` sats) | borrower |
| Collateral value @ $98,400 | $2,460,000 | S5.4 |
| Drawn debt | $2,000,000 (81.3% current LTV) | S6 sub-ledger |
| AMINA **warning** threshold | 90% (`warningThresholdBps = 9000`) | S7 RiskConfig |
| AMINA **liquidation** threshold | 95% (`liquidationThresholdBps = 9500`) | S7 RiskConfig |
| Morpho **LLTV** | 96.5% (`morphoLLTVBps = 9650`) | immutable market (S6) |

Check the invariant: `9000 < 9500 < 9650` ✓.

Now find the BTC price at each trigger (debt fixed at $2,000,000; ignore interest accrual for
the snapshot):

- **Current LTV = debt / collateralValue**. A threshold is hit when `currentLTV == thresholdBps/1e4`,
  i.e. when `collateralValue == debt * 1e4 / thresholdBps`.
- Warning (90%): `collateralValue = 2,000,000 / 0.90 = $2,222,222` → BTC = `2,222,222 / 25 =
  **$88,889**`. (Matches digest "warning at BTC ≈ $88,900.")
- AMINA liquidation (95%): `collateralValue = 2,000,000 / 0.95 = $2,105,263` → BTC =
  `2,105,263 / 25 = **$84,210**`. (Matches digest "full liquidation at BTC ≈ $84,200.")
- Morpho LLTV backstop (96.5%): `collateralValue = 2,000,000 / 0.965 = $2,072,539` → BTC =
  `2,072,539 / 25 = **$82,902**`.

So as BTC falls: **$88,889 (AMINA warns) → cure window → $84,210 (AMINA liquidates) →
$82,902 (Morpho would liquidate if AMINA never acted).** AMINA always has a **$1,308/BTC
(≈1.6%) headroom** between its own liquidation trigger and the Morpho backstop — the
mechanical expression of S0.9 #6. Internal HF at $84,210 against the 95% threshold:
`HF = 2,105,263 * 9500 / 2,000,000 / 1e4 = 1.000` → exactly `1e18`, confirming the predicate.

The headroom is a curated parameter (S7): widening the gap between `liquidationThresholdBps`
and `morphoLLTVBps` buys AMINA more time for orderly custody redemption at the cost of
liquidating borrowers slightly earlier; `RiskConfig` MUST reject any param set that does not
satisfy `liquidationThresholdBps < morphoLLTVBps` (cross-variable coherence, enforced in S7).

---

### S5.6 Fail behavior (stale price, liquidation attestation override)

The two paths treat staleness **asymmetrically**, by design:

**(A) New borrows / re-borrows / value-increasing actions — FAIL CLOSED.**
`CollateralBridge.borrow` (S6) calls `collateralValueUsd`, which calls `getBtcUsdPrice`
(reverting variant). If the feed is stale, zero, or incomplete, or the reserve attestation is
stale, the call **reverts** and **no new debt can be drawn**. Rationale: extending credit on
an unverifiable valuation is the solvency-critical direction. This is the same fail-closed
posture as `ReserveGuard` on the mint path (S0.9 #1, S2). A stale feed therefore *pauses
origination* without any explicit pause action.

**(B) Liquidation when the feed is stale — MAY PROCEED on a signed price attestation.**
A falling-and-then-stuck feed must not *prevent* protecting the lender. So liquidation has an
objective-but-degraded path: when `peekPrice` returns `ok = false` (stale), `LiquidationModule`
(S6) may proceed using a **signed oracle price attestation** — an EIP-712 report
(`PriceAttestation`, signed by the `ORACLE_ADMIN` 2-of-3 set of S0.6: AMINA + Chainlink) that
carries an objective off-chain-observed price and an `observedAt`. This keeps liquidation
**objective** (it is still an oracle report, not AMINA discretion — D-3/D-7) while removing
the liveness dependency on a single live feed.

```solidity
struct PriceAttestation {
    address cbtc;
    uint256 btcUsd1e18;   // attested price, already 1e18
    uint256 observedAt;   // must be recent per attestation staleness window
    uint256 expiresAt;
    uint256 pledgeId;     // binds the report to a specific position
    uint256 nonce;        // anti-replay (per EIP712Hashes, S0.3)
}
```

The attestation path:
- is consumed **only** by `LiquidationModule` (S6), never by the borrow path (a signed price
  can never *open* credit — only the live feed can);
- still applies the **peg cap** (S5.3): liquidation value = `min(attestedPrice * amount,
  attestedReserveValue)`, so a signed price cannot over-value collateral either;
- still requires the **cure window** to have elapsed (S6) — the attestation proves
  eligibility, not immediacy;
- is an *objective report* (S0.7 6b "AMINA-signed price attestation for stale oracle during
  liquidation"), so it does not convert liquidation into discretionary action.

If both the live feed is stale **and** no valid attestation is presented, liquidation cannot
finalize — and the **Morpho permissionless backstop** (S0.9 #6) remains available to any
third party once HF reaches the market LLTV. There is no state in which the protocol is both
unable to liquidate and exposed to growing bad debt.

**Summary of fail matrix:**

| Condition | New borrow | AMINA liquidation | Morpho backstop |
|-----------|-----------|-------------------|-----------------|
| Feed fresh | allowed (peg-capped) | allowed on live price | available at LLTV |
| Feed stale, no attestation | **blocked** | blocked (await attestation/backstop) | available at LLTV |
| Feed stale, valid attestation | **blocked** | **allowed** on attested price (peg-capped, post-cure) | available at LLTV |
| Reserve attestation stale | **blocked** | allowed (debt fixed; cap uses last attested or backstop) | available at LLTV |

---

### S5.7 CAPO note (Optional — future ETH/LST only)

Triora Core values **BTC only** (D-7). BTC has no exchange-rate / accrual component: 1 cBTC
represents 1 BTC, and the only oracle needed is a spot BTC/USD price plus the peg cap above.

A **Correlated-Asset Price Oracle (CAPO)** — which caps an LST's price at
`min(market, snapshotRatio * (1 + maxYearlyGrowth * elapsed))` to defend against a
manipulated or stale exchange-rate feed — is **only required for an accruing collateral such
as ETH/wstETH** (Optional, `Triora-Core-vs-Optional-3.md` §3.2 / digest). It is explicitly
**out of Core** and is flagged here so the `OracleAdapter` interface stays CAPO-ready: a
future `IPriceTransform` hook can be inserted between `_readValidated` and the peg cap without
touching the BTC path. The digest's warning is recorded for that future work: the **March-2026
Aave CAPO incident** ($27M wrongful liquidations from a stale `snapshotRatio`) means any future
CAPO must monitor and bound snapshot staleness as aggressively as price staleness. Core ships
none of this; BTC's flat 1:1 backing makes the peg cap (S5.3) sufficient.

---

### S5.8 Invariants upheld by this section

1. **`collateralValueUsd ≤ attested_reserve_value`** for every valuation (S0.9 #1 at the
   valuation layer; the `min` guarantees it). cBTC is never valued above its real backing.
2. **`warningThresholdBps < liquidationThresholdBps < morphoLLTVBps`** (S0.9 #6) — AMINA's
   warning and objective liquidation always precede the Morpho permissionless backstop.
3. **No new debt on unverifiable valuation** — a stale/zero/incomplete price or stale reserve
   attestation reverts every borrow path (fail-closed, mirrors S0.9 #1 mint posture).
4. **Liquidation eligibility is always objective** — driven either by a validated live feed or
   by a signed `PriceAttestation`, never by AMINA discretion (S0.9 implied by D-3/D-7).
5. **Price and quantity are never conflated** — the price feed never sets quantity; the
   reserve attestation never sets price; the peg cap is their only join (S5.3).
6. **HF math is consistent across surfaces** — the same `HF = collateralValueUsd * ltvBps /
   debtUsd / 1e4` is computed on-chain and rendered as `LIQ/currentLTV` on the UI (S0.5 F3).

### S5.9 External dependencies

- **Chainlink** `AggregatorV3Interface` BTC/USD feed (`latestRoundData`) — the only external
  price source. Heartbeat and decimals cached in `FeedConfig`.
- **`IReserveSource`** (`SignedCustodyAdapter`, S2) — supplies the attested BTC quantity and
  `asOf` for the peg cap.
- **`RiskConfig` / `ParameterArchive`** (S7) — supplies version-pinned `warningThresholdBps`,
  `liquidationThresholdBps`, reserve/price staleness windows, and `morphoLLTVBps` (mirrored
  from the immutable market for the coherence check).
- **`LiquidationModule` / `CollateralBridge`** (S6) — consumers of `collateralValueUsd`,
  `healthFactor`, and the stale-feed `PriceAttestation` override.
- **`EIP712Hashes`** (S0.3) — typehash for `PriceAttestation`.


## S6. Lending Engine — CollateralBridge, Positions & Interest

This is the central engine of Triora Core. It is the only contract that *owns* the
protocol's single aggregate Morpho position, the only contract that holds cBTC as
Morpho collateral, and the only place where the many per-borrower obligations are
reconciled against the one position Morpho can see. Everything upstream
(tokenization, reserve guarding, pledge accounting — S2/S3/S4/S5) produces the cBTC
and the pledge that this engine consumes; everything downstream (Morpho calls — S7;
liquidation, release, settlement — S8) is either invoked by this engine or invokes a
hook on it.

Three contracts are specified here:

1. **`CollateralBridge`** (L3, UUPS + timelock, owner/admin = CURATOR) — the engine and
   the per-borrower sub-ledger.
2. **`PositionRegistry`** (L3, immutable) — write-once per-position terms.
3. **`FixedRateIRM`** (L3, immutable) — the Morpho IRM that pins the market's borrow
   rate to AMINA's curated fixed APR, so the borrower's *Morpho* debt accrues at the
   same fixed rate the bridge sub-ledger mirrors.

The position state machine (S0.8) and the no-interest-before-`Active` invariant
(S0.9 #4) are realized inside `CollateralBridge` and are restated normatively at the
end of this section.

---

### S6.1 Why the sub-ledger exists (the defining constraint)

Per **D-3** (S0.2): the Core loan rail is the bridge over **one isolated, immutable
Morpho market** (cBTC collateral / USDC loan). The bridge supplies cBTC and borrows
USDC `onBehalf = bridge`, so on Morpho there is exactly **one** `Position{supplyShares,
borrowShares, collateral}` — the bridge's aggregate. Morpho cannot tell that this
aggregate is the sum of N independent institutional loans with different principals,
APRs (all equal to AMINA's curated rate via `FixedRateIRM`, but conceptually
per-position), maturities, and pledges.

Therefore **per-borrower accounting and liquidation attribution are not provided by
Morpho — Triora must build them.** That is the `CollateralBridge` sub-ledger: a
`mapping(uint256 pledgeId => Position)` plus aggregate mirrors. The sub-ledger is the
single source of truth for: how much each borrower owes (principal + fixed interest),
which slice of the aggregate Morpho collateral belongs to each pledge, when each
position matured, and which positions are warned/liquidatable. Without it, a single
defaulting borrower's debt is indistinguishable from a healthy borrower's, AMINA
cannot liquidate one position without touching another, and the surplus-to-borrower
invariant (S0.9 #7) cannot be computed per borrower.

The sub-ledger must remain consistent with Morpho's aggregate at every step:
`sum(position.outstanding) ≈ bridge's USDC debt on Morpho` and
`sum(position.collateralCBtc) == bridge's cBTC collateral on Morpho`. S6.6 specifies
the mirroring discipline.

---

### S6.2 `CollateralBridge` (L3 — UUPS+TL, owner = CURATOR)

#### Purpose

Orchestrate the full Model-B loan lifecycle for every borrower: record posted cBTC,
supply it to Morpho and borrow USDC to the borrower (Flow-5), accrue fixed interest in
the sub-ledger, return margin (Flow-2), repay-and-release (Flow-4), top up collateral,
and expose the hooks the `LiquidationModule` (S8) calls. It owns the aggregate Morpho
position and is the only `protocol` address allowed to move cBTC into/out of the
`MorphoAdapter` (S0.9 #3).

#### Storage (ERC-7201 namespaced)

```solidity
/// @custom:storage-location erc7201:triora.storage.CollateralBridge
struct BridgeStorage {
    // ── external dependencies (set once at init, GOVERNOR-rewireable behind TL) ──
    IKYBGateway            kyb;
    IPledgeRegistry        pledges;
    IPermissionedCollateralToken cbtc;     // 8-dec restricted cBTC
    IERC20                 usdc;            // 6-dec loan asset
    IProtocolAdapter       morpho;         // MorphoAdapter (S7)
    IPositionRegistry      positions;      // write-once terms (S6.4)
    IOracleAdapter         oracle;         // BTC/USD, peg-capped (S2)
    IRiskConfig            risk;           // version-pinned params (S2)
    ISettlementRouter      router;         // append-only event stream (S8)
    address                liquidationModule; // the only caller of liq hooks
    address                releaseAuthorizer; // burns are voucher-gated (S8)

    // ── the per-borrower sub-ledger ──
    mapping(uint256 pledgeId => Position) position;   // pledgeId is the position key
    uint256[]              activePledgeIds;           // enumeration for ops/lens

    // ── aggregate mirrors of the single Morpho position ──
    uint256 aggCollateralCBtc;   // Σ position.collateralCBtc (8 dec) == Morpho collateral
    uint256 aggPrincipalUsdc;    // Σ position.principalUsdc   (6 dec)
    uint256 aggOutstandingUsdc;  // Σ position.outstanding (last-accrued, 6 dec)

    // ── halt / pause overlay (does NOT advance state; pauses interest clock) ──
    bool    globalHalt;
    mapping(uint256 pledgeId => bool) positionPaused;

    // ── caps (version-pinned snapshot taken at borrow) ──
    uint256 marketCapUsdc;       // aggregate principal ceiling for this market
}
```

`Position` (defined in `Types`, S0.3 libraries) is the locked struct from the brief:

```solidity
enum PositionState {
    None, PledgePending, Collateralized, Active, Warned,
    RepaymentPending, ReleasePending, Closed,
    LiquidationPending, Liquidated, Defaulted
}

struct Position {
    address      borrower;        // KYB-approved wallet that draws/repays
    uint256      pledgeId;        // 1:1 with the PledgeRegistry pledge (S4)
    uint256      principalUsdc;   // 6 dec — drawn principal (immutable post-borrow)
    uint16       rateBps;         // AMINA curated fixed APR, copied from RiskConfig
    uint64       startTs;         // first second interest accrues (== Active timestamp)
    uint64       maturityTs;      // interest clamps here
    uint256      outstanding;     // 6 dec — principal + accrued, as of lastAccrueTs
    uint256      collateralCBtc;  // 8 dec — cBTC slice supplied to Morpho for this pledge
    PositionState state;
    uint64       paramVersion;    // RiskConfig version this position is pinned to (S0.9 #9)
    uint64       lastAccrueTs;    // last time outstanding was crystallized
    uint64       pausedAccumSec;  // total seconds spent Paused (deducted from elapsed)
}
```

> **Decimals (S0.10):** `principalUsdc`, `outstanding`, `marketCapUsdc` are **6-dec**
> (USDC). `collateralCBtc`, `aggCollateralCBtc` are **8-dec** (cBTC). Any LTV / HF math
> that compares the two normalizes through `OracleAdapter` (S2) at the 1e36 Morpho
> oracle scale — never by truncating decimals. See S6.7.

#### External functions

All borrower-facing functions require `kyb.isApproved(msg.sender)`; all are blocked
when `globalHalt` or the position's `positionPaused` flag is set (except repayment and
liquidation-finalization paths, which must remain live so a borrower can always exit and
AMINA can always close a bad position — S6.8).

##### Collateral intake

```solidity
function depositCollateral(uint256 pledgeId, uint256 amountCBtc) external;
```
- **Role:** ISSUER_MINTER path delivered cBTC to the bridge via `mintForPledge`
  (S3/S5); `depositCollateral` is the bridge-side *record* of that cBTC against the
  pledge. Caller = ALLOCATOR or the mint flow (S0.7 step 3→4). Restricted.
- **Effect:** moves `position.state: PledgePending → Collateralized` (or augments an
  existing `Collateralized`/`Active` position via `topUpCollateral`), increments
  `position.collateralCBtc` and `aggCollateralCBtc`. The cBTC is **not yet** on Morpho
  — it sits in the bridge until `borrow` supplies it (lazy supply keeps `Collateralized`
  positions out of the aggregate Morpho collateral so they cannot be liquidated before
  a loan exists).
- **Reverts:** `NotKYB`, `Halted`, `PledgeNotFree` (pledge already encumbered per S4),
  `PledgeMismatch` (`pledges.borrowerOf(pledgeId) != position.borrower`),
  `MintExceedsPledged` (defense-in-depth against S0.9 #2; PledgeRegistry is primary),
  `WrongState`.

```solidity
function mintAndDeposit(uint256 pledgeId, uint256 amountCBtc) external;
```
- Convenience wrapper for S0.7 steps 3+4 record side when mint and deposit are
  co-submitted by the ALLOCATOR: asserts `pledges.recordMint` already succeeded for
  this amount, then runs `depositCollateral`. Restricted (ALLOCATOR). Same reverts.

##### Borrow (Flow-5 — the core draw)

```solidity
function borrow(uint256 pledgeId, uint256 usdcAmount) external;
```
- **Role:** borrower (== `position.borrower`). KYB-gated.
- **Preconditions checked, in order (fail-closed):**
  1. `kyb.isApproved(msg.sender)` and `msg.sender == position.borrower` → else `NotBorrower`.
  2. `position.state == Collateralized` → else `WrongState` (one active position per
     pledge, S0.9 #2).
  3. `pledges.isFree(pledgeId)` and `pledges.isLockActive(pledgeId)` (custody control
     agreement still in force) → else `PledgeNotBorrowable`.
  4. `risk.isMarketActive()` and not `globalHalt`/`positionPaused` → else `MarketInactive`.
  5. `oracle.isFresh()` (BTC/USD within heartbeat, positive answer, peg-cap holds:
     value ≤ attested reserve value) → else `StaleOracle` (S2, S0.9 invariants).
  6. **LTV check** (S6.7): drawn USD value of `usdcAmount` ≤ `currentLtvBps` of the
     pledge's cBTC USD value, using version-pinned params → else `ExceedsMaxLtv`.
  7. **Cap check:** `aggPrincipalUsdc + usdcAmount ≤ marketCapUsdc` → else `CapExceeded`.
- **Effect (atomic):**
  1. Pin `position.paramVersion = risk.currentVersion()`; copy
     `position.rateBps = risk.rateBps(version)`, `position.maturityTs`,
     and the position's `marketCapUsdc` snapshot.
  2. Lock the pledge for this deal: `pledges.lockForDeal(pledgeId)`
     (`free → encumbered`, S4; enforces one deal per pledge).
  3. `morpho.supplyCollateral(position.collateralCBtc)` **the first time** this pledge's
     cBTC enters Morpho (idempotent — only the not-yet-supplied delta is supplied).
     `aggCollateralCBtc` already reflects it; this realizes it on Morpho.
  4. `morpho.borrow(usdcAmount, onBehalf = address(this), receiver = position.borrower)`
     — Morpho delivers **real USDC on-chain, atomically, to the borrower** (D-2 DvP).
  5. **Write-once terms:** `positions.record(pledgeId, terms)` (S6.4) — immutable
     obligation snapshot (S0.9 #9).
  6. Sub-ledger: `position.principalUsdc = usdcAmount`,
     `position.outstanding = usdcAmount`, `position.startTs = block.timestamp`,
     `position.lastAccrueTs = block.timestamp`,
     `position.state = Active`; bump `aggPrincipalUsdc`, `aggOutstandingUsdc`.
  7. `router.emitPositionOpened(pledgeId, ...)` (S8 append-only stream).
- **Invariant realized:** a position is `Active` **iff** the Morpho `borrow` succeeded
  and USDC reached the borrower (S0.9 #4). Because steps 4–6 are in one transaction, the
  `Active` write and the USDC delivery are inseparable; a Morpho revert reverts the whole
  call and the position stays `Collateralized`. **Interest never accrues before `Active`**
  because `startTs`/`lastAccrueTs` are first set here (S0.9 #4; S6.5).
- **Reverts:** all preconditions above; `MorphoBorrowFailed` (bubbled from adapter).

##### Repay & release (Flow-4)

```solidity
function repay(uint256 pledgeId, uint256 usdcAmount) external;            // partial allowed in v1? — see note
function repayWithdrawAndBurn(uint256 pledgeId) external;                 // full close
```
- **Role:** borrower or AMINA (ALLOCATOR) on the borrower's behalf. KYB-gated for the
  borrower path. **Must remain callable even when `positionPaused`** (a paused position
  must still be exitable).
- **`repay`** (kept minimal in Core — partial repayment is an Optional hardening per the
  digests; Core may restrict to full repayment by reverting if `usdcAmount <
  outstanding`. The signature is reserved so the Optional partial path is non-breaking):
  1. `_accrue(pledgeId)` (S6.5) to crystallize `outstanding`.
  2. Pull `usdcAmount` USDC from the payer (`SafeERC20.safeTransferFrom`).
  3. `morpho.repay(usdcAmount, onBehalf = address(this))`.
  4. Decrement `position.outstanding`, `aggOutstandingUsdc`. If `outstanding == 0`,
     advance to `repayWithdrawAndBurn` continuation.
- **`repayWithdrawAndBurn`** (the close):
  1. `_accrue`; require full `outstanding` repaid (pull remainder).
  2. `morpho.repay(outstanding, onBehalf=this)` then
     `morpho.withdrawCollateral(position.collateralCBtc, receiver = address(this))` —
     cBTC returns to the bridge.
  3. `position.state = RepaymentPending` → on Morpho success → `ReleasePending`.
  4. `ReleaseAuthorizer.issueRepaymentRelease(pledgeId)` (S8) — voucher destination
     **derived from state = borrower** (S0.9 #5), never caller-supplied.
  5. `router.emitReleaseVoucher(...)`. Off-chain custody listener + AMINA co-sign move
     BTC to the borrower and ack on-chain (S8/O6).
  6. On ack: `cbtc.burnForRelease(voucherId, position.collateralCBtc)` (voucher-gated
     burn, S5), `pledges.markReleased(pledgeId)`, `position.state = Closed` [terminal].
     Decrement `aggCollateralCBtc`, `aggPrincipalUsdc`.
- **Reverts:** `NotBorrowerOrAmina`, `WrongState`, `Underpaid`, `MorphoRepayFailed`,
  `OracleNotRequiredHere` (repay path does not read price — closing is always allowed).

##### Margin return (Flow-2)

```solidity
function withdrawAndBurn(uint256 pledgeId, uint256 amountCBtc) external;
```
- **Role:** borrower. KYB-gated. Returns *excess* collateral (margin) while the loan is
  still `Active` — i.e. a partial collateral withdraw that keeps the position healthy.
- **Checks:** `_accrue`; after removing `amountCBtc`, the remaining collateral must
  still satisfy `currentLtvBps < maxLtvBps` at a **fresh** oracle price (S6.7); the
  pledge's `mintedAmount` accounting (S4) must permit the burn (`encumbered ≤ minted`).
- **Effect:** `morpho.withdrawCollateral(amountCBtc, receiver=this)`; decrement
  `position.collateralCBtc`, `aggCollateralCBtc`; route a **state-derived** release
  voucher to the borrower (S8); on ack, `cbtc.burnForRelease`. Position stays `Active`.
- **Reverts:** `NotBorrower`, `WrongState`, `StaleOracle`, `WouldExceedMaxLtv`,
  `PledgeAccountingViolation`.

##### Top-up

```solidity
function topUpCollateral(uint256 pledgeId, uint256 amountCBtc) external;
```
- **Role:** borrower. Adds cBTC (already minted against the same pledge, S0.9 #2) to a
  `Active` or `Warned` position; supplies it to Morpho; if the position was `Warned` and
  the top-up restores health below the AMINA warning threshold, transitions
  `Warned → Active` and clears the cure clock (the `LiquidationModule` reads health, S8).
- **Effect:** `morpho.supplyCollateral(amountCBtc)`; bump `position.collateralCBtc`,
  `aggCollateralCBtc`; emit `router.emitTopUp(...)`.
- **Reverts:** `NotBorrower`, `WrongState`, `MintExceedsPledged`.

##### Liquidation hooks (called only by `LiquidationModule`, S8)

```solidity
function setWarned(uint256 pledgeId) external onlyLiquidationModule;
function applyLiquidation(
    uint256 pledgeId,
    uint256 debtToCoverUsdc,
    uint256 collateralSeizedCBtc,
    uint256 surplusCBtc
) external onlyLiquidationModule;
```
- **`setWarned`:** `Active → Warned` (idempotent); records the cure-clock start in the
  `LiquidationModule` (the module owns the clock; the bridge only flips state and
  freezes nothing else). Interest **continues** to accrue in `Warned` (S0.8 overlay).
- **`applyLiquidation`:** the bridge-side accounting half of S8's Flow-6b. Preconditions
  are enforced by the `LiquidationModule` (objective oracle predicate + cure elapsed,
  S0.9 #6, AMINA threshold strictly tighter than Morpho LLTV). The bridge:
  1. `_accrue(pledgeId)`.
  2. `morpho.repay(debtToCoverUsdc, onBehalf=this)` and
     `morpho.withdrawCollateral(collateralSeizedCBtc, receiver=this)` — atomic.
  3. `position.outstanding -= debtToCoverUsdc` (full close → 0),
     `position.collateralCBtc -= collateralSeizedCBtc`; update aggregates.
  4. Set `position.state = LiquidationPending`; `ReleaseAuthorizer.issueLiquidationRelease`
     routes the seized cBTC voucher to the **AMINA desk** (state-derived, S0.9 #5).
     The `surplusCBtc` (proceeds − debt − bonus − fee, computed off-chain on sale, but
     the on-chain surplus *collateral* slice) is recorded so the borrower-surplus
     invariant (S0.9 #7) is auditable; the actual surplus refund is a second
     state-derived voucher to the borrower (S8).
  5. On custody ack: `cbtc.burnForRelease`, `pledges.markLiquidated`,
     `position.state = Liquidated` [terminal]; if proceeds < debt, `Defaulted` and the
     shortfall is booked off-chain to AMINA (S0.8).
- **Reverts:** `NotLiquidationModule`, `WrongState`, `MorphoRepayFailed`.

##### Admin (CURATOR / GUARDIAN / EMERGENCY — privilege-separated per S0.6, S0.9 #8)

```solidity
function pausePosition(uint256 pledgeId) external onlyGuardianOrEmergency; // overlay; pauses interest clock
function unpausePosition(uint256 pledgeId) external onlyGuardianOrEmergency;
function setGlobalHalt(bool halted) external onlyEmergency;
function setMarketCap(uint256 capUsdc) external onlyCurator;               // cap *increase* timelocked; decrease is GUARDIAN
```
- **No function in this contract both moves collateral/USDC and sets a risk
  parameter** (S0.9 #8). `setMarketCap`/risk params live behind CURATOR+timelock;
  collateral-moving functions are borrower/liquidation-module gated. GUARDIAN may only
  *reduce* exposure (pause, cap decrease) — a hot key that can only de-risk (S0.6).

#### Events

`PositionCollateralized`, `PositionOpened` (Active), `Repaid`, `PositionClosed`,
`MarginReturned`, `ToppedUp`, `Warned`, `Liquidated`, `Defaulted`, `PositionPaused`,
`PositionUnpaused`, `GlobalHaltSet`, `MarketCapSet`. All material lifecycle events are
*also* mirrored onto the append-only `SettlementRouter` stream (S8) with a monotonic
sequence number for off-chain gap detection — the bridge's own events are for indexers;
the router stream is the authenticated instruction feed.

#### Errors (custom, per S0.10)

`NotKYB`, `NotBorrower`, `NotBorrowerOrAmina`, `NotLiquidationModule`, `WrongState`,
`Halted`, `MarketInactive`, `StaleOracle`, `ExceedsMaxLtv`, `WouldExceedMaxLtv`,
`CapExceeded`, `PledgeNotFree`, `PledgeNotBorrowable`, `PledgeMismatch`,
`MintExceedsPledged`, `Underpaid`, `MorphoBorrowFailed`, `MorphoRepayFailed`,
`PledgeAccountingViolation`.

#### Invariants upheld

- **S0.9 #4** — `Active` iff Morpho `borrow` succeeded and USDC reached the borrower;
  interest accrues only from `Active` (`startTs`/`lastAccrueTs` first set in `borrow`).
- **S0.9 #2** — one active position per pledge (`borrow` requires `Collateralized` and
  `pledges.lockForDeal` enforces single deal); `collateralCBtc` slices never exceed the
  pledge's minted amount.
- **S0.9 #3** — only the bridge moves cBTC into/out of the Morpho adapter; cBTC burns
  are voucher-gated via `ReleaseAuthorizer` (S5/S8).
- **S0.9 #5** — every release destination is state-derived (repay→borrower,
  liq→AMINA desk, surplus→borrower); the bridge never accepts a caller-supplied
  destination.
- **S0.9 #8** — privilege separation: no bridge function both moves value and sets risk.
- **Sub-ledger ↔ Morpho consistency** — `aggCollateralCBtc == Morpho collateral` and
  `aggOutstandingUsdc ≈ Morpho USDC debt` after every state-changing call (S6.6).

#### External dependencies

`MorphoAdapter`/Morpho (S7), `PermissionedCollateralToken` cBTC (S5), USDC, `KYBGateway`
(S?), `PledgeRegistry` (S4), `PositionRegistry` (S6.4), `OracleAdapter` (S2),
`RiskConfig`/`ParameterArchive` (S2), `ReleaseAuthorizer`+`SettlementRouter`+
`LiquidationModule` (S8), `RoleManager`/AccessManager (S1).

#### Why Core / What breaks if omitted

- **Test passed: Solvency + Liability.** The `CollateralBridge` *is* the loan product
  (S0.3 #10: "If omitted: there is no loan product"). It is also the only place where
  per-borrower solvency is even computable: Morpho sees one aggregate position, so
  without the sub-ledger Triora cannot attribute debt, collateral, or liquidation to a
  specific borrower.
- **Concrete failure mode if cut:** with no sub-ledger, one borrower's default
  contaminates the whole aggregate — AMINA cannot liquidate position A without seizing
  position B's collateral, the surplus-to-borrower invariant (S0.9 #7) is uncomputable,
  and a healthy borrower can be force-liquidated because Morpho's single-position health
  reflects the *blend*, not the individual. With no on-chain LTV/cap/KYB gate in
  `borrow`, an unscreened or over-leveraged draw succeeds (Liability + Solvency breach).
  With no atomic `borrow` (state-set fused to Morpho DvP), a position could be marked
  `Active` and begin accruing interest before the borrower ever receives USDC — directly
  violating S0.9 #4 and the corpus's most load-bearing invariant ("no interest before
  funding").

---

### S6.3 The aggregate Morpho position it owns

The bridge holds exactly one Morpho position in the isolated cBTC/USDC market
(market params fixed at deploy per D-1: `loanToken=USDC`, `collateralToken=cBTC`,
`oracle=OracleAdapter-fed`, `irm=FixedRateIRM` (S6.5), `lltv=marketLLTV`). All bridge
Morpho calls pass `onBehalf=address(bridge)`; `borrow`/`withdrawCollateral` pass
`receiver` explicitly (borrower on draw, bridge on repay/liq). The bridge is both the
Morpho debtor and the position owner; per-borrower attribution lives entirely in the
sub-ledger. The exact adapter signatures and Morpho call sequencing are specified in
**S7** — this section specifies only *what* the bridge calls and *why* (DvP, atomicity),
not the adapter ABI.

---

### S6.4 `PositionRegistry` (L3 — Immutable)

#### Purpose

A write-once, append-only record of every position's *terms* — the immutable audit of
the obligation, independent of the mutable runtime in the bridge sub-ledger. This
separates "what was agreed" (immutable, here) from "what is currently owed" (mutable,
in the bridge). It realizes S0.9 #9 (terms write-once; params version-pinned).

#### Storage

```solidity
struct PositionTerms {
    address borrower;
    uint256 pledgeId;
    uint256 principalUsdc;       // 6 dec
    uint16  rateBps;             // AMINA curated APR at origination
    uint64  startTs;
    uint64  maturityTs;
    address market;              // the Morpho market id / adapter
    uint64  paramVersion;        // RiskConfig version pinned
    bytes32 legalTermsHash;      // hash of the off-chain loan/control-agreement terms
}

mapping(uint256 pledgeId => PositionTerms) private _terms;
mapping(uint256 pledgeId => bool)          private _recorded;
address public immutable engine;   // the CollateralBridge — sole writer
```

#### External functions

```solidity
function record(uint256 pledgeId, PositionTerms calldata terms) external onlyEngine; // write-once
function getTerms(uint256 pledgeId) external view returns (PositionTerms memory);
function exists(uint256 pledgeId) external view returns (bool);
```
- **`record`:** callable **only** by the bound `engine` (the bridge), **only once** per
  `pledgeId` (`_recorded[pledgeId]` guard → `AlreadyRecorded`). Called inside
  `borrow` step 5. After this, terms are frozen forever — a later param change cannot
  retroactively alter a live deal (S0.9 #9; the bridge keeps `paramVersion` pinned and
  reads the archived `ParamsV{n}` from `ParameterArchive`, S2).
- The bridge `engine` address is set in the constructor (one-shot, immutable) — no
  setter, consistent with the immutable-spine decision (D-9).

#### Events / Errors

`TermsRecorded(pledgeId, borrower, principalUsdc, rateBps, maturityTs, paramVersion)`;
errors `OnlyEngine`, `AlreadyRecorded`, `ZeroPledge`.

#### Invariants upheld

- **S0.9 #9** — terms are write-once; any mutation attempt reverts. The version pin makes
  every live position immune to subsequent `RiskConfig` changes.

#### External dependencies

`CollateralBridge` (writer), `ParameterArchive` (the archived params the `paramVersion`
points to live in S2).

#### Why Core / What breaks if omitted

- **Test passed: Liability.** Institutions audit the obligation; the immutable terms are
  the on-chain proof of *what was agreed*, separate from the changing balance.
- **Failure mode if cut:** position terms would live only in the mutable bridge storage,
  where an upgrade of the UUPS bridge (or a bug) could silently rewrite a borrower's APR,
  maturity, or principal after origination. There would be no immutable audit trail of
  the original obligation — a regulated institutional product cannot offer "your terms
  cannot be changed under you" without this. (S0.3 #9: "Terms can be silently mutated;
  no immutable audit of the obligation.")

---

### S6.5 `FixedRateIRM` (L3 — Immutable) and interest mirroring

#### Purpose

Morpho markets accrue borrower debt through a pluggable **Interest Rate Model (IRM)**.
A normal Morpho IRM returns a *variable*, utilization-driven rate. Triora's product
promise is a **fixed-rate repo** at AMINA's curated APR (D-3). `FixedRateIRM` is a
Morpho-conformant IRM that returns AMINA's fixed per-second rate, so the **borrower's
Morpho debt itself accrues at the fixed APR** — not just the bridge's mirror. This keeps
the aggregate Morpho debt and the sum of sub-ledger `outstanding` values in lock-step
(S6.6) instead of drifting (which they would if Morpho accrued a variable rate while the
sub-ledger accrued a fixed one).

#### Interface (Morpho IRM conformance)

Morpho calls the IRM with the market state and expects a per-second borrow rate scaled
to 1e18 (WAD/seconds). Two entry points, one stateful (called inside Morpho `accrue`),
one view:

```solidity
interface IIrm {
    // called by Morpho during accrual; may update internal state
    function borrowRate(MarketParams calldata p, Market calldata m) external returns (uint256 ratePerSecondWad);
    // pure/view variant for off-chain & lens reads
    function borrowRateView(MarketParams calldata p, Market calldata m) external view returns (uint256 ratePerSecondWad);
}

contract FixedRateIRM is IIrm {
    IRiskConfig public immutable risk;          // source of the curated APR
    uint256     public immutable marketId;      // the one Triora market

    /// returns the AMINA-curated fixed rate as a per-second WAD rate
    function _ratePerSecond() internal view returns (uint256) {
        uint16 aprBps = risk.rateBps(marketId);              // e.g. 800 = 8.00% APR
        // ratePerSecond = apr / SECONDS_PER_YEAR, in 1e18 WAD
        return (uint256(aprBps) * 1e18) / (10_000 * 365 days);
    }
    function borrowRate(MarketParams calldata, Market calldata) external view returns (uint256) {
        return _ratePerSecond();
    }
    function borrowRateView(MarketParams calldata, Market calldata) external view returns (uint256) {
        return _ratePerSecond();
    }
}
```

- The IRM is **immutable** (D-9): it does not store the rate — it reads the curated APR
  from `RiskConfig` (S2). Because every live Triora position is **version-pinned**, a
  rate change in `RiskConfig` affects only *new* positions; but note that Morpho's single
  aggregate position accrues at whatever `_ratePerSecond()` returns *now*. Core ships
  with **one effective curated rate at a time** for the live aggregate; per-position fixed
  rates that differ are an Optional extension (it would require either one Morpho market
  per rate or a bridge-side rate-spread accounting layer). For Core, the locked decision
  is: **all simultaneously-open positions share the curated rate**, and the bridge
  mirrors that exact rate per position — so Morpho-debt and sub-ledger stay equal.
  (Documented in S6.6 as the consistency precondition.)

#### Bridge sub-ledger interest formula (mirrors Morpho)

The bridge crystallizes each position's `outstanding` with a **simple linear** accrual,
matching the corpus's locked model, computed only when the position is in an
interest-bearing state and clamped at maturity:

```
function _accrue(pledgeId):
    p = position[pledgeId]
    if p.state not in {Active, Warned, RepaymentPending}:   // S0.9 #4 / S0.8 overlay
        return                                              // no accrual otherwise
    nowEff = min(block.timestamp, p.maturityTs)             // clamp at maturity
    elapsed = nowEff - p.lastAccrueTs - newlyPausedSeconds  // pause-aware (S0.8)
    if elapsed <= 0: { p.lastAccrueTs = block.timestamp; return }
    interest = p.principalUsdc * p.rateBps * elapsed / (10_000 * 365 days)
    p.outstanding += interest
    aggOutstandingUsdc += interest
    p.lastAccrueTs = block.timestamp
```

- **No interest before `Active`** (S0.9 #4): `_accrue` returns immediately for `None`,
  `PledgePending`, `Collateralized`. `startTs == lastAccrueTs == 0` until `borrow`, so
  even if called early there is nothing to accrue.
- **Clamp at maturity:** `nowEff = min(now, maturityTs)` — interest stops at maturity,
  exactly as the corpus's three implementations do.
- **Pause-aware:** seconds the position spent `Paused` (overlay, S0.8) are excluded;
  `pausedAccumSec` tracks the running total, and `_accrue` deducts the increment since
  the last accrual. The interest clock is frozen while paused (S0.8: "Paused … pauses the
  interest clock").
- **Mirror discipline:** because `FixedRateIRM` makes Morpho accrue at the *same*
  per-second rate, `Σ position.outstanding` tracks Morpho's aggregate USDC borrow assets
  (modulo Morpho's share-rounding, which the bridge tolerates via a small dust margin —
  S6.6). When closing, the bridge always repays the **Morpho** figure (the authoritative
  debt), using its own `outstanding` only for per-borrower attribution and surplus math.

#### Events / Errors

The IRM emits nothing (Morpho-side accrual emits). Bridge accrual is captured in the
lifecycle events (`Repaid`, `Liquidated`) carrying the crystallized `outstanding`.
IRM errors: none (pure rate read); a misconfigured `marketId`/`risk` is a deploy-time
wiring error caught by the wiring checks (S1).

#### Invariants upheld

- **S0.9 #4** — interest only from `Active` onward; `_accrue` enforces the state gate.
- **No-interest-before-Active** (S0.8 invariant line) — structurally guaranteed by the
  state gate and zero `startTs` before `borrow`.
- **Fixed-rate fidelity (D-3)** — borrower's Morpho debt and the bridge mirror accrue at
  the identical AMINA-curated per-second rate.

#### External dependencies

Morpho (calls the IRM during accrual), `RiskConfig` (curated APR source, S2).

#### Why Core / What breaks if omitted

- **Test passed: Liability (product fidelity) + Solvency (ledger consistency).**
- **Failure mode if cut:** without `FixedRateIRM`, the isolated Morpho market would use a
  standard variable IRM, so the **borrower faces a fluctuating DeFi rate** — breaking the
  fixed-rate-repo promise the entire product is sold on (S0.3 #12: "Borrower faces
  variable DeFi rate — breaks fixed-rate-repo fidelity"). Worse for solvency: the bridge
  sub-ledger (fixed) and Morpho aggregate (variable) would **drift apart**, so the bridge
  would either under-repay Morpho (leaving residual debt and risking the aggregate's
  liquidation) or over-charge the borrower. Fixing the Morpho-side rate is what keeps the
  two ledgers reconcilable.

---

### S6.6 Sub-ledger ↔ Morpho reconciliation (the consistency contract)

Because the bridge owns one Morpho position but tracks N, it must keep its mirrors
provably consistent. The discipline:

| Quantity | Bridge mirror | Morpho truth | Reconciliation rule |
|----------|---------------|--------------|---------------------|
| Collateral | `aggCollateralCBtc` (8 dec) | `Position.collateral` | **Exact equality** after every `supplyCollateral`/`withdrawCollateral` — cBTC has no share accounting, so they must match to the satoshi. |
| Debt | `aggOutstandingUsdc` (6 dec) | `totalBorrowAssets × bridgeBorrowShares / totalBorrowShares` | **Equal within a dust margin** — Morpho carries debt in shares with rounding; the bridge accepts a small `reconcileDustUsdc` tolerance and always repays the *Morpho* figure on close. |
| Rate | per-position `rateBps` | `FixedRateIRM` per-second rate | Identical by construction (S6.5). |

- On **`borrow`**: bridge increments mirrors *and* realizes the Morpho `supplyCollateral`
  + `borrow` in the same tx; a Morpho revert reverts the mirror update (atomicity).
- On **close/liquidation**: bridge reads Morpho's authoritative debt for this slice
  (via the adapter, S7) and repays *that*; per-borrower `outstanding` is used only to
  split surplus and attribute the slice. If Morpho's figure exceeds the borrower's
  `outstanding` by more than `reconcileDustUsdc`, the bridge emits a
  `ReconcileDrift` alarm event (monitored per S0.4 O9) and reverts the close — drift
  beyond dust is a solvency-relevant invariant breach, fail-closed.
- A read-only `BridgeLens` (S5/L5) exposes both the mirror and the live Morpho figure so
  the off-chain monitor (O9) can alert on any divergence before it grows.

This reconciliation is *why* `FixedRateIRM` is non-negotiable: it removes rate drift, so
the only residual divergence is Morpho's share rounding, which is bounded and dust-sized.

---

### S6.7 LTV / health math (decimal-explicit)

`borrow`, `withdrawAndBurn`, and the `LiquidationModule` (S8) all need the position's
current LTV. Cross-asset math normalizes cBTC (8 dec) and USDC (6 dec) explicitly via
the oracle, never by truncation (S0.10):

```
// OracleAdapter returns BTC/USD at Morpho's 1e36 oracle scale, peg-capped to
// min(market, attested-reserve value) per S2.
collateralValueUsd6 = position.collateralCBtc            // 8 dec
                    * oracle.price()                      // 1e36-scaled BTC/USD
                    / 1e36                                // → USD at cBTC's 8-dec base
                    / 10**(8 - 6);                        // normalize 8-dec cBTC → 6-dec USD basis

currentLtvBps = position.outstanding * 10_000 / collateralValueUsd6;   // both 6-dec now
```

- **Frontend HF copy constraint (S0.10):** the UI shows health as `HF = LIQ / currentLTV`
  (e.g. LIQ=80%, currentLTV=70% → HF=1.14), **never** `MAX_LTV / currentLTV`. `LIQ` is the
  **AMINA liquidation threshold**, which by S0.9 #6 is **strictly tighter than the Morpho
  market LLTV** — so AMINA's HF reaches 1.00 before Morpho's would. The UI/lens must label
  the rate as "AMINA's parameter," never "platform offer," and must never imply "instant
  liquidation guarantee" or "Chainlink mints" (S0.10).
- The bridge enforces `currentLtvBps ≤ maxLtvBps` (version-pinned) on `borrow` and on
  the *post-withdraw* state of `withdrawAndBurn`. The `LiquidationModule` (S8) compares
  against the (tighter) AMINA warning/liquidation thresholds.

---

### S6.8 Position state machine (normative, realizes S0.8)

The bridge is the sole authority over `PositionState`. Allowed transitions (any other
attempt reverts `WrongState`):

```
None ──registerPledge(S4)──▶ PledgePending
PledgePending ──depositCollateral──▶ Collateralized
Collateralized ──borrow (Morpho DvP ok)──▶ Active        // S0.9 #4: Active iff USDC delivered
Active ──setWarned(HF<AMINA warn)──▶ Warned
Warned ──topUpCollateral / cure (HF recovers)──▶ Active
Active|Warned ──repayWithdrawAndBurn──▶ RepaymentPending
RepaymentPending ──Morpho repay+withdraw ok──▶ ReleasePending
ReleasePending ──custody ack + burn──▶ Closed            // [terminal]
Active|Warned ──applyLiquidation (cure elapsed, objective trigger)──▶ LiquidationPending
LiquidationPending ──custody ack + burn (proceeds ≥ debt)──▶ Liquidated      // [terminal]
LiquidationPending ──proceeds < debt──▶ Defaulted        // [terminal, shortfall off-chain to AMINA]
Overlay: Paused (bool) on any non-terminal state — does NOT advance state; freezes the interest clock.
```

**Hard invariants enforced by the machine (all from S0.9 / S0.8):**

1. **#4 — Active iff funded.** The `Collateralized → Active` edge exists *only* inside
   `borrow`, fused to a successful Morpho `borrow` that delivers USDC to the borrower.
   There is no other path to `Active`, and `startTs` (hence interest) is set on that edge
   and nowhere else.
2. **No interest before Active.** `_accrue` is a no-op for every pre-`Active` state, and
   `lastAccrueTs == 0` until `borrow`.
3. **#2 — one active position per pledge.** `borrow` requires `Collateralized`; the
   pledge lock (S4) blocks a second deal on the same pledge.
4. **#5 — state-derived release only.** `RepaymentPending`/`ReleasePending` issue a
   borrower voucher; `LiquidationPending` issues an AMINA-desk voucher; surplus issues a
   borrower voucher. Destination is never caller-supplied.
5. **#6 — AMINA before Morpho.** `setWarned`/`applyLiquidation` fire at the AMINA
   threshold, which is strictly tighter than Morpho LLTV — AMINA's orderly path runs
   before Morpho's permissionless backstop can.
6. **Repay/close always live.** Repayment and liquidation-finalization paths are exempt
   from the `Paused`/`positionPaused` block, so a position can always be exited and a bad
   position can always be closed (liveness).

Cross-references: pledge lifecycle and `lockForDeal`/`markReleased`/`markLiquidated` —
**S4**; Morpho call sequencing and adapter ABI — **S7**; objective liquidation trigger,
cure window, release vouchers, settlement router, surplus refund — **S8**; oracle
freshness/peg-cap and `RiskConfig` version pinning — **S2**; KYB gate — **S1/identity**;
cBTC restricted-transfer and voucher-gated burn — **S5**.


## S7. Morpho Market Integration (ProtocolAdapter)

This section specifies the external-liquidity rail of Triora Core: how the protocol borrows **real USDC against cBTC** on **one isolated, immutable Morpho Blue market** (decision **D-1/D-2/D-3**, `Triora-Core-vs-Optional-3.md` §2.3). It defines the market setup and curation, the `IProtocolAdapter` boundary and the `MorphoAdapter` implementation (component #11 in S0.3), the **bridge-owns-the-position** pattern that makes per-borrower attribution the bridge's job (S6), the Morpho permissionless-liquidation backstop and how AMINA's tighter threshold guarantees AMINA acts first (invariant S0.9 #6), oracle scaling, and the reversibility the adapter buys us.

This section is the *cash leg*. The cToken/reserve/pledge spine (S2–S5) and the `CollateralBridge` engine + sub-ledger (S6) are specified elsewhere; S7 specifies only the Morpho boundary the bridge sits on top of, and obeys every S0.9 invariant.

---

### S7.1 The isolated Morpho Blue market (Core data layer)

Triora Core borrows from **exactly one** Morpho Blue market. A Morpho market is defined by **5 immutable parameters** (`MarketParams`); once the market is created none of them — not even Morpho governance — can be changed. Triora pins all live positions to this market's id.

| Param | Triora Core value | Notes |
|-------|-------------------|-------|
| `loanToken` | **USDC** (6 dec) | The real asset borrowers receive. No cUSDC anywhere (D-2). |
| `collateralToken` | **cBTC** (`PermissionedCollateralToken`, 8 dec, S5) | Restricted ERC-20; transfers allowed only on protocol paths (S0.9 #3). |
| `oracle` | **`OracleAdapter`** (S0.3 #8) | Returns cBTC/USDC at Morpho's **1e36** scale (S7.5). |
| `irm` | **`FixedRateIRM`** (S0.3 #12, spec S8) | Returns the AMINA-curated fixed borrow rate (D-3). |
| `lltv` | **AMINA-curated LLTV** (e.g. 0.86e18) | Morpho's liquidation LTV — the **backstop** threshold, strictly looser than AMINA's own (S7.4). |

```solidity
// from Morpho IMorpho.sol — exact upstream shape, do not redefine
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;            // 18-decimal WAD, e.g. 0.86e18
}
// id = keccak256(abi.encode(marketParams)) -> Id (bytes32)
```

**Triora stores the market id once.** `RiskConfig`/`ParameterArchive` (S0.3 #16) holds the `MarketParams` struct and the derived `Id`; live positions are version-pinned to it (S0.9 #9). The `MorphoAdapter` is constructed with the immutable `MarketParams` and refuses any call referencing a different market (S7.3).

#### S7.1.1 Curation by AMINA (who deploys, who approves)

- **CURATOR (AMINA 2-of-3 Safe, S0.6)** chooses every market parameter (LLTV, oracle wiring, the IRM rate). Market creation on Morpho is permissionless, but admitting the market into Triora — writing its `MarketParams`/`Id` into `RiskConfig` and wiring the `MorphoAdapter` — is a **CURATOR** action, timelocked per D-9/D-10. CURATOR sets *risk values*; it cannot mint or move collateral (privilege separation, S0.9 #8).
- **GOVERNOR (P2P, S0.6)** wires contracts (sets the `MorphoAdapter` address on the bridge), behind the upgrade timelock. GOVERNOR cannot set risk values.
- The market is **immutable after creation**: a wrong LLTV/oracle is unfixable in place — the remedy is to curate a *new* market and migrate, which is why the `MarketParams` live in `ParameterArchive` and positions are version-pinned.

#### S7.1.2 Where USDC liquidity comes from in Core

The bridge can only `borrow` USDC that has been `supply`'d to the market. In **Core**, supply comes from **AMINA-approved lenders or AMINA treasury supplying USDC directly** to the isolated market (i.e., `Morpho.supply(marketParams, assets, 0, lenderOrTreasury, "")`). The four-party economics are preserved: the **lender provides cash**, the **borrower provides BTC**, **AMINA curates/co-signs/liquidates**, the **custodian holds the BTC** (`Triora-Core-vs-Optional-3.md` Part 1).

A **curated MetaMorpho (ERC-4626) vault** that pools multiple lenders and auto-allocates into this market is **Optional/v2** (`Triora-Core-vs-Optional-3.md` §3.2) — it is a managed-supply convenience, not a safety control, and adding it does not touch the bridge or adapter (Reversibility). Core liquidity-availability handling: if the market lacks free USDC, `borrow` reverts with Morpho's insufficient-liquidity error; the bridge surfaces it as `EBorrowNoLiquidity` (S7.3) and the position stays pre-`Active` (no debt booked, no interest — invariant S0.9 #4).

#### Why Core / What breaks if omitted

**Test: Solvency + Reversibility.** The isolated immutable market is what gives Core **on-chain DvP** — USDC is delivered atomically when the bridge calls `borrow`, with no off-chain cash-settlement trust gap (the decisive reason Model B beats Model A, `Triora-Core-vs-Optional-3.md` §7.2). Isolation means a bad oracle/LLTV in any other Morpho market can never contaminate Triora's market. **If omitted** (i.e., a bespoke cash engine instead), Triora must build and audit interest-accrual, health-factor, and liquidation-incentive math from scratch and accept unenforceable off-chain settlement — strictly more novel attack surface and a weaker settlement guarantee.

---

### S7.2 `IProtocolAdapter` — the venue boundary

`IProtocolAdapter` is the *only* surface through which `CollateralBridge` (S6) touches an external lending venue. It abstracts the five Morpho operations the bridge needs plus a position read, so the bridge holds **zero** Morpho ABI knowledge. This is the Reversibility seam: Aave (or a second Morpho market) is added later by writing a new adapter, with no change to bridge logic (S0.3 #11; D-8).

```solidity
interface IProtocolAdapter {
    /// One-time-ish: deposit cBTC collateral into the venue on behalf of the bridge.
    /// @param assets cBTC amount, 8 decimals. Pure assets-only op (no shares).
    function supplyCollateral(uint256 assets) external;

    /// Withdraw cBTC collateral back to the bridge.
    function withdrawCollateral(uint256 assets) external;

    /// Borrow loanToken (USDC, 6dp). Exactly ONE of assets/shares is nonzero.
    /// receiver is where USDC lands (the borrower in Core); onBehalf is the debtor (the bridge).
    /// Returns (assetsBorrowed, sharesBorrowed) as reported by the venue.
    function borrow(uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// Repay loanToken. Exactly ONE of assets/shares is nonzero.
    /// Pass shares==full borrowShares for an exact full close (avoids dust, S7.3.1).
    /// Returns (assetsRepaid, sharesRepaid).
    function repay(uint256 assets, uint256 shares, address onBehalf)
        external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// Read the bridge's single aggregate venue position.
    function position() external view returns (
        uint256 supplyShares, uint256 borrowShares, uint256 collateral
    );

    /// Convenience reads for the bridge sub-ledger / lenses (S6, S11).
    function expectedBorrowAssets() external view returns (uint256); // accrued debt, USDC 6dp
    function marketId() external view returns (bytes32);
    function loanToken() external view returns (address);
    function collateralToken() external view returns (address);
    function oracle() external view returns (address);
    function lltv() external view returns (uint256);
}
```

**Notes binding on every implementation:**
- The adapter is **immutable** (S0.3 #11) and constructed with a single `MarketParams`. It never accepts a `MarketParams` argument at call time — eliminating the "operate on the wrong market" footgun.
- The adapter is **caller-restricted**: only the wired `CollateralBridge` may call the state-changing methods (`onlyBridge`). The bridge, in turn, is the only on-chain holder of the position.
- The adapter performs **no business logic** (no LTV, no sub-ledger, no surplus math). It is a thin, auditable wrapper. All per-borrower accounting and AMINA-first liquidation policy live in the bridge (S6) and `LiquidationModule` (S9).

---

### S7.3 `MorphoAdapter` — the implementation

```solidity
/// @notice Immutable thin wrapper over ONE isolated Morpho Blue market.
/// @dev Holds no business logic; only the wired CollateralBridge may mutate.
contract MorphoAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IMorpho   public immutable MORPHO;
    address   public immutable BRIDGE;        // the only authorized caller
    IERC20    public immutable LOAN_TOKEN;     // USDC (6dp)
    IERC20    public immutable COLLATERAL;     // cBTC (8dp)
    // MarketParams stored field-by-field (immutables) + cached Id:
    address   public immutable ORACLE;
    address   public immutable IRM;
    uint256   public immutable LLTV;
    Id        public immutable MARKET_ID;      // keccak256(abi.encode(marketParams))

    error ENotBridge();
    error EAssetAndSharesSet();   // both nonzero in borrow/repay
    error EAssetAndSharesZero();  // both zero in borrow/repay
    error EZeroAddress();

    modifier onlyBridge() { if (msg.sender != BRIDGE) revert ENotBridge(); _; }

    constructor(IMorpho morpho, MarketParams memory mp, address bridge) {
        if (bridge == address(0)) revert EZeroAddress();
        MORPHO = morpho; BRIDGE = bridge;
        LOAN_TOKEN = IERC20(mp.loanToken);
        COLLATERAL = IERC20(mp.collateralToken);
        ORACLE = mp.oracle; IRM = mp.irm; LLTV = mp.lltv;
        MARKET_ID = mp.id(); // library helper over MarketParams
        // one-time max approvals to Morpho for collateral supply & USDC repay
        COLLATERAL.forceApprove(address(morpho), type(uint256).max);
        LOAN_TOKEN.forceApprove(address(morpho), type(uint256).max);
    }

    function _params() internal view returns (MarketParams memory mp) {
        mp = MarketParams({
            loanToken: address(LOAN_TOKEN),
            collateralToken: address(COLLATERAL),
            oracle: ORACLE, irm: IRM, lltv: LLTV
        });
    }
    // ... methods below
}
```

#### S7.3.1 Method bodies (sketches) and the dual asset/share care

Morpho's `borrow`, `repay`, `supply`, `withdraw` take **both** an `assets` and a `shares` argument and require **exactly one** to be nonzero. Getting this wrong is the single most dangerous integration mistake: passing the wrong one, or both, mis-sizes the operation. The adapter **enforces the XOR** before every call.

```solidity
function supplyCollateral(uint256 assets) external onlyBridge {
    // cBTC must already be held by this adapter (bridge transfers in, or supplies onBehalf=bridge).
    MORPHO.supplyCollateral(_params(), assets, BRIDGE, "");
}

function withdrawCollateral(uint256 assets) external onlyBridge {
    // onBehalf = BRIDGE (debtor), receiver = BRIDGE (collateral returns to bridge custody-mirror).
    MORPHO.withdrawCollateral(_params(), assets, BRIDGE, BRIDGE);
}

function borrow(uint256 assets, uint256 shares, address onBehalf, address receiver)
    external onlyBridge returns (uint256 a, uint256 s)
{
    _requireXor(assets, shares);
    // onBehalf MUST be BRIDGE (the bridge owns the single position); receiver is the borrower.
    (a, s) = MORPHO.borrow(_params(), assets, shares, onBehalf, receiver);
}

function repay(uint256 assets, uint256 shares, address onBehalf)
    external onlyBridge returns (uint256 a, uint256 s)
{
    _requireXor(assets, shares);
    // For a FULL close the bridge passes shares == current borrowShares so the position
    // zeroes exactly (asset-denominated full repay leaves rounding dust that blocks withdraw).
    (a, s) = MORPHO.repay(_params(), assets, shares, onBehalf, "");
}

function _requireXor(uint256 assets, uint256 shares) internal pure {
    if (assets != 0 && shares != 0) revert EAssetAndSharesSet();
    if (assets == 0 && shares == 0) revert EAssetAndSharesZero();
}
```

**Asset vs share rule of thumb the bridge follows (and the adapter enforces shape for):**
- **Borrow / partial repay** → use **`assets`** (the human-meaningful USDC amount the borrower asked for / is paying), `shares = 0`.
- **Full repay / full close** → use **`shares = position.borrowShares`**, `assets = 0`. Repaying by asset amount equal to the *read* debt leaves 1–2 wei of `borrowShares` after intra-block interest accrual, which then **blocks `withdrawCollateral`** and strands the position. Closing by shares is the only dust-safe full-close (S7.3.2). The bridge pre-funds the adapter with enough USDC to cover the share-implied asset amount plus a small accrual buffer; any leftover USDC is returned to the bridge.
- `supplyCollateral` / `withdrawCollateral` are **assets-only** (no share form in Morpho).

#### S7.3.2 Interest accrual & reads

`Morpho.borrow/repay/withdrawCollateral` call the IRM (S8) and accrue interest *before* applying the operation, so a state-changing call always works against fresh debt. For **views**, raw `Market.totalBorrowAssets` is stale between blocks; the adapter exposes `expectedBorrowAssets()` which calls Morpho's `accruedInterest`/`expectedMarketBalances` helper so the bridge sub-ledger and `BridgeLens` (S11) mirror the *current* aggregate debt. The bridge then attributes that aggregate per-borrower in its sub-ledger (S6) — Morpho never sees per-borrower numbers.

```solidity
function position() external view returns (uint256 supplyShares, uint256 borrowShares, uint256 collateral) {
    Position memory p = MORPHO.position(MARKET_ID, BRIDGE);
    return (p.supplyShares, p.borrowShares, p.collateral);
}
function expectedBorrowAssets() external view returns (uint256) {
    return MORPHO.expectedBorrowAssets(_params(), BRIDGE); // periphery helper; fallback: accrue-then-read
}
```

#### S7.3.3 Authorization (`setAuthorization`)

Morpho gates delegated operation through `setAuthorization(authorized, bool)` / `setAuthorizationWithSig`. In Core the bridge **is** the position owner (`onBehalf = bridge`), so the bridge does **not** need to authorize the adapter for a *different* owner — the adapter calls Morpho with `onBehalf = BRIDGE` and Morpho permits an account to operate on its own position. The one place authorization matters:

- **Morpho-side liquidation is permissionless** and needs **no** authorization from the bridge — anyone may liquidate the bridge's position when HF < LLTV (S7.4). That is the backstop and is intentionally not gated.
- If a future design routes operations through Bundler3/adapters (Optional), the bridge would `setAuthorization(bundler, true)` once. **Core does not use Bundler3** (convenience, not safety — `digest_web_crypto_lending` §Optional). The adapter exposes no generic `setAuthorization` passthrough, to avoid an operator granting a third party operating rights over the bridge's position. If ever needed it is a GOVERNOR-gated, single-purpose function — not an open passthrough.

#### Events & Errors (adapter)

```solidity
event CollateralSupplied(uint256 assets);
event CollateralWithdrawn(uint256 assets);
event Borrowed(address indexed receiver, uint256 assets, uint256 shares);
event Repaid(uint256 assets, uint256 shares);
// errors: ENotBridge, EAssetAndSharesSet, EAssetAndSharesZero, EZeroAddress
```
Adapter events are *secondary* to the authoritative `SettlementRouter` stream (S0.3 #15); they exist for venue-level reconciliation. The bridge emits the deal-level `PositionOpened`/`ReleaseVoucher` events.

#### Why Core / What breaks if omitted

**Test: Reversibility.** The `IProtocolAdapter` seam is the *only* reason Aave or a second market can be added later without rewriting and re-auditing `CollateralBridge` (D-8, S0.3 #11). **If omitted** (bridge calls `IMorpho` directly), the bridge is welded to Morpho's exact ABI, the dual-asset/share XOR and dust-safe full-close discipline are scattered through engine code, and swapping/adding a venue is a bridge rewrite — exactly the migration the Reversibility test forbids deferring. The `onlyBridge` restriction and the no-`setAuthorization`-passthrough rule are **Solvency/Liability** controls: they keep the single Morpho position operable only by the bridge.

---

### S7.4 Bridge-owns-the-position + the liquidation backstop

#### S7.4.1 One position, one debtor

Morpho tracks **one** `Position{supplyShares, borrowShares, collateral}` keyed by `(marketId, bridge)`. Triora may have **many** borrowers. Therefore:

- Morpho sees **only the bridge's aggregate**: total cBTC collateral, total USDC borrowShares.
- **Per-borrower attribution is 100% the bridge's job** (the sub-ledger, S6). Morpho cannot and must not be asked who owes what.
- Every borrow adds to the same aggregate collateral and borrowShares; every repay/withdraw subtracts. The bridge's sub-ledger invariant (S6) is that the sum of per-borrower collateral equals `position().collateral` and the sum of per-borrower debt equals `expectedBorrowAssets()` (within rounding) — this reconciliation is a monitored invariant (S0.4 O9, S12).

This is the single biggest engineering consequence of Model B and is called out as a real gap in `digest_web_crypto_lending` §Open-questions and `digest_reviews_gaps`: Morpho provides no per-borrower accounting or per-borrower liquidation attribution, so Triora builds both in the bridge.

#### S7.4.2 Two liquidation thresholds, and why AMINA always acts first

There are **two** liquidation triggers in the system, and the relationship between them is **invariant S0.9 #6**:

```
AMINA internal liquidation threshold  <  Morpho market LLTV
```

| Threshold | Operated by | Trigger | Path |
|-----------|-------------|---------|------|
| **AMINA threshold** (tighter, e.g. HF reaches 1.0 at LTV 0.80) | `LiquidationModule` (S9), **LIQUIDATOR** role | Objective oracle predicate + fixed cure window (D-7) | Orderly: bridge `repay`+`withdrawCollateral`, BTC → AMINA desk, surplus → borrower (S0.9 #7) |
| **Morpho LLTV** (looser, e.g. 0.86) | **Anyone** (permissionless) | HF < 1 on Morpho's own math | Backstop only: Morpho seizes cBTC for repaid USDC |

Because AMINA's threshold is **strictly tighter**, as a position deteriorates it crosses **AMINA's** line **first**. AMINA gets the cure window and the orderly custody-redemption path while Morpho still considers the position healthy. The Morpho permissionless liquidation only ever fires if **AMINA is unavailable** long enough for the position to deteriorate all the way to the looser LLTV — the last-resort liveness backstop (`Triora-Core-vs-Optional-3.md` D-4, §7.2). This removes the AMINA-only single-point-of-failure (bad debt sitting unliquidated) while keeping AMINA in control of the normal path.

**Enforcement of the invariant.** The AMINA threshold lives in `RiskConfig` (S0.3 #16). On every `CURATOR`/`GUARDIAN` write of the AMINA threshold, `RiskConfig` reverts if `aminaThresholdLtv >= MorphoAdapter.lltv()` (read live from the immutable adapter). Since `lltv` is immutable, the check is one-sided and cannot be defeated by later loosening Morpho. Monitoring (S0.4 O9) alerts if the *effective* margin between the two shrinks below a configured buffer.

#### S7.4.3 LIF / seized-collateral math (for understanding the backstop)

When Morpho's permissionless backstop fires, the liquidator repays USDC debt and seizes cBTC at a bonus given by the **Liquidation Incentive Factor**:

```
LIF = min( M , 1 / ( β·LLTV + (1 − β) ) )       with  β = 0.30 ,  M = 1.15
Seized Collateral (value) = Repaid Debt (value) × LIF
```

Worked example for an `lltv = 0.86`:
```
β·LLTV + (1−β) = 0.30·0.86 + 0.70 = 0.958
1 / 0.958      = 1.0438
LIF            = min(1.15, 1.0438) = 1.0438   → ~4.4% bonus
```
So a backstop liquidation of, say, 50,000 USDC of debt seizes ~52,190 USDC-worth of cBTC. **Triora does not implement this math** — it is Morpho's, used here only to *understand* the backstop's cost and to size the gap between AMINA's threshold and LLTV: AMINA's orderly path (with its own bonus+fee, defined in S9) must remain economically reachable *before* the position decays into the more expensive Morpho LIF zone. The spread between AMINA's threshold and `lltv` is exactly the room AMINA has to act before the permissionless backstop becomes profitable to outsiders.

Bad debt on the backstop path (if cBTC value < debt) is socialized on Morpho via supply-share depreciation among that market's lenders — a further reason the AMINA-first path (which books shortfall off-chain to AMINA, state `Defaulted`, S0.8) is the intended one.

#### Why Core / What breaks if omitted

**Test: Solvency (liveness) + Liability.** The bridge-owns-position pattern is what lets Triora reuse Morpho's audited engine at all; the sub-ledger is what makes per-borrower lending possible on top of a single aggregate position. The tighter-AMINA-threshold + Morpho-backstop arrangement is what makes liquidation **both** controlled (AMINA-first, orderly, surplus-to-borrower) **and** live (backstopped if AMINA is down). **If omitted:** AMINA-only liquidation has no backstop (bad debt sits unliquidated when the bot is down); or, without the tighter threshold, an outsider could liquidate on Morpho before AMINA, stripping AMINA of the orderly custody redemption and the borrower of surplus.

---

### S7.5 Oracle scale (1e36) and price-feed wiring

Morpho prices collateral with a **fixed 36-decimal convention**. The market `oracle` (Triora's `OracleAdapter`, S0.3 #8) must return:

```
price = (USDC per 1 cBTC) scaled so that:
  collateralValueInLoan = collateral × price / 1e36
```

The scale already absorbs the asset-decimal difference. With cBTC = 8 dp and USDC = 6 dp, the canonical Morpho oracle scale for this pair is:

```
SCALE = 1e36 × 10^(loanDecimals)      / 10^(collateralDecimals)
      = 1e36 × 10^6  / 10^8           (collapsed into the 1e36 convention)
```

Concretely, `OracleAdapter.price()` composes the Chainlink BTC/USD feed (8-dp answer) into the 1e36 frame:

```solidity
// OracleAdapter (S0.3 #8) — Morpho IOracle: returns price at 1e36 base.
function price() external view returns (uint256) {
    (, int256 answer,, uint256 updatedAt, uint80 roundId) = BTC_USD.latestRoundData();
    if (answer <= 0) revert EBadPrice();                 // reject non-positive
    if (block.timestamp - updatedAt > MAX_AGE) revert EStalePrice();
    // answeredInRound / round completeness checks per S(oracle section).
    uint256 btcUsd = uint256(answer);                    // 8-dp USD per BTC
    // Compose into Morpho 1e36 frame, normalizing cBTC(8) -> USDC(6):
    //   1 cBTC = 1 BTC (1:1 peg, enforced below) priced at btcUsd USD.
    //   target: USDC(6) value of 1e8 cBTC base units, scaled by 1e36 / 1e8.
    uint256 p = Math.mulDiv(btcUsd, ORACLE_SCALE_NUM, ORACLE_SCALE_DEN);
    // PEG CAP (S0.9 spirit): never value cBTC above its attested reserve backing.
    return Math.min(p, _attestedBackedPrice());
}
```

Two Triora-specific guards layered on top of the raw feed (these are `OracleAdapter`'s job, restated here because they bound what the *market* will value):
1. **Staleness / non-positive / round-completeness** rejection — fail-closed (a stale or zero feed must not let the market over-value collateral).
2. **Peg sanity cap** — cBTC is valued at `min(market price, attested-reserve-implied value)`, so a depeg or a feed glitch can never let the market price cBTC above the BTC actually attested in custody (`Triora-Core-vs-Optional-3.md` C-13). This keeps the market's collateral valuation consistent with the on-chain backing the rest of the spine enforces (S0.9 #1).

**Wiring:** the `OracleAdapter` address is one of the 5 immutable `MarketParams`. It is chosen by **CURATOR** at curation time (S7.1.1) and, because the market is immutable, can only be *replaced* by curating a new market and migrating. Emergency mis-pricing is handled by the `EMERGENCY` oracle-override sidecar (S0.6) which is delayed and never mutates terms — it cannot silently re-point the live market's oracle.

#### Why Core / What breaks if omitted

**Test: Solvency.** The 1e36 wiring is what makes Morpho value the collateral correctly; the staleness + peg-cap guards are what stop a stale or depegged feed from letting the bridge over-borrow against cBTC that isn't really there. **If omitted:** wrong scaling silently mis-sizes every borrow and liquidation; without the peg cap, a feed glitch lets cBTC be valued above its real BTC backing and the 1:1 invariant (S0.9 #1) is breached at the borrowing layer even though the mint layer held.

---

### S7.6 Reversibility — adding Aave (or a second market) later

The whole point of `IProtocolAdapter` is that the venue is swappable/extensible **without touching the bridge or re-auditing the spine** (D-8, S0.3 #11):

- **Add Aave:** write `AaveAdapter is IProtocolAdapter` mapping `supplyCollateral→supply`, `borrow→borrow`, `repay→repay`, `withdrawCollateral→withdraw`, `position()→getUserAccountData/reserve reads`. Aave is **pooled and mutable** (not isolated/immutable like Morpho), so the AMINA-threshold-< -venue-liquidation-threshold invariant (S7.4.2) must be re-expressed against Aave's liquidation threshold, and the oracle frame re-expressed for Aave's 8-dp base — both confined to the new adapter and its `RiskConfig` entry. Bridge logic is unchanged.
- **Add a second Morpho market** (e.g., different LLTV tier): deploy a second `MorphoAdapter` with the new `MarketParams`; register it in `RiskConfig`; GOVERNOR wires it. Positions remain version-pinned (S0.9 #9).
- **Add a MetaMorpho curated vault** for lender supply (Optional, §3.2): that changes only *where supply comes from*, not how the bridge borrows — no adapter change at all.

Because the bridge depends only on the interface, none of these forces a migration of the immutable spine (token, pledge registry, reserve guard, vouchers, router). That is the Reversibility test passing by construction.

#### Why Core / What breaks if omitted

**Test: Reversibility.** Shipping the adapter interface now (even with exactly one implementation) is cheap and makes every future venue a non-breaking addition. **If omitted**, adding Aave later forces a bridge rewrite and a re-audit of the most sensitive engine code — precisely the "later addition is a migration → build the boundary now" case the Reversibility test classifies as Core.

---

### S7.7 Section summary — signatures, events, errors, invariants

**External functions (`MorphoAdapter`, all state-changing are `onlyBridge`):**
`supplyCollateral(uint256)` · `withdrawCollateral(uint256)` · `borrow(uint256,uint256,address,address)→(uint256,uint256)` · `repay(uint256,uint256,address)→(uint256,uint256)` · views `position()` · `expectedBorrowAssets()` · `marketId()` · `loanToken()` · `collateralToken()` · `oracle()` · `lltv()`.

**Events:** `CollateralSupplied`, `CollateralWithdrawn`, `Borrowed`, `Repaid` (venue-level reconciliation; authoritative stream is `SettlementRouter`, S0.3 #15).

**Errors:** `ENotBridge`, `EAssetAndSharesSet`, `EAssetAndSharesZero`, `EZeroAddress`; bridge-surfaced `EBorrowNoLiquidity`.

**External dependencies:** `IMorpho` (Morpho Blue, immutable), USDC, cBTC (S5), `OracleAdapter` (S0.3 #8), `FixedRateIRM` (S8), `RiskConfig` (S0.3 #16). Consumed by `CollateralBridge` (S6) and `LiquidationModule` (S9); read by `BridgeLens` (S11).

**Invariants upheld by S7:**
- S0.9 #4 — a position is `Active` iff `borrow` succeeded and USDC reached the borrower (`receiver`); no debt/interest booked on a failed/no-liquidity borrow.
- S0.9 #6 — `aminaThresholdLtv < MorphoAdapter.lltv()`, enforced on every threshold write against the immutable LLTV.
- S0.9 #3 — cBTC moves only on protocol paths: the only cBTC transfers S7 causes are bridge↔Morpho via the adapter.
- Aggregate reconciliation — `Σ sub-ledger collateral = position().collateral` and `Σ sub-ledger debt ≈ expectedBorrowAssets()` (monitored, S12).
- Dual asset/share XOR enforced on every `borrow`/`repay`; full-close is share-denominated (dust-safe).


## S8. Liquidation, Release Vouchers & Settlement Events

This section specifies the **safety valve** of Triora Core: the path by which a position
that breaches AMINA's risk threshold (or reaches maturity) is wound down, the BTC is
moved out of custody **only to the destination the deal state dictates**, and every
instruction is emitted on an authenticated, gap-detectable stream the off-chain custody
operators act on. It covers four contracts and one atomic bridge flow:

1. **`LiquidationModule`** (L4, UUPS+TL, `LIQUIDATOR`-only) — objective, oracle-gated,
   two-report, fixed-cure-window liquidation that drives the bridge.
2. **`ReleaseAuthorizer`** (L4, UUPS+TL) — state-derived, one-use release vouchers.
3. **`SettlementRouter`** (L4, immutable, versioned) — the append-only, monotonic-sequence
   event catalog consumed by off-chain ops (O6 custody listener).
4. **`CollateralBridge.liquidateWithdrawAndBurn`** (the atomic Flow-3 wind-down).

All four uphold the S0.9 invariants — especially **#5** (release destination derived from
state, one-use vouchers), **#6** (AMINA threshold strictly tighter than Morpho LLTV),
**#7** (surplus → borrower), **#8** (privilege separation), and **#10** (every off-chain
custody movement = exactly one consumed voucher + AMINA co-sign). The objective-trigger
design directly implements S0.2 **D-7** and the `Triora-liquidation-ADR.md` ruling:
*"AMINA may operate liquidation, but AMINA must not be trusted to determine eligibility."*

Cross-references: oracle reads and decimal normalization → **S6** (`OracleAdapter`); the
Morpho position, sub-ledger, and `borrow`/`repay`/`withdraw` mechanics → the
`CollateralBridge` section; pledge encumbrance/release lifecycle → the `PledgeRegistry`
section; cBTC `burnForRelease` → the token section; roles → S0.6; lifecycle/state machine
→ S0.7 / S0.8.

---

### S8.0 Shared types (library `Types`, typehashes in `EIP712Hashes`)

These structs are referenced by all four components and by the off-chain services (O6, O8).

```solidity
// ---- Oracle liquidation evidence (signed off-chain by an oracle/Chainlink key) ----
struct LiquidationReport {
    bytes32 dealId;              // = positionId; binds report to one position
    bytes32 positionId;          // explicit echo for off-chain matching (== dealId)
    bytes32 legalTermsHash;      // pins the report to the immutable PositionRegistry terms
    uint256 collateralValue;     // USD, 1e18-scaled (decimals normalized per S6)
    uint256 debtValue;           // USD, 1e18-scaled (principal + accrued, from sub-ledger)
    uint32  thresholdBps;        // AMINA liquidation threshold, basis points (< Morpho LLTV)
    uint64  observedAt;          // when the price/health was observed (oracle clock)
    uint64  expiresAt;           // report TTL; finalize/request must run before this
    bytes32 reportRef;           // unique id of THIS report (two-report distinctness)
    // signature carried alongside as (bytes signature); signer recovered on-chain
}

// ---- State-derived custody release authority (one-use) ----
enum DestinationType   { Borrower, AminaDesk }
enum ReleaseReason     { REPAID, LIQUIDATED, SURPLUS }

struct ReleaseVoucher {
    bytes32         dealId;
    bytes32         pledgeId;
    address         asset;           // cBTC token address (8 dec)
    uint256         amount;          // cBTC units (sats) authorized to release
    DestinationType destinationType; // DERIVED from state, never caller-supplied (S0.9 #5)
    bytes32         destinationRef;  // borrower custody ref OR AMINA desk ref (from state)
    ReleaseReason   reason;
    uint64          sequenceNumber;  // monotonic, anti-replay
    uint64          issuedAt;
    uint64          expiresAt;       // TTL (voucherTtl)
    bool            consumed;        // one-use flag
}
```

`thresholdBps` is carried **in the report** but is verified on-chain against the
position's version-pinned `RiskConfig` value (see S8.1 STEP 4) — the report cannot relax
the threshold below what AMINA configured, and the on-chain comparison against the Morpho
market LLTV (S0.9 #6) is enforced at `RiskConfig` write time, not here.

---

### S8.1 `LiquidationModule` (L4, UUPS behind timelock, `LIQUIDATOR`-only)

#### Purpose

Make liquidation **eligibility objective** (a signed oracle predicate, never AMINA
discretion), **borrower-protective** (a fixed, non-per-deal-configurable cure window),
and **double-checked** (two distinct fresh reports straddling the cure window). The module
holds no funds; it validates evidence, runs the cure clock, and on finalization calls
`CollateralBridge.liquidateWithdrawAndBurn` (S8.4) which performs the atomic wind-down.
Full-only liquidation in Core; partial liquidation is Optional (S0 / `Triora-Core-vs-Optional-3.md` §3.1).

#### Storage (ERC-7201 namespaced)

```solidity
/// @custom:storage-location erc7201:triora.storage.LiquidationModule
struct LiquidationStorage {
    ICollateralBridge   bridge;            // the engine it drives
    IPositionRegistry   positions;         // write-once terms (legalTermsHash, maturity)
    IRiskConfig         risk;              // version-pinned thresholds per position
    IOracleAdapter      oracle;            // S6: not read for the trigger, used for warn() context
    address             reportSigner;      // oracle/Chainlink key authorized to sign reports
    uint64              cureWindow;         // FIXED constant mirror (e.g. 24-48h); NOT per-deal
    mapping(bytes32 => Pending) pending;   // positionId => pending liquidation
    mapping(bytes32 => uint64)  warnedAt;  // positionId => warn timestamp (cure clock start)
    mapping(bytes32 => bool)    reportRefUsed; // global: a reportRef can anchor only one action
    mapping(address => DailyCap) liqDaily; // per-LIQUIDATOR-wallet daily cap (S0.6 constraint)
}

struct Pending {
    bytes32 initialReportRef;  // the request-time report id (must differ at finalize)
    uint64  requestedAt;
    uint64  cureDeadline;      // requestedAt + cureWindow
    uint8   priorState;        // PositionState to restore on cancel (Active or Warned)
    bool    active;
}
```

> **`cureWindow` is a constant, not per-deal.** Per the liquidation ADR, a per-deal cure
> window is a misconfiguration footgun (0 removes borrower protection; long delays harm
> lenders). The window is a single protocol constant changeable only by `CURATOR` through
> the timelock, and it applies uniformly to every position. The module exposes it read-only
> (`cureWindow()`) for the UI countdown (S0.5 F5 / the lifecycle frontend section).

#### External functions

```solidity
// --- Warning (starts the cure clock; no liquidation effect) ---
function warn(bytes32 positionId, LiquidationReport calldata r, bytes calldata sig)
    external;                               // role: LIQUIDATOR

// --- Request: HF/threshold breach OR maturity; begins the fixed cure window ---
function requestLiquidation(bytes32 positionId, LiquidationReport calldata r, bytes calldata sig)
    external;                               // role: LIQUIDATOR

// --- Finalize: requires a SECOND distinct fresh report after the cure deadline ---
function finalizeLiquidation(bytes32 positionId, LiquidationReport calldata fresh, bytes calldata sig, bytes32 settlementRef)
    external;                               // role: LIQUIDATOR

// --- Permissionless escape hatch after the window if AMINA never finalized ---
function cancelPendingLiquidation(bytes32 positionId, bytes32 reasonRef)
    external;                               // NO role: anyone, only after cureDeadline

// --- Views ---
function cureWindow() external view returns (uint64);
function pendingOf(bytes32 positionId) external view returns (Pending memory);
function hashLiquidationReport(LiquidationReport calldata r) external view returns (bytes32);
```

##### `warn(positionId, r, sig)` — `LIQUIDATOR`

Marks a position `Warned`, starting the cure clock and surfacing the margin-call UI. It is
**not** a precondition for `requestLiquidation` (a sudden gap-down can go straight to
request), but it is the normal first step.

Checks, in order (fail-closed):
1. `_verifyReport(positionId, r, sig)` (see below) — same objective predicate as request,
   but the threshold compared is the **AMINA warning threshold** (`risk.warningBps(version)`),
   not the liquidation threshold: revert `NotWarnable()` if
   `mulDiv(r.debtValue, 10_000, r.collateralValue) < warningBps`.
2. Position is `Active` (revert `WrongState` otherwise).
3. Set `warnedAt[positionId] = block.timestamp`; transition `Active → Warned`
   (via `bridge.setWarned(positionId)` — bridge owns the state machine).
4. `SettlementRouter.emitLiquidationInstruction(... reason=WARN ...)` is **not** emitted
   here; `warn` emits a dedicated `PositionWarned` through the router (see S8.3 catalog note)
   and a contract-level `Warned` event. No custody movement results from a warning.

A position returns `Warned → Active` only through the bridge's cure path (borrower
`topUpCollateral` or repayment bringing HF back above warning); `LiquidationModule` does
not own that transition.

##### `requestLiquidation(positionId, r, sig)` — `LIQUIDATOR`

Opens the cure window. Eligibility is **objective**: either a proven health/threshold
breach, or maturity. AMINA cannot request a healthy, unmatured position.

Checks (fail-closed, in order):
1. `require(!s.pending[positionId].active, LiquidationAlreadyPending())`.
2. `_verifyReport(positionId, r, sig)` — full report validation (S8.1 STEP 4).
3. **Eligibility predicate** — at least ONE must hold:
   - *Threshold breach*: `mulDiv(r.debtValue, 10_000, r.collateralValue) >= effectiveThresholdBps`
     where `effectiveThresholdBps = risk.liquidationThresholdBps(version)` (version pinned
     to the position; S0.9 #9). If neither holds → revert `Healthy()`.
   - *Maturity*: `block.timestamp >= positions.maturity(positionId)`.
4. Per-wallet daily cap: `_chargeDailyCap(msg.sender)` (S0.6 LIQUIDATOR constraint) — revert
   `DailyCapExceeded()`.
5. Snapshot prior state (`Active` or `Warned`) into `Pending.priorState`; set
   `pending[positionId] = Pending(r.reportRef, now, now + cureWindow, priorState, true)`;
   mark `reportRefUsed[r.reportRef] = true`.
6. Transition position → `LiquidationPending` (via `bridge.markLiquidationPending(positionId)`).
7. `SettlementRouter.emitLiquidationInstruction(positionId, reason=REQUEST, r.reportRef, cureDeadline)`.

> **No funds move at request.** Request only starts a clock and changes state. The BTC
> stays in custody, the Morpho position untouched. This is the borrower's cure opportunity.

##### `finalizeLiquidation(positionId, fresh, sig, settlementRef)` — `LIQUIDATOR`

Executes the wind-down **only** after the cure window elapsed and a *second, distinct,
fresh* report still proves the breach (proving the borrower did not cure).

Checks (fail-closed, in order):
1. `Pending p = s.pending[positionId]; require(p.active, NoPendingLiquidation())`.
2. `require(block.timestamp >= p.cureDeadline, CureWindowActive())` — cannot finalize early.
3. **Second-report distinctness**: `require(fresh.reportRef != p.initialReportRef, ReportReused())`
   and `require(!reportRefUsed[fresh.reportRef], ReportReused())`.
4. **Post-cure observation**: `require(fresh.observedAt >= p.cureDeadline, StaleSecondReport())`
   — the fresh report must observe the world *after* the cure deadline, so it genuinely
   proves the cure failed (cannot reuse a pre-window observation).
5. `_verifyReport(positionId, fresh, sig)` — full validation of the second report.
6. **Eligibility still holds**: `mulDiv(fresh.debtValue, 10_000, fresh.collateralValue) >= effectiveThresholdBps`
   OR `block.timestamp >= positions.maturity(positionId)` (a position can also be cured of a
   price breach but still finalize because it matured). If neither → the position cured;
   revert `CuredNoLongerEligible()` (the LIQUIDATOR should instead let it return to Active /
   call `cancelPendingLiquidation`).
7. `reportRefUsed[fresh.reportRef] = true`; clear `pending[positionId]`.
8. **Drive the atomic wind-down** (S8.4):
   `bridge.liquidateWithdrawAndBurn(positionId, fresh.debtValue, settlementRef)`.
   This single call (a) removes the per-borrower commitment from the sub-ledger, (b) repays
   the Morpho debt for this borrower's slice with settled proceeds, (c) withdraws the cBTC
   from the Morpho position, (d) issues the liquidation release voucher (dest = AMINA desk),
   (e) burns the cBTC. Any failed step reverts the whole call (atomicity, S0.9 spine).
9. The bridge, inside that call, computes surplus and routes it to the borrower (S8.1 STEP 5
   surplus math is *applied* by the bridge; the module supplies `debtValue`).

> **Why a second distinct report and a post-cure observation?** A single report at request
> time proves the position *was* breaching; it does not prove the borrower *failed to cure*.
> Requiring a second report whose `observedAt >= cureDeadline` makes "cure failed" an
> on-chain fact, not an operator assertion. `reportRef` distinctness blocks replaying the
> first report to satisfy the second check.

##### `cancelPendingLiquidation(positionId, reasonRef)` — permissionless

The liveness escape hatch. If AMINA opens a liquidation but never finalizes (operator
outage, the borrower cured, the price recovered), **anyone** may cancel after the window so
the position is not stuck in `LiquidationPending` forever.

Checks:
1. `Pending p = s.pending[positionId]; require(p.active, NoPendingLiquidation())`.
2. `require(block.timestamp >= p.cureDeadline, LiquidationDelayLive())` — cannot cancel
   *during* the window (that would let anyone grief AMINA's in-progress liquidation).
3. Clear `pending[positionId]`; restore the position to `p.priorState`
   (`Active` or `Warned`) via the bridge.
4. `SettlementRouter.emitLiquidationInstruction(positionId, reason=CANCEL, reasonRef, 0)`.

> **Deliberately unauthenticated.** This is the same decision as the prior
> `TrioraLendingSimple.cancelPendingLiquidation`: it can only *restore* a non-terminal
> state after the window, never seize anything, so opening it to the public removes
> AMINA's liveness single-point-of-failure without granting power.

##### STEP 4 — `_verifyReport(positionId, r, sig)` (internal, used by warn/request/finalize)

Every report passes this gate before any state change. All checks fail-closed:

```text
1. signer = ECDSA.recover(_hashTyped(r), sig);  require(signer == s.reportSigner)   // OracleKey
2. require(r.dealId == positionId && r.positionId == positionId)                    // bound to THIS position
3. require(r.legalTermsHash == positions.legalTermsHash(positionId))                // pinned to immutable terms
4. require(r.observedAt <= block.timestamp)                                         // not future-dated
5. require(r.expiresAt  >  block.timestamp)                                         // not expired
6. require(r.collateralValue > 0 && r.debtValue > 0)                                // no div-by-zero / null report
7. require(r.thresholdBps > 0 && r.thresholdBps <= 10_000)                          // sane threshold
8. require(r.thresholdBps == risk.liquidationThresholdBps(version))                 // report cannot relax AMINA's bps
```

The report carries USD values already decimal-normalized (cBTC 8 dec, USDC 6 dec → 1e18
USD per **S6** `OracleAdapter` and `Math`); the module does no cross-asset math itself
beyond the bps ratio. The Morpho-LLTV-vs-AMINA-threshold ordering (S0.9 #6) is enforced
where `risk.liquidationThresholdBps` is *set* (the `RiskConfig` section asserts
`liquidationThresholdBps < morphoMarketLltvBps`), so by reading the pinned config here the
module inherits that guarantee.

#### STEP 5 — Surplus math (applied by the bridge, specified here)

On finalization the bridge computes how much collateral AMINA's desk needs to cover the
debt, the liquidation bonus, and the AMINA fee, and returns the remainder to the borrower
(S0.9 #7). All amounts normalize decimals explicitly (cBTC=8, USDC=6, prices 1e18):

```text
Let:
  debt          = fresh.debtValue                         (USD 1e18, principal + accrued)
  bonusBps      = risk.liquidationBonusBps(version)       (<= 2000)
  feeBps        = risk.aminaFeeBps(version)               (<= 2000)
  collateralPx  = OracleAdapter price of 1 cBTC in USD    (1e18 per S6, value-capped at attested reserve)
  collateral    = position cBTC units (8 dec)

  grossOwedUSD  = debt + debt * bonusBps / 10_000 + debt * feeBps / 10_000

  // cBTC units the AMINA desk must take to cover grossOwedUSD:
  amountToAmina = ceilDiv( grossOwedUSD * 1e8 , collateralPx )      // -> cBTC units (8 dec), round UP

  // remainder belongs to the borrower (S0.9 #7):
  surplusToBorrower = collateral - amountToAmina                    // cBTC units (8 dec)

  require(amountToAmina <= collateral, InsufficientCollateral())     // else Defaulted path (S0.8)
```

If `amountToAmina > collateral` (proceeds cannot cover debt+bonus+fee), the position
terminates `Defaulted` (S0.8): the desk takes the entire collateral, the bridge books the
shortfall off-chain to AMINA (`SettlementRouter.emitReserveShortfall`), and **no** surplus
voucher is issued. Otherwise the bridge issues **two** vouchers via `ReleaseAuthorizer`:
one `LIQUIDATED` voucher for `amountToAmina` (dest = AMINA desk) and, when
`surplusToBorrower > 0`, one `SURPLUS` voucher for `surplusToBorrower` (dest = borrower).
The desk sells the BTC off-chain, repays the Morpho lender, takes bonus+fee, and the
surplus BTC reaches the borrower under its own state-derived voucher — surplus is never
governance-seizable.

> Rounding is borrower-protective at the *threshold* (request/finalize use the report's
> exact bps) but desk-protective at *settlement* (`ceilDiv` on `amountToAmina` ensures the
> desk is never short by a sub-unit). The surplus the borrower receives is the floor of the
> remainder — the one-sat rounding favors solvency, consistent with the spine's
> conservative-rounding rule.

#### Events

```solidity
event Warned(bytes32 indexed positionId, bytes32 reportRef, uint64 warnedAt);
event LiquidationRequested(bytes32 indexed positionId, bytes32 reportRef, uint64 cureDeadline);
event LiquidationFinalized(bytes32 indexed positionId, bytes32 reportRef, uint256 amountToAmina, uint256 surplusToBorrower, bytes32 settlementRef);
event LiquidationCancelled(bytes32 indexed positionId, bytes32 reasonRef, address caller);
```

#### Errors

```solidity
error NotLiquidator(); error WrongState(); error NotWarnable(); error Healthy();
error LiquidationAlreadyPending(); error NoPendingLiquidation(); error CureWindowActive();
error LiquidationDelayLive(); error ReportReused(); error StaleSecondReport();
error CuredNoLongerEligible(); error BadSigner(); error ReportExpired(); error FutureReport();
error TermsMismatch(); error ThresholdMismatch(); error NullReport(); error DailyCapExceeded();
error InsufficientCollateral();
```

#### Invariants upheld

- **S0.9 #6**: AMINA threshold `<` Morpho LLTV — inherited by reading the version-pinned
  `RiskConfig.liquidationThresholdBps`, whose setter enforces `< morphoMarketLltvBps`.
- **S0.9 #7**: surplus → borrower — STEP 5 routes `surplusToBorrower` via a `SURPLUS`
  voucher to the borrower; the desk takes only `debt + bonus + fee`.
- **S0.9 #9**: the report is pinned to `legalTermsHash` and thresholds to the position's
  version; terms cannot be mutated to manufacture eligibility.
- **D-7 / liquidation ADR**: eligibility is an objective signed predicate, never AMINA
  discretion; a fixed (non-per-deal) cure window; two distinct fresh reports straddling the
  window; permissionless post-window cancel.

#### External dependencies

`CollateralBridge` (state transitions + atomic wind-down), `PositionRegistry` (immutable
terms, maturity), `RiskConfig`/`ParameterArchive` (version-pinned thresholds, bonus, fee),
`OracleAdapter` (S6, for the warn-context price; the *trigger* is the signed report, not a
live read), `RoleManager` (`LIQUIDATOR` gate), `SettlementRouter` (instruction emission),
the off-chain oracle/Chainlink report signer (`reportSigner`).

#### Why Core / What breaks if omitted

**Test passed: Liability + Solvency-liveness.** This is C-14 + C-15 + C-17 of
`Triora-Core-vs-Optional-3.md`. Without an *objective* trigger, AMINA — an interested party
— can liquidate at will (interested-party abuse) or be credibly accused of it, which is the
exact regulatory/reputational exposure the FINMA-licensed broker role must avoid. Without
the **fixed cure window** the borrower has no protected opportunity to top up (loss of
borrower protection). Without the **second post-cure report** "the borrower failed to cure"
is an operator assertion, not an on-chain fact. Without **permissionless cancel** a stuck
liquidation freezes the position when the AMINA bot is down (liveness SPOF). Without
**surplus-to-borrower** AMINA commits conversion of the borrower's over-collateralization
(legal liability). Cutting this module makes liquidation either discretionary, impossible,
or unfair — any of which breaks the regulated-lending premise.

---

### S8.2 `ReleaseAuthorizer` (L4, UUPS behind timelock)

#### Purpose

Convert a terminal/near-terminal on-chain deal state into a **single, verifiable authority**
to move BTC out of custody, with the **destination derived from state, never from the
caller** (S0.9 #5, D-6). It is the only thing in Core that can authorize a real custody
movement; the off-chain custody listener (O6) refuses to move anything without a matching,
unconsumed voucher *and* AMINA's co-signature (S0.9 #10). Vouchers are one-use and
TTL-bounded.

#### Storage (ERC-7201 namespaced)

```solidity
/// @custom:storage-location erc7201:triora.storage.ReleaseAuthorizer
struct ReleaseAuthorizerStorage {
    ICollateralBridge   bridge;          // caller authority (issue paths gated to bridge)
    IPositionRegistry   positions;       // to read borrower custody ref (state-derived dest)
    IPledgeRegistry     pledges;         // to read pledge<->custody binding
    address             aminaDeskRef;    // AMINA liquidation-desk destination (config, CURATOR+TL)
    uint64              voucherTtl;      // e.g. 7 days
    uint64              seq;             // monotonic voucher sequence (anti-replay)
    mapping(bytes32 => ReleaseVoucher) vouchers;     // voucherId => voucher
    mapping(bytes32 => bool)           consumed;     // voucherId => one-use guard
}
```

#### External functions

```solidity
// --- Issue (bridge-only); destination DERIVED FROM STATE, not passed in ---
function issueRepaymentRelease(bytes32 dealId)
    external returns (bytes32 voucherId);    // requires position Repaid/RepaymentPending->release; dest = Borrower

function issueLiquidationRelease(bytes32 dealId, uint256 amount)
    external returns (bytes32 voucherId);    // requires position LiquidationPending; dest = AminaDesk

function issueSurplusRelease(bytes32 dealId, uint256 surplusAmount)
    external returns (bytes32 voucherId);    // requires LiquidationPending; dest = Borrower; reason = SURPLUS

// --- Consume (one-use); called on custody ack ---
function consumeVoucher(bytes32 voucherId, bytes32 ackRef)
    external;                                 // role: bridge or SettlementAcker path

// --- Views ---
function isVoucherValid(bytes32 voucherId) external view returns (bool);
function getVoucher(bytes32 voucherId) external view returns (ReleaseVoucher memory);
```

##### Destination is derived, not supplied

The three issue functions **compute** `(destinationType, destinationRef)` from on-chain
state; no caller — not even AMINA — passes a destination:

| Issue function | Required position state | `destinationType` | `destinationRef` source | `reason` |
|----------------|------------------------|-------------------|-------------------------|----------|
| `issueRepaymentRelease` | repayment confirmed (S0.8 ReleasePending) | `Borrower` | `positions.borrowerCustodyRef(dealId)` | `REPAID` |
| `issueLiquidationRelease` | `LiquidationPending` | `AminaDesk` | `s.aminaDeskRef` (config) | `LIQUIDATED` |
| `issueSurplusRelease` | `LiquidationPending` | `Borrower` | `positions.borrowerCustodyRef(dealId)` | `SURPLUS` |

`_issue` builds the voucher deterministically and stores it:

```solidity
function _issue(
    bytes32 dealId, bytes32 pledgeId, address asset, uint256 amount,
    DestinationType dt, bytes32 destRef, ReleaseReason reason
) internal returns (bytes32 voucherId) {
    uint64 sn = ++s.seq;
    voucherId = keccak256(abi.encode(
        block.chainid, address(this), dealId, pledgeId, asset, amount, dt, destRef, reason, sn
    ));
    s.vouchers[voucherId] = ReleaseVoucher({
        dealId: dealId, pledgeId: pledgeId, asset: asset, amount: amount,
        destinationType: dt, destinationRef: destRef, reason: reason,
        sequenceNumber: sn, issuedAt: uint64(block.timestamp),
        expiresAt: uint64(block.timestamp) + s.voucherTtl, consumed: false
    });
    SettlementRouter.emitReleaseVoucher(voucherId, dealId, pledgeId, asset, amount, dt, destRef, reason, sn);
}
```

**Access:** all `issue*` functions are gated to `bridge` (the engine is the only legitimate
caller; it calls them inside `repayWithdrawAndBurn` / `liquidateWithdrawAndBurn` after the
state transition is committed). This keeps the privilege chain: only the engine, only after
state advances, can request a voucher; and the engine cannot choose where the asset goes.

##### `consumeVoucher(voucherId, ackRef)` — one-use

Called when the off-chain custody listener acknowledges the movement (S8.3
`ReleaseAcknowledged`). Marks the voucher spent so it can never authorize a second
movement:

```text
1. ReleaseVoucher v = s.vouchers[voucherId]; require(v.issuedAt != 0, UnknownVoucher())
2. require(!s.consumed[voucherId], VoucherAlreadyConsumed())     // one-use (S0.9 #5)
3. require(block.timestamp <= v.expiresAt, VoucherExpired())     // TTL
4. s.consumed[voucherId] = true; s.vouchers[voucherId].consumed = true
5. emit VoucherConsumed(voucherId, ackRef)
```

`isVoucherValid` returns `issuedAt != 0 && !consumed && now <= expiresAt`.

> **TTL + one-use together.** The TTL bounds how long an authorization lingers if the
> listener is slow or the movement is abandoned; one-use blocks replay. An expired voucher
> is dead — the bridge must re-issue (e.g. via the repayment recovery path) rather than
> resurrect it.

#### Events

```solidity
event RepaymentReleaseIssued(bytes32 indexed voucherId, bytes32 indexed dealId, uint256 amount);
event LiquidationReleaseIssued(bytes32 indexed voucherId, bytes32 indexed dealId, uint256 amount);
event SurplusReleaseIssued(bytes32 indexed voucherId, bytes32 indexed dealId, uint256 amount);
event VoucherConsumed(bytes32 indexed voucherId, bytes32 ackRef);
```

#### Errors

```solidity
error NotBridge(); error WrongStateForRelease(); error UnknownVoucher();
error VoucherAlreadyConsumed(); error VoucherExpired(); error ZeroAmount();
```

#### Invariants upheld

- **S0.9 #5**: destination is derived from state (Repaid→borrower, Liquidated→AMINA desk,
  Surplus→borrower); caller cannot supply it; each voucher is one-use (`consumed` guard +
  `keccak` id including `sequenceNumber`).
- **S0.9 #10**: a custody movement requires exactly one voucher; the off-chain listener
  (O6) additionally requires AMINA co-sign, so issuance alone never moves the asset.
- Surplus voucher (`SURPLUS`, dest=Borrower) makes S0.9 #7 enforceable end-to-end.

#### External dependencies

`CollateralBridge` (sole issuer), `PositionRegistry` (borrower custody ref — the
state-derived destination), `PledgeRegistry` (pledge↔custody binding), `SettlementRouter`
(voucher emission + consume ack), `RoleManager` (config setters for `aminaDeskRef`,
`voucherTtl` under timelock).

#### Why Core / What breaks if omitted

**Test passed: Solvency + Liability.** This is C-16. Without state-derived vouchers, an
operator (or a compromised operator key) can redirect released collateral to an arbitrary
destination, or a repaid borrower can be denied their asset. The voucher mechanism removes
the redirect power *even from AMINA* on the repayment path (destination is mechanically the
borrower) and removes the *withhold* power (the voucher is auto-derivable once the deal is
Repaid), giving both safety and liveness. Omitting it collapses the "asset moves only where
state dictates" guarantee — the central promise of the custody design. It is far cheaper to
include now than to retrofit into a live mint/release path (a re-audit of the most
sensitive code).

---

### S8.3 `SettlementRouter` (L4, immutable, versioned)

#### Purpose

The single **authenticated, append-only, gap-detectable** instruction/voucher event stream
that the off-chain custody and ops services consume (O6 listener, O8 liquidation bot, O3
indexer, O9 monitoring). It holds no business logic and no funds; it is a stateless event
emitter with a **monotonic sequence number** so off-chain consumers can prove they have
seen every instruction (a missing sequence number = an alert, S0.9 monitoring). Immutable
and version-pinned (`VERSION`): event field shapes are stable within a version; any new
field ships as a new router version (D-9, D-19), never a silent field-mutation.

#### Storage

```solidity
contract SettlementRouter {
    uint16  public constant VERSION = 1;
    uint64  private _seq;                       // monotonic, never resets
    address public immutable roleManager;       // for onlyEmitter authorization
    mapping(address => bool) public emitters;   // bridge, LiquidationModule, ReleaseAuthorizer
    // emitters set once at deploy/bind by GOVERNOR; immutable thereafter (one-shot bind)
}
```

`onlyEmitter` = the bridge, the `LiquidationModule`, and the `ReleaseAuthorizer` (bound
once at wiring time by `GOVERNOR`). Every event carries `sequenceNumber = ++_seq` so the
stream is totally ordered and gap-detectable.

#### The full event catalog (Core)

Each event is emitted by exactly one component on exactly one state transition. Off-chain
consumers key on `sequenceNumber` for ordering and gap detection, and on `dealId`/`positionId`
for per-position reconstruction.

```solidity
// ---- Origination / funding (emitted by CollateralBridge) ----
event PositionOpened(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, bytes32 pledgeId,
    address borrower, uint256 principalUsdc, uint64 maturity, uint32 aprBps, bytes32 routeHash);

event FundingConfirmed(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, uint256 usdcToBorrower, bytes32 settlementRef);

// ---- Repayment (emitted by CollateralBridge) ----
event RepaymentInstruction(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, uint256 repayAmountUsdc, bytes32 routeHash);

// ---- Release authority (emitted by ReleaseAuthorizer) ----
event ReleaseVoucher(
    uint64 indexed sequenceNumber, bytes32 indexed voucherId, bytes32 dealId, bytes32 pledgeId,
    address asset, uint256 amount, DestinationType destinationType, bytes32 destinationRef,
    ReleaseReason reason, uint64 voucherSeq);

event ReleaseAcknowledged(
    uint64 indexed sequenceNumber, bytes32 indexed voucherId, bytes32 dealId, bytes32 custodyTxRef);

// ---- Liquidation (emitted by LiquidationModule + CollateralBridge) ----
event LiquidationInstruction(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, uint8 phase /*WARN|REQUEST|FINALIZE|CANCEL*/,
    bytes32 reportRef, uint64 cureDeadline);

event Liquidated(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, uint256 amountToAmina,
    uint256 surplusToBorrower, bytes32 settlementRef);

// ---- Exceptions (emitted by CollateralBridge / LiquidationModule) ----
event ReserveShortfall(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, uint256 debtUsd, uint256 proceedsUsd, uint256 shortfallUsd);

event CustodyException(
    uint64 indexed sequenceNumber, bytes32 indexed positionId, bytes32 voucherId, bytes32 reasonCode);
```

| Event | Emitter | Trigger | Consumed by |
|-------|---------|---------|-------------|
| `PositionOpened` | `CollateralBridge` | borrow drawn, position Active | O3 indexer, O9 monitor |
| `FundingConfirmed` | `CollateralBridge` | USDC reached borrower | O3, O9 |
| `RepaymentInstruction` | `CollateralBridge` | repay path entered | O6 listener, O3 |
| `ReleaseVoucher` | `ReleaseAuthorizer` | voucher issued (any reason) | **O6 listener** (the trigger to move BTC, with AMINA co-sign) |
| `ReleaseAcknowledged` | `CollateralBridge`/acker | custody movement done | O3, O9, drives `consumeVoucher` |
| `LiquidationInstruction` | `LiquidationModule` | warn/request/finalize/cancel | O8 bot, O9, F5 UI |
| `Liquidated` | `CollateralBridge` | wind-down finalized | O3, O9, F5 UI |
| `ReserveShortfall` | `CollateralBridge` | proceeds < debt (Defaulted) | **O9 monitor (page)** |
| `CustodyException` | `CollateralBridge`/module | listener-reported failure/freeze | **O9 monitor (page)** |

> **Gap detection is the safety property.** Because `sequenceNumber` is strictly
> increasing and never resets, O9 monitoring can assert "every sequence number 1..N has
> been observed." A skipped number means an event was missed (RPC/indexer fault) — paged
> immediately, before acting on stale state. An unacknowledged `ReleaseVoucher` (no matching
> `ReleaseAcknowledged` within a window) is likewise a page.

#### Errors

```solidity
error NotEmitter(); error AlreadyBound();
```

#### Invariants upheld

- Append-only, monotonic `sequenceNumber` (never resets, never reused) → off-chain gap
  detection (S0.9 monitoring obligations; C-23).
- Field-stable within `VERSION` (D-9/D-19): consumers can hard-code the v1 schema; a v2
  router is a new contract, so a parsing change is always explicit.
- Only bound emitters can emit → no spoofed custody instructions reach the listener.

#### External dependencies

`RoleManager` (one-shot emitter binding by `GOVERNOR`); consumed by the off-chain O3/O6/O8/O9
services. No other on-chain dependency (deliberately minimal — it is the audit-trail spine).

#### Why Core / What breaks if omitted

**Test passed: Solvency + Liability.** This is C-23 (the on-chain half) and S0.3 #15.
Off-chain custody ops have no other authenticated, ordered, gap-detectable instruction
feed: the listener (O6) acts **only** on `ReleaseVoucher` events, and monitoring (O9)
detects every invariant breach (voucher gaps, unacknowledged vouchers, shortfalls) from
this stream. Without it, custody movements would be driven by ad-hoc messages with no
ordering guarantee and no way to prove completeness — the ledger and custody would desync
silently, which is exactly the failure the design exists to prevent. Immutability +
versioning is what lets institutions trust that the audit trail's meaning cannot be
silently changed under them.

---

### S8.4 The atomic `liquidateWithdrawAndBurn` flow (image Flow 3)

#### Purpose

The single bridge call that finalization (S8.1) drives. It performs the complete on-chain
wind-down **atomically** — every step succeeds or the whole transaction reverts, so the
position can never be left half-liquidated (e.g. cBTC withdrawn but Morpho debt unpaid, or
debt paid but commitment still recorded in the sub-ledger). This is the on-chain DvP
equivalent for the wind-down leg.

#### Signature

```solidity
function liquidateWithdrawAndBurn(
    bytes32 positionId,
    uint256 debtValueUsd,      // from the finalize report (principal + accrued)
    bytes32 settlementRef
) external;                     // role: LiquidationModule only (onlyLiquidationModule)
```

Access is gated to the `LiquidationModule` — the bridge does not let `LIQUIDATOR` call this
directly; it must go through the module's two-report cure-window gate (S8.1). This preserves
S0.9 #8 (the module that *decides* eligibility is distinct from the engine that *moves*
collateral, and neither sets risk params).

#### Ordered, atomic steps

```text
PRE:  position state == LiquidationPending (set by LiquidationModule.requestLiquidation)
      caller == LiquidationModule

1. SUB-LEDGER: remove this borrower's commitment from the bridge per-borrower sub-ledger.
   - read borrowerSlice = subLedger[positionId] (principal + accrued debt, cBTC posted)
   - compute amountToAmina / surplusToBorrower per S8.1 STEP 5 surplus math
   - require(amountToAmina <= borrowerSlice.cBTC) else go to DEFAULT branch
   - zero the borrower's commitment (so Morpho's aggregate position is re-attributed correctly)

2. REPAY MORPHO: MorphoAdapter.repay(USDC, onBehalf = bridge, amount = borrowerSlice.debt)
   - the USDC is the SETTLED PROCEEDS routed in for this wind-down (real DvP);
     in Core the proceeds arrive via the AMINA desk settlement path; the repay closes
     this borrower's share of the bridge's aggregate Morpho borrow.
   - on failure -> REVERT (atomicity): nothing else has externally happened yet.

3. WITHDRAW cBTC: MorphoAdapter.withdrawCollateral(cBTC, amount = borrowerSlice.cBTC, to = bridge)
   - pulls the borrower's cBTC out of the Morpho collateral position back to the bridge.
   - on failure -> REVERT.

4. ISSUE VOUCHERS (state-derived, S8.2):
   a. vLiq = ReleaseAuthorizer.issueLiquidationRelease(positionId, amountToAmina)   // dest = AMINA desk
   b. if surplusToBorrower > 0:
        vSurplus = ReleaseAuthorizer.issueSurplusRelease(positionId, surplusToBorrower) // dest = borrower

5. BURN cBTC: cBTC.burnForRelease(from = bridge, pledgeId, amount = borrowerSlice.cBTC, voucherId = vLiq)
   - the on-chain claim is retired; the real BTC now moves off-chain under vLiq (+ vSurplus)
     with AMINA co-sign (O6). PledgeRegistry.markLiquidated(pledgeId).

6. EMIT: SettlementRouter.Liquidated(positionId, amountToAmina, surplusToBorrower, settlementRef)
   transition position -> Liquidated (terminal, S0.8).

DEFAULT branch (amountToAmina > collateral, proceeds cannot cover debt+bonus+fee):
   - desk takes entire collateral; NO surplus voucher
   - SettlementRouter.ReserveShortfall(positionId, debtUsd, proceedsUsd, shortfallUsd)
   - transition position -> Defaulted (terminal, S0.8); shortfall booked off-chain to AMINA
```

> **Why atomic and why this order.** Morpho repay (step 2) is attempted before the cBTC
> withdrawal (step 3) and the burn (step 5) so that if the debt cannot be settled the
> collateral is never released. The vouchers (step 4) are issued *after* the on-chain debt
> is cleared and the cBTC is back in the bridge, so a voucher never authorizes moving BTC
> that is still encumbered on Morpho. The burn (step 5) ties the retirement of the on-chain
> claim to the specific liquidation voucher (`voucherId = vLiq`), keeping the cBTC supply ↔
> reserve invariant (S0.9 #1) consistent through the wind-down. The entire sequence is one
> transaction: a revert anywhere leaves the position exactly as it was (`LiquidationPending`),
> and the permissionless `cancelPendingLiquidation` (S8.1) remains available.

#### Relationship to repayment (`repayWithdrawAndBurn`)

The repayment path (S0.7 step 6a, owned by the `CollateralBridge` section) is the mirror:
repay Morpho with the borrower's USDC, withdraw cBTC, `ReleaseAuthorizer.issueRepaymentRelease`
(dest = borrower), burn. Same atomicity and same ordering discipline; the only differences
are (a) the trigger (borrower/AMINA repayment vs module finalization), (b) the destination
(borrower vs AMINA desk), and (c) no surplus/shortfall branch. Both flows funnel through the
same `ReleaseAuthorizer` and `SettlementRouter` so the off-chain listener treats them
uniformly: act only on a `ReleaseVoucher`, require AMINA co-sign, acknowledge on-chain.

#### Invariants upheld

- **Atomicity**: no partial wind-down state is observable; revert restores
  `LiquidationPending`.
- **S0.9 #1**: cBTC burned exactly equals the withdrawn collateral; supply ≤ reserves − margin
  is preserved across the wind-down.
- **S0.9 #5/#7/#10**: AMINA-desk voucher + borrower-surplus voucher are state-derived and
  one-use; the BTC moves only under those vouchers + AMINA co-sign.
- **S0.9 #8**: the `LiquidationModule` decides, the bridge moves; neither sets risk params.

#### External dependencies

`MorphoAdapter` (repay/withdraw), `ReleaseAuthorizer` (vouchers), cBTC
`PermissionedCollateralToken` (`burnForRelease`), `PledgeRegistry` (`markLiquidated`),
`SettlementRouter` (`Liquidated`/`ReserveShortfall`), `RiskConfig` (bonus/fee/threshold
version-pinned), `OracleAdapter` (S6 collateral price for surplus math).

#### Why Core / What breaks if omitted

**Test passed: Solvency.** This is the executable core of C-14/C-15 and the image-1 Flow 3
artifact the brief elevates. Without an atomic wind-down, a liquidation could leave cBTC
withdrawn while the Morpho debt is unpaid (the bridge's aggregate position becomes
under-collateralized and is exposed to permissionless Morpho liquidation at a worse price),
or the debt paid while the borrower's commitment still sits in the sub-ledger (double-count,
the borrower could be liquidated twice). Atomicity is the property that makes per-borrower
liquidation safe on a shared Morpho position; cutting it reintroduces exactly the
half-settled states the spine exists to prevent.


## S9. Risk Parameters, Settlement Router Config, Views & Libraries

This section specifies the **supporting layer** of Triora Core (component #16, #17, and the
shared libraries from the S0.3 inventory). These are the contracts that every other section
reads from but that themselves move no money: the **risk-parameter store** (`RiskConfig` +
`ParameterArchive`) that pins each live position to an immutable snapshot of its terms; the
**day-one caps data model**; the **fee/bonus model**; the **read-only lenses**
(`PortfolioLens` / `BridgeLens`); and the **libraries** (`Types`, `Errors`, `Roles`, `Math`,
`EIP712Hashes`) that fix the protocol's vocabulary, fixed-point math, decimal handling, and
EIP-712 typehashes once so the rest of the codebase cannot drift.

The governing principle (Part 4 of `Triora-Core-vs-Optional-3.md`, D-9): **the parameter
spine is immutable and version-pinned**. Tightening a parameter must never retroactively
endanger a live deal, and adding a *new dimension* of risk control (e.g. a per-jurisdiction
cap) must be possible without a storage migration of live positions. This drives the
snapshot-and-pin design below.

---

### S9.1 `RiskConfig` (configurable) + `ParameterArchive` (immutable)

#### Purpose

`RiskConfig` is the single mutable source of the **current** per-market risk parameters that
AMINA (CURATOR) curates. `ParameterArchive` is the immutable, append-only, write-once store
of every parameter **version** ever published. When `CollateralBridge` opens a position
(S5/S7), it reads the *current* version number from `RiskConfig`, and `PositionRegistry`
(S6) records that `paramVersion` write-once into the position's immutable terms. From then
on, every consumer that needs that position's parameters reads them from
`ParameterArchive[marketId][paramVersion]` — **never** from the live `RiskConfig`. This is
the mechanism that upholds invariant S0.9-9 (*risk params are version-pinned per position*).

> **Why two contracts, not one.** `RiskConfig` is UUPS+TL (component #16, "Config UUPS+TL")
> so AMINA can publish new versions and add caps. `ParameterArchive` is **immutable**
> (component #16, "Archive immutable") because a live position's pinned snapshot is part of
> the deal's legal terms; if the archive could be rewritten, the obligation could be
> silently mutated, breaking invariant S0.9-9 and the Liability test.

#### The `Params` struct (the curated per-market parameter set)

```solidity
// in Types.sol (S9.6); one Params per (marketId, version)
struct Params {
    // --- the liquidation ladder (all in basis points of collateral value) ---
    uint16  ltvBps;             // max borrow LTV at origination (e.g. 7000 = 70%)
    uint16  aminaWarningBps;    // AMINA warning threshold; cure clock starts (e.g. 7500)
    uint16  aminaLiquidationBps;// AMINA objective liquidation threshold (e.g. 8000)
    uint16  morphoLltvBps;      // mirror of the immutable Morpho market LLTV (e.g. 8500)
                               //   INVARIANT (S0.9-6): aminaLiquidationBps < morphoLltvBps
    // --- temporal bounds ---
    uint32  cureWindowSecs;     // fixed cure window after warn (e.g. 172800 = 48h)
    uint64  maxMaturitySecs;    // max tenor of a new position (e.g. 90 days)
    // --- rate bound (the cap on what AMINA may set the FixedRateIRM to) ---
    uint16  maxRateBps;         // upper bound on the fixed APR (e.g. 2000 = 20%)
    // --- fees & bonus (S9.3) ---
    uint16  liquidationBonusBps;// bonus on seized collateral at liquidation (e.g. 500 = 5%)
    uint16  aminaFeeBps;        // AMINA's share of the 40bps origination split (e.g. 20)
    uint16  p2pFeeBps;          // P2P's share of the 40bps origination split (e.g. 20)
    // --- caps (S9.2); near-unbounded at launch but the dimensions exist day-one ---
    uint128 globalCapUsd;       // protocol-wide outstanding-principal cap, 1e8 USD-scaled
    uint128 perBorrowerCapUsd;  // per-borrower outstanding-principal cap
    uint128 perMarketCapUsd;    // per-market outstanding-principal cap
    // --- oracle config (read by OracleAdapter, S8) ---
    address priceFeed;          // Chainlink BTC/USD aggregator
    uint8   priceFeedDecimals;  // feed answer decimals (Chainlink BTC/USD = 8)
    uint32  priceStalenessSecs; // max age of a price answer before FAIL-CLOSED (e.g. 3600)
    uint32  reserveStalenessSecs;// max age of a PoR/attestation before mint FAIL-CLOSED
    // --- lifecycle ---
    bool    active;             // false => no NEW positions in this market (existing unaffected)
}
```

> **Decimals discipline (S0.10):** `cBTC = 8`, `USDC = 6`. All `*Usd` caps are stored in a
> single canonical **1e8 USD scale** (8 decimals) so the cap data model is decimal-stable
> regardless of the loan token. `Math.toUsd8` (S9.5) is the only place that normalizes a
> raw USDC (6-dec) or cBTC (8-dec) amount into the 1e8 USD scale. No consumer does ad-hoc
> `10**x` scaling.

#### The ladder invariant (validated on every publish)

`RiskConfig` rejects any `Params` that violates the **ordering ladder** (S0.9-6; matches the
implemented `CollateralRegistry._validate` in the digests):

```
0 < ltvBps < aminaWarningBps < aminaLiquidationBps < morphoLltvBps <= 10000
```

plus: `0 < maxRateBps <= 10000`, `liquidationBonusBps <= 2000`,
`aminaFeeBps + p2pFeeBps <= 200` (the 40bps cap, S9.3), `cureWindowSecs > 0`,
`maxMaturitySecs > 0`, `priceFeed != address(0)`, `priceFeedDecimals != 0`,
`priceStalenessSecs > 0`, `reserveStalenessSecs > 0`, and **cap coherence** (S9.2): each
narrower cap must not exceed the broader one (`perBorrowerCapUsd <= perMarketCapUsd <=
globalCapUsd`). This enforces R14 (cross-variable invariant + constraint coherence + setter
regression): a setter that publishes a per-market cap *below* the already-accumulated
outstanding for that market is allowed (tightening is legal) but is flagged in the event so
monitoring (O9) can detect a cap set below live exposure.

#### Storage layout

```solidity
// RiskConfig — ERC-7201 namespaced (UUPS upgradeable)
/// @custom:storage-location erc7201:triora.storage.RiskConfig
struct RiskConfigStorage {
    mapping(bytes32 => uint32) currentVersion;   // marketId => latest published version (1-based; 0 = none)
    mapping(bytes32 => bool)   marketExists;      // marketId => registered
    mapping(bytes32 => bool)   marketPaused;      // marketId => paused (no new positions)
    address parameterArchive;                     // immutable archive target
}

// ParameterArchive — plain immutable contract (NOT upgradeable, NOT ERC-7201)
struct ArchiveStorage {
    // marketId => version => snapshot. Write-once per (marketId, version).
    mapping(bytes32 => mapping(uint32 => Params)) snapshots;
    mapping(bytes32 => mapping(uint32 => bytes32)) paramsHash; // keccak256(abi.encode(Params))
    address riskConfig;                            // the only authorized writer
}
```

`marketId` is the deterministic key `keccak256(abi.encode(collateralToken, loanToken,
morphoMarketId))` (computed by `Math.marketId`, S9.5), binding a Triora market 1:1 to its
underlying immutable Morpho market.

#### External functions

```solidity
interface IRiskConfig {
    // --- CURATOR (AMINA), timelocked ---
    function addMarket(bytes32 marketId, Params calldata p) external returns (uint32 version);
    function updateMarket(bytes32 marketId, Params calldata p) external returns (uint32 version);
    // --- GUARDIAN (hot key, may only REDUCE risk): pause blocks new positions ---
    function pauseMarket(bytes32 marketId) external;
    function unpauseMarket(bytes32 marketId) external; // CURATOR only (un-pause = increase risk)
    // --- views (consumed by CollateralBridge S5, OracleAdapter S8, lenses S9.4) ---
    function currentVersion(bytes32 marketId) external view returns (uint32);
    function currentParams(bytes32 marketId) external view returns (Params memory);
    function isMarketActive(bytes32 marketId) external view returns (bool); // exists && !paused && p.active
}

interface IParameterArchive {
    // --- only callable by RiskConfig ---
    function write(bytes32 marketId, uint32 version, Params calldata p) external;
    // --- views (the authoritative read for any LIVE position) ---
    function readParams(bytes32 marketId, uint32 version) external view returns (Params memory);
    function paramsHashOf(bytes32 marketId, uint32 version) external view returns (bytes32);
}
```

**`addMarket`** (CURATOR, timelocked): requires `!marketExists`, validates the ladder + cap
coherence, sets `currentVersion = 1`, calls `archive.write(marketId, 1, p)`, emits
`MarketAdded`.

**`updateMarket`** (CURATOR, timelocked): requires `marketExists`, validates, increments
`currentVersion`, **snapshots the new params into the archive at the new version** (the old
version's snapshot is never touched — invariant S0.9-9). Live positions keep their pinned
`paramVersion` and are therefore unaffected. Emits `MarketUpdated(marketId, oldVersion,
newVersion, paramsHash)`.

**`pauseMarket`** (GUARDIAN — hot key, risk-reducing only): sets `marketPaused = true`. New
positions revert; existing positions are untouched (the interest clock and the loan continue;
pausing a *market* is not pausing a *position* — see S0.8 `Paused` overlay, owned by
`CollateralBridge`/`PositionRegistry`, not here).

#### Events

```solidity
event MarketAdded(bytes32 indexed marketId, uint32 version, bytes32 paramsHash);
event MarketUpdated(bytes32 indexed marketId, uint32 oldVersion, uint32 newVersion, bytes32 paramsHash);
event MarketPaused(bytes32 indexed marketId, address indexed by);
event MarketUnpaused(bytes32 indexed marketId, address indexed by);
event CapBelowLiveExposure(bytes32 indexed marketId, uint128 newCapUsd, uint128 liveOutstandingUsd); // R14 monitoring
```

#### Errors (from `Errors.sol`, S9.6)

`MarketNotFound`, `MarketAlreadyExists`, `LadderInvariantViolated`, `CapIncoherent`,
`AminaThresholdNotBelowLltv`, `RateBoundExceeded`, `FeeBpsExceedsCap`, `ZeroOracleConfig`,
`ArchiveVersionAlreadyWritten`, `OnlyRiskConfig`, `ParamsHashMismatch`.

#### Invariants upheld

- S0.9-6: `aminaLiquidationBps < morphoLltvBps` (validated on every publish).
- S0.9-9: position terms write-once; **risk params are version-pinned** — a live position's
  parameters are read from the immutable archive at its `paramVersion`, never from live config.
- R14 cap coherence: `perBorrowerCapUsd <= perMarketCapUsd <= globalCapUsd`.
- Archive write-once: `ArchiveVersionAlreadyWritten` on any re-write; `paramsHash` verified
  on write so the stored bytes match the hash a position can later attest against.

#### External dependencies

`RoleManager` (S2) for CURATOR/GUARDIAN gating + timelock; consumed by `CollateralBridge`
(S5), `LiquidationModule` (S7), `OracleAdapter` (S8), `ReserveGuard` (S4, staleness),
`PortfolioLens`/`BridgeLens` (S9.4).

#### Why Core / What breaks if omitted

**Test: Reversibility (+ Solvency).** Without version-pinning, a CURATOR tightening `ltvBps`
or `aminaLiquidationBps` would retroactively push live, healthy positions into a liquidatable
state — a parameter change becomes a silent margin call, breaking the borrower's deal terms
(Liability) and potentially triggering unjust liquidations (Solvency). Without the immutable
archive, the recorded obligation is mutable and the legal terms are unprovable. Without the
**caps data model existing day-one** (S9.2), adding a cap dimension later is a storage
migration of every live position (it changes what `Params` a position is pinned to), which is
exactly the migration the Reversibility test says to avoid. This is the borderline-but-Core
call from `Triora-Core-vs-Optional-3.md` C-22 and Part 4 D-? — built now even though values
start near-unbounded.

---

### S9.2 Caps data model (day-one, even if near-unbounded)

#### Why caps are a data model, not a feature

The three cap dimensions — **global**, **per-borrower**, **per-market** — are fields of the
version-pinned `Params` struct (S9.1). They are enforced by `CollateralBridge` at `borrow`
(S5) against the protocol's running outstanding-principal accumulators. At launch the values
may be set to `type(uint128).max` (effectively unbounded), but **the fields, the enforcement
sites, and the accumulators all exist on day one.**

The Reversibility argument: a cap is a new *dimension* of the risk surface. If the `Params`
struct has no cap fields, then introducing them later changes the snapshot schema that live
positions are pinned to in `ParameterArchive` — forcing a migration that re-pins or
re-snapshots every live deal (a re-audit of the spine). By reserving the three dimensions
now, raising or lowering a cap is a normal `updateMarket` publish (a config change), never a
schema migration. This is the precise distinction `Triora-Core-vs-Optional-3.md` C-22 draws:
*"adding a cap dimension later is a migration, not a config change."*

#### Accumulator storage (lives in `CollateralBridge`, S5; specified here for the data model)

```solidity
// running outstanding principal, all in 1e8 USD scale (Math.toUsd8)
uint128 globalOutstandingUsd;
mapping(address => uint128) borrowerOutstandingUsd;   // borrower => outstanding
mapping(bytes32 => uint128) marketOutstandingUsd;     // marketId => outstanding
```

#### Enforcement (R14 + R5)

At `borrow`, `CollateralBridge` reads the position's pinned `Params` (via `paramVersion` →
`ParameterArchive`) and asserts, after adding the new principal:

```
globalOutstandingUsd     + dUsd <= p.globalCapUsd
borrowerOutstandingUsd[b]+ dUsd <= p.perBorrowerCapUsd
marketOutstandingUsd[m]  + dUsd <= p.perMarketCapUsd
```

On repay/liquidation the accumulators are decremented by the realized principal reduction.
**Severity-aware note (R10):** caps are checked against worst-state outstanding (principal
+ never less than the recorded principal), not a transient snapshot. The coherence invariant
(S9.1) guarantees no narrower cap can be configured above a broader one, so a single
`perMarketCapUsd` check can never be satisfied while violating `globalCapUsd` for a
single-market protocol.

#### Errors

`GlobalCapExceeded`, `BorrowerCapExceeded`, `MarketCapExceeded` (categorized under
`Errors.Caps`, S9.6).

#### Why Core / What breaks if omitted

**Test: Reversibility.** Omitting the cap *fields* (even with infinite values) means the
first time AMINA wants to bound per-borrower exposure — an inevitable risk-management need —
the `Params` schema changes, the archive snapshot schema changes, and every live position
pinned to an old snapshot must be migrated. That is a spine migration + re-audit. Reserving
the dimensions now costs three `uint128` fields and three enforcement lines, and converts a
migration into a config publish.

---

### S9.3 Fee model: the 40 bps split + liquidation bonus

#### The model

Triora's revenue is a **40 bps total origination/servicing fee**, split per the banks-plan
v0.2 economics: **20 bps P2P (infrastructure) + 20 bps AMINA (broker)**. Encoded as
`p2pFeeBps` and `aminaFeeBps` in `Params` (S9.1), with the hard invariant
`p2pFeeBps + aminaFeeBps <= 200` (200 bps = 2% absolute ceiling; the 40 bps split sits well
inside it, leaving room without ever approaching a usurious level). Separately,
`liquidationBonusBps` (cap `<= 2000`) is the incentive/penalty applied to seized collateral
at liquidation.

#### Where each fee is taken (single-source-of-truth: the fee is *computed* here, *taken* by the bridge)

| Fee | When | Computed from | Taken where | Paid to |
|-----|------|---------------|-------------|---------|
| **P2P fee** (`p2pFeeBps`) | at `borrow` (origination) | drawn principal | `CollateralBridge.borrow` (S5) — deducted from the USDC routed to borrower, OR billed as an addition to outstanding (D: deducted at draw for Core simplicity) | P2P treasury |
| **AMINA fee** (`aminaFeeBps`) | at `borrow` (origination) | drawn principal | `CollateralBridge.borrow` (S5) | AMINA treasury |
| **Liquidation bonus** (`liquidationBonusBps`) | at liquidation | seized collateral value | off-chain settlement after `LiquidationModule.finalize` (S7); accounted in the surplus waterfall | AMINA desk (compensates orderly-liquidation cost) |

> **Core decision (matches S0.7 step 6b and `Triora-Core-vs-Optional-3.md` C-17):** the
> liquidation **surplus waterfall** is `proceeds − debt − bonus − fee → borrower`. The bonus
> and AMINA fee are taken *before* surplus; the **surplus always returns to the borrower**
> (invariant S0.9-7, ungovernance-seizable). The fee/bonus values are read from the
> position's **pinned** `Params` (the version at origination), so changing the fee schedule
> never alters a live deal's economics — another instance of version-pinning (S9.1).

#### Fee math (in `Math`, S9.5)

```solidity
// origination fees, in the loan-token's own decimals (USDC = 6)
uint256 p2pFee   = Math.bps(principal, p.p2pFeeBps);    // principal * bps / 10_000
uint256 aminaFee = Math.bps(principal, p.aminaFeeBps);
// liquidation: collateral value math is normalized to 1e8 USD then back to cBTC (8 dec)
uint256 bonusUsd = Math.bps(seizedCollateralUsd8, p.liquidationBonusBps);
```

All `bps` math uses `Math.bps` (which is `mulDiv(x, bps, 10_000)`), so rounding is consistent
and there is no inline `* / 10000` anywhere (avoids the decimal/rounding bug class).

#### Why Core / What breaks if omitted

**Test: Liability.** Without `liquidationBonusBps` and the surplus-to-borrower waterfall,
liquidation either has no cost-recovery for AMINA's orderly redemption (lenders bear it) or,
worse, the over-collateralization surplus is kept by the protocol — which is **conversion of
the borrower's property** (C-17, a direct legal liability). Without the version-pinned fee
fields, a fee change would retroactively re-price a live loan, breaking the deal terms
(Liability). The fee *values* could in principle launch at zero, but the *fields and
waterfall* are Core because retrofitting them touches the priced-at-origination terms.

---

### S9.4 `PortfolioLens` / `BridgeLens` — read-only views

#### Purpose

Two immutable, **zero-privilege, state-free** view contracts that aggregate the scattered
on-chain state into the shapes the UI (S10–S11 surfaces F1–F7) and the indexer (O3) consume.
They hold no storage of their own and can never move funds or mutate state — they are pure
read-routers over the other contracts. `BridgeLens` answers *bridge/position* questions;
`PortfolioLens` answers *per-borrower aggregate* questions. (Splitting them keeps each view's
return struct small and lets the indexer call only what it needs.)

> These are the **only** "not-a-safety-cut" components in the Core (S0.3 note: *"UI/indexer
> must hand-assemble state… not a safety cut"*). They exist to make the evidence hub (F4) and
> the margin-call lifecycle (F5) buildable without the frontend reconstructing HF math, which
> is where copy/math errors creep in.

#### `BridgeLens` — per-position view

```solidity
struct PositionView {
    bytes32 positionId;
    address borrower;
    bytes32 pledgeId;
    bytes32 marketId;
    uint32  paramVersion;          // the pinned version (S9.1)
    uint8   state;                 // S0.8 PositionState enum (Types.sol)
    bool    paused;                // S0.8 Paused overlay
    // economics
    uint256 principalUsdc;         // drawn principal, USDC 6-dec
    uint256 outstandingUsdc;       // principal + accrued (FixedRateIRM mirror), 6-dec
    uint16  fixedRateBps;          // the AMINA-curated APR for this position
    uint64  maturityTs;
    // collateral & health
    uint256 pledgedCbtc;           // cBTC 8-dec
    uint256 collateralValueUsd8;   // OracleAdapter value, 1e8 USD (peg-capped, S8)
    uint16  currentLtvBps;         // outstanding / collateralValue  (Math, 1e4 scale)
    // the ladder (from pinned Params) — UI renders the threshold ladder + HF from these
    uint16  ltvBps;
    uint16  aminaWarningBps;
    uint16  aminaLiquidationBps;
    uint16  morphoLltvBps;
    // lifecycle / cure
    uint64  warnedAt;              // 0 if not warned
    uint64  cureDeadline;          // warnedAt + cureWindowSecs, 0 if not warned
    // evidence refs (S4/S5/S6/S7)
    bytes32 controlAgreementHash;
    bytes32 latestReserveReportId;
    uint64  latestReserveFreshnessTs;
    bytes32 settlementRouteHash;
    bytes32 activeVoucherId;       // 0 if none outstanding
    uint8   nextRequiredAction;    // enum: None/TopUp/Repay/AwaitCustodyAck/Cure/...
}

interface IBridgeLens {
    function position(bytes32 positionId) external view returns (PositionView memory);
    function positionsByBorrower(address borrower) external view returns (PositionView[] memory);
    function reserveStatus(bytes32 pledgeId) external view returns (
        uint256 pledgedCbtc, uint256 mintedCbtc, uint256 encumberedCbtc,
        bool lockActive, uint64 lastAttestationTs, bool stale
    );
}
```

#### `PortfolioLens` — per-borrower aggregate view

```solidity
struct PortfolioView {
    address borrower;
    uint256 totalOutstandingUsdc;
    uint256 totalCollateralValueUsd8;
    uint16  blendedLtvBps;
    uint256 activePositions;
    uint256 warnedPositions;        // positions currently in cure
    uint128 borrowerOutstandingUsd; // for cap-headroom display (S9.2)
    uint128 perBorrowerCapUsd;      // headroom = cap - outstanding
}

interface IPortfolioLens {
    function portfolio(address borrower) external view returns (PortfolioView memory);
    function evidenceBundle(bytes32 positionId) external view returns (
        bytes32 controlAgreementHash,
        bytes32 pledgeId,
        bytes32 latestReserveReportId, uint64 reserveFreshnessTs,
        uint16  reserveRatioBps,          // totalSupply vs attestedReserve (S0.9-1 headroom)
        address tokenAddress,
        bytes32 transferPolicyHash,
        bytes32 settlementRouteHash,
        uint8   kybApprovalState
    );
}
```

#### Data source map (each datum's authoritative source — S0.10 frontend rule)

| Datum | Source contract (S-ref) |
|-------|--------------------------|
| state, paused, principal, outstanding, fixedRateBps, accumulators | `CollateralBridge` (S5) sub-ledger |
| paramVersion + entire ladder + caps + fees | `ParameterArchive` (S9.1) at the pinned version |
| collateralValueUsd8, currentLtvBps, peg cap | `OracleAdapter` (S8) |
| pledged / minted / encumbered / lockActive | `PledgeRegistry` (S4) |
| controlAgreementHash, reserve report id + freshness, reserveRatio | `SignedCustodyAdapter` / `ReserveGuard` (S4) |
| warnedAt, cureDeadline, nextRequiredAction (cure path) | `LiquidationModule` (S7) |
| settlementRouteHash, activeVoucherId | `SettlementRouter` (S9.5 events) / `ReleaseAuthorizer` (S7) |
| kybApprovalState | `KYBGateway` (S3) |
| transferPolicyHash, tokenAddress | `cBTC` token (S4) |

#### HF / LTV math copy constraint (S0.10, F3/F5)

The lens returns `currentLtvBps`, `aminaLiquidationBps`, and the full ladder; the UI computes
health as **`HF = aminaLiquidationBps / currentLtvBps`** (the corpus's `LIQ / currentLTV`
form, banks-plan §HF). The lens MUST NOT label the rate as a "platform offer" in any returned
metadata — `fixedRateBps` is *AMINA's curated parameter*. The lens never returns any field
implying "instant liquidation" or "Chainlink mints"; it returns objective state and the UI
applies the S0.10 copy constraints.

#### Why Core / What breaks if omitted

**Test: none directly — it is the one declared non-safety Core component (S0.3).** Omitting
the lenses does not break Solvency, Liability, or Reversibility *on-chain*. They are Core by
the *product* test: the evidence hub (F4) and margin-call lifecycle (F5) are Core surfaces,
and without an authoritative on-chain view the frontend would re-derive HF and the threshold
ladder itself — exactly where the S0.10 copy/math errors ("instant liquidation guarantee",
wrong HF denominator) originate, and where indexer/UI state can drift from chain. The lens
centralizes the math so the institution-facing auditability promise holds. If cut for a
controlled launch, the indexer (O3) must replicate this math server-side — acceptable only
as a deliberate, documented degradation, never silently.

---

### S9.5 `SettlementRouter` configuration (the view/config seam)

> The `SettlementRouter` contract itself (component #15, immutable, append-only,
> sequence-numbered event stream) is specified in S7. This subsection fixes only its
> **configuration surface and the shape of its events** because the lenses (S9.4) and the
> off-chain custody listener (O6) depend on the exact field set, and because *adding a field
> is a new router version, never a field mutation* (D-19 in the digests).

#### Configuration model (versioned, field-stable)

```solidity
// SettlementRouter (immutable, VERSION constant baked in)
uint8 public constant VERSION = 1;
// one-shot binding of authorized emitters by the deployer/binder:
//   CollateralBridge (S5), ReleaseAuthorizer (S7), LiquidationModule (S7)
function bind(address bridge, address releaseAuthorizer, address liquidationModule) external; // one-shot
modifier onlyEmitter; // == one of the bound emitters
```

- **Monotonic sequence:** every emitted instruction carries a strictly increasing
  `sequenceNumber` (global, gap-detectable by O6/O9). A gap = a missed instruction =
  a paging alert (S0.4 O9).
- **Route hash:** every instruction carries a `routeHash` binding `(positionId, pledgeId,
  asset, amount, destinationType, deadline)`; the off-chain ack (custody listener, O6) must
  echo the same `routeHash` and an AMINA co-signature (S0.9-10).
- **Field-stability rule:** a `VERSION = 1` router NEVER removes or repurposes an event
  field. A new field ships as `SettlementRouterV2` with `VERSION = 2`. This lets the indexer
  and lenses pin to a known schema (mirrors the D-19 decision).

#### Why this lives in S9

It is the read/config seam between on-chain decisions and off-chain execution, consumed by
the same lenses and indexer this section serves. Its safety semantics (one-use vouchers,
state-derived destination) are owned by `ReleaseAuthorizer` (S7); S9 only fixes the field
contract the views and listener rely on.

---

### S9.6 Libraries: `Types`, `Errors`, `Roles`, `Math`, `EIP712Hashes`

Five shared libraries fix the protocol's vocabulary once. Every contract imports from these;
nothing redefines a struct, enum, role id, fixed-point helper, or typehash locally. This
prevents the decimal/signature/duplication bug class (S0.3 note: *"Duplication + decimal/sig
bugs"*).

#### `Types` — all structs and enums

```solidity
library Types {
    // ---- enums ----
    enum PositionState {           // S0.8 state machine
        None, PledgePending, Collateralized, Active, Warned,
        RepaymentPending, ReleasePending, Closed,
        LiquidationPending, Liquidated, Defaulted
    }
    enum PledgeStatus { None, Pledged, Minted, Encumbered, ReleasePending, Released, Liquidated }
    enum DestinationType { None, Borrower, AminaDesk }     // release voucher destination (state-derived, S0.9-5)
    enum NextAction { None, TopUp, Repay, AwaitCustodyAck, Cure, AwaitMint, AwaitBorrow }

    // ---- structs ---- (Params in S9.1; others summarized)
    struct Params { /* S9.1 */ }
    struct PositionTerms {        // write-once in PositionRegistry (S6); S0.9-9
        address borrower; bytes32 pledgeId; uint256 principalUsdc;
        uint16 fixedRateBps; uint64 startTs; uint64 maturityTs;
        bytes32 marketId; uint32 paramVersion; bytes32 legalTermsHash;
    }
    struct CustodyProof {         // dual-signed; EIP712Hashes.CUSTODY_PROOF_TYPEHASH
        bytes32 subjectId; bytes32 custodyAccountRef; address token;
        uint256 amount; uint8 decimals; uint64 observedAt; uint64 expiresAt;
        bytes32 evidenceHash; bytes32 controlAgreementHash;
    }
    struct LiquidationReport {     // objective oracle predicate; EIP712Hashes.LIQUIDATION_REPORT_TYPEHASH
        bytes32 positionId; bytes32 legalTermsHash;
        address collateralToken; address loanToken;
        uint256 debtValueUsd8; uint256 collateralValueUsd8;
        uint16  liquidationThresholdBps;             // <= 10000
        uint64  observedAt; uint64 expiresAt; bytes32 reportRef;
    }
    struct ReleaseVoucher {        // one-use; EIP712Hashes.VOUCHER_TYPEHASH
        bytes32 voucherId; bytes32 positionId; bytes32 pledgeId; address asset;
        uint256 amount; DestinationType destinationType; bytes32 destinationRef;
        uint64 issuedAt; uint64 expiry; bool consumed;
    }
    struct BorrowIntent {          // signed borrower intent; EIP712Hashes.BORROW_INTENT_TYPEHASH
        bytes32 positionId; bytes32 pledgeId; uint256 usdcAmount;
        uint16 maxRateBps; uint64 deadline; uint256 nonce;
    }
}
```

> **Decimals are encoded in the types, not in call sites.** `*Usd8` fields are always the
> 1e8 USD scale; `*Usdc` fields are 6-dec; `*Cbtc` fields are 8-dec. The suffix is the unit
> contract — any cross-unit arithmetic must pass through `Math` (below).

#### `Errors` — categorized custom errors

Grouped by layer so each revert is unambiguous (no generic `InvalidParams` — matches the
implemented `Errors` library):

```solidity
library Errors {
    // Roles/Access
    error Unauthorized(bytes32 role); error OnlyRiskConfig(); error OnlyEmitter();
    // RiskConfig/Archive (S9.1)
    error MarketNotFound(); error MarketAlreadyExists(); error LadderInvariantViolated();
    error CapIncoherent(); error AminaThresholdNotBelowLltv(); error RateBoundExceeded();
    error FeeBpsExceedsCap(); error ZeroOracleConfig(); error ArchiveVersionAlreadyWritten();
    error ParamsHashMismatch();
    // Caps (S9.2)
    error GlobalCapExceeded(); error BorrowerCapExceeded(); error MarketCapExceeded();
    // Reserve/Mint (S4)
    error ReserveExceeded(); error ReserveStale(); error MintExceedsPledge();
    // Oracle (S8)
    error PriceStale(); error PriceNonPositive(); error PegCapExceeded();
    // Lifecycle/Voucher (S5–S7)
    error BadState(Types.PositionState have, Types.PositionState want);
    error VoucherConsumed(); error VoucherExpired(); error DestinationNotStateDerived();
    error CureWindowActive(); error NotLiquidatable();
    // Common
    error ZeroAddress(); error ZeroAmount(); error ZeroReference();
}
```

#### `Roles` — role identifiers (mirrors S0.6)

```solidity
library Roles {
    uint64 internal constant GOVERNOR      = 1; // P2P 3-of-5
    uint64 internal constant EMERGENCY     = 2; // joint 2-of-2
    uint64 internal constant CURATOR       = 3; // AMINA risk params
    uint64 internal constant ALLOCATOR     = 4; // AMINA ops (open/record positions)
    uint64 internal constant LIQUIDATOR    = 5; // AMINA bots (warn/request/finalize)
    uint64 internal constant ISSUER_MINTER = 6; // custodian/CRE mint key
    uint64 internal constant GUARDIAN      = 7; // hot key, risk-reducing only (pause, cap decrease)
    uint64 internal constant ORACLE_ADMIN  = 8; // AMINA + Chainlink 2-of-3
}
```

> These ids are the keys used with `RoleManager` (OZ `AccessManager`, S2). Defining them once
> here is what makes invariant S0.9-8 (no role both moves collateral and sets params)
> auditable: the privilege split is a static property of which role guards which function,
> and every guard references a `Roles.*` constant.

#### `Math` — fixed-point, bps, decimal scaling

```solidity
library Math {
    uint256 internal constant USD8 = 1e8;     // canonical USD scale
    uint256 internal constant BPS  = 10_000;

    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256); // OZ-style, no overflow
    function bps(uint256 x, uint256 bpsv) internal pure returns (uint256) { return mulDiv(x, bpsv, BPS); }

    // decimal normalization — the ONLY place raw units cross into 1e8 USD
    function toUsd8(uint256 amount, uint8 tokenDecimals, uint256 priceUsd8, uint8 priceDecimals)
        internal pure returns (uint256);   // (amount / 10**tokenDecimals) * (price / 10**priceDecimals) * 1e8
    function usd8ToToken(uint256 usd8, uint8 tokenDecimals, uint256 priceUsd8, uint8 priceDecimals)
        internal pure returns (uint256);

    // cBTC(8) <-> USDC(6) and USD8 conversions, explicit decimal handling (S0.10)
    function scaleDecimals(uint256 amount, uint8 from, uint8 to) internal pure returns (uint256);

    // current LTV in bps, given outstanding (USD8) and collateral value (USD8)
    function ltvBps(uint256 outstandingUsd8, uint256 collateralUsd8) internal pure returns (uint16)
    { return uint16(mulDiv(outstandingUsd8, BPS, collateralUsd8)); } // 0 collateral => caller guards

    // deterministic market key (S9.1)
    function marketId(address collateral, address loan, bytes32 morphoMarketId)
        internal pure returns (bytes32) { return keccak256(abi.encode(collateral, loan, morphoMarketId)); }
}
```

> **No inline `* / 10000` or `10**x` anywhere else in the codebase.** All basis-point math
> goes through `Math.bps`; all decimal crossing goes through `Math.toUsd8` /
> `Math.scaleDecimals`. cBTC is 8 dec, USDC is 6 dec, Chainlink BTC/USD is 8 dec — these are
> passed explicitly, never assumed 18 (S0.10).

#### `EIP712Hashes` — typehashes for every signed message

One library holds every EIP-712 typehash so a signature's domain and field order cannot drift
between the verifying contract and the off-chain signer (O5/O6/O8). Each typehash binds
`chainId` + verifying contract via the domain separator, plus an explicit `nonce`/`reportRef`
for replay protection.

```solidity
library EIP712Hashes {
    bytes32 internal constant CUSTODY_PROOF_TYPEHASH = keccak256(
      "CustodyProof(bytes32 subjectId,bytes32 custodyAccountRef,address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt,bytes32 evidenceHash,bytes32 controlAgreementHash)");
    bytes32 internal constant LIQUIDATION_REPORT_TYPEHASH = keccak256(
      "LiquidationReport(bytes32 positionId,bytes32 legalTermsHash,address collateralToken,address loanToken,uint256 debtValueUsd8,uint256 collateralValueUsd8,uint16 liquidationThresholdBps,uint64 observedAt,uint64 expiresAt,bytes32 reportRef)");
    bytes32 internal constant VOUCHER_TYPEHASH = keccak256(
      "ReleaseVoucher(bytes32 voucherId,bytes32 positionId,bytes32 pledgeId,address asset,uint256 amount,uint8 destinationType,bytes32 destinationRef,uint64 issuedAt,uint64 expiry)");
    bytes32 internal constant BORROW_INTENT_TYPEHASH = keccak256(
      "BorrowIntent(bytes32 positionId,bytes32 pledgeId,uint256 usdcAmount,uint16 maxRateBps,uint64 deadline,uint256 nonce)");
    bytes32 internal constant CUSTODY_ACK_TYPEHASH = keccak256(
      "CustodyAck(bytes32 voucherId,bytes32 routeHash,bytes32 settlementRef,uint64 ackedAt,uint256 nonce)");
}

interface IEIP712Domain { function DOMAIN_SEPARATOR() external view returns (bytes32); }
```

- `CUSTODY_PROOF` — dual (custodian + AMINA) reserve/lock/pledge attestation (S4, D-5).
- `LIQUIDATION_REPORT` — objective oracle predicate (S7, D-7); `reportRef` enforces the
  two-distinct-report cure rule (a finalize report's `reportRef` must differ from the request).
- `VOUCHER` — one-use release voucher; `destinationType` is state-derived (S0.9-5), so the
  signed voucher cannot encode a caller-chosen destination.
- `BORROW_INTENT` — borrower's signed borrow with `maxRateBps` (so the borrower bounds the
  AMINA rate they accept) + `nonce` replay guard.
- `CUSTODY_ACK` — the off-chain custody co-sign echoing `routeHash` (S9.5), upholding S0.9-10.

#### Why Core / What breaks if omitted

**Test: Solvency + Liability (via correctness).** The libraries are Core because every
solvency- and liability-critical computation depends on them being singular: if two contracts
define `Params` or a typehash differently, a signature verified in one place is forgeable in
another (Liability), or a decimal mismatch lets cBTC be valued as if 18-dec, inflating
collateral value and enabling over-lending (Solvency — the exact failure S0.10 decimals rule
guards). `Errors` and `Roles` are Core by auditability: categorized errors make negative
tests (S0.6 acceptance) precise, and centralized role ids make the privilege-separation
invariant (S0.9-8) a static, checkable property. Omitting these doesn't remove a feature; it
scatters the same logic into N copies that *will* drift — the duplication/decimal/sig bug
class the corpus repeatedly flags.

---

### S9.7 Section invariants summary (what S9 guarantees to the rest of the spec)

1. **Version-pinning (S0.9-9):** every live position reads its parameters from
   `ParameterArchive[marketId][paramVersion]`, an immutable write-once snapshot; live config
   changes never reach a live deal.
2. **Ladder (S0.9-6):** `ltvBps < aminaWarningBps < aminaLiquidationBps < morphoLltvBps <=
   10000`, validated on every publish; AMINA always acts strictly before the Morpho backstop.
3. **Cap coherence (R14):** `perBorrowerCapUsd <= perMarketCapUsd <= globalCapUsd`; the three
   dimensions exist day-one so a future cap is a config publish, not a migration (S9.2).
4. **Fee ceiling + surplus (S0.9-7):** `p2pFeeBps + aminaFeeBps <= 200`; liquidation surplus
   (`proceeds − debt − bonus − fee`) always returns to the borrower.
5. **Decimal singularity (S0.10):** all unit crossing goes through `Math` with explicit
   cBTC=8 / USDC=6 / price=8 decimals; no inline scaling exists elsewhere.
6. **Signature singularity:** all typehashes live in `EIP712Hashes`; every signed message
   binds chainId + verifying contract + an explicit nonce/reportRef replay guard.
7. **Lenses are pure:** `PortfolioLens` / `BridgeLens` hold no state and have no privileged
   function; they cannot affect any invariant — they only read.


## S10. Off-chain Services (Backend, Indexer, Custody Ops, Bots, Monitoring)

This section specifies the seven Core off-chain services **O3–O9** from S0.4. O1 (Web app) and
O2 (AMINA Operator Console) are frontend surfaces specified in their own sections; this section
covers the backend systems that ingest chain state, hold KYB evidence, sign and submit custody
attestations, execute the real BTC movement, publish reserve quantity, run liquidation, and page
on invariant breaches.

The unifying principle of S10 is the **ledger/custody split** from `Triora-Core-vs-Optional-3.md`:
the chain is the source of *decisions* (mint authorized, position open, voucher issued, liquidation
finalized); the off-chain services are the *executors* of those decisions and the *evidence-bearers*
for the facts the chain cannot observe (BTC actually in custody, BTC actually released). Every service
that touches solvency is **FAIL-CLOSED**: on uncertainty it refuses to advance state, it never
invents backing, and it never moves an asset without exactly one consumed on-chain voucher plus an
AMINA co-signature (S0.9 invariant 10).

Three rules bind every service in this section:

- **R-IDEM (idempotency)**: every chain event and every off-chain instruction carries a unique key;
  reprocessing it is a no-op. Chainlink/CRE delivery, RPC re-orgs, and listener restarts must never
  double-execute. Keys: `(chainId, contractAddress, txHash, logIndex)` for events;
  `voucherRef` (the one-use `keccak256` from `ReleaseAuthorizer`) for custody movements.
- **R-SEQ (sequence integrity)**: `SettlementRouter` (S4) emits monotonic per-router sequence numbers.
  Every consumer tracks the last processed sequence and **halts + pages** on a gap (a missing
  instruction may be a missed solvency event), never silently skips.
- **R-FINAL (finality before action)**: an EVM `included ≠ finalized`. Services that move real BTC or
  publish reserves wait for the configured block-finality depth before acting on an on-chain trigger,
  and BTC deposits wait for 6 Bitcoin confirmations before attestation.

All persisted data is stored in a single Postgres cluster (logical separation by schema), with the
Bitcoin/EIP-712 signing keys held in HSM/KMS (custodian + AMINA signers never expose raw keys to the
application layer). All inter-service calls are mTLS with role-scoped service identities.

---

### S10.1 (O3) Backend API + Indexer

#### Responsibility

The read model and audit trail of the protocol. It (a) ingests every event from the in-scope
contracts, (b) maintains denormalized read tables that reconstruct each borrower position, its
evidence bundle, and the portfolio, and (c) serves authenticated REST + GraphQL endpoints to the
Web app (O1, S9), the AMINA Operator Console (O2), and downstream services (O5/O6/O8 read the same
read model rather than re-deriving chain state). It owns **no private keys** and performs **no
state-changing chain writes** — it is a pure reader/aggregator. It also stores the KYB intake
artifacts and evidence hashes written by O4 (S10.2).

#### Inputs / Outputs

- **Inputs**: WebSocket + JSON-RPC event subscriptions to all Core contracts (`RoleManager`,
  `KYBGateway`, `TokenizationRegistry`, `ReserveGuard`, `SignedCustodyAdapter`, `PledgeRegistry`,
  `PermissionedCollateralToken`, `OracleAdapter`, `PositionRegistry`, `CollateralBridge`,
  `LiquidationModule`, `ReleaseAuthorizer`, `SettlementRouter`, `RiskConfig`/`ParameterArchive`);
  KYB intake payloads from O4; periodic `BridgeLens`/`PortfolioLens` (S5) view reads for
  reconciliation.
- **Outputs**: REST + GraphQL responses; server-sent events / WS push to the UI on state changes
  (margin-call fired, voucher issued, position closed); a reconciliation feed consumed by O9.

#### Event ingestion pipeline

```
RPC node (finalized head) ──▶ Subscriber ──▶ raw_event (append-only)
                                                  │
                                          Decoder + Router (per-ABI)
                                                  │
                              ┌───────────────────┼────────────────────┐
                          position_*           pledge_*            voucher_*
                          read tables         read tables         read tables
                                                  │
                                          Reconciler (vs BridgeLens / PledgeRegistry)
                                                  │
                                              read API
```

1. **Subscribe** at the **finalized** head only (R-FINAL); a separate "pending" subscription may feed
   optimistic UI hints but never the canonical read model.
2. **Persist raw** first: every log is written to an append-only `raw_event` table keyed by
   `(chainId, address, blockNumber, txHash, logIndex)` **before** decoding. This is the replay source
   and the immutable ingest audit trail.
3. **Decode + route** per contract ABI; a reorg below the finalized depth deletes affected
   `raw_event` rows and replays — read tables are deterministically rebuildable from `raw_event`
   (the indexer is a pure projection; it can be dropped and rebuilt).
4. **Project** into read tables (below). Each projection is idempotent on the event key (R-IDEM).
5. **Reconcile**: on a schedule, compare projected per-borrower sub-ledger totals against
   `BridgeLens` aggregate reads and `PledgeRegistry` on-chain state; emit a drift signal to O9 on any
   mismatch (this is the on-chain/read-model consistency check; the custody/ledger drift check is O9's).

#### Persisted data (read model tables)

| Table | Key | Contents | Source events |
|-------|-----|----------|--------------|
| `raw_event` | `(chainId,address,block,txHash,logIndex)` | Append-only decoded log JSON | all |
| `position` | `pledgeId` | borrower, state (S0.8), principal, APR, maturity, market, accrued outstanding (mirrored sub-ledger), current HF inputs | `PositionOpened`, bridge sub-ledger events, `Warned`, `Repaid`, `Liquidated` |
| `pledge` | `pledgeId` | custody account ref, pledgedAmount, mintedAmount, encumbered, status, custodyAgreementHash, lockActive (last attested) | `PledgeRegistered`, `MintRecorded`, `LockForDeal`, `MarkReleased/Liquidated` |
| `attestation` | `(pledgeId, asOf)` | reserve quantity, custodian sig ref, AMINA sig ref, freshness | `ProofSubmitted` (SignedCustodyAdapter) |
| `reserve_snapshot` | `(token, asOf)` | attested reserves, totalSupply at snapshot, margin, effective limit | `ReserveGuard` / publisher events |
| `voucher` | `voucherRef` | dealId, pledgeId, amount, destinationType, reason, sequenceNumber, issuedAt, ackStatus | `ReleaseVoucher`, `ReleaseAcknowledged` |
| `kyb` | `entityId` | status, expiry, jurisdiction, wallet set, on-chain `KYBGateway` mirror | `KYBStatusSet` + O4 intake |
| `kyb_evidence` | `(entityId, docType)` | document **hash only**, storage ref, upload status, AMINA decision ref | O4 (off-chain) |
| `liquidation` | `pledgeId` | warn time, cure deadline, oracle report ref, finalize time, proceeds, debt, bonus, fee, surplus | `LiquidationModule` events |
| `settlement_seq` | `routerAddress` | last processed sequence (R-SEQ cursor) | `SettlementRouter` |

> **Privacy**: `kyb` and `kyb_evidence` hold real legal identities and document hashes. These are
> readable **only** by the AMINA-scoped role; the borrower/lender-scoped API never returns the
> counterparty's legal identity (S9 pseudonymity). The Web app sees anonymized counterparty codes.

#### Interfaces (endpoints)

REST (read-only, paginated, ETag-cached) and a mirrored GraphQL schema:

- `GET /positions?wallet=&role=` → list positions for the caller's entity. Returns the consolidated
  position view (S0.5 F3): one row per pledge with state, HF (computed `LIQ/currentLTV` — never
  `maxLTV/currentLTV`), outstanding, maturity.
- `GET /positions/{pledgeId}` → position detail: full terms (from `PositionRegistry`, immutable),
  sub-ledger outstanding, threshold ladder (warning / AMINA-liquidation / Morpho-LLTV with the
  BTC price at each level), repay/top-up/withdraw eligibility.
- `GET /positions/{pledgeId}/evidence` → **evidence bundle** (S0.5 F4): entity legal name (AMINA
  scope) / anon code (counterparty scope), AMINA client id, control-agreement hash, pledge id,
  reserve source id + report freshness (`asOf`, age), reserve ratio (`totalSupply / attestedReserves`),
  cBTC token address, transfer policy reference, settlement route (router address + last sequence),
  AMINA approval state. Every datum names its on-chain source so the institution can independently
  verify (auditability is a product feature).
- `GET /portfolio?wallet=` → aggregate across positions: total borrowed (USDC), total collateral
  (cBTC × oracle price, normalized 8→price decimals), weighted APR, aggregate HF, maturities.
- `GET /kyb/{entityId}` → KYB status + expiry (status only for self; full record for AMINA scope).
- `GET /vouchers/{voucherRef}` and `GET /settlement?from_seq=` → for O6 reconciliation and the
  AMINA settlement-queue UI.

#### Auth + role mapping

- **AuthN**: SIWE (Sign-In-With-Ethereum) for borrower/lender wallets; OIDC + MFA (TOTP) for AMINA
  operators and P2P operators. Sessions are short-lived JWTs.
- **AuthZ**: the JWT claim set maps to one of `{ BORROWER, LENDER, AMINA_OPS, AMINA_RISK,
  P2P_GOVERNOR_VIEW, SERVICE }`. The role gates row-level access: a borrower sees only positions whose
  `borrower` wallet is in their entity's KYB wallet set; AMINA scopes see all rows plus legal
  identities; service roles (O5/O6/O8) get the subset they need read-only. The mapping is derived
  from on-chain `KYBGateway` + `RoleManager` membership, cached and refreshed on the relevant events
  — the API never grants a privilege the chain does not.

#### Failure handling

- RPC outage → ingestion stalls at last finalized block; the API serves stale data flagged with the
  read model's `lastIndexedBlock` and age. The UI shows a "data may be delayed" state (not an error).
  No write path depends on the indexer, so a stalled indexer cannot cause an unsafe action.
- Decode failure on an unknown event → quarantined in `raw_event` with an `undecoded` flag and paged
  to O9 (an unrecognized event may be a contract the indexer was not updated for).
- The indexer is **not solvency-critical** itself, but its **reconciler** feeds O9's drift detection,
  so a reconciler failure pages.

#### Idempotency / replay

Every projection keyed on the event key (R-IDEM); reorgs handled by raw-event delete-and-replay. The
read model is fully rebuildable from `raw_event`, and `raw_event` is rebuildable from the chain — there
is no authoritative state in the indexer that is not derivable from the chain or from O4's intake store.

#### Why Core / What breaks if omitted

**Liability + Reversibility.** Without it there is no read model, no portfolio/position view, no
evidence bundle, and no reconciliation feed — the UI and the AMINA console would have to hand-assemble
chain state, and the on-chain/read-model drift check that backs O9 would not exist. The evidence
bundle is itself a product feature (institutions must be able to audit a position). It is not directly
*solvency*-load-bearing (it writes nothing on-chain), which is why it is the one service in this
section that may serve degraded/stale data rather than fail closed — but its reconciler is the early-warning
sensor for ledger drift, so omitting it removes the detection of an invariant breach before loss.

---

### S10.2 (O4) KYB Intake Service

#### Responsibility

The regulatory entry-control surface. It collects KYB documents from an applicant institution, hashes
and stores them, routes the package to AMINA for the single approval decision (AMINA's FINMA licence
authorizes onboarding — P2P never decides), and on AMINA approval writes the result on-chain via
`KYBGateway.setStatus`. It is the only service that submits the KYB write, and it does so **only** under
an AMINA-authorized decision.

#### Inputs / Outputs

- **Inputs**: applicant documents (entity info, signatories + IDs, entity docs, custody-link proof,
  legal click-throughs) from the KYB onboarding surface (S0.5 F6); AMINA approve/reject decisions from
  the Operator Console (O2).
- **Outputs**: a hashed evidence package persisted in O3's `kyb_evidence` table; an on-chain
  `KYBGateway.setStatus(entity, wallet, status, expiry, jurisdiction, evidenceHash)` transaction signed
  by the AMINA `CURATOR` (or a delegated KYB key) — the service prepares and submits but the authorizing
  signature is AMINA's; an `attestationHash`/`documentsHash` anchored on-chain (the chain stores the
  hash, never the documents).

#### Mechanism (step by step)

```
Applicant ──docs──▶ Intake ──hash──▶ evidence store (hash on-chain, doc off-chain)
                                          │
                                  Package + checklist ──▶ AMINA decision (O2)
                                          │
                         approve ─────────┴───────── reject
                            │                            │
            KYBGateway.setStatus(Approved,expiry)   record reason (generic to applicant; AMLA)
```

1. **Collect** the 5-step intake (entity, signatories+docs, custody link, legal agreements, submit).
   Submit is blocked unless every mandatory accuracy checkbox is set (mirrors F6).
2. **Hash + store**: each document is hashed (keccak256 over the canonical bytes); the document goes to
   encrypted object storage, the hash + storage ref + upload status go to `kyb_evidence`. Only the hash
   is ever placed on-chain.
3. **Route**: assemble the decision package (entity, signatories, doc-hash manifest, custody-link
   verification result, jurisdiction) and expose it to AMINA via O2. AMINA performs
   sanctions/PEP/source-of-funds/credit/custody-confirmation off-chain.
4. **Decide**: AMINA approves (with expiry + jurisdiction) or rejects. On approve, the service builds
   `setStatus` and submits it under the AMINA authorizing signature. On reject, it records the decision
   and returns a **generic** non-specific message to the applicant (AMLA confidentiality — no
   tipping-off).
5. **Expiry**: the on-chain record carries `reviewedUntil`; an expired wallet fails the
   `KYBGateway.requireApproved` gate without a separate revoke write. The service schedules
   re-attestation reminders ahead of expiry.

#### Persisted data

`kyb_evidence` (hash, storage ref, doc type, upload status, AMINA decision ref) and the off-chain
encrypted document blobs. Real identities live here and in O3's `kyb` table; access is AMINA-scoped.

#### Interfaces

Consumed: the F6 intake form; the O2 decision actions. Produced: `KYBGateway.setStatus` on-chain;
the evidence rows in O3.

#### Failure handling

- A failed `setStatus` submission (RPC/gas/nonce) is retried with the same payload (idempotent: the
  KYBGateway write is keyed by `(entity, wallet)` so re-submitting the same approved status is a no-op
  on the final state). The approval decision is durably recorded **before** submission so a crash
  between decision and submission resumes cleanly.
- The KYB write is **not** solvency-critical (it gates entry, not minting), but it **is** liability-critical:
  the service must never write `Approved` without a recorded AMINA decision. There is no auto-approve path.

#### Idempotency / replay

Approval decisions are content-addressed by `(entity, decision, evidenceHash)`; resubmitting an already-applied
decision is a no-op. Document uploads are deduplicated by content hash.

#### Why Core / What breaks if omitted

**Liability (regulatory).** Without the on-chain KYB gate fed by an AMINA-authorized decision,
unscreened or sanctioned entities can transact, and P2P risks reclassification as a broker (an
onboarding decision made by anyone but AMINA is an unlicensed decision). The intake *UI* can be manual
at launch (per `Triora-Core-vs-Optional-3.md` §7.4), but the *service* that hashes evidence and writes
the AMINA-authorized status on-chain is Core.

---

### S10.3 (O5) Custody Attestation Signer

#### Responsibility

The producer of authenticated reserve and lock evidence. It watches the segregated custody account for
the borrower's BTC deposit, waits for 6-confirmation Bitcoin finality, builds the `CustodyProof` packet,
gathers the **dual (custodian + AMINA) EIP-712 signatures**, and submits the proof to
`SignedCustodyAdapter` (the `ICustodyAdapter`/`IReserveSource` of S2). It is the on-ramp for the facts
the chain cannot observe: *the BTC exists*, *it is locked under AMINA-mandatory release control*, and
*for how much*. It also runs the **re-attestation cadence** that keeps the `isLockActive` and
`attestedReserves` facts fresh, and it is **FAIL-CLOSED**: it never signs a proof for BTC it has not
confirmed.

#### Inputs / Outputs

- **Inputs**: custody-account balance + deposit events from the custodian's portal/API (read-only;
  no contract calls a custodian API — facts arrive as evidence the service constructs); Bitcoin
  confirmation depth; the control-agreement reference binding the account to AMINA.
- **Outputs**: a signed `CustodyProof` submitted to `SignedCustodyAdapter.submitProof(...)`; periodic
  re-attestations refreshing reserves + lock-active; a staleness alarm to O9 if it cannot re-attest in
  time.

#### The CustodyProof packet (EIP-712)

The packet binds the custody fact to a specific pledge, asset, quantity, time window, and chain. The
typehash lives in `EIP712Hashes` (S2). Conceptually:

```solidity
// CustodyProof — dual-signed (custodian + AMINA). Both signatures required.
struct CustodyProof {
    bytes32 custodyAgreementHash; // ties this account to the tri-party control agreement
    bytes32 pledgeId;             // the pledge this proof backs (binds proof to deal, not free-floating)
    bytes32 assetId;              // BTC
    bytes32 custodyAccountRef;    // the segregated account identifier (hashed)
    uint256 reserveAmount;        // BTC quantity, normalized to cBTC 8 decimals (NOT a USD value)
    bool    lockActive;           // AMINA-mandatory-release control confirmed in force
    uint64  asOf;                 // observation time (post 6-conf)
    uint64  expiresAt;            // freshness bound; adapter rejects after this
    uint256 chainId;              // domain separation — proof valid only on this chain
    uint64  nonce;                // strictly increasing per (custodyAccountRef, assetId)
}
// Submitted with custodianSig and aminaSig (both over the EIP-712 digest).
```

Key constraints (enforced by the adapter, mirrored by the signer):

- `reserveAmount` is a **quantity in cBTC decimals (8)**, not a USD price — it must never route through
  the price-oracle plane (S2 OracleAdapter). The reserve plane and price plane never share config.
- `chainId` + the EIP-712 domain separator make the proof unusable on another chain (no cross-chain
  replay).
- `nonce` strictly increases per account+asset; the adapter rejects stale/reused nonces (replay-safe).
- `expiresAt` gives the adapter a hard freshness bound; an expired proof fails the mint path closed.

#### Mechanism (step by step)

```
BTC deposit ─▶ watch account ─▶ wait 6 confirmations (R-FINAL) ─▶ build CustodyProof
                                                                       │
                                            custodian HSM sign ◀───────┴───────▶ AMINA HSM sign
                                                                       │
                                               SignedCustodyAdapter.submitProof(proof, custSig, aminaSig)
                                                                       │
                                                 PledgeRegistry.registerPledge [Pledged]
```

1. **Watch**: subscribe to the custodian account for an incoming BTC deposit to the segregated address
   under the control agreement.
2. **Finality**: wait for **6 Bitcoin confirmations** before treating the deposit as real (R-FINAL).
   A deposit below 6 conf is never attested.
3. **Build**: construct `CustodyProof` with `reserveAmount` = the confirmed balance normalized to 8
   decimals, `lockActive = true` only if the control-agreement lock is verified in force, `asOf` = now,
   `expiresAt` = now + freshness window, `chainId`, next `nonce`.
4. **Sign (dual)**: obtain the custodian EIP-712 signature (custodian HSM) and the AMINA EIP-712
   signature (AMINA HSM). **Both** are required; a single-signed proof is never submitted.
5. **Submit**: call `SignedCustodyAdapter.submitProof`. The adapter verifies both signatures, the
   `chainId`, the nonce, and freshness, then exposes `attestedReserves`, `isLockActive`, `verifyPledge`
   for `ReserveGuard` and `PledgeRegistry`. On success, `registerPledge` moves the pledge to `Pledged`.
6. **Re-attest**: on a cadence (≤ `adapterMaxAge`, e.g. 10 minutes per the pilot config in the PoR
   plan), re-submit a fresh proof so `attestedReserves`/`isLockActive` never go stale while positions
   are live. If the signer cannot produce a fresh dual-signed proof before the previous one expires, it
   **alarms O9** and the mint path fails closed (no new mint against stale reserves) — but burns,
   repay, and liquidation remain possible (operational fault ≠ collateral vanished).

#### Re-attestation cadence / staleness

- Fresh window per the TokenizationRegistry `adapterMaxAge` (S2). The signer targets re-attestation at
  roughly half the window so a single missed cycle does not immediately stale the reserve.
- A proof's `expiresAt` is the hard cliff: past it, `ReserveGuard` treats reserves as missing and
  **blocks new mints** (fail-closed); it does **not** block liquidation (a stale attestation does not
  mean the BTC left custody).

#### Persisted data

Submitted proofs (full packet + both signatures + tx ref), the per-account+asset nonce cursor,
deposit-watch checkpoints (last confirmed Bitcoin height), re-attestation schedule + last-success time.

#### Interfaces

Consumed: custodian portal/API (read), custodian + AMINA HSM signers. Produced:
`SignedCustodyAdapter.submitProof` on-chain; staleness alarms to O9; pledge/reserve rows projected by O3.

#### Failure handling (FAIL-CLOSED)

- Custodian API unreachable / balance unverifiable → **do not sign**, do not submit, alarm O9. Never
  attest a quantity the service cannot confirm.
- Missing AMINA co-signature → **do not submit** (dual signature is invariant). A custodian-only proof
  is never valid.
- Re-attestation missed → reserve goes stale → mint path blocks closed; O9 pages.
- The single rule: **never respond to reserve uncertainty by enabling a fresh mint.**

#### Idempotency / replay

Nonce-per-account+asset makes each proof single-use on-chain; resubmitting the same nonce is rejected
by the adapter. Deposit watching is checkpointed by Bitcoin height so a restart resumes without
double-attesting the same deposit.

#### Why Core / What breaks if omitted

**Solvency.** Without authenticated, dual-signed, fresh reserve + lock evidence reaching the chain,
`ReserveGuard` has nothing to enforce against — backing becomes self-attested ("PoR theater"), or the
mint path opens to unbacked cBTC. This service produces fact 1 (exists) and fact 2 (locked) of the
three-part backing invariant; without it the entire 1:1 premise (S0.9 invariant 1) is unenforceable.

---

### S10.4 (O6) Custody Listener / Settlement Service

#### Responsibility

The off-chain executor that moves the real BTC — and **only** on an authenticated on-chain decision. It
subscribes to `SettlementRouter` (S4), acts **only** on a consumed one-use voucher whose destination was
derived from on-chain state (S0.9 invariant 5), requires an AMINA co-signature for the actual movement
(S0.9 invariant 10), executes the custody movement through the custodian, and acknowledges back on-chain.
It is **idempotent, replay-safe, and sequence-gap-detecting**. It is the single thing that desyncs the
ledger from custody if it gets this wrong, so it is FAIL-CLOSED on every ambiguity.

#### Inputs / Outputs

- **Inputs**: `ReleaseVoucher` / `SettlementRouter` instruction events (with `voucherRef`, sequence
  number, destinationType derived from state, amount); the AMINA co-signature authorizing the physical
  movement; custodian execution results.
- **Outputs**: a real BTC custody movement (borrower on repay; AMINA desk on liquidation); an on-chain
  acknowledgment (`SignedCustodyAdapter.acknowledgeRelease` / `releaseAcknowledged(pledgeId, voucherRef)`)
  that lets the chain advance the pledge to `Released`/`Liquidated` and `burnForRelease` the cBTC.

#### Mechanism (step by step)

```
SettlementRouter event ─▶ verify sequence (R-SEQ) ─▶ load voucher by voucherRef
        │                                                   │
   gap? ─yes─▶ HALT + page O9                        already acked? ─yes─▶ no-op (R-IDEM)
        │                                                   │
       no                                          require AMINA co-sign for THIS voucherRef
                                                            │
                                          execute custody movement to STATE-DERIVED destination
                                                            │
                                            acknowledge on-chain (voucherRef) [idempotent]
```

1. **Read in sequence** (R-SEQ): process `SettlementRouter` events in strictly increasing sequence per
   router. A gap → **halt and page O9** (a missing instruction could be a release the service must not
   skip).
2. **Resolve the voucher**: load the voucher by `voucherRef`. The destination (`Borrower` on repay,
   `AminaDesk` on liquidation) is read from the voucher (which derived it from on-chain state). The
   service **never** accepts a destination from any other source — an off-chain instruction without a
   matching on-chain voucher is rejected outright.
3. **Check ack state** (R-IDEM): if `voucherRef` is already acknowledged, the event is a no-op (replay).
4. **Require AMINA co-sign**: obtain the AMINA co-signature over the exact `voucherRef` + amount +
   destination. Without it, **no movement** (S0.9 invariant 10). The co-sign authorizes *this specific*
   one-use voucher, not a class of movements.
5. **Execute**: instruct the custodian to move the BTC to the state-derived destination. Operator
   signing is digest-bound / human-readable (VisualSign-style "what you sign is what moves") to prevent
   blind-signing of the wrong destination or amount.
6. **Acknowledge**: write the acknowledgment on-chain keyed by `voucherRef`. The ack is idempotent (a
   second ack for the same `voucherRef` is a no-op). The on-chain ack is what permits `burnForRelease`
   and the pledge transition to its terminal state — closing the loop ledger↔custody.

#### Persisted data

A per-`voucherRef` execution ledger: `{ voucherRef, sequence, destination, amount, aminaCoSignRef,
custodyTxRef, ackTxRef, status ∈ (Seen, CoSigned, Executed, Acked) }`; the per-router last-processed
sequence cursor (R-SEQ). This ledger is the replay-safety and gap-detection backbone.

#### Interfaces

Consumed: `SettlementRouter` events; AMINA co-sign HSM; custodian execution API. Produced: the BTC
movement; the on-chain acknowledgment; status rows projected by O3 for the AMINA settlement-queue UI.

#### Failure handling (FAIL-CLOSED)

- **Sequence gap** → halt, do not advance, page O9. Never skip a sequence number.
- **No matching voucher** for an instruction → reject; an instruction the chain did not authorize is
  never executed.
- **Missing AMINA co-sign** → do not move BTC.
- **Custodian execution failure after co-sign** → the voucher stays `CoSigned`/`Executed`-pending and is
  retried; the on-chain ack is written **only** after confirmed custody execution, so a crash between
  execution and ack resumes by re-checking custody state (the movement is not double-executed because
  the voucher is one-use and the execution ledger records the attempt).
- **Ack failure (RPC)** → retried; idempotent on `voucherRef`.

#### Idempotency / replay

Every movement is gated by a one-use `voucherRef` and recorded in the execution ledger; reprocessing any
`SettlementRouter` event for an already-executed/acked voucher is a no-op (R-IDEM). Sequence cursor
guarantees no instruction is silently skipped (R-SEQ).

#### Why Core / What breaks if omitted

**Solvency + Liability.** This is the only service that executes the on-chain decision against the real
asset. Without it, on-chain decisions never move the BTC (a repaid borrower is held hostage; a
liquidation never completes), or — worse — a movement executes without a matching voucher or AMINA
co-sign, breaking S0.9 invariant 10 and desyncing ledger from custody silently. The voucher-gated,
co-signed, idempotent acknowledgment loop is the mechanical guarantee that "the asset moves only where
state dictates."

---

### S10.5 (O7) Reserve / PoR Publisher (or Chainlink CRE Workflow)

#### Responsibility

Publish the attested reserve **quantity** to the `IReserveSource` that `ReserveGuard` reads in the mint
path. At launch this is the **signed-attestation publisher** (the same dual-signed path as O5, surfaced
as an `IReserveSource`), because Chainlink CRE is Early Access and "announced ≠ provably live" (the Kiln
Railnet caution). The CRE workflow is the **v1.1 path** behind the *same* `ReserveGuard` interface, so
slotting it in requires no re-audit of the mint path (the security boundary is the consumer-side guard,
not the producer).

#### Inputs / Outputs

- **Inputs (launch / signed publisher)**: the dual-signed custody attestation reserve quantity from O5
  (or read directly off `SignedCustodyAdapter`).
- **Inputs (v1.1 / CRE)**: custody balance + lock facts read by the CRE Workflow DON via HTTP/Confidential-HTTP
  capabilities.
- **Outputs**: an on-chain reserve value consumable by `ReserveGuard` via `IReserveSource`
  (`attestedReserves(token)`), normalized to cBTC 8 decimals, with freshness metadata. The mint rule it
  serves: `cBTC.totalSupply + amount ≤ min(freshPoR, freshAttestation) − positiveMargin`, fail-closed
  (S0.9 invariant 1).

#### Launch path — signed-attestation publisher

The launch publisher is effectively a thin façade over O5's evidence: it exposes the dual-signed
`attestedReserves` as an `IReserveSource` so that when both a Chainlink PoR feed and the signed
attestation exist, `ReserveGuard` takes `min()` of the two; when only the attestation exists (no PoR
feed yet for this custom cBTC), it runs `AdapterOnly` mode — explicitly lower-assurance, pilot-only, and
flagged in `TokenizationRegistry` config (negative margins are disallowed; staleness disabling is
forbidden).

The reserve value is read identically to a price feed (`AggregatorV3Interface`:
`decimals()`, `latestRoundData()`), but `answer` is a **reserve quantity in BTC units**, never a USD
price — it must never route through the OracleAdapter price plane (S2). Reject `answer ≤ 0`, reject
stale (`block.timestamp − updatedAt > maxAge`), reject incomplete round (`answeredInRound < roundId`),
scale reserve decimals → cBTC 8 decimals (round down, conservative).

#### v1.1 path — CRE workflow shape (described, not launched)

```
Trigger (cron / log / EVM event)
   └▶ Workflow DON (identical WASM per node)
        └▶ Capability calls: HTTP / Confidential-HTTP read custody balance + lock
             └▶ NodeRuntime per-node observation  ──▶  AUTHOR-WRITTEN aggregation to ONE value
                  └▶ DON-signed report
                       └▶ KeystoneForwarder (f+1 distinct authorized signatures)
                            └▶ CREReportReceiver.onReport(metadata, report)  [auth + route only]
                                 └▶ IReserveSource update consumed by ReserveGuard
```

CRE-specific obligations the receiver/workflow MUST honor (from the PoR/CRE digest):

- **NodeRuntime aggregation is the author's job**: CRE does not auto-make external data trustworthy.
  Per-node observations inside `RunInNodeMode` must be deterministically aggregated to one value with
  explicit source diversity — "CRE provides consensus automatically" is a misreading.
- **KeystoneForwarder authentication**: the receiver authenticates on the **full workflow ID + owner**,
  **never** the 10-byte (40-bit) workflow-name hash prefix. It validates the exact forwarder per
  `chainId`, the expected `workflowId`/owner, payload `chainId` match, required fields + bounded
  numerics, and a strictly-increasing sequence per `(reportType, token)`.
- **Domain separation + replay**: payload carries a chain selector/domain (signatures don't bind the
  destination chain by default); failed report delivery is intentionally replayable → the receiver is
  idempotent on sequence; `included ≠ finalized`.
- **Keep the receiver small**: "authenticate and route, not business logic." The secure-mint decision
  stays in `ReserveGuard`.
- **Do not claim CRE-powered without deployment evidence** (workflowId, owner, version, DON family,
  config hash, receiver source+address, KeystoneForwarder per chain, authorized workflowIds, example
  txs, role assignments, runbooks) — the Railnet lesson.

#### Persisted data

Published reserve values + freshness per token; (CRE) workflow deployment metadata (workflowId, owner,
version, DON family, KeystoneForwarder address per chain, authorized workflowIds) for the evidence
bundle and O9.

#### Interfaces

Consumed (launch): O5 dual-signed attestation. Consumed (v1.1): custodian read via CRE capabilities.
Produced: `IReserveSource` reserve value for `ReserveGuard`.

#### Failure handling (FAIL-CLOSED)

- No fresh reserve value (publisher down, CRE report stale/undelivered) → `ReserveGuard` sees missing/stale
  reserves and **blocks new mints**. The product halts new minting rather than minting unbacked — the
  correct fail-closed behavior. O9 pages on stale PoR/attestation.
- Discrepancy between Chainlink PoR and the signed attestation beyond `maxDiscrepancyBps` → freeze new
  mints + new activations (repay/release/liquidation stay possible).

#### Idempotency / replay

Reserve publications carry a round/sequence; the consumer is idempotent on it. CRE report delivery is
explicitly replayable, so the receiver dedupes on the strictly-increasing sequence.

#### Why Core / What breaks if omitted

**Solvency.** `ReserveGuard` is the single mechanical defense against the infinite-mint failure class
(PYUSD, uniBTC), but a guard with no data source enforces nothing. Without a publisher feeding fresh
reserve quantity, either mints block forever (product dead) or the guard is bypassed (unbacked cBTC).
CRE-as-orchestrator is **Optional/v1.1** precisely because the on-chain guard — not the producer — is the
control; the signed publisher is the Core launch source.

---

### S10.6 (O8) Risk / Liquidation Bot (AMINA OPS)

#### Responsibility

The liveness engine for liquidation. Holding the `LIQUIDATOR` role (AMINA bot wallets, rotatable,
per-wallet daily cap), it polls the oracle + positions, computes each position's health factor, fires
margin-call warnings at the **AMINA warning threshold**, runs the **cure clock**, and — if not cured and
the objective oracle predicate is met — `requestLiquidation` and (after the cure window)
`finalizeLiquidation` via `LiquidationModule` (S4) with signed oracle reports. Eligibility is
**objective** (an oracle predicate), never the bot's discretion (S0.9 invariant — AMINA operates, does
not determine). AMINA's threshold is **strictly tighter than the Morpho market LLTV** (S0.9 invariant 6)
so AMINA acts first and the Morpho permissionless backstop is last-resort.

#### Inputs / Outputs

- **Inputs**: `OracleAdapter` BTC/USD price (with staleness + decimals + peg cap); per-position state
  from O3's read model + `PositionRegistry`/`CollateralBridge` sub-ledger; risk thresholds from
  `RiskConfig`/`ParameterArchive` (version-pinned per position); the signed oracle liquidation report.
- **Outputs**: `LiquidationModule.warn(pledgeId)` (starts cure clock, no asset movement);
  `LiquidationModule.requestLiquidation(pledgeId, oracleReport)`;
  `LiquidationModule.finalizeLiquidation(pledgeId)` after the cure window → drives
  `CollateralBridge.liquidateWithdrawAndBurn` (atomic: repay Morpho, withdraw cBTC) → a liquidation
  voucher (dest = AMINA desk) flows to O6; margin-call notifications to the borrower via O3.

#### Mechanism (step by step)

```
poll oracle + positions ─▶ HF = collateralValue·LIQ / (outstanding) per position (version-pinned params)
        │
   HF < AMINA warning?  ─yes─▶ warn(pledgeId)  [Warned, cure clock starts, notify borrower]
        │                                  │
   cured/topped-up? ─yes─▶ back to Active   cure window elapsed AND objective predicate met?
                                                          │
                                          requestLiquidation(pledgeId, signedOracleReport)
                                                          │  (after cure deadline)
                                          finalizeLiquidation(pledgeId)
                                                          │
                                CollateralBridge.liquidateWithdrawAndBurn (atomic)
                                                          │
                                ReleaseAuthorizer liquidation voucher (dest = AMINA desk) ─▶ O6
```

1. **Poll** oracle + positions on a tight cadence. Compute HF with the **correct** formula
   (`LIQ/currentLTV` framing; HF = 1.00 at the liquidation threshold), using the **version-pinned** risk
   params for each position (a later LTV tightening must not retroactively endanger a live deal).
   Cross-asset math normalizes decimals explicitly (cBTC 8, USDC 6, oracle price decimals).
2. **Warn** at the AMINA warning threshold → `LiquidationModule.warn` → state `Warned`, cure clock
   starts (fixed window, e.g. 24–48h per RiskConfig), borrower notified via O3. **No token movement** at
   warn.
3. **Cure**: if the borrower tops up collateral or repays enough to clear the warning before the
   deadline, the position returns to `Active`. The bot must re-poll and detect the cure (it does not
   liquidate a cured position even if a stale poll said otherwise — it re-checks at finalize).
4. **Request**: if not cured and the **objective oracle predicate** (HF breach proven by a fresh signed
   oracle report) holds, `requestLiquidation` with that report. Eligibility is the report, not the bot's
   opinion.
5. **Finalize**: after the cure deadline, `finalizeLiquidation` → `CollateralBridge.liquidateWithdrawAndBurn`
   atomically repays the Morpho debt for that borrower's share and withdraws the cBTC; a state-derived
   liquidation voucher (dest = AMINA desk) is issued for O6 to move the real BTC. Surplus
   (proceeds − debt − bonus − fee) is routed to the **borrower** (S0.9 invariant 7).
6. **Backstop awareness**: because the AMINA threshold is tighter than Morpho LLTV, AMINA always reaches
   the position first; if the AMINA bot is unavailable and HF reaches Morpho LLTV, Morpho's
   permissionless liquidation is the last-resort backstop (the bot monitors the gap to LLTV and pages O9
   if a position approaches LLTV without AMINA having acted).

#### Stale-oracle posture

Per the degradation rules: on a stale/circuit-broken price, **new mints/activations block**, but
**liquidation may proceed at the last sane price** (AMINA bears the risk with off-chain market data) —
a stale feed is an operational fault, not proof the collateral is fine. The bot never liquidates on a
`≤ 0` or peg-cap-violating price; it pages O9.

#### Persisted data

Per-position HF history + last poll; warn/cure-deadline state; submitted liquidation requests +
oracle-report refs + finalize results; per-wallet daily liquidation count (rate-limit enforcement).

#### Interfaces

Consumed: `OracleAdapter`, O3 read model, `RiskConfig`/`ParameterArchive`, signed oracle reports.
Produced: `LiquidationModule.warn/requestLiquidation/finalizeLiquidation`; margin-call notifications;
liquidation vouchers (via the module → ReleaseAuthorizer) for O6.

#### Failure handling (FAIL-CLOSED on safety, FAIL-OPEN on liveness via backstop)

- Bot down → no margin calls / no AMINA liquidation, **but** the Morpho permissionless backstop still
  protects solvency (this is exactly why the backstop exists; AMINA-only would leave bad debt
  unliquidated). O9 pages immediately on bot heartbeat loss.
- Stale/invalid oracle → do not liquidate on bad data; page O9.
- Cure not re-checked at finalize → **must** re-check (never finalize a position that cured between
  request and finalize).
- Per-wallet daily cap exceeded → rotate wallet or halt + page (a runaway bot is bounded by the cap).

#### Idempotency / replay

`warn`/`request`/`finalize` are state-gated on the on-chain position state (S0.8) and the
`LiquidationModule` step counter; re-issuing a call for an already-advanced phase reverts on-chain, so a
bot retry cannot double-liquidate.

#### Why Core / What breaks if omitted

**Solvency (liveness).** Without the bot, margin calls never fire and AMINA-orderly liquidation never
runs — bad debt would sit unliquidated until the Morpho backstop triggers (loss of the orderly,
surplus-returning, custody-redeeming AMINA path and of borrower margin-call awareness). The objective
oracle predicate + cure window is what makes liquidation fair (not interested-party discretion) and the
tighter-than-LLTV threshold is what keeps AMINA in control while the backstop guarantees liveness.

---

### S10.7 (O9) Monitoring & Alerting

#### Responsibility

The off-chain detection of every invariant the contracts assert — the system that surfaces a breach
**before** loss, not after. It runs continuous invariant monitors over the chain (via O3's read model
and direct lens reads), the off-chain service heartbeats, and the custody/ledger reconciliation, and
pages on every breach with a defined severity. It writes nothing on-chain and authorizes nothing — it
is pure observation — but it is Core because an invariant that breaks silently is discovered after the
loss.

#### Inputs / Outputs

- **Inputs**: O3 read model + reconciler; direct `BridgeLens`/`PortfolioLens`/`ReserveGuard` reads;
  `SettlementRouter` sequence; O5/O6/O8 service heartbeats + last-success timestamps; custodian-reported
  balances (for ledger↔custody drift); `RoleManager` membership.
- **Outputs**: alerts to the on-call paging system, severity-tagged; an alert ledger; dashboards.

#### The exact invariant monitors

| # | Monitor | Condition (breach) | Severity | Page |
|---|---------|--------------------|----------|------|
| M1 | **Supply > reserve** | `cBTC.totalSupply() > min(freshPoR, freshAttestation) − margin` (S0.9 inv 1) | **CRITICAL** | immediate, 24/7 |
| M2 | **Stale PoR / attestation** | reserve `asOf` age > `maxAge`, or `expiresAt` passed, while positions live | **HIGH** | immediate |
| M3 | **Lock inactive** | `isLockActive(pledgeId) == false` for any `Bound`/active pledge | **CRITICAL** | immediate, 24/7 |
| M4 | **AMINA removed from quorum** | AMINA signer absent from a required multisig / `RoleManager` membership where its co-sign is mandatory | **CRITICAL** | immediate, 24/7 |
| M5 | **Voucher sequence gap** | `SettlementRouter` sequence non-contiguous (R-SEQ) | **HIGH** | immediate |
| M6 | **Unacknowledged voucher** | voucher issued but not acked within SLA (O6 stuck) | **HIGH** | escalating |
| M7 | **Ledger / custody drift** | bridge sub-ledger / `pledge.mintedAmount` vs custodian-reported BTC balance mismatch beyond tolerance | **CRITICAL** | immediate, 24/7 |
| M8 | **HF breach** | any position `HF < 1` (at/through AMINA threshold), or approaching **Morpho LLTV** without AMINA having acted | **HIGH** (warning), **CRITICAL** (near LLTV unactioned) | immediate |
| M9 | **Service heartbeat loss** | O5 (signer), O6 (listener), O8 (liquidation bot) heartbeat / last-success stale | **HIGH** (O5/O6), **CRITICAL** (O8 with positions near threshold) | immediate |
| M10 | **Mint blocked (fail-closed engaged)** | `ReserveGuard` rejecting mints due to stale/discrepant reserves | **MEDIUM** → **HIGH** if sustained | escalating |
| M11 | **Oracle degraded** | price stale / `≤ 0` / peg-cap violated / circuit-broken | **HIGH** | immediate |
| M12 | **Read-model drift** | O3 projection vs `BridgeLens`/`PledgeRegistry` mismatch | **MEDIUM** | working-hours |

> M1, M3, M4, M7 are the four **solvency-fatal** monitors — they map directly to the four failure modes
> of `Triora-Core-vs-Optional-3.md` Part 0 (lose a custodied asset, mint unbacked, wrong party takes
> collateral, AMINA control lost). They page 24/7 with no auto-resolve.

#### Mechanism

Each monitor is an independent evaluator on its own cadence (M1/M3/M7 every block-finality cycle;
heartbeats every few seconds; drift checks on the reconciliation schedule). A breach opens an incident
with severity, dedupes on the breach key (R-IDEM — a sustained breach is one incident, not a storm),
escalates on SLA, and auto-resolves only when the condition clears for a hold-down period.

#### Persisted data

Alert ledger (open/resolved incidents, severity, first/last seen, ack/escalation history); per-monitor
last-evaluation + last-value (for trend + flap suppression); on-call schedule + escalation policy.

#### Interfaces

Consumed: O3 read model + reconciler, direct lens/guard reads, service heartbeats, custodian balances.
Produced: pages (PagerDuty/Opsgenie-class), dashboards, the incident audit trail.

#### Failure handling

- A monitor that cannot evaluate (its data source is down) is itself an alert ("monitor blind") — a
  silent monitor is treated as a breach of its own coverage (fail-closed on observability).
- Paging path is redundant (two independent channels) so a single notification-vendor outage does not
  blind on-call.

#### Idempotency / replay

Incidents dedupe on the breach key; re-evaluating an already-open breach updates last-seen, never opens
a duplicate. Alert delivery is at-least-once with incident-level dedup downstream.

#### Why Core / What breaks if omitted

**Solvency.** Monitoring is the off-chain sensor for every on-chain invariant. The contracts *assert*
the invariants; O9 is what *notices* when one breaks. Without day-one monitoring + paging (mandated as
Core in both `Triora-Core-vs-Optional-3.md` C-23 and the definition-of-done gate 5), an invariant breach
— unbacked supply, an inactive lock, AMINA dropped from quorum, ledger/custody drift — is discovered
after the loss instead of before it. M1/M3/M4/M7 must page before the first mainnet pledge.

---

### S10.8 Cross-service guarantees (summary)

| Guarantee | O3 | O4 | O5 | O6 | O7 | O8 | O9 |
|-----------|----|----|----|----|----|----|----|
| Writes on-chain | no | KYB status | attestations | acks | reserve | liq calls | no |
| Holds signing keys | no | AMINA KYB | cust+AMINA | AMINA co-sign | (CRE DON) | LIQUIDATOR | no |
| FAIL-CLOSED on solvency | n/a (degrades) | n/a | **yes** | **yes** | **yes** | safety yes / liveness backstop | observ. yes |
| Idempotent (R-IDEM) | event key | decision hash | nonce | voucherRef | round/seq | phase-gated | breach key |
| Sequence integrity (R-SEQ) | cursor | — | nonce | **gap→halt** | seq | — | gap monitor |
| Finality wait (R-FINAL) | finalized head | — | 6-conf BTC | — | finalized | finalized | — |

These seven services, together with the on-chain spine (S1–S5) and the frontend (S6–S9), complete the
ledger/custody loop: the chain decides, O5/O7 prove the backing, O6 executes the movement, O8 keeps
liquidation live, O3 serves the truth, O4 gates entry, and O9 watches every invariant. Cross-reference:
S2 (`ReserveGuard`/`SignedCustodyAdapter`/`OracleAdapter`), S3 (`CollateralBridge`/`PositionRegistry`),
S4 (`LiquidationModule`/`ReleaseAuthorizer`/`SettlementRouter`), S0.9 (the invariants every service
upholds), S12 (the full invariant catalog O9 monitors).


## S11. Frontend (borrower app + AMINA operator console)

This section specifies the **seven Core frontend surfaces** (F1–F7 from S0.5). Each surface is
built so an engineer can implement directly: purpose, layout (regions), components, every datum +
its source (a `PortfolioLens`/`BridgeLens` view per S0.3 #17, or a Backend API endpoint per S0.4
O3), the exact contract call each user action triggers (signatures from S5–S10), UI states, and
the binding copy constraints from S0.10.

### S11.0 Cross-cutting frontend rules (apply to every surface)

**Data sourcing discipline.** The frontend never assembles position state from raw contract storage.
Every on-chain datum is read through a **Lens** (`PortfolioLens` for borrower-facing aggregation,
`BridgeLens` for sub-ledger/HF detail) or through a **Backend API endpoint** (O3 indexer) for
anything the chain does not hold (KYB intake status, evidence-hash provenance, freshness clocks
derived from event timestamps). Where a datum exists in both, the **Lens is authoritative for
money/state and the API for off-chain evidence and human-readable metadata**.

**Two apps, one design system.** F1–F6 are the **borrower app** (persona-guarded: a wallet must be
KYB-approved per `KYBGateway` to see anything past F6). F7 is the **AMINA Operator Console** (gated
to `CURATOR`/`ALLOCATOR`/`LIQUIDATOR`/`GUARDIAN`/`EMERGENCY` wallets). The router blocks all
`/operator/*` routes for non-AMINA wallets and all borrower routes for AMINA-only wallets.

**Health-factor math (LOCKED).** HF is **always** computed and displayed as
`HF = LIQ_threshold / currentLTV` where `LIQ_threshold` is the AMINA liquidation threshold (NOT the
Morpho LLTV, NOT the max LTV at origination) and `currentLTV = outstandingUSDC / collateralValueUSD`.
HF = 1.00 occurs at the AMINA threshold; the borrower is healthy above it. The mockup's
`MAX_LTV/currentLTV` formula is **wrong and must not be used** (digest_reviews_gaps §"HF math is
wrong"). Collateral value uses `OracleAdapter` (S0.3 #8) with the peg cap (value ≤ attested reserve).

**Decimals.** cBTC is 8 decimals, USDC is 6. All display formatting normalizes explicitly; never
render BTC at 18 decimals. Cross-asset previews (e.g. max-borrowable) state the price source.

**Copy constraints (LOCKED, every surface).**
- The borrow rate is **"AMINA's parameter"** / "rate set by AMINA" — **never** "platform offer",
  "our rate", or "market rate". (`FixedRateIRM`, S0.3 #12; the IRM is AMINA-curated, D-3.)
- **Never** "Chainlink mints" / "Chainlink issues your token". Minting is `ISSUER_MINTER` gated by
  `ReserveGuard` + `PledgeRegistry` (S0.6). Chainlink/PoR is a **reserve attestation source** only.
- **Never** "instant liquidation", "guaranteed liquidation", "liquidation without delay". Always
  describe the **objective oracle trigger + fixed cure window + AMINA-operated** sequence (D-7).
- **Never** imply cBTC is a freely transferable/DeFi-usable ERC-20. Copy: "restricted collateral
  claim, transferable only on protocol paths" (S0.9 inv. 3).
- **Never** "Safe co-signer = qualified custodian" or "P2P holds your BTC". P2P is technology only
  (S0.1). BTC sits at the qualified custodian under the tri-party control agreement.

---

### S11.1 F1 — Tokenize collateral

#### Purpose
Onboard a KYB-approved entity's BTC into the protocol: connect the custody address, drive the AMINA
tri-party control-agreement step, and surface the dual-attestation → secure-mint of cBTC **1:1**
against verified reserves. This is the entry to the entire product (S0.5 F1).

#### Layout (regions)
1. **Stepper header** — 4 steps: (1) Connect custody → (2) Tri-party control agreement → (3) Deposit
   & attestation → (4) Mint cBTC. Current step highlighted; completed steps locked.
2. **Main panel** — the active step's form/status.
3. **Evidence sidebar** — live mirror of pledge facts (pledge id, attested reserves, lock status,
   reserve ratio) as they materialize; links to F4.
4. **Reserve-guard banner** — shows the current `ReserveGuard` headroom (`min(PoR, attestation) −
   margin − supply`) so the borrower sees how much can be minted.

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| Entity name, KYB status/expiry | Backend API `/kyb/{wallet}` (mirrors `KYBGateway`) |
| Connected custody account ref (masked) | Backend API `/custody/link/{wallet}` |
| Tri-party control-agreement hash | `TokenizationRegistry.tokenConfig.custodyAgreementHash` (S0.3 #3) via API |
| Deposit detection + confirmations (6-conf) | Backend API `/custody/deposits` (O5 attestation signer watches finality) |
| Attested reserves (custodian + AMINA dual EIP-712) | `SignedCustodyAdapter.attestedReserves()` (S0.3 #5) |
| PoR quantity (if a PoR source is live) | `IReserveSource` read via Lens / API |
| `effectiveReserveLimit` = `min(PoR, attestation) − margin` | `ReserveGuard.reserveStatus()` (S0.3 #4) |
| Pledge id + status | `PledgeRegistry.getPledge(pledgeId)` (S0.3 #6) |
| Minted cBTC for pledge | `PledgeRegistry` `mintedAmount` |
| cBTC token address + transfer policy | `TokenizationRegistry` / `PortfolioLens` |

#### User actions → contract calls
1. **Connect custody address** → off-chain only: Backend API `POST /custody/link` (provider + account
   ref + verification token); no chain write. UI shows confirmed custody balance when the link verifies.
2. **Sign tri-party control agreement** → off-chain EIP-712 acceptance recorded by API; the resulting
   `custodyAgreementHash` is what `TokenizationRegistry` pins. No borrower-initiated chain write here —
   AMINA/custodian co-sign drives the on-chain attestation.
3. **(System) Submit custody attestation** → O5 service calls
   `SignedCustodyAdapter.submitProof(proofPacket, custodianSig, aminaSig)` →
   `PledgeRegistry.registerPledge(...)`. UI polls and advances the stepper to step 4 when status is
   `Pledged`.
4. **(System/ISSUER_MINTER) Mint** → `ISSUER_MINTER` calls
   `cBTC.mintForPledge(bridge, pledgeId, amount)` which internally invokes `ReserveGuard.checkMint`
   and `PledgeRegistry.recordMint`. The borrower does **not** mint; the UI displays "Minting against
   verified reserves" and shows the mint tx hash on success. cBTC is minted **to the CollateralBridge**
   (S0.7 step 3), not to the borrower's wallet — copy must reflect this ("your collateral claim is held
   by the protocol bridge for your positions").

#### States
- **Empty**: "Connect your custody account to begin." CTA: Connect.
- **Loading**: per-step spinners; deposit step shows "Awaiting 6 confirmations (n/6)".
- **Warning**: reserve-guard headroom < requested amount → "Mint amount exceeds verified reserve
  headroom. Available to mint now: X cBTC." Block the mint CTA. Stale PoR/attestation → "Reserve data
  is stale; minting is paused until fresh attestation arrives (fail-closed)."
- **Error**: attestation rejected (signature/age) → "Custody attestation could not be verified."
  KYB expired → route to F6.
- **Success**: "X cBTC minted 1:1 against your locked BTC." Link to F2 (Borrow).

#### Copy constraints
- "cBTC is a restricted 1:1 collateral claim against BTC locked at your custodian under AMINA
  tri-party control." **Never** "Chainlink mints your cBTC."
- Reserve text: "Minting is allowed only up to verified reserves minus a safety margin
  (fail-closed)." Reference `ReserveGuard`, not a price feed.

#### Why Core / What breaks if omitted
**Solvency.** F1 is the only surface where the 1:1 backing fact (`supply ≤ min(PoR, attestation) −
margin`, S0.9 inv. 1) becomes visible and actionable to the borrower. If omitted, there is no entry to
the product (S0.5 F1) and no user-facing rendering of the secure-mint guard — the borrower would have
no way to see whether their claim is backed, undermining the auditability that is the product's core
promise.

---

### S11.2 F2 — Markets / Borrow

#### Purpose
Show the **AMINA-set fixed rate** and the **LTV + threshold ladder with BTC price at each threshold**,
then let the borrower size, preview, and **sign** a borrow against an existing pledge. This is where a
loan is originated (S0.5 F2).

#### Layout (regions)
1. **Rate hero** — the fixed APR (large), "set by AMINA", ACT/360 day-count note, fixed-for-term note.
2. **Collateral & ladder panel** — origination LTV, AMINA warning/liquidation thresholds, Morpho LLTV
   (backstop, shown smaller/secondary), and **the BTC price at each threshold** for the borrower's
   intended size.
3. **Order panel** — segmented toggle: **Specify collateral** ↔ **Specify loan amount**; live
   max-borrowable and initial HF.
4. **Preview modal** — full term sheet before signing (principal, rate, maturity, repurchase total,
   fee, AMINA co-signature attestation).

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| Fixed APR (AMINA's parameter) | `FixedRateIRM.borrowRate()` (S0.3 #12) via `BridgeLens`; mirror `RiskConfig` |
| Max LTV at origination | `RiskConfig` version for the market (S0.3 #16) via Lens |
| AMINA warning threshold | `RiskConfig` `warningThreshold` |
| AMINA liquidation threshold (`LIQ`) | `RiskConfig` `liquidationThreshold` (S0.9 inv. 6: `< Morpho LLTV`) |
| Morpho LLTV (backstop) | `MorphoAdapter`/market params via `BridgeLens` |
| BTC/USD price | `OracleAdapter.price()` with staleness (S0.3 #8) |
| Available pledge + mintable/minted cBTC | `PledgeRegistry` via `PortfolioLens` |
| Max borrowable for size | computed: `collateralValueUSD × maxLTV`, normalized 8↔6 decimals |
| BTC price at each threshold | computed from outstanding + threshold; see formula below |

**BTC-price-at-threshold formula** (display): for threshold `T` (a max-LTV ratio at which that stage
triggers), `priceAtThreshold = outstandingUSDC / (collateralBTC_normalized × T)`. Render for warning,
AMINA-liquidation, and Morpho-LLTV (backstop) rows. Normalize cBTC 8-dec to a USD value using
`OracleAdapter` decimals explicitly.

#### User actions → contract calls
1. **Toggle specify-collateral / specify-loan** → client-side recompute only.
2. **Adjust amount** → client-side live preview (max borrowable, initial HF = `LIQ / initialLTV`).
3. **Place + sign borrow** → borrower signs the borrow intent (EIP-712 per S9), then submits:
   `CollateralBridge.borrow(pledgeId, usdcAmount)` (S0.3 #10, S0.7 step 4). Internally this triggers
   `MorphoAdapter.supplyCollateral` (first draw) + `borrow(USDC, onBehalf=bridge, receiver=borrower)`,
   `PledgeRegistry.lockForDeal`, `PositionRegistry.record`, and `SettlementRouter.PositionOpened`.
   The position becomes `Active` **iff** the Morpho borrow succeeds and USDC reaches the borrower
   (S0.9 inv. 4) — the UI must not show "Active" until the tx confirms and Lens reports `Active`.

#### States
- **Empty** (no pledge): "Tokenize collateral first." CTA → F1.
- **Loading**: rate/price/ladder skeletons; "Confirming borrow…" after submit.
- **Warning**: requested size pushes initial HF below a safe buffer → "This loan starts close to the
  warning threshold (HF X). Consider borrowing less." Stale oracle → "Pricing is stale; new borrows are
  paused" (mirrors S0 oracle posture, fail-closed for new draws).
- **Error**: borrow reverts (cap exceeded, KYB expired, pledge not bound) → surface the custom error
  name from S10 (e.g. `CapExceeded`, `PledgeNotBound`) in human copy.
- **Success**: "Borrowed X USDC. Funds sent to your wallet." Link to F3.

#### Copy constraints
- Rate label: **"Fixed APR — AMINA's parameter (set quarterly; fixed for your term)."** Never
  "platform offer" / "market rate".
- Ladder copy: "AMINA acts first at its liquidation threshold (after a cure window). Morpho's
  permissionless liquidation is a last-resort backstop at a looser threshold." Never "instant" or
  "guaranteed".
- HF shown as `LIQ/currentLTV`.

#### Why Core / What breaks if omitted
**Liability + Solvency.** F2 is the only place the borrower consents (signs) to the obligation and sees
the rate as AMINA's parameter and the objective threshold ladder. If omitted, no loan can be originated
by a user (S0.5 F2), and the regulated framing (rate = AMINA's parameter, not P2P's offer) cannot be
presented — risking P2P reclassification as a broker (Liability test, S0/Part 0).

---

### S11.3 F3 — Position / Portfolio

#### Purpose
Present **ONE consolidated position** (S0/aggregation invariant) with the **correct HF =
LIQ/currentLTV**, the threshold ladder, and the three lifecycle actions: **repay (full)**, **top-up
margin (with live new-HF)**, and **withdraw margin**. This is how the borrower manages the loan and
responds to risk (S0.5 F3).

#### Layout (regions)
1. **Position header** — consolidated principal, outstanding (principal + accrued), blended fixed rate,
   maturity, single HF gauge.
2. **Threshold ladder** — warning / AMINA-liquidation / Morpho-LLTV with BTC price at each (as F2).
3. **Action bar** — Repay full · Top-up margin · Withdraw margin. (Partial repay/partial liquidation
   are Optional v1.1 per S0/Part 3 — render disabled with "Coming in v1.1" if shown at all.)
4. **Sub-ledger detail (optional drill-down)** — per-borrower outstanding from the bridge sub-ledger
   (since Morpho sees only the aggregate bridge position, D-3).

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| Consolidated outstanding (principal + accrued) | `BridgeLens.outstandingOf(borrower)` (bridge sub-ledger, D-3) |
| Collateral posted (cBTC) | `PortfolioLens` / `PledgeRegistry` |
| Collateral value USD | `OracleAdapter` (peg-capped) |
| currentLTV | `outstandingUSDC / collateralValueUSD` (normalize 6↔8) |
| HF | `LIQ / currentLTV` (LOCKED) |
| Fixed APR | `FixedRateIRM` via `BridgeLens` |
| Maturity / accrual basis | `PositionRegistry` (immutable terms, S0.3 #9) |
| Position state | `BridgeLens` state machine (S0.8) |

#### User actions → contract calls
1. **Repay full** → `CollateralBridge.repayWithdrawAndBurn(pledgeId, amount)` (S0.7 step 6a).
   Requires borrower USDC approval (SafeERC20). Internally: `MorphoAdapter.repay(USDC)` +
   `withdrawCollateral(cBTC)` → `ReleaseAuthorizer.issueRepaymentRelease(dest=borrower)` →
   `SettlementRouter.ReleaseVoucher`. UI transitions position to `RepaymentPending` →
   `ReleasePending` and shows "Release voucher issued; awaiting custody acknowledgement" (S0.8).
   **Release destination is derived from state (borrower), never entered by the user** (S0.9 inv. 5);
   the UI must NOT expose a destination field.
2. **Top-up margin** → `CollateralBridge` margin-add path (deposit additional cBTC from a pledge to the
   position). Show a **live new-HF preview** before submit: `newHF = LIQ / (outstanding /
   (collateral+added)ValueUSD)`. On submit, the bridge supplies the added cBTC to Morpho and updates the
   sub-ledger; UI shows the new HF and new BTC-price-at-threshold.
3. **Withdraw margin** → `CollateralBridge` withdraw-margin path, **bounded so post-withdraw HF stays
   above the warning threshold**. UI computes and shows the max withdrawable that keeps HF safe; the
   contract reverts (custom error) if the request would breach it. Withdrawn cBTC follows a state-derived
   release voucher (no caller-supplied destination).

#### States
- **Empty**: "No active position." CTA → F2.
- **Loading**: gauge + ladder skeletons; "Submitting repayment…".
- **Warning**: HF below warning threshold → inline banner linking to F5; top-up CTA emphasized.
- **Error**: repay/withdraw reverts (insufficient allowance, HF breach, paused) → surface S10 error.
- **Success**: repay → "Repaid in full. Awaiting custody release of your BTC." Top-up → "Margin added.
  New HF: X." Withdraw → "Margin withdrawn. New HF: X."

#### Copy constraints
- HF always `LIQ/currentLTV`. Never show `MAX_LTV/currentLTV`.
- Repay copy: "Your BTC is released to you after AMINA co-signs the custody movement authorized by a
  one-use voucher." Never "instant return".
- Never expose or imply a user-chosen release destination.

#### Why Core / What breaks if omitted
**Solvency + Reversibility.** F3 is where the borrower manages outstanding debt and **responds to margin
risk** (top-up) — without it the borrower cannot cure or repay, and the correct HF (`LIQ/currentLTV`)
cannot be shown, leaving the borrower with a wrong risk picture (the mockup's documented HF bug,
digest_reviews_gaps). Repay drives the state-derived release voucher (S0.9 inv. 5), so omitting F3 also
breaks the reversibility of the deposit (returning BTC to the borrower).

---

### S11.4 F4 — Account / Evidence hub

#### Purpose
The **auditability surface**: a single screen where an institution can verify every fact binding its
on-chain claim to the real, locked, exclusively-controlled BTC. This is a product feature for
institutions (S0.5 F4), the corpus-flagged "Account screen too thin" fix (digest_reviews_gaps).

#### Layout (regions)
1. **Entity & approval** — legal entity, AMINA client id, KYB status + expiry, AMINA approval state.
2. **Custody & control** — control-agreement hash, custodian, settlement route id.
3. **Pledge & token** — pledge id(s), cBTC token address, transfer policy summary.
4. **Reserve & attestation** — PoR report id + freshness clock, attested reserves, **reserve ratio**
   (`supply / attestedReserves`), margin headroom.
5. **Provenance footer** — links every hash/id to its on-chain event (via indexer) so the institution
   can independently verify.

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| Legal entity, AMINA client id | Backend API `/kyb/{wallet}` (off-chain, AMINA-held identity) |
| KYB status + expiry, approval state | `KYBGateway` via API mirror |
| Control-agreement hash | `TokenizationRegistry.tokenConfig.custodyAgreementHash` |
| Pledge id(s) + status | `PledgeRegistry.getPledge` |
| PoR report id + freshness (age vs maxAge) | `IReserveSource` read + API-derived freshness clock |
| Attested reserves | `SignedCustodyAdapter.attestedReserves()` |
| Reserve ratio = `supply / attestedReserves` | `cBTC.totalSupply()` ÷ attested (Lens) |
| Margin headroom = `min(PoR,att) − margin − supply` | `ReserveGuard.reserveStatus()` |
| cBTC token address + transfer policy | `TokenizationRegistry` / `PortfolioLens` |
| Settlement route id | `SettlementRouter` config via API |

#### User actions → contract calls
- **Read-only.** Actions are limited to: copy-hash, open-on-explorer (links to the on-chain event/tx),
  download evidence pack (Backend API `/evidence/{wallet}.pdf`, hashes + tx refs). No chain writes.

#### States
- **Empty**: pre-pledge → "Evidence will populate after your first tokenization." Link → F1.
- **Loading**: per-card skeletons; freshness clocks show "checking…".
- **Warning**: PoR/attestation age exceeds `maxAge` → amber "Reserve attestation is stale (age > limit).
  New mints are paused (fail-closed)." Reserve ratio > 1 (supply exceeds attested − margin, should be
  impossible) → red "Invariant breach — contact AMINA OPS" (this should trip O9 monitoring too).
- **Error**: indexer unreachable → "Evidence temporarily unavailable; on-chain links still valid."

#### Copy constraints
- Reserve framing: "cBTC supply is mechanically capped at verified reserves minus margin
  (`ReserveGuard`, fail-closed)." Never "PoR proves custody control" — PoR proves **quantity**;
  exclusive control comes from the control agreement + AMINA mandatory co-sign (digest_reviews_gaps).
- Never "Chainlink mints". The reserve source line reads "Reserve attestation source: {custodian dual
  EIP-712 attestation}{, Chainlink PoR if live}".

#### Why Core / What breaks if omitted
**Liability + Solvency.** Auditability is the institutional selling point: F4 lets a regulated
counterparty independently confirm the control-agreement, pledge binding, and reserve ratio. If omitted,
the institution cannot trust or audit its position, and the protocol's "every claim is verifiably backed
1:1 and exclusively controlled" promise becomes unverifiable from the user's side.

---

### S11.5 F5 — Margin-call / cure / liquidation lifecycle

#### Purpose
Make the **objective trigger + cure window + AMINA-operated** liquidation path visible and actionable:
a persistent warning banner with a **48h cure countdown** and a top-up CTA, then the liquidation result
with **surplus returned to the borrower**. The corpus's biggest mockup omission (digest_reviews_gaps;
S0.5 F5).

#### Layout (regions)
1. **Status banner (persistent)** — when `Warned`: red banner with shortfall, **cure countdown**,
   top-up CTA, AMINA OPS contact.
2. **Cure panel** — current HF, the BTC price that would clear the warning, top-up sizing (live new-HF).
3. **Liquidation result panel** — after finalize: collateral liquidated, debt repaid, AMINA bonus + fee,
   **surplus returned to borrower** (BTC), settlement reference.

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| Position state (`Active`/`Warned`/`LiquidationPending`/`Liquidated`) | `BridgeLens` (S0.8) |
| Cure deadline / countdown | `LiquidationModule` warn timestamp + cure window (S0.3 #13); freshness via API |
| Shortfall to cure | computed: outstanding − (collateralValueUSD × warningThreshold)⁻¹ basis |
| HF + price-to-cure | `OracleAdapter` + `LIQ/currentLTV` |
| Liquidation result (liquidated, debt repaid, bonus, fee, surplus) | `SettlementRouter` events + `BridgeLens` |
| Surplus destination (borrower) | derived from state (S0.9 inv. 7) — display only |

#### User actions → contract calls
1. **Top-up to cure** → same call as F3 top-up (`CollateralBridge` margin-add). On success and HF back
   above warning, state returns `Warned → Active` (S0.8). UI clears the banner.
2. **(No borrower liquidation action.)** Warn/request/finalize are `LIQUIDATOR`-only (S0.6) and operated
   from F7; the borrower **observes** them here. The UI shows progress: `Warned` (cure running) →
   `LiquidationPending` (objective trigger + cure elapsed) → `Liquidated`.
3. **View liquidation settlement** → read-only; surplus, if any, shown as returned to the borrower's
   custody account (state-derived destination = borrower for surplus; AMINA desk for proceeds, S0.7 6b).

#### States
- **Empty/Healthy**: no banner (position `Active`, HF above warning).
- **Loading**: countdown + HF skeletons.
- **Warning** (`Warned`): persistent red banner, live 48h countdown ("47h 23m"), top-up CTA, "AMINA may
  liquidate after the cure window if the position is not cured."
- **Liquidation pending**: "Cure window elapsed; AMINA is finalizing liquidation per the objective oracle
  trigger." No "instant" language.
- **Liquidated (success/terminal)**: "Position liquidated. Surplus of X BTC returned to your custody
  account." If proceeds < debt → `Defaulted` copy: "Liquidation proceeds did not cover the debt; the
  shortfall is booked to AMINA" (S0.8 `Defaulted`).
- **Error**: countdown/feed unavailable → "Status temporarily unavailable; your cure deadline is
  unchanged."

#### Copy constraints
- **Never** "instant liquidation" or "guaranteed". Always: "objective oracle trigger + fixed cure
  window + AMINA-operated; Morpho permissionless backstop only if AMINA is unavailable" (D-7).
- Surplus copy: "Any value above your debt, AMINA's bonus, and fees is returned to you" (S0.9 inv. 7).
- The cure countdown is informational; never imply the borrower can self-liquidate or self-release.

#### Why Core / What breaks if omitted
**Liability + fairness.** Without F5 the borrower cannot see or respond to a margin call (cure), and the
surplus-return (S0.9 inv. 7) and objective-trigger/cure-window protections (D-7) are invisible. Omitting
it recreates the "interested-party liquidation with no borrower protection" failure the architecture
exists to prevent, and removes the borrower's only window to cure before liquidation.

---

### S11.6 F6 — KYB onboarding (thin)

#### Purpose
A **minimal** regulatory entry surface: show KYB status and provide an intake form whose decision is
**AMINA's**. The on-chain gate (`KYBGateway`) is Core; the portal is intentionally thin (S0.5 F6;
onboarding UI is "lean/manual for launch" per Part 7.4 of the Core-vs-Optional doc).

#### Layout (regions)
1. **Status card** — current state: Not started / Submitted / Under review / Approved / Rejected, with
   confirmation number and expiry (when approved).
2. **Intake stepper (thin)** — entity info → signatories + docs → custody link → legal click-throughs →
   submit. (Full 5-step richness is Optional; Core needs status + a submit path.)
3. **What-happens-next** — AMINA-decision wording.

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| KYB status + expiry | `KYBGateway` via Backend API `/kyb/{wallet}` |
| Confirmation number | Backend API (intake service O4) |
| Uploaded doc status (hashes) | Backend API `/kyb/intake/{id}` (docs hashed off-chain, O4) |
| Legal agreement hashes | `TokenizationRegistry` policy hashes / API |

#### User actions → contract calls
1. **Submit intake** → Backend API `POST /kyb/intake` (docs collected + hashed off-chain by O4). **No
   borrower chain write.**
2. **(AMINA decision, off this surface)** → AMINA approves/rejects via F7, which calls
   `KYBGateway.approve(entity, wallet)` / `revoke(...)`. F6 reflects the resulting on-chain status.

#### States
- **Empty**: "Begin KYB to access the protocol." CTA: Start.
- **Loading**: upload progress; "Submitting…".
- **Submitted / Under review**: "Under review by AMINA (1–3 business days). Confirmation: KYB-YYYY-NNNN."
- **Warning**: KYB expiring soon (`reviewedUntil` near) → "Your approval expires on {date}; re-attestation
  required."
- **Error**: upload failed / missing required doc → field-level errors; submit blocked until all required
  click-throughs are checked.
- **Approved**: "Approved. You can now tokenize collateral." Link → F1.
- **Rejected**: generic AMLA-confidential message ("We are unable to proceed; contact the KYB team"); no
  specific reason (regulatory confidentiality).

#### Copy constraints
- Decision wording: **"AMINA reviews and decides"** / "Approval is AMINA's regulated decision." Never
  imply P2P approves onboarding (P2P is technology only; AMINA holds the FINMA licence, S0.1).
- Rejection copy is intentionally non-specific (AMLA confidentiality).

#### Why Core / What breaks if omitted
**Liability (regulatory).** The on-chain `KYBGateway` is the regulated entry control; F6 is its thin user
surface. If omitted entirely, there is no user path to request approval and no status visibility — though
the **on-chain gate remains the Core control**, so the UI can be manual at launch (hence "thin"). Cutting
the gate itself (not this UI) would let unscreened entities transact (AMLA breach).

---

### S11.7 F7 — AMINA Operator Console

#### Purpose
The privileged surface AMINA uses to **operate the protocol safely** (S0.5 F7; O2). The mockups omitted
every AMINA-action screen (digest_product_ui "AMINA OPS app not mocked") — this surface fills that gap.
Strictly gated by role (S0.6); enforces the S0.10/D-10 separation (no operator both moves collateral and
sets risk params).

#### Layout (regions / tabs)
1. **KYB queue** (`CURATOR`/OPS) — pending entities; Approve / Reject.
2. **Risk params** (`CURATOR`) — per-market versioned params; cap **increases** (timelocked).
3. **Warn / liquidate queue** (`LIQUIDATOR`) — positions by HF; warn, request, finalize.
4. **Oracle status** (`ORACLE_ADMIN` view; override is `EMERGENCY`) — feed health, staleness, overrides.
5. **Pause / caps** (`GUARDIAN`) — pause tiers; cap **decreases**.
6. **Emergency** (`EMERGENCY` 2-of-2) — global halt, delayed oracle override.

Role-gating: each tab is enabled only for wallets holding the corresponding role; actions a wallet
cannot perform are hidden, not just disabled, to keep the separation explicit.

#### Components & data (datum → source)
| Datum | Source |
|---|---|
| Pending KYB entities (legal names — AMINA-only) | Backend API `/kyb/queue` |
| HF heatmap of positions | `BridgeLens` per-borrower HF (`LIQ/currentLTV`) |
| Cure deadlines / liquidation queue | `LiquidationModule` + `SettlementRouter` |
| Risk param versions + caps | `RiskConfig` / `ParameterArchive` (S0.3 #16) |
| Oracle feed health (price, age, heartbeat, breaker) | `OracleAdapter` |
| Pause states (token/market/position) | bridge + token pause flags |
| Cap utilisation | `RiskConfig` caps vs live exposure (Lens) |

#### User actions → contract calls (by role)
1. **KYB approve / reject** (`CURATOR`/OPS) → `KYBGateway.approve(entity, wallet)` /
   `KYBGateway.revoke(wallet)`.
2. **Set risk params / increase cap** (`CURATOR`) → `RiskConfig.setParams(market, params)` (writes a new
   version into `ParameterArchive`; live positions stay pinned to their version, S0.9 inv. 9). Cap
   increases are **timelocked** (S0.6); UI shows the pending-timelock state.
3. **Warn** (`LIQUIDATOR`) → `LiquidationModule.warn(positionId)` (starts cure clock; no token movement).
4. **Request liquidation** (`LIQUIDATOR`) → `LiquidationModule.requestLiquidation(positionId, oracleReport)`
   — eligibility is the **objective oracle predicate**, not discretion (D-7). UI requires attaching the
   signed oracle report; the call reverts if the predicate is not met.
5. **Finalize liquidation** (`LIQUIDATOR`) → `LiquidationModule.finalizeLiquidation(positionId)` after the
   cure window → drives `CollateralBridge.liquidateWithdrawAndBurn` and
   `ReleaseAuthorizer.issueLiquidationRelease(dest=AMINA desk)` (S0.7 6b). Surplus → borrower (state-derived).
6. **Oracle override** (`EMERGENCY`) → delayed/sidecar override (never mutates position terms, S0.6).
7. **Pause / decrease cap** (`GUARDIAN`) → pause tier calls + `RiskConfig` cap **decrease** (hot key may
   only reduce risk, S0.6).
8. **Global halt** (`EMERGENCY` 2-of-2) → global pause.

#### States
- **Empty**: queues empty → "No pending KYB / No positions need attention."
- **Loading**: heatmap + queue skeletons.
- **Warning**: oracle stale → banner "Pricing stale: new borrows blocked; liquidation allowed at last
  price (AMINA bears risk)" (matches S0 oracle posture). Cap near limit → amber.
- **Error**: action reverts (timelock not elapsed, predicate not met, wrong role) → surface S10 error
  (e.g. `TimelockNotElapsed`, `NotEligible`).
- **Success**: per-action toast with tx hash; queue row updates state.

#### Copy constraints
- Liquidation actions framed as **operating an objective trigger**, never discretionary: "Eligibility is
  proven by the oracle report; AMINA operates, it does not decide eligibility" (D-7).
- Rate/param edits: AMINA sets parameters; never "platform sets the rate" — AMINA **is** the curator.
- No operator UI may present a release-destination field (destinations are state-derived, S0.9 inv. 5).

#### Why Core / What breaks if omitted
**Liability + Safety.** Every privileged action (KYB decision, risk params, warn/liquidate, pause,
emergency) needs an operable, role-separated surface; without F7, AMINA runs the protocol by raw scripts
with no guardrails — defeating the S0.6/D-10 privilege separation and making operational errors
(e.g. an operator both moving collateral and setting params) far more likely. It also makes the
objective-trigger liquidation operable in the intended controlled way (attach oracle report, respect cure
window, timelocked cap increases).

---

### S11.8 Frontend ↔ Section cross-references

- HF math and threshold ladder: S0.9 inv. 6, `RiskConfig` (S0.3 #16), `OracleAdapter` (S0.3 #8).
- Borrow/repay/liquidate calls: `CollateralBridge` (S0.3 #10), `MorphoAdapter` (S0.3 #11),
  `LiquidationModule` (S0.3 #13), `ReleaseAuthorizer` (S0.3 #14) — see those sections for full signatures.
- Mint path surfaced by F1: `ReserveGuard` (S0.3 #4), `PledgeRegistry` (S0.3 #6), cBTC token (S0.3 #7),
  `SignedCustodyAdapter` (S0.3 #5).
- Read models: `PortfolioLens`/`BridgeLens` (S0.3 #17); Backend API + indexer (S0.4 O3) for off-chain
  evidence/KYB/freshness.
- Lifecycle states the UI renders: S0.8 position state machine. Custody acknowledgement that closes the
  repay/liquidation loop: `SettlementRouter` (S0.3 #15) + custody listener (S0.4 O6).


## S12. Security Model, Invariants, Test Plan, Deployment & Build Plan

This section is the security and operations contract for everything specified in S1–S11. It enumerates the attacker classes Triora Core must withstand and binds each to a concrete control and to one or more S0.9 invariants; expands S0.9 into a full, testable invariant catalog naming the enforcing contract; specifies the `forge` test plan (unit / fuzz / invariant / fork / negative) with concrete file and function names; restates the five acceptance gates; gives the deployment order, role-wiring and immutable-binding ceremonies plus the operational runbooks; defines the off-chain Core data model; and lays out the prioritized build plan. Every control below is justified against the Solvency / Liability / Reversibility tests of `Triora-Core-vs-Optional-3.md` Part 0.

This is a Model B deployment (S0.10): a `CollateralBridge` over one isolated Morpho market (cBTC collateral / USDC loan), AMINA-curated `FixedRateIRM`, per-borrower sub-ledger in the bridge. No cUSDC, no off-chain USDC settlement. References to "the bridge", roles, and structs use the exact names in S0.

### S12.1 Threat model — attacker classes and mitigating controls

The protocol is modeled as a set of partially-trusted actors, each of which may be malicious or compromised, plus fully external adversaries. The design rule (S0.6, S0.9 #8) is privilege separation: no single key both moves collateral/USDC **and** sets risk parameters, and hot keys may only *reduce* risk. The table maps each attacker class to its primary control and the invariants that control upholds.

| # | Attacker class | What they can attempt | Primary control(s) | S0.9 invariant(s) defended | Residual risk / fallback |
|---|----------------|----------------------|--------------------|----------------------------|--------------------------|
| T1 | **Compromised `ISSUER_MINTER` key** (custodian/CRE mint key) | Mint cBTC with no real BTC behind it; over-mint against a real pledge; mint after release. | `ReserveGuard.checkMint` fail-closed (`supply+amt ≤ min(freshPoR,freshAttestation)−margin`) sits *in* the mint path (S2/`ReserveGuard`); `PledgeRegistry` enforces `minted ≤ pledged`, one deal per pledge, no remint after release (S2/`PledgeRegistry`); cBTC mint is `pledgeBound` + reserve-guarded (S2/cBTC). | INV-1, INV-2, INV-3, INV-13 | A compromised mint key cannot exceed attested reserves; worst case = mint up to `pledged−minted` of an existing real pledge, caught by INV-2 and monitoring (S12.9 M-1). `GUARDIAN` pauses the token. |
| T2 | **Compromised AMINA hot key** (`ALLOCATOR` / `LIQUIDATOR` / `GUARDIAN`) | Open spurious positions; trigger liquidation without cause; redirect released collateral; loosen risk to inflate exposure. | Eligibility is an *objective oracle predicate*, not discretion — `LiquidationModule` requires a fresh `OracleAdapter` breach + elapsed cure window (S4); release destination is *state-derived*, never caller-supplied (S4/`ReleaseAuthorizer`); hot keys can only *reduce* risk (S0.6, `GUARDIAN`=cap decreases/pause only); `ALLOCATOR` is rate-limited and bounded by caps + signatures; per-`LIQUIDATOR`-wallet daily cap. | INV-5, INV-6, INV-7, INV-8, INV-15, INV-18 | A rogue `LIQUIDATOR` cannot liquidate a healthy position (oracle gate) nor send proceeds anywhere but the AMINA desk (state-derived voucher); surplus still routes to borrower (INV-7). Every off-chain movement still needs AMINA co-sign **and** a consumed voucher (INV-10). |
| T3 | **Malicious borrower** | Borrow then refuse to repay; self-release collateral without repaying; double-pledge; replay a release voucher; grief via dust. | Borrow draws only via `CollateralBridge.borrow` against a locked pledge; release on repay path requires `outstanding==0` (INV-4 inverse); voucher destination derived from state (borrower only on Repaid) and one-use (INV-5); `PledgeRegistry` one-deal-per-pledge (INV-2); cBTC is non-transferable except protocol paths (INV-3). | INV-2, INV-3, INV-4, INV-5 | Borrower default is a *credit* event handled by liquidation (objective trigger), not a contract break. A borrower can never extract collateral without clearing debt. |
| T4 | **Stale / manipulated oracle** | Feed a wrong BTC/USD price to over-value collateral (block legitimate liquidation) or under-value it (force a wrongful liquidation). | `OracleAdapter` enforces staleness (`updatedAt`), `answer>0`, round completeness (`answeredInRound ≥ roundId`), decimal normalization, and a **peg cap** (cBTC valued at `min(market, attestedReserveValue)`) so it can never be valued above its backing (S2/`OracleAdapter`); liquidation reads the same adapter; `EMERGENCY` oracle override is a delayed sidecar that never mutates terms (S0.6, S11). | INV-6, INV-16, INV-17 | Stale feed fails *closed* for new mints/borrows; for liquidation, a stale feed blocks the AMINA path but the Morpho LLTV backstop still protects the lender. Flash-loan price manipulation is bounded by Chainlink (not a spot AMM). |
| T5 | **Custodian non-cooperation / compromise** | Refuse to act on a valid release voucher; move pledged BTC unilaterally; sign a false reserve attestation. | Dual-signature custody (custodian **+** AMINA EIP-712) for every fact and every movement (S0.1, INV-10) — neither party acts alone; `min(PoR, attestation)` reserve source so a single false attestation cannot inflate the limit beyond PoR (S2/`ReserveGuard`); off-chain control agreement perfects AMINA's enforcement right (the legal layer, not the token, is what survives bankruptcy — see web_triparty UCC §9-314). | INV-1, INV-10, INV-19 | A non-cooperating custodian is a *liability/legal* failure, not a solvency break: the on-chain claim stays burned-pending and the dispute is resolved under the control agreement. Monitoring pages on `isLockActive==false` and unacknowledged vouchers (S12.9 M-4, M-7). |
| T6 | **Morpho market risk** (the external venue) | Lender liquidity dries up at repay/withdraw; permissionless liquidator front-runs AMINA; market parameters change under the bridge. | The market is **isolated and immutable** (one cBTC/USDC market, fixed oracle/LLTV/IRM — S3); AMINA's internal threshold is **strictly tighter than Morpho LLTV** (INV-6) so AMINA always acts first and the permissionless path is a backstop only; `MorphoAdapter` isolates the bridge from the ABI (S3, Reversibility). | INV-6, INV-4, INV-20 | If Morpho liquidates first (AMINA bot down past the LLTV gap), the lender is still made whole — that is the backstop's purpose. The bridge sub-ledger reconciles the seized aggregate position to the affected borrower(s). |
| T7 | **Off-chain settlement / listener failure** | A custody instruction executes with no matching voucher; a voucher is acted on twice; the listener processes a replayed event. | The custody listener acts on `SettlementRouter` vouchers **only**, requires AMINA co-sign, and acknowledges back on-chain *idempotently* (S0.4 O6, S5); `SettlementRouter` is append-only with monotonic `sequenceNumber` for gap detection (S4/`SettlementRouter`); vouchers are one-use (INV-5). | INV-5, INV-10, INV-11 | A dropped ack leaves the position in `ReleasePending` (recoverable, not lost). A sequence gap pages immediately (S12.9 M-6). No movement is ever authorized by anything but a consumed voucher + co-sign. |
| T8 | **Compromised `GOVERNOR` / upgrade key** (P2P) | Upgrade the bridge to malicious logic; rewire contracts; drain via a new implementation. | The spine is **immutable** (token, registries, vault-of-record, vouchers, settlement router, parameter archive — S0.2 D-9); only the `CollateralBridge` engine is UUPS and it is behind a **timelock** with `GOVERNOR` = P2P 3-of-5 Safe; `GOVERNOR` cannot move collateral or set risk values (S0.6); ERC-7201 storage layout is CI-validated to block storage-collision upgrades. | INV-8, INV-9, INV-21 | A malicious upgrade is timelocked (24h default), giving `EMERGENCY` (joint 2-of-2) time to halt. Immutable spine means backing/accounting rules cannot be changed under users even by a captured upgrader. |
| T9 | **External / permissionless attacker** (no role) | Call protocol functions directly; reenter; donate tokens to corrupt accounting; manipulate via flash loan. | Every state-changing user action is KYB-gated (S1/`KYBGateway`); `nonReentrant` on all external-call functions (mint, borrow, repay, liquidate); vault reconciliation uses `≥` so unsolicited donations become unattributed (sweepable by `GOVERNOR`+TL only — INV-12); flash-loan-accessible preconditions (price, reserve) are read from Chainlink + attestations, not spot balances. | INV-3, INV-9, INV-12 | An unscreened caller cannot transact at all (KYB revert). cBTC cannot leak into open DeFi (INV-3 both-sides allowlist). |

#### Why Core / What breaks if omitted

The threat model passes the **Liability** and **Solvency** tests. If omitted, controls would be added ad hoc per incident with no proof that each attacker class is covered — the exact failure that produced PYUSD's 300T mint (a system that *had* an issuer access check but no reserve guard in the mint path). Each row that is cut re-opens a named loss: drop T1's `ReserveGuard` → unbacked cBTC (Solvency death); drop T2's state-derived vouchers → an operator redirects a borrower's BTC (Liability); drop T8's immutable spine → backing rules change under users (Reversibility — retrofitting immutability is impossible). The threat→control→invariant mapping is what the audit and the test plan (S12.3) are graded against.

### S12.2 Invariant catalog (full, testable; expands S0.9)

The ten S0.9 invariants are expanded to twenty (INV-1…INV-20) plus one privilege-separation meta-invariant (INV-21). Each names the **enforcing contract**, a one-line statement, and the test that proves it (test IDs defined in S12.3). "Formal" marks Halmos/Certora candidates.

| ID | Invariant (must hold at all times) | Enforced by | S0.9 ref | Proof |
|----|------------------------------------|-------------|----------|-------|
| INV-1 | `cBTC.totalSupply() ≤ min(freshPoR, freshAttestation) − margin` | `ReserveGuard` (mint path) | 1 | `invariant_supplyNeverExceedsReserve`; `test_mint_revertsWhenAtReserveLimit` |
| INV-2 | For every pledge: `mintedAmount ≤ pledgedAmount`; `encumbered ≤ minted`; ≤1 active position per pledge | `PledgeRegistry` | 2 | `invariant_mintedLEpledged`; `test_pledge_rejectsSecondDeal` |
| INV-3 | cBTC transfers succeed **only** on protocol paths; both `from` **and** `to` checked | cBTC (`_update` override) | 3 | `test_transfer_revertsNonAllowlistedFrom/To`; `invariant_noOpenMarketTransfer` |
| INV-4 | Position is `Active` **iff** Morpho `borrow` succeeded and USDC reached the borrower; interest accrues only from `Active` | `CollateralBridge` | 4 | `test_borrow_setsActiveOnlyOnDelivery`; `invariant_noInterestBeforeActive` |
| INV-5 | Release destination is **state-derived** (Repaid→borrower, Liquidated→AMINA desk), never caller-supplied; each voucher one-use | `ReleaseAuthorizer` | 5 | `test_voucher_destinationFromState`; `test_voucher_replayReverts` (formal: one-use) |
| INV-6 | AMINA liquidation threshold **<** Morpho market LLTV | `RiskConfig` / `LiquidationModule` | 6 | `invariant_aminaThresholdBelowLLTV`; `test_riskConfig_rejectsThresholdAboveLLTV` |
| INV-7 | Liquidation surplus (`proceeds − debt − bonus − fee`) → borrower; ungovernance-seizable | `LiquidationModule` | 7 | `test_liquidation_surplusToBorrower`; `invariant_surplusNotSeizable` (formal) |
| INV-8 | No role both moves collateral/USDC **and** sets risk params | `RoleManager` (role graph) | 8 | `test_roles_privilegeSeparation` (formal candidate) |
| INV-9 | `PositionRegistry` terms are write-once; risk params version-pinned per position | `PositionRegistry` / `ParameterArchive` | 9 | `test_position_termsImmutable`; `test_param_versionPinnedToPosition` |
| INV-10 | Every off-chain custody movement is authorized by exactly one consumed voucher **and** an AMINA co-signature | `ReleaseAuthorizer` + off-chain listener (S5) | 10 | `test_listener_rejectsNoVoucher`; `test_listener_rejectsNoAminaSig` (off-chain harness) |
| INV-11 | `SettlementRouter` events are append-only with strictly-increasing `sequenceNumber` per stream | `SettlementRouter` | (10 support) | `test_router_sequenceMonotonic`; `invariant_noSequenceGapOrReuse` |
| INV-12 | Vault/bridge reconciliation: `cBTC.balanceOf(bridge) ≥ Σ(sub-ledger encumbered)`; excess = unattributed, sweepable only by `GOVERNOR`+TL | `CollateralBridge` | (2 support) | `invariant_bridgeBalanceGEledgerSum`; `test_donation_becomesUnattributed` |
| INV-13 | A released/burned pledge can never be re-minted or re-bound | `PledgeRegistry` | (2 support) | `test_pledge_noRemintAfterRelease` |
| INV-14 | Per-borrower sub-ledger outstanding sums to ≤ the bridge's aggregate Morpho borrow | `CollateralBridge` | (4 support) | `invariant_subledgerSumLEaggregate`; `test_subledger_attribution` |
| INV-15 | `FixedRateIRM` returns the AMINA-curated fixed APR for the market (no variable drift) | `FixedRateIRM` | (D-3) | `test_irm_returnsFixedRate`; `invariant_borrowerRateIsFixed` |
| INV-16 | Oracle reads reject `answer≤0`, stale `updatedAt`, incomplete round; decimals normalized to USDC=6 / cBTC=8 | `OracleAdapter` | (peg cap) | `test_oracle_revertsStale/Negative/IncompleteRound`; `test_oracle_decimalNormalization` |
| INV-17 | cBTC is valued at `min(marketPrice, attestedReserveValue)` — never above its backing | `OracleAdapter` | (peg cap) | `test_oracle_pegCapAppliesBelowMarket` |
| INV-18 | Interest accrues only in `Active`/`Warned`/`RepaymentPending`; never before `Active`; pause stops the clock | `CollateralBridge` | (S0.8) | `invariant_interestOnlyInLiveStates`; `test_pause_stopsInterestClock` |
| INV-19 | Reserve config (quantity) and price config (USD) never share structs or heartbeat fields | `TokenizationRegistry` / `OracleAdapter` | (por_cre) | `test_config_reserveAndPriceSeparated` |
| INV-20 | Defaulted shortfall (proceeds < debt) is booked off-chain to AMINA and **not** socialized to other borrowers/lenders | `LiquidationModule` / `CollateralBridge` | (S0.8) | `test_default_shortfallNotSocialized` |
| INV-21 | (meta) No single key can both inflate risk and move funds; hot keys reduce-only; cap *increases* require `CURATOR`(+TL) | `RoleManager` | 8 | `test_roles_hotKeyReduceOnly`; `test_roles_capIncreaseRequiresCurator` |

#### Why Core / What breaks if omitted

A written invariant with no enforcing contract and no test is "PoR theater" (por_cre). Each invariant passes Solvency or Liability and is what the fuzz/invariant suite (S12.3) executes against random action sequences. Omit INV-1/INV-2 → infinite mint; omit INV-5/INV-10 → collateral redirection; omit INV-12 → a donation breaks accounting; omit INV-21 → one captured key drains and mis-prices everything. The catalog is the bridge between the threat model (S12.1) and the executable tests (S12.3).

### S12.3 Test plan (Foundry / `forge`)

Build command: `forge build`. Test command: `forge test --match-test test_{ID} -vvv`. Fuzz/invariant: `forge test --match-contract {Invariant} -vvv`. Fork: `forge test --match-test test_{ID} --fork-url $MAINNET_RPC -vvv`. Fee split for surplus math: 40 bps total = 20 bps P2P + 20 bps AMINA, plus AMINA liquidation bonus (reviews_gaps). LTV ladder: Max LTV 70%, Morpho LLTV 80%, AMINA threshold strictly < 80% (e.g. 77%). HF math is `LIQ/currentLTV` (HF=1.00 at 80%, HF≈1.14 at 70%) — never `MAX_LTV/currentLTV` (the mockup's bug).

#### S12.3.1 Unit tests (per contract)

| Test file | Targets | Representative functions |
|-----------|---------|--------------------------|
| `test/unit/ReserveGuard.t.sol` | `ReserveGuard` | `test_checkMint_passesUnderLimit`, `test_checkMint_revertsOverLimit`, `test_checkMint_revertsStalePoR`, `test_checkMint_revertsNegativeReserve`, `test_checkMint_usesMinOfSources`, `test_margin_appliedPositiveOnly` |
| `test/unit/PledgeRegistry.t.sol` | `PledgeRegistry` | `test_registerPledge`, `test_recordMint_revertsOverPledged`, `test_lockForDeal_oneActivePerPledge`, `test_markReleased_blocksRemint`, `test_encumberedLEminted` |
| `test/unit/PermissionedCollateralToken.t.sol` | cBTC | `test_mintForPledge_onlyIssuerMinter`, `test_transfer_revertsNonAllowlistedFrom`, `test_transfer_revertsNonAllowlistedTo`, `test_burnForRelease_onlyVoucher`, `test_decimals_is8` |
| `test/unit/OracleAdapter.t.sol` | `OracleAdapter` | `test_oracle_revertsStale`, `test_oracle_revertsNegative`, `test_oracle_revertsIncompleteRound`, `test_oracle_decimalNormalization`, `test_oracle_pegCapAppliesBelowMarket` |
| `test/unit/CollateralBridge.t.sol` | `CollateralBridge` | `test_borrow_setsActiveOnlyOnDelivery`, `test_subledger_attribution`, `test_repay_reducesOutstanding`, `test_pause_stopsInterestClock`, `test_noInterestBeforeActive` |
| `test/unit/ReleaseAuthorizer.t.sol` | `ReleaseAuthorizer` | `test_issueRepaymentRelease_destBorrower`, `test_issueLiquidationRelease_destAminaDesk`, `test_voucher_replayReverts`, `test_voucher_destinationNotCallerSupplied` |
| `test/unit/LiquidationModule.t.sol` | `LiquidationModule` | `test_warn_startsCureClock`, `test_finalize_revertsBeforeCure`, `test_surplusToBorrower`, `test_default_shortfallNotSocialized`, `test_eligibility_requiresOracleBreach` |
| `test/unit/FixedRateIRM.t.sol` | `FixedRateIRM` | `test_irm_returnsFixedRate`, `test_irm_noVariableDrift` |
| `test/unit/RoleManager.t.sol` | `RoleManager` | `test_roles_privilegeSeparation`, `test_roles_hotKeyReduceOnly`, `test_roles_capIncreaseRequiresCurator`, `test_governorCannotMoveCollateral` |
| `test/unit/KYBGateway.t.sol` | `KYBGateway` | `test_requireApproved_revertsUnapproved`, `test_requireApproved_revertsExpired`, `test_borrow_revertsUnscreened` |
| `test/unit/SettlementRouter.t.sol` | `SettlementRouter` | `test_router_sequenceMonotonic`, `test_router_appendOnly` |
| `test/unit/RiskConfig.t.sol` | `RiskConfig`/`ParameterArchive` | `test_param_versionPinnedToPosition`, `test_riskConfig_rejectsThresholdAboveLLTV`, `test_archive_writeOncePerVersion` |

#### S12.3.2 Fuzz tests (boundary values)

`test/fuzz/` — each uses `bound()` on amounts/timing/ordering. Boundary set per parameter: `{0, 1, dust, typical, maxPledged, type(uint256).max}` for amounts; `{0, <cure, ==cure, >cure}` for timing.

- `testFuzz_mint_neverExceedsReserve(uint256 amt, uint256 reserve, uint256 margin)` — asserts INV-1 across the full range, including `amt` at `reserve−margin` boundary.
- `testFuzz_borrow_respectsMaxLTV(uint256 collateral, uint256 borrow)` — borrow must revert above 70% Max LTV.
- `testFuzz_repay_partialAndFull(uint256 outstanding, uint256 repayAmt)` — outstanding never goes negative; release only at zero.
- `testFuzz_liquidate_surplusMath(uint256 collateral, uint256 debt, uint256 price)` — surplus = `max(0, proceeds−debt−bonus−fee)`; never negative; never exceeds collateral.
- `testFuzz_oracle_normalization(int256 answer, uint8 feedDecimals)` — value scales to cBTC=8 deterministically; rejects ≤0.
- `testFuzz_cure_timing(uint64 warnTs, uint64 finalizeTs)` — finalize reverts iff `finalizeTs − warnTs < cureWindow`.

#### S12.3.3 Invariant tests (stateful, random action sequences)

`test/invariant/TrioraInvariants.t.sol` with a handler (`test/invariant/handlers/BridgeHandler.sol`) exposing `mint`, `borrow`, `repay`, `topUp`, `warn`, `finalizeLiquidation`, `donate`, `advanceTime`, `setPrice` as fuzzable actions. The handler is the *only* actor; the invariant functions assert after every call sequence:

- `invariant_supplyNeverExceedsReserve()` — INV-1 (`cBTC.totalSupply ≤ reserves − margin`) under random mint/repay/price sequences.
- `invariant_mintedLEpledged()` — INV-2.
- `invariant_noOpenMarketTransfer()` — INV-3 (no allowlisted-bypass transfer ever succeeds).
- `invariant_noInterestBeforeActive()` / `invariant_interestOnlyInLiveStates()` — INV-4, INV-18.
- `invariant_aminaThresholdBelowLLTV()` — INV-6.
- `invariant_surplusNotSeizable()` — INV-7.
- `invariant_bridgeBalanceGEledgerSum()` — INV-12 (donations become unattributed, never credited).
- `invariant_subledgerSumLEaggregate()` — INV-14.
- `invariant_noSequenceGapOrReuse()` — INV-11.

Run config: `forge` invariant `runs = 256`, `depth = 50`, `fail_on_revert = false` (handler bounds inputs so reverts are expected, not failures).

#### S12.3.4 Fork tests (mainnet fork, real Morpho + Chainlink)

`test/fork/OneDealLifecycle.t.sol`, `--fork-url $MAINNET_RPC`, pinned block. Uses the real Morpho Blue singleton, the real Chainlink BTC/USD feed, and a mock `SignedCustodyAdapter` (signed attestations are off-chain by design).

- `test_fork_oneDealLifecycleReconciles()` — the full S0.7 loop: dual attestation → secure-mint cBTC → `supplyCollateral` + `borrow` USDC to borrower (real Morpho) → accrue at fixed APR → repay → state-derived voucher → (simulated) custody release ack → burn cBTC → assert ledger and the bridge sub-ledger reconcile to the satoshi (this is Acceptance Gate 1, S12.4).
- `test_fork_morphoBackstopLiquidation()` — drive price below Morpho LLTV without AMINA acting; assert a permissionless liquidator can liquidate the bridge position on real Morpho and the lender is made whole.
- `test_fork_aminaLiquidatesBeforeBackstop()` — price between AMINA threshold (77%) and LLTV (80%); assert AMINA's `LiquidationModule` path liquidates first and surplus returns to borrower.
- `test_fork_chainlinkStaleness()` — warp past the BTC/USD heartbeat; assert `OracleAdapter` flags stale and new mint/borrow fail closed.

#### S12.3.5 Negative tests (must revert)

`test/negative/Negatives.t.sol` — each asserts a revert with the specific custom error:

- `test_neg_stalePoRBlocksMint()` — stale/negative/missing PoR → `ReserveGuard` revert (fail-closed).
- `test_neg_transferToNonAllowlistedReverts()` and `test_neg_transferFromNonAllowlistedReverts()` — cBTC `_update` reverts on **both** sides.
- `test_neg_liquidationBeforeCureReverts()` — `finalizeLiquidation` before cure deadline → revert.
- `test_neg_voucherReplayReverts()` — consuming a spent voucher → revert.
- `test_neg_unauthorizedCustodyInstructionRejected()` — off-chain listener harness (`test/offchain/Listener.t.ts`) rejects an instruction with no matching voucher OR no AMINA co-sign.
- `test_neg_callerSuppliedDestinationIgnored()` — a release call attempting to pass a destination has it ignored in favor of the state-derived one.
- `test_neg_thresholdAboveLLTVRejected()` — `RiskConfig` rejects an AMINA threshold ≥ Morpho LLTV (INV-6 cannot be misconfigured).
- `test_neg_unscreenedBorrowerReverts()` — `KYBGateway` blocks an unapproved/expired wallet.
- `test_neg_governorCannotMoveCollateral()` — `GOVERNOR` calling a collateral-moving function reverts (INV-8/INV-21).

#### Why Core / What breaks if omitted

The test plan is the executable form of S12.2 and is graded by Acceptance Gate 2 (invariants) and Gate 3 (negatives). It passes the Solvency test: a `[POC-PASS]`-style invariant counterexample is the only ground truth that the backing/redirection guarantees actually hold under adversarial sequences. Omit the invariant suite → invariants are asserted but never exercised (PYUSD failure class); omit the fork test → the one-deal reconciliation (the real "done" signal per claude_arch "the first demo is a deal, not a dashboard") is never proven against real Morpho/Chainlink; omit negatives → fail-closed behavior is assumed, not verified.

### S12.4 Acceptance gates (the five from vision Part 6)

The Core is "done" only when all five hold. These are reproduced verbatim in intent from `Triora-Core-vs-Optional-3.md` Part 6 and bound to the tests above.

1. **One-deal lifecycle on a mainnet fork reconciles to the satoshi** — `test_fork_oneDealLifecycleReconciles` (S12.3.4) passes: deposit → dual attestation → reserve-guarded secure-mint → bridge `supplyCollateral` + `borrow` USDC to borrower → accrue → repay → state-derived voucher → custody release → burn cBTC → ledger and custody reconcile exactly.
2. **Invariant suite passes** (fuzz + formal where possible) — all `invariant_*` in S12.3.3 green; INV-1, INV-2, INV-5, INV-6, INV-7, INV-8 are the non-negotiable subset; Halmos/Certora run on the formal candidates (INV-5 one-use, INV-7 surplus, INV-8/INV-21 privilege separation).
3. **Negative tests pass** — every S12.3.5 case reverts as specified (stale PoR blocks mint; both-sided allowlist; pre-cure liquidation; voucher replay; unauthorized custody instruction).
4. **External audit + legal opinion** — third-party audit of the spine + bridge complete with all Critical/High resolved; legal opinion that the control agreement perfects the security interest (UCC §9-314 control) and that P2P is not a custodian/issuer/broker.
5. **Monitoring live with paging on every invariant** before the first mainnet pledge — all S12.9 monitors deployed and alerting.

#### Why Core / What breaks if omitted

The gates pass all three tests at once and are the release contract. Without them, "done" silently degrades to "the dashboard renders" — the exact anti-pattern both prior architectures (claude_arch, gpt_arch) explicitly reject. Gate 4 (legal opinion) is the only thing standing between "regulated infrastructure" and P2P being reclassified as a broker/custodian (Liability test).

### S12.5 Deployment order, role wiring, immutable-binding ceremonies

Deployment is staged so that immutable contracts are deployed and cross-wired first (their addresses are constructor args downstream), then the upgradeable engine, then the binding ceremonies, then role grants, and finally the irreversible revocations. Use CREATE2 with vanity salts for the immutable spine so addresses are predictable across the wiring.

**Phase D-0 — Libraries:** deploy `Types`, `Errors`, `Roles`, `Math`, `EIP712Hashes` (linked or inlined).

**Phase D-1 — Immutable spine (CREATE2):**
1. `RoleManager` (OZ AccessManager; immutable) — deploy with the deployer as temporary admin.
2. `PermissionedCollateralToken` (cBTC, 8 decimals; immutable) — constructor pins `RoleManager`, decimals.
3. `SignedCustodyAdapter` (immutable per custodian) — pins custodian + AMINA signer keys, EIP-712 domain.
4. `PositionRegistry` (immutable) — pins `RoleManager`.
5. `SettlementRouter` (immutable, versioned) — pins `RoleManager`.
6. `ParameterArchive` (immutable) — pins `RoleManager`.
7. `FixedRateIRM` (immutable) — pins the AMINA-curated fixed APR.
8. `MorphoAdapter` (immutable) — pins the Morpho singleton + the isolated market id.

**Phase D-2 — UUPS engines (behind timelock):** deploy proxies + impls for `KYBGateway`, `TokenizationRegistry`, `ReserveGuard`, `PledgeRegistry`, `OracleAdapter`, `CollateralBridge`, `LiquidationModule`, `ReleaseAuthorizer`, `RiskConfig`. Each `initialize()` pins its immutable dependencies by address. Set the proxy admin to the `GOVERNOR` timelock.

**Phase D-3 — Isolated Morpho market creation:** create the one immutable cBTC/USDC market on Morpho Blue with `OracleAdapter` as oracle, `FixedRateIRM` as IRM, and the chosen LLTV (e.g. 80%). Record the market id; it is now immutable.

**Phase D-4 — Immutable-binding ceremonies (one-shot, then revoked):**
- `cBTC.bindMinter(ISSUER_MINTER)` and `cBTC.bindBurner(ReleaseAuthorizer)` — one-time; deployer's binding right is then revoked.
- `cBTC.setAllowlist(bridge, MorphoAdapter, ReserveGuard paths)` — the protocol-path allowlist for INV-3; then frozen.
- `CollateralBridge.bindMarket(morphoMarketId, MorphoAdapter)` — one-time.
- `ReserveGuard.bindSources(SignedCustodyAdapter, [optional PoR feed])` with `sourceMode = MinOfAdapterAndChainlink` or `AdapterOnly` (pilot) — set once.
- `PledgeRegistry.bindConsumers(cBTC, CollateralBridge, ReleaseAuthorizer)` — one-time.
- `RiskConfig.setMarketParams(maxLTV=70%, aminaThreshold=77%, morphoLLTV=80%, cureWindow=48h, fees)` — with the on-chain assertion `aminaThreshold < morphoLLTV` (INV-6); snapshot to `ParameterArchive` v1.

**Phase D-5 — Role wiring (`RoleManager`):**
- Grant `GOVERNOR` → P2P 3-of-5 Safe; `CURATOR` → AMINA 2-of-3 Safe; `ALLOCATOR` → AMINA ops hot wallet (rate-limited); `LIQUIDATOR` → AMINA bot wallet set (per-wallet daily cap); `ISSUER_MINTER` → custodian/CRE mint key; `GUARDIAN` → AMINA OPS; `EMERGENCY` → joint P2P+AMINA 2-of-2; `ORACLE_ADMIN` → AMINA+Chainlink 2-of-3.
- Configure the timelock (24h default, emergency-shortenable to 1h) for upgrades, cap *increases*, market/token admission, oracle param versions.
- Assert privilege separation (INV-8/INV-21): no address holds both a fund-moving role and a risk-setting role; run `test_roles_privilegeSeparation` against the live wiring.

**Phase D-6 — Irreversible revocations:** revoke the deployer's temporary admin on `RoleManager`; revoke all one-shot binding rights; transfer proxy admin fully to the timelock. After this point the spine is immutable and the engine is only changeable via timelocked `GOVERNOR` upgrade.

**Phase D-7 — Monitoring + listener bring-up:** deploy the custody listener, attestation signer, risk/liquidation bot, indexer, and all S12.9 monitors; confirm paging end-to-end **before** the first mainnet pledge (Gate 5).

#### Why Core / What breaks if omitted

The ceremony order passes the Solvency + Reversibility tests: immutable-first wiring means the spine's addresses and bindings are fixed before any value flows, and the irreversible revocations (D-6) are what make "immutable spine" true rather than aspirational. Omit the `aminaThreshold < morphoLLTV` assertion at D-4 → INV-6 can be misconfigured at deploy (AMINA loses first-mover control or Morpho liquidates first). Omit D-6 revocations → a retained deployer key is a permanent backdoor.

### S12.6 Runbooks

Each runbook is owned by a role and references the contracts/roles in S0.6.

- **Key rotation** (`LIQUIDATOR`, `ALLOCATOR` hot keys; `GOVERNOR`/`CURATOR`/`EMERGENCY` Safes): hot keys are rotatable via `RoleManager.grantRole`/`revokeRole` by `GOVERNOR` (timelocked for non-emergency). Procedure: pre-stage new key → `EMERGENCY`/`GUARDIAN` pause the affected surface → revoke old, grant new → unpause → verify with a no-op liquidation/allocation dry-run. Safe membership changes follow the multisig's own threshold (2-of-3 / 3-of-5 / 2-of-2).
- **Pause** (`GUARDIAN` for token/market/position; `EMERGENCY` for global halt): `GUARDIAN.pause(target)` is immediate (hot key, reduce-risk-only). Pause is a boolean overlay (S0.8) that stops the interest clock; it never advances state. Global halt allows repay/top-up/claim-surplus/claim-released paths so users can still de-risk. Unpause requires `CURATOR` (or `GOVERNOR` for global).
- **Oracle override** (`EMERGENCY` 2-of-2): `forceOracleOverride(market, prices, reason)` writes a sidecar `oracleOverride` with `effectiveAt = now + EMERGENCY_GRACE` (~30 min); it **never** mutates `PositionRegistry` terms or `paramVersion` (S11). Used only when Chainlink is provably wrong/stale and liquidation correctness is at risk. Loud event; logged for audit.
- **Custody exception** (custodian + AMINA, via control agreement): when a custodian cannot act on a valid voucher (operational/legal), the position holds in `ReleasePending`; resolution is off-chain under the control agreement. The voucher is NOT re-issued (one-use, INV-5); a superseding voucher requires a documented governance-delay path. No on-chain state is forced.
- **Incident response** (joint, `EMERGENCY` lead): (1) `GUARDIAN`/`EMERGENCY` pause the smallest sufficient scope; (2) triage against the S12.2 invariant catalog to identify which invariant broke; (3) if engine bug → `EMERGENCY` global halt → `GOVERNOR` timelocked UUPS upgrade with CI-verified empty storage-layout diff → unhalt; (4) if spine bug → no on-chain recovery for the immutable vault-of-record logic (honestly stated, per claude_arch) → custodian/issuer freeze + legal process + post-mortem migration; (5) write a public post-mortem; (6) feed the root cause back into the invariant suite as a new regression test.

#### Why Core / What breaks if omitted

Runbooks pass the Liability + Safety tests: a live exploit with no rehearsed pause/halt path is an unrecoverable incident. The honesty about the spine's worst case (step 4) is deliberate — pretending a magical evacuation exists is the over-stated claim both prior architectures retracted. Omit oracle-override-as-sidecar → an override mutates the immutable legal record (Liability). Omit key rotation → a leaked hot key cannot be cleanly retired.

### S12.7 Off-chain Core data model (DB tables)

The backend (S0.4 O3) persists a read model and the audit trail. Real custody facts and signatures live here; the chain holds hashes/refs. All tables are append-or-versioned; nothing solvency-relevant is mutated in place. Amounts are stored as exact integers in native decimals (cBTC=8, USDC=6) plus a normalized USD column for the UI.

| Table | Key columns | Purpose |
|-------|-------------|---------|
| `entities` | `entity_id` (PK), legal_name, jurisdiction, amina_client_id, kyb_status, kyb_expiry, docs_hash | KYB intake + the on-chain `KYBGateway` mirror; one row per institution. |
| `wallets` | `wallet` (PK), entity_id (FK), role (borrower/lender), approved_at, revoked_at | Wallet↔entity binding; mirrors KYB approvals. |
| `kyb_documents` | `doc_id` (PK), entity_id (FK), kind, sha256, storage_uri, uploaded_at | Hashed evidence; only the hash goes on-chain. |
| `pledges` | `pledge_id` (PK), entity_id, custody_account_ref, custodian_id, pledged_amt(8), minted_amt(8), encumbered_amt(8), status, control_agreement_hash, latest_attestation_id | Off-chain twin of `PledgeRegistry`; reconciliation source. |
| `custody_attestations` | `attestation_id` (PK), pledge_id, reserve_qty(8), as_of, expires_at, custodian_sig, amina_sig, onchain_tx | The dual EIP-712 packets; feed `ReserveGuard` / `SignedCustodyAdapter`. |
| `reserve_snapshots` | `snapshot_id` (PK), token, por_qty(8), attestation_qty(8), effective_limit(8), source_mode, taken_at | PoR/attestation history powering the reserve-ratio UI and the supply>reserve monitor. |
| `positions` | `position_id` (PK), borrower_wallet, pledge_id, principal(6), apr_bps, maturity_ts, market_id, param_version, legal_hash, state, opened_at | Off-chain twin of `PositionRegistry` + bridge sub-ledger; the consolidated position view (F3). |
| `subledger_entries` | `entry_id` (PK), position_id, outstanding(6), accrued_interest(6), as_of | Per-borrower accrual snapshots (the bridge sees only the aggregate). |
| `vouchers` | `voucher_id` (PK), position_id, pledge_id, dest_type (Borrower/AminaDesk), reason (REPAID/LIQUIDATED/SURPLUS), amount(8), sequence_no, issued_at, consumed_at, ack_tx | Release-voucher ledger; gap/idempotency detection (T7, INV-5/INV-11). |
| `settlement_events` | `event_id` (PK), stream, sequence_no, type, ref_hash, payload_hash, block, tx, observed_at | Indexed `SettlementRouter` stream; gap detection. |
| `liquidations` | `liq_id` (PK), position_id, warned_at, cure_deadline, oracle_report_ref, proceeds(6), debt(6), bonus(6), fee(6), surplus(8), shortfall(6), state | Cure-window + surplus/shortfall audit (INV-7, INV-20). |
| `risk_params` | `param_version` (PK), market_id, max_ltv_bps, amina_threshold_bps, morpho_lltv_bps, cure_window_s, fees, created_at | Versioned params mirror of `RiskConfig`/`ParameterArchive`; positions pin a version. |
| `alerts` | `alert_id` (PK), monitor, severity, position_id, detail, raised_at, acked_at | Monitoring audit trail (S12.9). |

Failure handling: all writers are **idempotent on (sequence_no, stream)** for chain-derived rows; the custody listener is FAIL-CLOSED — it will not emit a custody instruction unless a matching, unconsumed `vouchers` row + AMINA co-sign exists. Replay of a settlement event with a seen sequence_no is a no-op write.

#### Why Core / What breaks if omitted

The data model passes Solvency (reconciliation) + Liability (audit trail). It is what makes the Account/evidence hub (F4) and the one-deal reconciliation (Gate 1) possible. Omit `custody_attestations` / `vouchers` / `settlement_events` → no authenticated, gap-detectable audit of who moved what under which authority; the off-chain/on-chain reconciliation that defines "done" cannot run.

### S12.8 Prioritized build plan (phases)

Ordered by risk-retirement: build and brutally test the irreducible solvency spine first, then the loan rail, then liquidation, then the data source and surfaces. Each phase ends with its tests green.

- **Phase 0 — Foundations & legal:** custodian selection + control agreement drafting; `RoleManager`, libraries; the role graph and privilege-separation test (`test_roles_*`). *Retires:* governance/blast-radius risk.
- **Phase 1 — Solvency spine:** `ReserveGuard`, `PledgeRegistry`, `SignedCustodyAdapter`/`ICustodyAdapter`, `PermissionedCollateralToken` (cBTC). Unit + the INV-1/INV-2/INV-3/INV-13 invariants. *Retires:* the infinite-mint / unbacked-claim class (the single most dangerous cut). This is the launch blocker per por_cre.
- **Phase 2 — Loan rail (Model B):** `OracleAdapter`, `FixedRateIRM`, `MorphoAdapter`, `PositionRegistry`, `CollateralBridge` (mint/deposit/borrow/repay/withdraw + sub-ledger). Unit + INV-4/INV-12/INV-14/INV-15/INV-16/INV-17/INV-18. *Retires:* the borrow→repay loop and per-borrower attribution.
- **Phase 3 — Liquidation & release:** `LiquidationModule` (objective trigger + cure window + surplus), `ReleaseAuthorizer` (state-derived one-use vouchers), `SettlementRouter`, `RiskConfig`/`ParameterArchive`. Unit + INV-5/INV-6/INV-7/INV-10/INV-11/INV-20 + negatives. *Retires:* the safety-valve and collateral-redirection class.
- **Phase 4 — Reserve data source:** wire the launch source (signed attestations; optional Chainlink PoR feed behind the same `ReserveGuard` interface, `sourceMode`). *Retires:* the self-attestation gap; keeps CRE/PoR a non-breaking later swap (Reversibility).
- **Phase 5 — Off-chain services:** indexer + API + the S12.7 data model; custody attestation signer; custody listener (idempotent, FAIL-CLOSED); risk/liquidation bot; AMINA Operator Console. *Retires:* the execution gap between on-chain decisions and real custody movement.
- **Phase 6 — Frontend:** F1–F5 surfaces (Tokenize, Markets/Borrow with rate = "AMINA's parameter", Position/Portfolio with `LIQ/currentLTV` HF math, Account/evidence hub, margin-call/cure/liquidation lifecycle). *Retires:* the product-surface gap.
- **Phase 7 — Verification & launch:** full fuzz + invariant + fork + negative suites green (Gates 1–3); external audit + legal opinion (Gate 4); monitoring live with paging (Gate 5); testnet AMINA pilot → small mainnet pilot.

Each safety control is Core because its omission re-opens a named failure: drop Phase 1 → unbacked mint (Solvency death, PYUSD class); drop Phase 2's oracle peg cap → cBTC valued above backing (over-lending); drop Phase 3's state-derived vouchers → operator redirects collateral (Liability); drop Phase 3's objective trigger → interested-party liquidation abuse (Liability); drop Phase 4's `min(PoR, attestation)` → PoR-theater self-attestation; drop Phase 5's FAIL-CLOSED listener → unauthorized custody movement; drop Phase 7 gates → "done" degrades to "the dashboard renders."

#### Why Core / What breaks if omitted

The build plan passes all three tests by *sequencing* them: solvency before the loan, the loan before liquidation, the data source and surfaces last. Building in any other order (UI first, spine last) is the failure mode the prior architectures warn against ("the first demo is a deal, not a dashboard"). The phase order is itself a control: it guarantees that no value can flow before the invariant that protects it is built and tested.

