# P2PxAmina — Updated Architecture & Implementation Plan

**Status**: design + delivery plan, v0.2
**Companion to**: `P2PxAmina-lending-protocol-for-banks` (v0.7 product brief) and `P2PxAmina-lending-protocol-for-banks-Contracts.html` (v0.1 architecture sketch)
**Audience**: protocol engineering, AMINA integration team, auditors, the v0.7 brief's reviewers
**One-sentence framing**: bilateral, fixed-term, permissioned institutional repo over Ethereum mainnet, with AMINA Bank as the single licensed broker / curator / liquidator and P2P Staking as the technology provider.

---

## Table of contents

1. [What changed since v0.1](#1-what-changed-since-v01)
2. [Lessons from peer protocols](#2-lessons-from-peer-protocols)
3. [Updated architecture](#3-updated-architecture)
4. [Cross-cutting design refinements](#4-cross-cutting-design-refinements)
5. [Implementation plan — phases &amp; milestones](#5-implementation-plan--phases--milestones)
6. [Testing strategy](#6-testing-strategy)
7. [Audit strategy](#7-audit-strategy)
8. [Deployment &amp; ops runbook](#8-deployment--ops-runbook)
9. [Risk register](#9-risk-register)
10. [Open questions for v0.8 brief revision](#10-open-questions-for-v08-brief-revision)

---

## 1. What changed since v0.1

The v0.1 sketch nailed the overall shape (six layers, ten contracts, ~1,340 LOC) but rested on assumptions that the second pass should make explicit:

| Topic | v0.1 stance | v0.2 stance | Why it changed |
|---|---|---|---|
| Deal mutability | "Immutable after creation, except for state transitions" | **Strictly immutable.** Modifying terms = close + reopen as new deal, both in one atomic batch. | Morpho Blue's market-immutability proof shows this is auditable, reduces upgrade-blast radius, and matches the legal "trade confirmation per deal" semantics in tri-party repo. |
| Compliance enforcement | Hard-coded `KYBGateway.requireApproved` calls at every entry point | **Hook-based.** A `ComplianceRegistry` maps `(token, action)` → hook contract; the engine calls the hook before/after state-changing actions. | Euler V2's hook pattern. Different custodians (Fireblocks, AMINA-issued via Tokeny, BitGo) have different compliance shapes — hook target abstracts that. |
| Activation flow | Two-step: `recordDeal` then `activate` | **One-step atomic settlement** using EIP-2612 permits or pre-signed approvals; multi-step kept as a fallback for tokens without permit support. | Maple v3 and Clearpool Prime both originate-and-settle in one tx. Reduces the window in which one party can renege; reduces the surface for grief attacks. |
| Liquidation engine | Three-phase (warn → partial → full) called sequentially | Same three-phase, but each phase has an explicit **monotonic step counter**, **per-deal grace clocks**, and a **borrower-cure path** that lets the borrower top up collateral and skip the partial liquidation. | Maple v3 loan state machine. Lets borrowers self-rescue before AMINA acts, which is the typical institutional preference. |
| Future DeFi channel | "Wrap the engine in a Mellow/Morpho-style ERC-4626 vault later" | The engine exposes **ERC-7540-compatible request/claim interfaces** from day one for the lender side. The vault layer can be added later without touching the engine. | Centrifuge V3 ships ERC-7540 vaults precisely for institutional async settlement. ERC-7540 was finalised March 2024 and is now the accepted standard for "off-chain settlement, on-chain accounting." |
| AMINA economic exposure | None — AMINA is purely contractual | Architecture leaves a place for **optional on-chain bonding by AMINA** (Maple PoolDelegate-style first-loss capital) that can be enabled in v2 without re-architecting. | Aligning AMINA's regulatory accountability with on-chain skin in the game makes the protocol more credibly trustless without removing the licence model. |
| State of `DealRegistry` | Append-only, in-engine | **Separate immutable contract** with no upgrade path, deployed via CREATE2 to a vanity address per environment. | Maple's PoolManager/Pool split. Loan terms are the legal record — they must not be touchable by governance. |
| Cross-chain | Out of scope | Out of scope, but interfaces shaped so a v2 Centrifuge-style "router + adapter" layer can be retrofitted without breaking the v1 ABI. | Centrifuge V3 deploys the same protocol to 9 chains via a router pattern. Worth not foreclosing. |

---

## 2. Lessons from peer protocols

A short matrix of the protocols studied and the single architectural idea borrowed from each.

| Protocol | Architecture trait borrowed | Where it lands in our design |
|---|---|---|
| **Morpho Blue** (650 LOC immutable lending primitive, 5 immutable params per market, used by Coinbase / Apollo / Société Générale's USDC lending) | Deal/market immutability as a first-class invariant. Governance cannot change live terms. | `DealRegistry` and `EscrowVault` are non-upgradeable. Deal struct is set-once. |
| **Maple Finance v3** (PoolManager pattern, PoolDelegate as curator, MapleLoan as agreement) | Three-way separation: simple core vault (ERC-4626), externalised manager (admin), externalised loan contract (legal terms). Pool Delegate = credit professional with first-loss capital. | `LendingEngine` (core) + `CollateralRegistry/IssuerRegistry` (admin) + `DealRegistry` (terms). AMINA Bank = our Pool Delegate equivalent; first-loss bonding is reserved as a v2 hook. |
| **Clearpool Prime** (Securitize ID for KYB, whitelisted borrower-launched pools, non-custodial — funds wired directly to borrower wallets) | Identity-as-infrastructure (Securitize-style off-chain attestation → on-chain status). Minimise time funds are in protocol custody. | `KYBGateway` mirrors Securitize ID; activation is atomic so funds touch `EscrowVault` for a single block before settling to borrower. |
| **Centrifuge V3** (ERC-7540 tranches, Investment Manager + Pool Manager split, multi-chain via adapter routers) | ERC-7540 async request/claim flow as the canonical pattern for "off-chain settlement, on-chain accounting." | The engine emits ERC-7540-shaped events (`RequestDeposit`, `Claim*`) and the `SettlementRouter` carries the off-chain settlement reference. Future DeFi-channel ERC-4626/7540 vault drops in without changes. |
| **Euler V2 EVK** (modular ERC-4626 vaults with governable hook contracts for KYC, flash-fee, pause, etc.) | Hooks as the compliance extension point — keeps the core small, lets per-asset compliance evolve. | `ComplianceRegistry` exposes a `ICompliancePre/PostHook` interface; tokens register their hook at `IssuerRegistry.activate(token)`. |
| **Membrane Labs** (US Patent for non-custodial credit-aware multi-chain settlement; CustodyLink settlement network) | Settlement routing as a first-class concern; the on-chain side must publish structured intents that custody listeners can act on. | `SettlementRouter` becomes a thicker, richer surface — typed intents with off-chain reference IDs, expected settlement deadlines, and per-custodian receiving addresses. |
| **Sygnum MultiSYG** (5-of-N multi-sig for BTC collateral wallets, three independent signers + bank + borrower) | Multi-party control of custody as a security control. Not the protocol's job, but the protocol must accommodate it. | `IssuerRegistry` stores per-token settlement endpoints, not just custodian addresses, so a multi-sig wallet can be one valid endpoint. |
| **JPM Onyx / Broadridge DLR** (intra-day repo on a private chain, JPM Coin as cash leg, DvP cross-chain via synchronised lock-then-release) | Delivery-versus-payment atomicity as the settlement primitive. | The atomic activation flow (`activate` pulls collateral + pulls supply + releases supply in one tx) is our DvP equivalent within one chain. |
| **OpenTrade** (institutional yield infrastructure, permissioned + permissionless deployments, ERC-4626 vaults over RWAs) | Two-mode deployment: permissioned for institutions, permissionless wrapper for retail-via-RWA-vault. | Out-of-scope for v1, but the engine's interfaces don't preclude an OpenTrade-style permissionless ERC-4626 wrapper as the v2 DeFi channel. |
| **ERC-3643 / T-REX** ($28B+ tokenized assets, identity registry + compliance contract + restricted ERC-20) | Transfer-time compliance checks built into the token itself. | We don't reinvent this; we *consume* ERC-3643 tokens and wrap their compliance reverts with structured error handling. `EscrowVault` only ever holds compliant tokens. |
| **AAVE v4 (Hub-Spoke)** | Configurator pattern; dynamic risk configuration with versioning; per-Spoke oracle isolation; emergency state semantics. | Carried over from v0.1: `RoleManager` + per-pair `CollateralRegistry` version snapshots + `OracleRouter` per-token isolation + the paused/frozen/halted/deactivated state space (adapted to per-deal/per-pair/global). |
| **Compound v3 (Comet)** | Storage-layout-first design; explicit `…Storage` contracts; Configurator-as-factory pattern. | Each upgradeable contract has its own `XxxStorage` mixin to keep upgrade safety mechanical. |

> **Net effect.** The v0.2 architecture is closer to a "Morpho Blue with permissioning, settled like Centrifuge, curated like Maple, hooked like Euler" than to a hub-spoke AAVE descendant. The hub-spoke metaphor was a useful starting point for the v0.1 sketch but, in light of the bilateral economics, the right reference model is *isolated-market lending with a regulated curator and asynchronous settlement*.

---

## 3. Updated architecture

### 3.1 Layer map

```
┌──────────────────────────────────────────────────────────────────────┐
│                        OFF-CHAIN (P2P + AMINA)                       │
│  Matching engine · Rate engine · Order book · KYB intake · Dashboard │
│              AMINA monitoring · liquidation bot · OPS                │
└────────────────────────────────┬─────────────────────────────────────┘
                                 │ EIP-712 signed deal terms
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│  L1 — GOVERNANCE & IDENTITY (UUPS where noted, OZ AccessManager root)│
│   ┌───────────────┐ ┌──────────────┐ ┌────────────────────────────┐  │
│   │  RoleManager  │ │  KYBGateway  │ │  IssuerRegistry            │  │
│   │  (OZ AM root) │ │  (id status) │ │  (custodians + tokens)     │  │
│   └───────┬───────┘ └───────┬──────┘ └─────────────┬──────────────┘  │
│                                                                       │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │  ComplianceRegistry  (Euler-style hook registry, NEW v0.2)  │    │
│   │  (token, action) → ICompliancePre/PostHook                  │    │
│   └─────────────────────────────────────────────────────────────┘    │
└──────────┼─────────────────┼──────────────────────┼──────────────────┘
           │                 │                      │
┌──────────┼─────────────────┼──────────────────────┼──────────────────┐
│  L2 — RISK ENGINE                                                    │
│   ┌──────▼─────────────┐ ┌─▼────────────────┐ ┌──▼────────────────┐  │
│   │ CollateralRegistry │ │  OracleRouter    │ │ ParameterArchive  │  │
│   │ (per-pair, versioned)│ │ (per-token feeds)│ │ (historical keys │  │
│   └──────┬─────────────┘ └─────────┬────────┘ │  for live deals)  │  │
│                                                └───────────────────┘  │
└──────────┼────────────────────────┬┴──────────────────────────────────┘
           │                        │
┌──────────┼────────────────────────┼──────────────────────────────────┐
│  L3 — DEAL ENGINE (core)                                             │
│                                                                       │
│   ┌──────▼─────────┐  ┌──────────▼─────────┐  ┌──────────────────┐   │
│   │  DealRegistry  │  │  LendingEngine     │  │  EscrowVault     │   │
│   │  (IMMUTABLE)   │  │  (state machine,   │  │  (IMMUTABLE,     │   │
│   │  terms +       │  │   UUPS+timelock)   │  │   pull-only      │   │
│   │  EIP-712       │  │                    │  │   from engine)   │   │
│   │  3-sig verify  │  │                    │  │                  │   │
│   └──────┬─────────┘  └──────────┬─────────┘  └────────┬─────────┘   │
└──────────┼───────────────────────┼─────────────────────┼─────────────┘
           │                       │                     │
┌──────────┼───────────────────────┼─────────────────────┼─────────────┐
│  L4 — SETTLEMENT & LIQUIDATION                                       │
│   ┌──────▼─────────┐  ┌──────────▼─────────────┐                     │
│   │ SettlementRouter│ │ LiquidationHandler     │                     │
│   │ (rich intents) │  │ (AMINA-only, 3-phase)  │                     │
│   └────────────────┘  └────────────────────────┘                     │
└──────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│           CUSTODY LAYER — AMINA / Fireblocks / BitGo / etc.          │
│         (mint/burn Token A & B; real-asset redemption; ERC-3643)     │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Contract list (updated)

| # | Contract | Purpose | Upgradeable | LOC budget |
|---|---|---|---|---|
| 1 | `RoleManager` | OZ `AccessManager` wrapper. Roles: `GOVERNOR`, `CURATOR`, `LIQUIDATOR`, `EMERGENCY`, `ORACLE_ADMIN`, `OPS`. | No (OZ-managed) | 40 |
| 2 | `KYBGateway` | Wallet-level KYB status: `Unknown / Approved / Suspended / Revoked` + expiry. | UUPS | 90 |
| 3 | `IssuerRegistry` | Whitelist of accepted custodians and the (supply / collateral) tokens they issue, with per-token paused flag and compliance-hook pointer. | UUPS | 130 |
| 4 | `ComplianceRegistry` *(new in v0.2)* | Maps `(token, action)` → hook contract. The engine calls `preTransfer` / `postTransfer` before any token movement that touches that token. | UUPS | 80 |
| 5 | `OracleRouter` | Token → price-source registry. Composite feeds + heartbeat enforcement + per-feed circuit breaker. | UUPS | 130 |
| 6 | `CollateralRegistry` | Per-(collateral, supply) pair risk parameters; `latestVersion` pointer; new entries bump the version. | UUPS | 150 |
| 7 | `ParameterArchive` *(new in v0.2)* | Immutable storage of historical risk-param versions referenced by live deals. The deal carries the version key; the archive guarantees the version is readable forever. | Immutable | 80 |
| 8 | `DealRegistry` | Append-only deal records, EIP-712 verification of 3 signatures, deal-ID derivation. | **Immutable** | 180 |
| 9 | `EscrowVault` | Per-deal token ledger. Only callable by `LendingEngine`. | **Immutable** | 140 |
| 10 | `LendingEngine` | State machine: `Pending → Active → Warned/Liquidating → Repaid/Liquidated/Defaulted`. Interest accrual JIT. Health-factor check. | UUPS + timelock | 280 |
| 11 | `LiquidationHandler` | AMINA-only three-phase liquidation; emits settlement intents; computes surplus return to borrower. | UUPS + timelock | 180 |
| 12 | `SettlementRouter` | Rich typed intents (advance, repay, top-up, liquidation, default, surplus return). Off-chain custody listeners subscribe here. | UUPS | 70 |
| 13 | `PortfolioLens` *(view-only, new)* | View contract aggregating a user's deals into the "one position" shape required by the dashboard. No state, no privileged calls. | Immutable | 90 |
| **Total** | | | | **≈ 1,640** |

The total has grown by ~300 LOC from v0.1 (1,340 → 1,640), still inside the 1,500 stretch goal but no longer inside the original 1,000–1,500 hard target. The growth is concentrated in `ComplianceRegistry` and `ParameterArchive`, which exist to harden two specific properties: per-custodian compliance flexibility and historical-version availability. Reviewers may push back; the trade is "more code now, fewer migrations later."

### 3.3 Storage and inheritance discipline

Every UUPS-upgradeable contract follows the Compound v3 storage pattern:

```
contracts/
├── L1/
│   ├── KYBGateway.sol            (interface + UUPS proxy logic)
│   ├── KYBGatewayStorage.sol     (storage layout only, namespaced ERC-7201)
│   └── KYBGatewayLib.sol         (pure functions, no storage)
├── L2/ ...
└── L3/ ...
```

Use of [ERC-7201 namespaced storage](https://eips.ethereum.org/EIPS/eip-7201) prevents storage collisions across upgrades and makes inheritance composition safe.

### 3.4 Deal lifecycle (refined)

```
            OFF-CHAIN                                ON-CHAIN
            ─────────                                ────────

1. Lender + borrower in matching engine
2. AMINA assigns base rate, LTV, maturity
3. All three parties sign EIP-712 (DealTerms, nonce)
4. Lender signs ERC-2612 permit on supplyToken (or pre-approves)
5. Borrower signs ERC-2612 permit on collateralToken (or pre-approves)
                                                   ┌───────────────────┐
6. AMINA submits all sigs                ─────────►│  CURATOR calls    │
                                                   │ LendingEngine     │
                                                   │  .openAndActivate │
                                                   │  (terms, sigs,    │
                                                   │   permits)        │
                                                   └─────────┬─────────┘
                                                             │
                                                             ▼
                                              ┌──────────────────────────┐
                                              │ DealRegistry.record(...) │
                                              │  - verify 3 sigs         │
                                              │  - check KYBGateway      │
                                              │  - check IssuerRegistry  │
                                              │  - snapshot version key  │
                                              │  - assign dealId         │
                                              └──────────────┬───────────┘
                                                             │
                                                             ▼
                                              ┌──────────────────────────┐
                                              │ ComplianceRegistry.preH..│
                                              │  for collateralToken     │
                                              │  for supplyToken         │
                                              └──────────────┬───────────┘
                                                             │
                                                             ▼
                                              ┌──────────────────────────┐
                                              │ EscrowVault.pullColl(...)│
                                              │ EscrowVault.pullSupp(...)│
                                              │ EscrowVault.releaseSupp  │
                                              │            (to borrower) │
                                              └──────────────┬───────────┘
                                                             │
                                                             ▼
                                              ┌──────────────────────────┐
                                              │ SettlementRouter.emit:   │
                                              │  AdvanceIntent(...)      │
                                              │ ComplianceRegistry.post  │
                                              └──────────────────────────┘

7. Custodian listener picks up AdvanceIntent
8. Custodian burns supplyToken from borrower wallet
9. Custodian credits borrower's real-asset account (e.g., real USDC)

... time passes ...

10. AMINA bot reads health factor via view              ◄── PortfolioLens / LendingEngine
11. Three branches:

   A. Maturity, healthy:
      Borrower repays                                   ──► LendingEngine.repay(dealId, amount)
      Engine: pull supply, release collateral
      → SettlementRouter.RedemptionIntent

   B. Health degrades, crosses warningBps:
      AMINA bot                                         ──► LendingEngine.warn(dealId)
      48h grace clock starts; borrower may top up
      Borrower tops up                                  ──► LendingEngine.topUpCollateral(...)
      → state back to Active

   C. Health crosses partialLiqBps after grace expired:
      AMINA bot                                         ──► LiquidationHandler.partial(dealId)
      Engine: release collateral to AMINA settlement
      → SettlementRouter.LiquidationIntent
      AMINA off-chain: redeem at custody, credit lender

      If health subsequently crosses fullLiqBps:
      AMINA bot                                         ──► LiquidationHandler.full(dealId)
      Engine: release remaining collateral
      Surplus (if any) returned to borrower
      Deal → Liquidated (or Defaulted if shortfall)
```

The whole flow happens in a single tx in step 6 — `openAndActivate` is the atomic settlement entry point. The engine refuses to record a `Pending` state; either the deal is fully settled or the tx reverts. This removes a class of "what if activation never happens" edge cases.

---

## 4. Cross-cutting design refinements

Each of the following resolves a specific class of concern not articulated cleanly in v0.1.

### 4.1 The `ComplianceRegistry` hook contract

```solidity
interface ICompliancePreHook {
    /// @dev Called before any token transfer of `token` in the protocol.
    /// @return ok If false, the engine reverts the surrounding action.
    /// @return reason Optional bytes32 reason tag for off-chain log.
    function preTransfer(
        address token,
        address from,
        address to,
        uint256 amount,
        bytes32 dealId,
        bytes32 action     // keccak256("ACTIVATE") etc.
    ) external returns (bool ok, bytes32 reason);
}

interface ICompliancePostHook {
    function postTransfer(
        address token,
        address from,
        address to,
        uint256 amount,
        bytes32 dealId,
        bytes32 action
    ) external;
}
```

Custodians register a single hook contract per token at `IssuerRegistry.activate(token)`. The hook is the place where:
- Fireblocks-issued tokens can call out to the Fireblocks policy engine for a pre-trade check.
- ERC-3643 (Tokeny) tokens can verify the destination is on the issuer's identity registry.
- AMINA-issued tokens can enforce per-deal velocity limits.

A token with no compliance need can register a no-op hook. The `ComplianceRegistry` itself ships with `DefaultPassHook` for that case.

### 4.2 Atomic activation via `openAndActivate`

```solidity
function openAndActivate(
    DealTerms calldata terms,
    Signatures calldata sigs,           // lender, borrower, amina
    Permit calldata supplyPermit,       // optional, can be 0-default
    Permit calldata collateralPermit    // optional
) external onlyRole(CURATOR) returns (bytes32 dealId);
```

Properties:
1. **All-or-nothing.** Either the deal is recorded *and* both legs are settled *and* the borrower's wallet holds the supply token, or the tx reverts and nothing changed.
2. **Single role gate.** Only `CURATOR` (AMINA) can call. The signatures + permits make it impossible for AMINA to fabricate a deal both counterparties did not sign.
3. **No `Pending` state.** The engine never carries a deal that's been recorded but not yet activated. This eliminates the v0.1 expiry concern.
4. **EIP-712 nonce in `DealTerms`** prevents the same signature being reused for a second `openAndActivate`. The nonce is per-counterparty and is stored on a small `nonceUsed` mapping inside `DealRegistry`.

### 4.3 Deal immutability (Morpho-style)

A deal struct, once recorded, is sealed. The only fields that mutate over the life of the deal are in `LendingEngine.state[dealId]`: `state`, `outstanding`, `collateralPosted`, `lastTouchTs`, `liquidationStep`. The `DealTerms` themselves — parties, principal, rate, maturity, collateral type, version key — never change.

Why this matters:
- Audit / regulatory traceability: the on-chain record exactly matches the off-chain trade confirmation.
- Upgrade safety: `LendingEngine` can be upgraded without rewriting the terms of live deals.
- Dispute resolution: if AMINA's records ever conflict with the chain, the chain is authoritative for terms (and AMINA's settlement records are authoritative for off-chain execution).

### 4.4 Versioned risk parameters with `ParameterArchive`

When `CURATOR` bumps the LTV on a (collateral, supply) pair:

1. `CollateralRegistry.updatePair(pair, newParams)` writes to `paramsByPair[pair]`.
2. The same call writes the *old* `Params` struct into `ParameterArchive[pair][oldVersion]`.
3. `latestVersion[pair]` increments.
4. New deals snapshot `latestVersion[pair]` at creation.
5. Live deals continue to read from `ParameterArchive[pair][snapshottedVersion]`.

This is structurally identical to AAVE v4's `dynamicConfigKey` model, but the archive is a separate immutable contract — the registry can be upgraded (e.g., to add new fields), and the archive guarantees old versions remain readable forever even if the registry's storage layout changes.

### 4.5 ERC-7540-shaped lender interface

For each deal the lender holds, the engine implements a view subset of [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540):

```solidity
function pendingDepositRequest(uint256 dealId, address controller) external view returns (uint256);
function claimableDepositRequest(uint256 dealId, address controller) external view returns (uint256);
function pendingRedeemRequest(uint256 dealId, address controller) external view returns (uint256);
function claimableRedeemRequest(uint256 dealId, address controller) external view returns (uint256);
```

The lender's "position" in a deal is effectively a single share in a single-deal vault. This makes a v2 ERC-7540 vault that aggregates many deals into a single share token a thin layer above the engine — no engine changes required to ship the DeFi liquidity channel.

We do **not** implement the deposit / redeem / claim write side of ERC-7540 in v1: lender flows happen through `LendingEngine.openAndActivate` and `LendingEngine.repay`, not via the ERC-7540 entry points. The reason is that ERC-7540's full write surface introduces async-claim accounting that's redundant when each deal has exactly one lender and one borrower. The view subset is enough to make later aggregation easy.

### 4.6 Liquidation: monotonic step counter and surplus return

```solidity
struct LiqState {
    uint8 phase;       // 0 None, 1 Warned, 2 Partial, 3 Full
    uint64 phaseEnteredAt;
    uint128 cumulativeLiquidated;
}
mapping(bytes32 => LiqState) public liqState;
```

Each `LiquidationHandler` call carries an expected `(phase, step)` pair; the call reverts if the on-chain step diverges. This protects against double-spend in the AMINA bot logic and against race conditions if multiple AMINA wallets are authorised.

**Surplus return**: at `LiquidationHandler.full`, the engine computes:

```
collateralValueAtClose = oracle(collateralToken) * collateralPosted
debtValueAtClose       = outstanding * oracle(supplyToken)
bonus                  = configured bonus on this pair
amountToAmina          = (debtValueAtClose + bonus) / oracle(collateralToken)
surplusToBorrower      = max(0, collateralPosted - amountToAmina)
```

The surplus returns to the borrower's wallet. This is the architectural answer to the v0.7 brief's silent question, "what happens to over-collateralisation at default?" — the borrower gets the residual, not AMINA, not the protocol treasury.

### 4.7 Pause hierarchy

```
Global halt              EMERGENCY 2-of-2 toggles a global flag in LendingEngine.
   ↓ blocks everything except: claim of pre-existing surplus, top-up
Token pause              IssuerRegistry.paused[token] = true.
   ↓ blocks new deals using this token; existing deals can still settle.
Pair pause               CollateralRegistry.paused[pair] = true.
   ↓ blocks new deals on this pair only; existing deals unaffected.
Deal pause               LendingEngine.pausedDeals[dealId] = true.
   ↓ rare; used for legal/regulatory hold. Locks the deal's clock at the moment of pause.
```

Each level is a separate role:
- Global halt = `EMERGENCY` (joint P2P + AMINA, 2-of-2 multisig)
- Token pause = `OPS` (AMINA operations, single-sig fast action)
- Pair pause = `CURATOR` (AMINA risk, single-sig)
- Deal pause = `CURATOR` + recorded reason hash

### 4.8 Oracle posture under degraded conditions

| Oracle state | New deals | Existing deals | Liquidation |
|---|---|---|---|
| Healthy | allowed | accrue normally | allowed |
| Stale (above heartbeat) | **blocked** (revert) | accrue normally on last sane price | **allowed at last price**, AMINA bears risk |
| Circuit-broken (manual) | blocked | frozen (no HF computed) | blocked unless `EMERGENCY` overrides |

The "stale but liquidation allowed at last price" rule is unusual but deliberate. In the bilateral model, only AMINA can liquidate, and AMINA has off-chain market data that may exceed the on-chain oracle's freshness. Letting AMINA liquidate at a slightly-stale price is safer than freezing positions and letting underwater debt compound while waiting for an oracle update.

### 4.9 Privacy posture

Three concrete properties:

1. **Per-deal address pseudonymity.** Custodians mint per-deal sub-account addresses; the protocol does not deduplicate. The chain reveals "wallet X borrowed from wallet Y on dealId Z" but cannot resolve X or Y to legal entities without custody-side data.
2. **Off-chain side letters.** Pricing footnotes, side agreements, and non-economic terms live in the EIP-712 `termsHash` packet that's hashed but not stored on chain. The on-chain row contains only the fields the engine computes against.
3. **No share tokens.** Pool protocols leak counterparty information through share-token graphs ("who else holds this share token = who else lent to the same pool"). Bilateral deals leak less by construction.

ZK-friendly upgrades (commitment-scheme `DealRegistry`, hidden parties) are out of scope for v1 but the registry's interface is designed so the storage backend can be swapped without touching the engine.

### 4.10 Reentrancy posture

- Every external entry point on `LendingEngine` is `nonReentrant`.
- `EscrowVault` is `nonReentrant` and only callable by `LendingEngine`.
- Token transfers happen *after* state updates inside each entry point (checks-effects-interactions).
- Compliance hooks are called *before* state updates; this is the only place a malicious hook can cause issues, which is why `IssuerRegistry.setHook` is `CURATOR`-only and the hook contract is audited as part of token onboarding.
- The protocol bans rebasing tokens at the `IssuerRegistry` admission stage.

---

## 5. Implementation plan — phases &amp; milestones

Target: production deployment by **Q4 2026**, assuming the v0.7 brief's open questions (AMINA partnership terms, pilot participants, Cayman legal opinion) resolve in parallel.

> **Calendar dates below assume kickoff in week 1 starting June 2026.** Adjust to actual start.

### Phase 0 — Foundations (Weeks 1–2)

| Goal | Set up the engineering substrate before writing any business logic. |
|---|---|
| **Deliverables** | Foundry project, CI (build + test + slither + mythril + halmos), pre-commit hooks, devcontainer, code style guide, secret management, deployment script skeleton. Repository scaffold with the L1–L4 directory layout. |
| **People** | 1 senior Solidity, 0.5 DevX. |
| **Acceptance** | `forge build` and `forge test --gas-report` green on CI for an empty contract. Slither pipeline green. Halmos symbolic exec running (even on noop). Foundry fork-test infrastructure runs against Ethereum mainnet snapshot. |
| **Risk** | Low. |

### Phase 1 — Identity, Registry, Roles (Weeks 2–4)

| Goal | Stand up `RoleManager`, `KYBGateway`, `IssuerRegistry`, `ComplianceRegistry`. The identity-and-allowlist layer. |
|---|---|
| **Deliverables** | All four contracts with full unit tests. ERC-7201 storage discipline applied. Deployment script for a local Anvil fork. Integration test that registers a Fireblocks-style ERC-20 and exercises the compliance hook with a `DefaultPassHook`. |
| **People** | 1 senior Solidity, 1 mid Solidity, 0.5 AMINA integration engineer (advisory). |
| **Acceptance** | 100% function coverage on unit tests. Symbolic check (halmos) on `KYBGateway.requireApproved` proves no path passes a non-Approved wallet. AMINA integration engineer signs off on the KYB status schema. |
| **Risk** | Medium — locking the KYB schema before AMINA's compliance team has finalised their data model is the single biggest schedule risk. Mitigation: keep the schema in a struct that can be extended via UUPS upgrade. |

### Phase 2 — Risk engine (Weeks 4–6)

| Goal | `OracleRouter`, `CollateralRegistry`, `ParameterArchive`. Everything that converts "what is the price + the rules" into a single source of truth the engine can query. |
|---|---|
| **Deliverables** | Three contracts with unit tests. Real Chainlink fork tests for BTC/USD, ETH/USD, USDC/USD. Composite-adapter scaffolding with at least one example adapter (LBTC/USD via LBTC/BTC × BTC/USD). CAPO-style cap on the LST/underlying component. |
| **People** | 1 senior, 1 mid, 0.5 quant for oracle adapter design review. |
| **Acceptance** | Fork tests pass at multiple historical block heights. Stale-price test reverts on `addDeal` but allows liquidation. Property test: bumping `CollateralRegistry` version preserves all previously-snapshotted versions in `ParameterArchive`. |
| **Risk** | Medium — composite oracle adapters are a common source of bugs (decimal mismatches, sign extension). Mitigation: heavy use of fork testing + adopt AAVE's existing CAPO adapter contracts where possible. |

### Phase 3 — Deal engine (Weeks 6–10)

| Goal | The core: `DealRegistry`, `EscrowVault`, `LendingEngine`. This is the hardest 4 weeks of the project. |
|---|---|
| **Deliverables** | Three contracts with unit tests and integration tests. The full `openAndActivate` flow working end-to-end with a mock custodian. Interest accrual logic exercised across the entire parameter space. Health-factor computation tested against hand-rolled vectors. EIP-712 signature verification tested with three independent signers. |
| **People** | 1 senior, 2 mid, 0.5 DevX. |
| **Acceptance** | The full happy path (`openAndActivate` → `repay`) runs in a single tx ≤ 250k gas. Negative-path tests: bad sig reverts, suspended KYB reverts, paused token reverts, stale oracle reverts, expired permit reverts. Property tests on interest accrual (commutativity across `_accrue` calls). |
| **Risk** | High — this is the heart of the protocol. Mitigation: pair-program on the state machine; require 2-of-2 review on every PR touching `LendingEngine`. |

### Phase 4 — Liquidation &amp; settlement (Weeks 10–12)

| Goal | `LiquidationHandler`, `SettlementRouter`, `PortfolioLens`. The off-chain-facing surface. |
|---|---|
| **Deliverables** | All three contracts. Full liquidation flow tested with all three phases (warn → partial → full) and all branch points (borrower-cure, AMINA-skip-partial, default). Settlement intents covered by a fixture set the AMINA integration team uses as their event-handler test corpus. |
| **People** | 1 senior, 1 mid, 1 AMINA integration engineer (now full-time, building the listener side). |
| **Acceptance** | Surplus-to-borrower computation correct across boundary cases (0 surplus, full surplus, surplus rounding). Liquidation step counter rejects out-of-order calls. AMINA integration engineer confirms their listener can deterministically reconstruct deal state from `SettlementRouter` events alone. |
| **Risk** | Medium — surplus computation is fiddly. Mitigation: write the calculation in plain English first, get sign-off, then write the Solidity. Foundry fuzz on the calc. |

### Phase 5 — Off-chain integration (Weeks 10–14, parallel)

| Goal | Matching engine, rate engine, order book, dashboard, AMINA monitoring bot, custody listener. Not Solidity, but on the critical path. |
|---|---|
| **Deliverables** | Match engine producing `DealTerms` ready for `openAndActivate`. EIP-712 signing UI for lenders / borrowers / AMINA. KYB intake flow that drives `KYBGateway.setStatus`. Dashboard portfolio view backed by `PortfolioLens`. Settlement listener reading `SettlementRouter` events and posting custody instructions. |
| **People** | 1 backend lead, 2 backend, 1 frontend, 0.5 product. |
| **Acceptance** | End-to-end staging test: a simulated lender + borrower can be onboarded, matched, settled, monitored, and repaid through the live UI. AMINA's compliance bot can warn / liquidate from the same staging deployment. |
| **Risk** | Medium — schedule risk if the on-chain team finishes Phase 4 ahead of off-chain Phase 5. Mitigation: parallelism, with the on-chain team writing the off-chain integration shim contracts (mock listener, fixture event emitter). |

### Phase 6 — Internal testing &amp; hardening (Weeks 14–16)

| Goal | All-hands hardening before the external audit gate. |
|---|---|
| **Deliverables** | Foundry invariant fuzz suite ≥ 80% line coverage and ≥ 40 invariants. Halmos symbolic exec on the state machine and HF calculation. Echidna campaign on `LendingEngine`. Differential test against a Python reference implementation. Internal red-team review of every privileged role. |
| **People** | All hands. |
| **Acceptance** | Zero unresolved high/critical from internal review. ≥ 95% statement coverage. Halmos counterexample search clean on safety invariants. Documented runbook of "what to do if X breaks." |
| **Risk** | Medium — invariant fuzzing on a multi-contract state machine routinely surfaces "interesting" issues. Mitigation: budget enough time to fix them, not just discover them. |

### Phase 7 — External audit round 1 (Weeks 16–20)

| Goal | First external audit. Recommend two firms in parallel for blast diversity. |
|---|---|
| **Deliverables** | Two audit reports (e.g., Trail of Bits + OpenZeppelin, or Spearbit + Cantina). Public fix-PR for every issue ≥ Medium. Re-audit pass on fixes. |
| **People** | Same internal team, plus the auditors. |
| **Acceptance** | Both reports closed with all High/Critical resolved and ≥ 80% of Medium resolved or accepted-with-mitigation. |
| **Cost estimate** | $250k–$450k for two parallel audits at this scope (≈1,640 LOC of business logic + interfaces). |
| **Risk** | Schedule risk — audit findings frequently require architectural changes. Mitigation: budget Phase 7.5 (Weeks 20–22) for fixes + re-audit before moving forward. |

### Phase 7.5 — Fix-and-re-audit (Weeks 20–22)

Slack for fixing audit findings, possibly re-running the audit pass on touched code.

### Phase 8 — Testnet pilot (Weeks 22–24)

| Goal | Sepolia deployment, one friendly counterparty pair runs through a synthetic deal lifecycle end-to-end. |
|---|---|
| **Deliverables** | Full system deployed to Sepolia. AMINA's compliance team uses the real dashboard with test KYB data. Custodian (Fireblocks or AMINA) integrates with their staging custody. One full deal: open → accrue → liquidate. One full deal: open → repay. |
| **People** | Engineering 50% on bugs, 50% on prod readiness checklist. |
| **Acceptance** | The two test deals reconcile against off-chain records exactly. AMINA's monitoring bot operates without manual intervention for a 7-day run. |
| **Risk** | Low–medium. |

### Phase 9 — Pilot mainnet (Weeks 24–28)

| Goal | First real deal between two willing counterparties at a small notional ($1M–$5M total exposure). |
|---|---|
| **Deliverables** | Mainnet deployment. Pre-funded EMERGENCY multisig. Per-pair and global caps set very conservatively. Active monitoring + standby revert plan. |
| **People** | Engineering on-call rotation, AMINA risk on-call. |
| **Acceptance** | At least one deal completes a full lifecycle (open → repay) on mainnet. Surplus-to-borrower path exercised via a controlled mock liquidation. |
| **Risk** | High institutional risk if anything goes wrong — even a non-critical bug at this stage is reputational. Mitigation: small notional, narrow counterparty set, fast revert capability. |

### Phase 10 — General mainnet launch (Weeks 28+)

| Goal | Open to all KYB-approved counterparties; remove caps incrementally based on volume + monitoring. |
|---|---|
| **Deliverables** | Public docs, integration guides for additional custodians, governance handover from launch multisig to a wider P2P + AMINA multisig structure. |

### 5.x Phase summary

```
Week:       1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28
Phase 0:    ▓▓
Phase 1:       ▓▓▓▓
Phase 2:             ▓▓▓▓
Phase 3:                   ▓▓▓▓▓▓▓▓
Phase 4:                                ▓▓▓▓
Phase 5:                   ▓▓▓▓▓▓▓▓▓▓▓▓
Phase 6:                                      ▓▓▓▓
Phase 7:                                            ▓▓▓▓▓▓▓▓
Phase 7.5:                                                      ▓▓▓▓
Phase 8:                                                              ▓▓▓▓
Phase 9:                                                                   ▓▓▓▓▓▓▓▓
Phase 10:                                                                              ▓▓▓...
```

---

## 6. Testing strategy

### 6.1 Test taxonomy

| Layer | Tool | Scope | Acceptance bar |
|---|---|---|---|
| Unit | Foundry | Every public/external function | 100% function coverage, ≥ 95% statement coverage |
| Property / invariant | Foundry invariant + Echidna | State-machine invariants, accounting identities | ≥ 40 invariants, ≥ 10M fuzz runs each |
| Symbolic | Halmos | Health-factor calc, signature verification, state-machine reachability | Counterexample-free on all flagged properties |
| Differential | Python reference + Foundry | Interest accrual, HF, liquidation surplus | Byte-identical results across 10k random inputs |
| Fork integration | Foundry fork | Composite oracles against historical Chainlink data | Pass at 50 random historical block heights |
| Gas | Foundry | Happy-path entry points | `openAndActivate` ≤ 250k, `repay` ≤ 120k, `full liquidate` ≤ 250k |
| End-to-end | Hardhat scripts / TS | Full lifecycle via the off-chain stack | Sepolia run with AMINA bot for 7 consecutive days |

### 6.2 Invariants (initial draft, expand during Phase 6)

For every deal `d`:

1. `state[d].outstanding ≥ terms[d].principal` whenever `state[d].state ∈ {Active, Warned, Liquidating, Matured}`.
2. `escrow.balanceOf[d][collateralToken] = state[d].collateralPosted` at end of every external call.
3. `escrow.balanceOf[d][supplyToken] = 0` outside of the atomic body of `repay` / `openAndActivate`.
4. `state[d].state` follows the documented DAG; no edge skips two steps (e.g., no direct `Active → Liquidated`).
5. Once `state[d].state ∈ {Repaid, Liquidated, Defaulted}`, no further state change is possible.

Global invariants:

1. For every token `t`, `sum over deals of escrow.balanceOf[d][t] == IERC20(t).balanceOf(escrow)`.
2. `DealRegistry.terms[d]` is never modified after creation.
3. `ParameterArchive[pair][version]` is never modified after first write.
4. `LendingEngine.totalActiveDeals` is non-negative and accurate.

### 6.3 Negative tests catalogue (incomplete, illustrative)

- All KYB statuses revert correctly across every entry point.
- Replay of an EIP-712 signature reverts.
- Permit signature for the wrong amount reverts.
- Compliance hook returning `false` reverts the surrounding action.
- Oracle staleness reverts `openAndActivate` but allows `repay` and `liquidate`.
- Token paused at `IssuerRegistry` reverts new deal but allows existing-deal repay.
- Global halt reverts every state-changing call except deal claim of pre-existing surplus.
- Liquidation step counter mismatch reverts.
- Surplus computation is exact at boundary cases (`surplus = 0`, `surplus = collateralPosted`).

### 6.4 Differential test against a Python reference

A Python implementation of the interest accrual, HF, and liquidation surplus formulas is maintained alongside the Solidity. For 10,000+ random `(principal, rate, dt, collateral, oracle)` tuples the Solidity output must match the Python output to the wei. This catches sign-extension and decimals bugs that fuzzing alone doesn't.

---

## 7. Audit strategy

### 7.1 Audit gating

| Phase | Gate before proceeding |
|---|---|
| Internal hardening (P6) | All P1–P5 deliverables green; coverage targets met |
| External audit 1 (P7) | Internal hardening passed; halmos clean |
| External audit 2 (P7) | (parallel, not sequential — see below) |
| Fix &amp; re-audit (P7.5) | All Critical / High resolved or formally accepted |
| Testnet pilot (P8) | Re-audit passed |
| Pilot mainnet (P9) | Sepolia run clean for 7 days |
| GA mainnet (P10) | Pilot deal lifecycle complete |

### 7.2 Recommended audit shops

Two independent shops in parallel, NOT sequential, for blast diversity. Suggested pairings (no endorsement implied):

- **Trail of Bits + OpenZeppelin** — proven on AAVE, Compound. Strong on access control + economic invariants.
- **Spearbit + Cantina** — Cantina specifically reviewed Euler v2 and is the strongest shop on the hook-vault interaction pattern we're adopting.
- **ChainSecurity + Code4rena** — would give us a contest-style adversarial review on top of a formal audit; complementary mindsets.

### 7.3 Bug-bounty plan

- Immunefi listing on mainnet launch, capped at $1M with severity-tiered payouts.
- Pre-launch on testnet: a smaller $100k campaign with the major audit shops invited.

### 7.4 Formal verification scope

Within budget, target Certora or Halmos rules on:
- Health-factor monotonicity under `_accrue`.
- "After `repay(d, x)` where `x >= outstanding`, `state[d] == Repaid`."
- "After `full(d)` where `collateralValueAtClose >= debtValueAtClose + bonus`, surplus > 0 implies borrower's balance increased by `surplus`."
- EIP-712 nonce non-replay across deals.

Formal verification is expensive; we should commit to it only on the four to six rules where the consequence of a violation would itself be a Critical bug.

---

## 8. Deployment &amp; ops runbook

### 8.1 Deployment order

1. `RoleManager` — sets the root authority. P2P GnosisSafe + AMINA GnosisSafe added as roles. Single-sig keys are never granted any role.
2. `KYBGateway`, `IssuerRegistry`, `ComplianceRegistry` — identity layer.
3. `OracleRouter`, `ParameterArchive`, `CollateralRegistry` — risk layer.
4. `EscrowVault` — immutable. Deploy via CREATE2 to a vanity address. Address pinned in the engine ABI.
5. `LendingEngine` — UUPS proxy. Implementation deployed first; proxy initialised with addresses of (1)–(4).
6. `LiquidationHandler`, `SettlementRouter`, `PortfolioLens` — bind to the engine.
7. `DealRegistry` — immutable. Last in the order so the EIP-712 domain (which includes the registry address) is final.

After deployment, run a smoke test: register a mock issuer, register a mock pair, run a fixture `openAndActivate → repay` against test tokens.

### 8.2 Role assignments at launch

| Role | Holder |
|---|---|
| `GOVERNOR` | P2P Staking 3-of-5 Safe |
| `CURATOR` | AMINA Bank 2-of-3 Safe |
| `LIQUIDATOR` | AMINA bot wallets (5 addresses rotatable), each rate-limited |
| `EMERGENCY` | Joint Safe: 1-of-P2P AND 1-of-AMINA, 2-of-2 |
| `OPS` | AMINA single-sig hot wallet, rate-limited |
| `ORACLE_ADMIN` | AMINA + Chainlink ops, 2-of-3 |

### 8.3 Monitoring + alerting

Required from day 1:

- Block-by-block listener on every `SettlementRouter` event.
- Per-deal HF computed every 5 minutes; alert if any deal crosses `warningBps`.
- Oracle freshness monitor with auto-page if any feed exceeds half its heartbeat.
- Reconciliation job that sums `EscrowVault.balanceOf[d][t]` across all deals every hour and compares to `IERC20(t).balanceOf(vault)`. Alert on mismatch.
- Liquidation step counter divergence between bot's expected state and on-chain state pages a human immediately.

### 8.4 Runbooks

- **Oracle stale → no new deals.** AMINA risk team decides whether to pause the pair until the feed recovers.
- **Liquidation fails (compliance hook reverts).** Pause the affected deal, alert AMINA legal, attempt to liquidate via custody-only path (off-chain).
- **Bug in `LendingEngine` discovered.** EMERGENCY halts the engine. P2P + AMINA jointly decide on patch + redeploy. `DealRegistry` and `EscrowVault` survive intact; engine reads them via interface.
- **Custodian insolvency.** `IssuerRegistry.pause(token)` for all that custodian's tokens. Existing deals continue (token transfers still work). AMINA's existing redemption pathway is the recovery mechanism.

---

## 9. Risk register

| ID | Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | Smart-contract bug in `LendingEngine` | Critical | Medium (despite audits) | Three audit shops; immunefi; engine is upgradeable behind timelock; `DealRegistry` and `EscrowVault` are immutable so funds survive engine bugs |
| R2 | EIP-712 sig replay across deals or chains | High | Low | Per-deal nonce + chain-ID in domain; nonce-used mapping enforced |
| R3 | Compliance hook misbehaves (reverts on legit transfers, or allows non-compliant transfers) | High | Medium | Hook contracts are audited at token-onboarding time; `IssuerRegistry.setHook` is `CURATOR`-only with timelock |
| R4 | Oracle manipulation or stall | High | Low–Medium | CAPO caps on derivative feeds; heartbeat enforcement; circuit breaker; AMINA off-chain price oracle as cross-check |
| R5 | Custody-side mint never happens after `AdvanceIntent` | High | Low | Atomic settlement means tokens are *already* in borrower's wallet before `AdvanceIntent` fires; the off-chain step is real-asset redemption, not mint, so user has on-chain receivable regardless |
| R6 | AMINA fails to liquidate when it should | High | Low (regulated bank, contractual obligation) | Monitoring + escalation; EMERGENCY halt as last resort; legal recourse |
| R7 | KYB schema needs to change post-launch | Medium | High | UUPS upgradeable `KYBGateway`; schema in an ERC-7201 namespace |
| R8 | Custodian insolvency | High | Low (regulated) | `IssuerRegistry.pause`; legal claim outside protocol scope |
| R9 | Privileged-role key compromise | High | Low | All roles held by multisig; `GOVERNOR` and `EMERGENCY` require multi-party signing |
| R10 | Cross-deal storage collision on upgrade | High | Low | ERC-7201 namespaced storage; storage-layout snapshots checked in CI |
| R11 | Solidity version EVM mismatch (Pectra/Prague) | Medium | Low | Pin solc 0.8.27+; test against Pectra fork |
| R12 | Bug-bounty payout depletes treasury | Low | Low | Bounty cap; insurance via Sherlock or similar |
| R13 | Counterparty reneges after signing | Medium | Medium | Atomic activation means a reneg before `openAndActivate` doesn't lock anything; AMINA's matching engine can blacklist repeat offenders |
| R14 | Regulatory change reclassifies the platform | High | Low–Medium | Matching is under AMINA's licence; P2P is tech provider; jurisdictional flexibility (Cayman + AMINA's EU/Asia licences) |

---

## 10. Open questions for v0.8 brief revision

These need answers from the product / legal / partnership side before we lock interfaces.

1. **AMINA bonding on-chain (R-architecture).** Will AMINA stake any capital on-chain as Pool-Delegate-style first-loss? If yes, add a `BondVault` contract to the architecture. If no, document explicitly.
2. **Borrower-initiated repay only, or anyone-can-repay?** AAVE allows anyone to repay another user's debt; Maple is stricter. Brief is silent. Default in v0.2 is anyone-can-repay (cheap, useful for partial third-party rescue); confirm OK.
3. **Surplus return on liquidation: borrower or AMINA?** Architectural answer is "borrower." Confirm with AMINA legal.
4. **Multi-collateral deals.** v0.7 brief uses singular "BTC collateral". For v1 we lock single-collateral-per-deal. Confirm.
5. **Maximum maturity.** Brief mentions 3-month cycles. Cap at 365 days or longer? Affects `CollateralRegistry.maxMaturity`.
6. **Partial-fill semantics.** Brief example: "1.2M of 2M filled, rest pending." Is "pending" an on-chain state (multiple deals, some not yet matched) or purely off-chain (UI shows aggregated state, but on-chain only the matched portions exist)? Default in v0.2: purely off-chain. Confirm.
7. **Cross-chain.** v0.7 says Ethereum mainnet. AMINA's EU clients may prefer Arbitrum / Base for lower fees on small deals. Out of scope for v1; confirm not for v2.
8. **Click-through legal terms.** Where is the hash anchored — `DealRegistry.termsHash` per deal, or a separate `MasterAgreement` contract once per onboarding? v0.2 uses the former; the latter is cleaner if terms versions matter.
9. **Privacy upgrade path.** Do we commit publicly to a future ZK-friendly deal registry, or leave it as a maybe? Affects how we describe the protocol to first counterparties.
10. **DeFi liquidity channel.** v0.7 §14 hints at ERC-4626 distribution for DeFi retail. ERC-7540 read-side support is now baked in. Confirm this is the intended path versus a separate distribution product.

---

## Appendix A — Comparison snapshot vs peer protocols

| | **P2PxAmina v0.2** | Maple v3 | Morpho Blue | Centrifuge V3 | Clearpool Prime |
|---|---|---|---|---|---|
| Pooled vs bilateral | **Bilateral** | Pooled per delegate | Isolated markets, pooled within | Pooled per tranche | Pool per borrower |
| Permissioned | **Yes (KYB)** | Yes (KYB) | No | Yes (transfer-restricted shares) | Yes (KYC via Securitize) |
| Collateral | Asset-backed via custody tokens | Collateral or uncollateralised | ERC-20 collateral, oracle priced | Tokenised RWAs as collateral | Unsecured |
| Liquidator | **Single privileged (AMINA)** | Permissioned via pool delegate | Permissionless | Pool-defined | n/a (unsecured) |
| Settlement | **Atomic on-chain + async custody** | Atomic on-chain | Atomic on-chain | Async (ERC-7540) | Atomic on-chain |
| Rate model | **Fixed at deal creation** | Fixed-term + open-term | Variable (IRM contract) | Pool-determined | Variable + spread |
| Upgradeability | **DealRegistry/Vault immutable, rest UUPS** | PoolManager upgradeable, Loan immutable | Fully immutable | Tranche & vault upgradeable | Pool-bespoke |
| Compliance | **Hook-based (per token)** | KYB at platform level | None native | Restricted-token + identity registry | Securitize ID gating |
| Async vault standard | **ERC-7540 view subset** | ERC-4626 | n/a | ERC-7540 full | n/a |
| Approximate LOC | **~1,640** | ~3,500 | 650 | ~5,000 | ~2,000 |

---

## Appendix B — Sources

Architectural ideas in this document draw from:

- [Morpho Blue: 650-line immutable lending primitive (Morpho docs)](https://morpho.org/blog/morpho-blue-and-how-it-enables-our-vision-for-defi-lending/)
- [Maple Finance smart contract architecture (Maple docs)](https://docs.maple.finance/technical-resources/protocol-overview/smart-contract-architecture)
- [Maple Finance institutional lending overview (OAK Research)](https://oakresearch.io/en/reports/protocols/maple-finance-complete-overview-hub-on-chain-institutional-lending)
- [Centrifuge V3 liquidity-pools ERC-7540 architecture (Centrifuge GitHub)](https://github.com/centrifuge/liquidity-pools)
- [Euler V2 EVK hooks and modular vault design (Euler docs)](https://docs.euler.finance/concepts/advanced/hooks/)
- [Clearpool Prime architecture (Clearpool docs)](https://docs.clearpool.finance/clearpool/products/lending/prime)
- [Membrane Labs institutional bilateral settlement (Membrane Labs)](https://membranelabs.com/)
- [Sygnum MultiSYG multi-sig BTC lending (CoinDesk)](https://www.coindesk.com/business/2025/10/24/swiss-bank-sygnum-to-launch-bitcoin-backed-loan-platform-with-multi-sig-wallet-control)
- [JPM Onyx × Broadridge DLR repo settlement (Securities Finance Times)](https://www.securitiesfinancetimes.com/securitieslendingnews/repoarticle.php?article_id=227046)
- [ERC-7540 asynchronous tokenized vaults (EIP)](https://eips.ethereum.org/EIPS/eip-7540)
- [ERC-3643 T-REX permissioned token standard (EIP)](https://eips.ethereum.org/EIPS/eip-3643)
- [ERC-7201 namespaced storage layout for upgradeable contracts (EIP)](https://eips.ethereum.org/EIPS/eip-7201)
- [AAVE v4 hub-spoke architecture and dynamic risk config (Aave v4 codebase, vendored at `mellow/aave/aave-v4/`)](https://github.com/aave/aave-v4)
- [Compound v3 (Comet) Configurator / proxy architecture (Compound GitHub)](https://github.com/compound-finance/comet)
- [OpenTrade institutional yield infrastructure (OpenTrade docs)](https://docs.opentrade.io/welcome-to-opentrade/platform-overview)

End of v0.2 implementation plan.
