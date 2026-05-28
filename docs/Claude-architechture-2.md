# P2PxAmina — Canonical Smart Contract Architecture v2

**Version**: v0.4 (Claude, 2026-05-26)
**Status**: design reference for engineering, audit, AMINA integration, and counsel review
**Supersedes**: `Claude-architechture-1.md`
**Cross-checked against**: `GPT-architechture-1.md` (same date, same scope)

This v2 keeps the v1 architecture intact and incorporates a set of small but meaningful improvements from GPT's parallel pass. The deltas are catalogued in §0 below.

---

## Table of contents

0. [Deltas from v1](#0-deltas-from-v1)
1. [Executive summary](#1-executive-summary)
2. [Design principles](#2-design-principles)
3. [System context (C4 L1)](#3-system-context-c4-l1)
4. [Container view (C4 L2)](#4-container-view-c4-l2)
5. [Contract inventory (C4 L3)](#5-contract-inventory-c4-l3)
6. [External dependencies](#6-external-dependencies)
7. [Roles, permissions, access control](#7-roles-permissions-access-control)
8. [Data model](#8-data-model)
9. [Deal state machine](#9-deal-state-machine)
10. [User stories](#10-user-stories)
11. [Use cases](#11-use-cases)
12. [Fund-flow diagrams](#12-fund-flow-diagrams)
13. [Settlement and off-chain integration](#13-settlement-and-off-chain-integration)
14. [Liquidation engine deep dive](#14-liquidation-engine-deep-dive)
15. [Risk parameters and versioning](#15-risk-parameters-and-versioning)
16. [Oracle architecture](#16-oracle-architecture)
17. [Compliance hooks](#17-compliance-hooks)
18. [Caps and limits](#18-caps-and-limits)
19. [Pause hierarchy](#19-pause-hierarchy)
20. [Upgradeability and recovery](#20-upgradeability-and-recovery)
21. [Reentrancy posture and gas budgets](#21-reentrancy-posture-and-gas-budgets)
22. [Risk allocation](#22-risk-allocation)
23. [Operational monitoring and alerts](#23-operational-monitoring-and-alerts)
24. [Deployment order](#24-deployment-order)
25. [Invariants](#25-invariants)
26. [Failure modes](#26-failure-modes)
27. [Audit surface](#27-audit-surface)
28. [v2 extension paths](#28-v2-extension-paths)
29. [Appendix A — Glossary](#29-appendix-a--glossary)
30. [Appendix B — EIP-712 typed data](#30-appendix-b--eip-712-typed-data)
31. [Appendix C — Event schema reference](#31-appendix-c--event-schema-reference)
32. [Appendix D — Open questions](#32-appendix-d--open-questions)

---

## 0. Deltas from v1

GPT's parallel architecture pass agreed with the v1 design at the structural level (same 13 contracts, same 8 roles, same atomic-activation flow, same immutability story). The differences are at the granularity of fields and policy enumeration. The following were adopted into v2:

| # | Delta | Source | Rationale |
|---|---|---|---|
| D1 | `TokenKind` becomes a 3-value enum: `Supply`, `Collateral`, `DualUse` | GPT §8.3 | USDC-class tokens may legitimately serve as both supply and collateral. Binary kind was unnecessarily restrictive. |
| D2 | `IssuerStatus` is an explicit enum (`Active`, `Paused`, `Deactivated`) at the issuer level, separate from per-token `paused` | GPT §8.3 | Issuer-level pause covers all of a custodian's tokens atomically. Cleaner than per-token cascading. |
| D3 | `legalAttestationHash` on the issuer record (in addition to per-token `redemptionAttestationHash`) | GPT §8.3 | Two anchors: master agreement with custodian, plus per-token redemption attestation. |
| D4 | `KybRecord.jurisdictionCode` field | GPT §8.2 | Compliance hooks need jurisdiction context. Cheap to carry. |
| D5 | `AMINASignedPriceAttestation` signs **both** collateral and supply prices, not just collateral | GPT §8.9 | Custody-issued stablecoins can deviate from peg under stress; AMINA should commit to both legs. |
| D6 | A fifth pause tier: `emergencySealedMode` (everything blocked, including borrower-favourable rescue actions) | GPT §15 | Genuine emergency lever; rarely used; documented explicitly to prevent ad-hoc additions later. |
| D7 | Two additional invariants for role separation and vault-access discipline | GPT §20 | Existing roles already enforce this; adding the invariant makes it test-targeted. |
| D8 | Dedicated **Risk Allocation** section (was embedded in failure modes) | GPT §24 | Cleaner reference for audit kickoff and investor materials. |
| D9 | Dedicated **Operational Monitoring & Alerts** section with alert severities | GPT §23 | Belongs in canonical architecture, not in a separate ops doc. |
| D10 | Dedicated **Deployment Order** section with a sequence diagram | GPT §22 | Reproducible deployment recipe; reduces "what did we do?" archaeology. |
| D11 | Dedicated **v2 extension paths** section with a table | GPT §25 | Makes clear what we deliberately did not foreclose. |
| D12 | Settlement events include `settlementRef` and `sequenceNumber` for reconciliation | GPT §8.10 | Makes off-chain reconciliation deterministic. |
| D13 | New §21 covering reentrancy posture and gas budgets | (mine, derived from both) | Both v1s implied this; lacked a single place to state it. |

The rest of v1 stands. Mermaid diagrams from v1 are preserved or upgraded; the C4 diagrams, role-speed Gantt, deal state machine, fund-flow flowcharts, and detailed sequence diagrams remain the canonical ones.

---

## 1. Executive summary

P2PxAmina is a **permissioned, bilateral, fixed-term repo rail** for institutional crypto lending. The smart-contract layer is a single self-contained system on Ethereum mainnet that:

- Records each deal as an **immutable bilateral agreement** signed by lender, borrower, and AMINA Bank.
- Holds collateral and supply tokens in a per-deal escrow ledger.
- Accrues interest on a simple-interest basis, pausing the clock during deal pause.
- Allows **only AMINA** to liquidate, in a deterministic three-phase flow.
- Emits structured settlement events that custodians use to reconcile real-asset redemptions.

Three actor types interact with the chain:

1. **Lenders and borrowers** — institutional counterparties, KYB'd by AMINA, holding custody-issued ERC-20 tokens.
2. **AMINA Bank** — licensed broker (FINMA Securities Dealer), curator (sets risk params), and liquidator.
3. **P2P Staking** — technology provider, contract governance via multisig + timelock.

**One-line framing**: a regulated bilateral repo workflow made legible on-chain — the contracts do *settlement, accounting, and audit*; AMINA does *brokerage, risk, and recovery*; custodians do *asset minting and real-world redemption*.

| Property | Value |
|---|---|
| Total LOC budget (Solidity) | ~1,800 |
| Contracts (concrete) | 13 |
| Roles | 8 |
| Invariants | 21 |
| Pause tiers | 5 |
| Cap dimensions | 9 |
| Upgrade policy | `DealRegistry`, `EscrowVault`, `ParameterArchive`, `DefaultPassHook`, `PortfolioLens` immutable; rest UUPS + timelock |
| Target chain | Ethereum mainnet (v1) |
| Audit shops | 2 in parallel (e.g., Trail of Bits + OpenZeppelin) + Immunefi bounty |

---

## 2. Design principles

These ten principles are the project's constitutional rules. Any PR that contradicts one of them is suspect.

1. **Bilateral, not pooled.** Each deal is its own logical market; risk does not commingle.
2. **Fixed-term, fixed-rate.** Rates are set off-chain by AMINA and frozen into the deal at creation. No utilisation curves.
3. **Permissioned counterparties.** Every wallet acting as lender or borrower has been KYB'd by AMINA. Permissionless wallets cannot transact.
4. **Single privileged liquidator.** Only AMINA can liquidate. No bonus auctions, no MEV opportunity, no permissionless keeper economics.
5. **Custody is the trust anchor.** Real assets live with regulated custodians; on-chain tokens are claims on custody. The protocol never holds real-asset value directly.
6. **Off-chain matching, on-chain settlement.** Matching is performed under AMINA's brokerage licence off-chain. The chain records the result via three signatures (lender, borrower, AMINA).
7. **Immutability where it matters.** `DealTerms` are write-once. `DealRegistry`, `EscrowVault`, and `ParameterArchive` are non-upgradeable. The state-machine engine and policy registries are upgradeable behind a timelocked multisig.
8. **Hook-based compliance.** Per-token compliance logic lives in audited hook contracts referenced by `ComplianceRegistry`. Pre-hooks are view-only; post-hooks cannot revert.
9. **Atomic settlement.** `openAndActivate` is a single transaction: terms recorded, collateral posted, supply advanced — or the transaction reverts. The protocol never carries half-settled deals.
10. **Multi-dimensional caps.** Global, per-token, per-pair, per-custodian, per-borrower, per-lender, per-maturity-bucket, and per-liquidator-daily caps exist from day one.

---

## 3. System context (C4 L1)

```mermaid
flowchart TB
    classDef ext fill:#fff4e6,stroke:#f59e0b,color:#333
    classDef sys fill:#e6f0ff,stroke:#3b82f6,color:#111,stroke-width:2px
    classDef custody fill:#f0faf3,stroke:#22c55e,color:#111
    classDef oracle fill:#f3f0ff,stroke:#8b5cf6,color:#111

    Lender["Lender<br/><i>Institutional LP<br/>holds custody-issued USDC</i>"]
    Borrower["Borrower<br/><i>Institutional borrower<br/>holds custody-issued BTC/ETH</i>"]
    Amina["AMINA Bank<br/><i>FINMA Securities Dealer<br/>broker · curator · liquidator</i>"]
    P2P["P2P Staking<br/><i>Tech provider · governance<br/>multisig + timelock</i>"]

    Protocol[("P2PxAmina<br/>Repo Rail<br/><i>13 Solidity contracts<br/>Ethereum mainnet</i>")]

    Fireblocks["Fireblocks<br/><i>Custodian<br/>mint/burn tokens</i>"]
    AminaCustody["AMINA Custody<br/><i>Tokeny / ERC-3643</i>"]
    BitGo["BitGo / Anchorage / etc."]

    Chainlink["Chainlink<br/><i>BTC/USD, ETH/USD, etc.</i>"]
    CAPO["CAPO adapters<br/><i>Composite price feeds<br/>with growth caps</i>"]

    Lender -->|"signs deals · supplies USDC"| Protocol
    Borrower -->|"signs deals · posts collateral · repays"| Protocol
    Amina -->|"attests matching · sets risk params · liquidates"| Protocol
    P2P -.->|"governance · upgrades · KYB intake"| Protocol

    Protocol -->|"reads price"| Chainlink
    Protocol -->|"reads price"| CAPO
    CAPO --> Chainlink

    Protocol -->|"holds tokens issued by"| Fireblocks
    Protocol -->|"holds tokens issued by"| AminaCustody
    Protocol -->|"holds tokens issued by"| BitGo

    Fireblocks -->|"mints/burns · redeem"| Lender
    Fireblocks -->|"mints/burns · redeem"| Borrower
    AminaCustody -.-> Amina

    class Lender,Borrower,Amina,P2P ext
    class Protocol sys
    class Fireblocks,AminaCustody,BitGo custody
    class Chainlink,CAPO oracle
```

---

## 4. Container view (C4 L2)

```mermaid
flowchart TB
    classDef offchain fill:#fff4e6,stroke:#f59e0b,color:#111
    classDef onchain fill:#e6f0ff,stroke:#3b82f6,color:#111
    classDef custody fill:#f0faf3,stroke:#22c55e,color:#111

    subgraph OffChain["Off-Chain Layer (P2P + AMINA)"]
        direction TB
        Dashboard["Dashboard / UI<br/>portfolio view · order entry · signing"]
        MatchEngine["Matching Engine<br/>FCFS · partial fills · under AMINA licence"]
        RateEngine["Rate Engine<br/>base rate · spreads"]
        KybIntake["KYB Intake<br/>document upload · status sync"]
        AminaBot["AMINA OPS Bots<br/>monitor HF · warn · liquidate"]
        CustodyListener["Custody Listener<br/>SettlementRouter event ingest"]
    end

    subgraph OnChain["On-Chain Layer (Ethereum mainnet)"]
        direction TB
        IdentityLayer["L1 — Identity &amp; Registry<br/>RoleManager · KYBGateway<br/>IssuerRegistry · ComplianceRegistry"]
        RiskLayer["L2 — Risk Engine<br/>CollateralRegistry · ParameterArchive"]
        DealLayer["L3 — Deal Engine<br/>DealRegistry · EscrowVault · LendingEngine"]
        SettleLayer["L4 — Settlement &amp; Liquidation<br/>LiquidationHandler · SettlementRouter"]
        ViewLayer["L5 — Views<br/>PortfolioLens"]
    end

    subgraph CustodyLayer["Custody Layer"]
        direction TB
        FireblocksApi["Fireblocks Policy Engine"]
        AminaApi["AMINA / Tokeny Engine"]
        BitGoApi["BitGo / Anchorage"]
    end

    Dashboard --> MatchEngine
    Dashboard --> KybIntake
    MatchEngine --> RateEngine
    KybIntake -->|"approve KYB"| IdentityLayer
    MatchEngine -->|"openAndActivate"| DealLayer
    AminaBot -->|"warn · partial · full"| SettleLayer
    AminaBot -->|"read HF"| DealLayer
    AminaBot -->|"read HF"| RiskLayer

    DealLayer -.->|"reads"| IdentityLayer
    DealLayer -.->|"reads"| RiskLayer
    SettleLayer -.->|"reads · writes"| DealLayer
    ViewLayer -.->|"reads"| DealLayer

    SettleLayer -->|"events"| CustodyListener
    CustodyListener --> FireblocksApi
    CustodyListener --> AminaApi
    CustodyListener --> BitGoApi

    FireblocksApi -.->|"mint/burn · settle"| OnChain
    AminaApi -.->|"mint/burn · settle"| OnChain
    BitGoApi -.->|"mint/burn · settle"| OnChain

    class Dashboard,MatchEngine,RateEngine,KybIntake,AminaBot,CustodyListener offchain
    class IdentityLayer,RiskLayer,DealLayer,SettleLayer,ViewLayer onchain
    class FireblocksApi,AminaApi,BitGoApi custody
```

---

## 5. Contract inventory (C4 L3)

```mermaid
flowchart TB
    classDef immutable fill:#ffe4e6,stroke:#dc2626,color:#111,stroke-width:2px
    classDef uups fill:#dbeafe,stroke:#2563eb,color:#111

    subgraph L1["L1 — Identity &amp; Registry"]
        RM["RoleManager<br/>~40 LOC · UUPS"]
        KYB["KYBGateway<br/>~95 LOC · UUPS"]
        IR["IssuerRegistry<br/>~150 LOC · UUPS"]
        CR["ComplianceRegistry<br/>~80 LOC · UUPS"]
        DPH["DefaultPassHook<br/>~15 LOC · IMMUTABLE"]
    end

    subgraph L2["L2 — Risk Engine"]
        CollR["CollateralRegistry<br/>~170 LOC · UUPS"]
        PA["ParameterArchive<br/>~80 LOC · IMMUTABLE"]
    end

    subgraph L3["L3 — Deal Engine"]
        DR["DealRegistry<br/>~180 LOC · IMMUTABLE"]
        EV["EscrowVault<br/>~140 LOC · IMMUTABLE"]
        LE["LendingEngine<br/>~340 LOC · UUPS+timelock"]
    end

    subgraph L4["L4 — Settlement &amp; Liquidation"]
        LH["LiquidationHandler<br/>~220 LOC · UUPS+timelock"]
        SR["SettlementRouter<br/>~70 LOC · UUPS"]
    end

    subgraph L5["L5 — Views"]
        PL["PortfolioLens<br/>~90 LOC · IMMUTABLE"]
    end

    RM -.->|"role checks"| KYB
    RM -.->|"role checks"| IR
    RM -.->|"role checks"| CR
    RM -.->|"role checks"| CollR
    RM -.->|"role checks"| LE
    RM -.->|"role checks"| LH

    LE -->|"verify KYB"| KYB
    LE -->|"check token kind &amp; cap"| IR
    LE -->|"compliance hooks"| CR
    LE -->|"snapshot params"| CollR
    LE -->|"read snapshotted params"| PA
    LE -->|"record terms"| DR
    LE -->|"move funds"| EV
    LE -->|"emit intents"| SR

    LH -->|"reads &amp; writes deal state"| LE
    LH -->|"emit intents"| SR
    LH -->|"check pair config"| CollR

    PL -->|"read"| LE
    PL -->|"read"| DR
    PL -->|"read"| EV

    CR -.->|"default fallback"| DPH
    CollR -->|"writes old version"| PA

    class DR,EV,PA,PL,DPH immutable
    class RM,KYB,IR,CR,CollR,LE,LH,SR uups
```

### 5.1 LOC summary

| Layer | LOC |
|---|---|
| L1 — Identity &amp; Registry (incl. `DefaultPassHook`) | ~380 |
| L2 — Risk Engine | ~250 |
| L3 — Deal Engine | ~660 |
| L4 — Settlement &amp; Liquidation | ~290 |
| L5 — Views | ~90 |
| Shared libraries (`FixedMath`, `EIP712Hash`, `ReasonCodes`) | ~150 |
| **Total** | **~1,820** |

### 5.2 Per-contract reference

#### `RoleManager`
OZ `AccessManager` wrapper. Owns the role bindings. Roles enumerated in [§7](#7-roles-permissions-access-control).

#### `KYBGateway`
Wallet eligibility. Now carries `jurisdictionCode` for hooks that need jurisdictional context. UUPS to allow schema growth.

#### `IssuerRegistry`
Two-level state: issuer-level `IssuerStatus` (`Active`, `Paused`, `Deactivated`) plus per-token `paused` flag. Two attestation hashes: `legalAttestationHash` on the issuer (master agreement), `redemptionAttestationHash` per token. Cap accounting on both axes.

#### `ComplianceRegistry`
Routes (token, action) → hook. Pre-hook is `staticcall` view; post-hook is best-effort `try/catch`. Default fallback to `DefaultPassHook`.

#### `DefaultPassHook`
Immutable no-op hook. The conservative default for tokens without per-token compliance logic.

#### `CollateralRegistry`
Per-pair params. **Oracle source is part of the params**, not a separate registry. Version-bumping snapshots the old params into `ParameterArchive` atomically.

#### `ParameterArchive`
Immutable historical store. Write-once per `(pair, version)`.

#### `DealRegistry`
Append-only signed terms. Three signatures (lender, borrower, AMINA). EIP-712 domain pinned at deployment.

#### `EscrowVault`
Per-deal token ledger. Only `LendingEngine` can mutate. Reconciliation invariant holds across all external calls.

#### `LendingEngine`
The state machine. Carries pause-clock state, cap counters, ERC-7540 view subset. UUPS + 24h timelock; emergency-shortened to 1h if `EMERGENCY` multisig approves.

#### `LiquidationHandler`
AMINA-only three-phase liquidation. Verifies dual-price `AMINASignedPriceAttestation` when oracle is stale. Surplus return computed and emitted.

#### `SettlementRouter`
Typed events with `settlementRef` and `sequenceNumber` for custodian-side reconciliation.

#### `PortfolioLens`
Read-only aggregation + ERC-7540 view re-export.

---

## 6. External dependencies

```mermaid
flowchart LR
    classDef ext fill:#fff4e6,stroke:#f59e0b
    classDef int fill:#dbeafe,stroke:#2563eb

    OZ["OpenZeppelin Contracts<br/>v5.x"]
    OZSafe["• AccessManager<br/>• UUPSUpgradeable<br/>• ReentrancyGuard<br/>• SafeERC20<br/>• ERC1967 / ERC-7201 storage<br/>• ECDSA / EIP-712"]

    CL["Chainlink"]
    CLDetail["• AggregatorV3Interface<br/>• Core USD pairs<br/>• Composite (CAPO) adapters"]

    ERC2612["ERC-2612 Permits"]
    ERC2612D["Single-tx atomic settlement.<br/>Fallback to pre-approval for<br/>tokens without permit."]

    ERC3643["ERC-3643 / T-REX"]
    ERC3643D["Permissioned-token compliance<br/>consumed via hooks, not<br/>built into the engine."]

    EIP712["EIP-712"]
    EIP712D["3-sig DealTerms.<br/>AMINASignedPriceAttestation."]

    ERC7201["ERC-7201"]
    ERC7201D["Namespaced storage for<br/>all UUPS contracts."]

    Foundry["Foundry + Halmos"]
    FoundryD["Build · test · fuzz · invariant ·<br/>fork · symbolic execution."]

    OZ --- OZSafe
    CL --- CLDetail
    ERC2612 --- ERC2612D
    ERC3643 --- ERC3643D
    EIP712 --- EIP712D
    ERC7201 --- ERC7201D
    Foundry --- FoundryD

    class OZ,CL,ERC2612,ERC3643,EIP712,ERC7201,Foundry ext
    class OZSafe,CLDetail,ERC2612D,ERC3643D,EIP712D,ERC7201D,FoundryD int
```

| Dependency | Used by | Risk | Mitigation |
|---|---|---|---|
| ERC-20 / ERC-3643 tokens | EscrowVault, hooks | Transfer reverts, issuer freeze, allowlist failures | `RepaidPendingCollateralRelease` state; typed hook errors; allowlist preflight at onboarding |
| Custodians | Token issuance + real-asset redemption | Insolvency, redemption delay | `IssuerStatus` lifecycle; per-issuer caps; legal attestation hash; AMINA runbook |
| Chainlink / CAPO | CollateralRegistry param oracles | Stale, decimal bug, wrong source | Heartbeat enforcement, source snapshot in `ParameterArchive`, shared decimal lib, `forceOracleOverride` |
| AMINA price desk | Stale-oracle liquidation evidence | Wrong / disputed off-chain price | Signed attestation event; signer rotation; permanent audit trail |
| AMINA matching engine | Deal construction | Wrong terms / unauthorised match | Three signatures; `ALLOCATOR` rate limit (100 deals / day / wallet); cap pre-checks |
| Safe / multisig infra | All privileged roles | Key compromise | Role separation; timelocked upgrades; rate-limited bot wallets |
| ERC-2612 permits | Atomic activation | Token lacks permit / replay | Fallback pre-approval path; nonce + domain checks |

---

## 7. Roles, permissions, access control

```mermaid
flowchart TB
    classDef gov fill:#ede5ff,stroke:#5b21b6
    classDef amina fill:#d1f2db,stroke:#15803d
    classDef joint fill:#ffe4e6,stroke:#dc2626

    GOV["GOVERNOR<br/>P2P 3-of-5 multisig<br/><i>upgrades · role grants</i>"]
    EMER["EMERGENCY<br/>Joint P2P+AMINA 2-of-2<br/><i>global halt · oracle override<br/>emergencySealedMode</i>"]
    CUR["CURATOR<br/>AMINA risk 2-of-3 multisig<br/><i>KYB · risk params · issuers</i>"]
    ALLOC["ALLOCATOR<br/>AMINA matching hot wallet<br/><i>openAndActivate<br/>100 deals/day cap</i>"]
    LIQ["LIQUIDATOR<br/>AMINA bot wallets (5)<br/><i>warn · partial · full<br/>$50M/day per wallet</i>"]
    GUARD["GUARDIAN<br/>AMINA OPS multisig<br/><i>pauses (token/pair/deal)</i>"]
    OPS["OPS<br/>AMINA hot wallet<br/><i>cap updates · feed rotation</i>"]
    ORAC["ORACLE_ADMIN<br/>AMINA + Chainlink 2-of-3<br/><i>price-source registration<br/>creates new param version</i>"]

    GOV -->|grants| EMER
    GOV -->|grants| CUR
    GOV -->|grants| ALLOC
    GOV -->|grants| LIQ
    GOV -->|grants| GUARD
    GOV -->|grants| OPS
    GOV -->|grants| ORAC

    class GOV gov
    class EMER joint
    class CUR,ALLOC,LIQ,GUARD,OPS,ORAC amina
```

### 7.1 Role-action speed

```mermaid
gantt
    title Role action latencies (typical)
    dateFormat X
    axisFormat %s

    section Slow (timelocked)
    GOVERNOR upgrade            :a1, 0, 86400
    CURATOR risk tighten        :a2, 0, 86400
    CURATOR issuer onboard      :a3, 0, 86400

    section Medium
    CURATOR risk loosen         :b1, 0, 600
    ORACLE_ADMIN feed rotate    :b2, 0, 600
    GUARDIAN unpause            :b3, 0, 600

    section Fast (no timelock, rate-limited)
    ALLOCATOR open deal         :c1, 0, 12
    LIQUIDATOR warn             :c2, 0, 12
    LIQUIDATOR partial          :c3, 0, 12
    LIQUIDATOR full             :c4, 0, 12
    GUARDIAN pause              :c5, 0, 12
    EMERGENCY global halt       :c6, 0, 12
    EMERGENCY oracle override   :c7, 0, 12
    OPS routine cap update      :c8, 0, 60
```

### 7.2 Access-control matrix

| Function | GOVERNOR | EMERGENCY | CURATOR | ALLOCATOR | LIQUIDATOR | GUARDIAN | OPS | ORACLE_ADMIN | * |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `RoleManager.grantRole` | ✓ | | | | | | | | |
| Engine / Handler upgrade | ✓ +TL | | | | | | | | |
| `KYBGateway.setStatus` | | | ✓ | | | | | | |
| `IssuerRegistry.addIssuer` | | | ✓ +TL | | | | | | |
| `IssuerRegistry.addToken` | | | ✓ +TL | | | | | | |
| `IssuerRegistry.pauseToken` | | | | | | ✓ | | | |
| `IssuerRegistry.setIssuerStatus` | | | | | | ✓ | | | |
| `IssuerRegistry.setCap` | | | ✓ | | | | ✓ | | |
| `ComplianceRegistry.registerHook` | | | ✓ +TL | | | | | | |
| `CollateralRegistry.addPair` | | | ✓ +TL | | | | | | |
| `CollateralRegistry.updatePair` (tighten) | | | ✓ +TL | | | | | | |
| `CollateralRegistry.updatePair` (loosen) | | | ✓ | | | | | | |
| `CollateralRegistry.pausePair` | | | | | | ✓ | | | |
| `OracleRotation` (new version) | | | | | | | | ✓ | |
| `LendingEngine.openAndActivate` | | | | ✓ | | | | | |
| `LendingEngine.repay` | | | | | | | | | ✓ (compliant) |
| `LendingEngine.topUpCollateral` | | | | | | | | | ✓ (borrower) |
| `LendingEngine.claimUnreleasedCollateral` | | | | | | | | | ✓ (borrower) |
| `LendingEngine.pauseDeal` | | | | | | ✓ | | | |
| `LendingEngine.unpauseDeal` | | | | | | ✓ +TL | | | |
| `LendingEngine.globalHalt` | | ✓ | | | | | | | |
| `LendingEngine.emergencySealedMode` | | ✓ | | | | | | | |
| `LiquidationHandler.warn` | | | | | ✓ | | | | |
| `LiquidationHandler.partial` | | | | | ✓ | | | | |
| `LiquidationHandler.full` | | | | | ✓ | | | | |
| `LendingEngine.forceOracleOverride` | | ✓ | | | | | | | |

*+TL = subject to timelock delay (24h default; emergency-shortenable to 1h)*

### 7.3 Privilege separation property

No single role can both (a) change risk parameters and (b) move funds from escrow. Compromising any single role does not enable a drain attack:

- `ALLOCATOR` compromise → can open deals but needs valid 3-party signatures.
- `LIQUIDATOR` compromise → can liquidate but only deals with HF below threshold, capped by daily limit + step counter.
- `GUARDIAN` compromise → can pause (annoying but no fund loss).
- `CURATOR` compromise → risk params; multisig + timelock for dangerous changes.
- `OPS` compromise → low-stakes metadata only.
- `ORACLE_ADMIN` compromise → new param version (not live-deal override).
- `GOVERNOR` compromise → upgrades behind timelock; EMERGENCY can intervene.
- `EMERGENCY` compromise → requires both P2P and AMINA to be compromised.

This is the access-control safety net.

---

## 8. Data model

```mermaid
classDiagram
    direction LR

    class DealTerms {
        +address lender
        +address borrower
        +address supplyToken
        +address collateralToken
        +uint128 principal
        +uint128 collateralAmount
        +uint32 rateBps
        +uint64 startTs
        +uint64 maturityTs
        +bytes32 pairKey
        +uint32 paramVersion
        +bytes32 nonceLender
        +bytes32 nonceBorrower
        +bytes32 nonceAmina
        +bytes32 legalTermsHash
    }

    class DealState {
        +DealStateEnum state
        +uint128 outstanding
        +uint128 collateralPosted
        +uint64 lastTouchTs
        +uint8 liquidationStep
        +uint64 pauseStartedAt
        +uint64 totalPausedTime
        +bytes32 lastPauseReason
        +uint32 versionKey
    }

    class DealStateEnum {
        <<enumeration>>
        None
        Active
        Warned
        Liquidating
        Matured
        Repaid
        Repaid_PendingCollateralRelease
        Liquidated
        Defaulted
    }

    class Params {
        +uint16 ltvBps
        +uint16 warningBps
        +uint16 partialLiqBps
        +uint16 fullLiqBps
        +uint32 maxMaturity
        +uint16 maxRateBps
        +uint16 liquidationBonusBps
        +uint16 aminaFeeBps
        +uint256 pairCapUsd
        +address priceSourceCollateral
        +address priceSourceSupply
        +uint32 heartbeatCollateral
        +uint32 heartbeatSupply
        +uint8 oracleDecimalsCollateral
        +uint8 oracleDecimalsSupply
        +bool active
    }

    class IssuerInfo {
        +address custodian
        +IssuerStatus status
        +bytes32 legalAttestationHash
        +uint256 globalCapUsd
        +uint256 usedCapUsd
    }

    class IssuerStatus {
        <<enumeration>>
        Unknown
        Active
        Paused
        Deactivated
    }

    class TokenInfo {
        +address issuer
        +TokenKind kind
        +uint8 decimals
        +bool paused
        +uint256 capUsd
        +uint256 usedCapUsd
        +bytes32 redemptionAttestationHash
    }

    class TokenKind {
        <<enumeration>>
        Unknown
        Supply
        Collateral
        DualUse
    }

    class KybRecord {
        +KybStatus status
        +uint64 approvedAt
        +uint64 expiryTs
        +bytes32 documentsHash
        +address approvedBy
        +bytes32 jurisdictionCode
    }

    class KybStatus {
        <<enumeration>>
        Unknown
        Approved
        Suspended
        Revoked
    }

    class Caps {
        +uint128 globalNotionalCap
        +uint128 globalOutstanding
        +mapping perTokenCap
        +mapping perPairCap
        +mapping perBorrowerCap
        +mapping perLenderCap
        +mapping perMaturityBucketCap
        +mapping perLiquidatorDailyCap
    }

    class LiqState {
        +uint8 phase
        +uint64 phaseEnteredAt
        +uint128 cumulativeLiquidated
        +bytes32 lastReasonCode
    }

    class AMINASignedPriceAttestation {
        +bytes32 dealId
        +bytes32 sourceId
        +uint256 observedCollateralPrice
        +uint256 observedSupplyPrice
        +uint64 observationTs
        +bytes32 reasonCode
        +bytes signature
    }

    DealTerms --> DealState : "1:1 via dealId"
    DealTerms --> Params : "via pairKey + paramVersion"
    DealState --> DealStateEnum
    Params --> TokenInfo : "supplyToken, collateralToken"
    IssuerInfo --> IssuerStatus
    TokenInfo --> IssuerInfo : "issued by"
    TokenInfo --> TokenKind
    KybRecord --> KybStatus
```

### 8.1 Key relationships

- `dealId = keccak256(abi.encode(DealTerms))` — content-addressable.
- `pairKey = keccak256(abi.encodePacked(collateralToken, supplyToken))`.
- `paramVersion` is snapshotted into `DealTerms` at creation; the engine reads `ParameterArchive[pairKey][paramVersion]` for the deal's lifetime.
- `legalTermsHash` is the off-chain master-agreement hash (separate from the EIP-712 terms hash).

### 8.2 Two-level token registry

The registry has two levels:

```
IssuerRegistry
├── issuers[issuerAddr] → IssuerInfo (custodian-level: status, legal attestation, global cap)
└── tokens[tokenAddr]   → TokenInfo (per-token: kind, decimals, cap, redemption attestation, paused)
```

Behaviours:

- `IssuerStatus.Paused` pauses *all* of a custodian's tokens at once (e.g., custodian operational incident).
- Per-token `paused` is a finer-grained tool (e.g., one mint contract has a bug).
- `IssuerStatus.Deactivated` is terminal-with-cleanup: new deals blocked, existing deals continue settling.

### 8.3 `DualUse` token kind

Tokens classified as `DualUse` may appear as either the supply or collateral leg of a deal. The classic case is USDC: lent on one deal, posted as collateral on another. The engine enforces:

```
require(supplyTokenInfo.kind == Supply || supplyTokenInfo.kind == DualUse, "BAD_SUPPLY_KIND");
require(collateralTokenInfo.kind == Collateral || collateralTokenInfo.kind == DualUse, "BAD_COLL_KIND");
require(supplyToken != collateralToken, "SAME_TOKEN");
```

The last constraint prevents a self-collateralised deal even when both legs are DualUse.

---

## 9. Deal state machine

```mermaid
stateDiagram-v2
    [*] --> None

    None --> Active: openAndActivate<br/>(atomic settlement)

    Active --> Active: topUpCollateral
    Active --> Active: repay (partial)
    Active --> Repaid: repay (full)<br/>collateral release ok
    Active --> Repaid_PendingCollateralRelease: repay (full)<br/>collateral blocked
    Active --> Warned: warn<br/>(HF crossed warningBps)
    Active --> Matured: settleMaturity
    Active --> Liquidating: full threshold breached<br/>(skipping warn)

    Warned --> Active: top-up or partial repay cures
    Warned --> Liquidating: partialLiquidate<br/>(grace expired)
    Warned --> Repaid: repay (full)
    Warned --> Matured: settleMaturity

    Matured --> Repaid: repay (full)
    Matured --> Liquidating: fullLiquidate<br/>(grace expired)

    Liquidating --> Liquidating: partialLiquidate (step++)
    Liquidating --> Active: borrower cures via top-up
    Liquidating --> Repaid: full repay before final liq
    Liquidating --> Liquidated: fullLiquidate<br/>collateral &gt;= debt+bonus
    Liquidating --> Defaulted: fullLiquidate<br/>collateral &lt; debt+bonus

    Repaid_PendingCollateralRelease --> Repaid: claimUnreleasedCollateral

    Repaid --> [*]
    Liquidated --> [*]
    Defaulted --> [*]

    note right of None: Deal never recorded.<br/>Activation atomic.
    note right of Repaid_PendingCollateralRelease: Debt cleared; collateral<br/>blocked by issuer freeze.<br/>Recoverable.
    note right of Defaulted: Residual debt after full liq.<br/>Booked off-chain to AMINA.
```

### 9.1 Transition guards

| From → To | Guard |
|---|---|
| `None → Active` | 3 valid sigs + KYB approved for L, B (and caller if non-counterparty) + 9 cap checks + issuer Active + token not paused + pair active + oracle fresh + compliance hooks ok |
| `Active|Warned → Warned` | HF crossed `warningBps`; `LIQUIDATOR` only |
| `Warned|Liquidating → Active` | HF back ≥ 1.0 after top-up or partial repay; automatic |
| `Warned → Liquidating` | HF crossed `partialLiqBps` AND grace expired; `LIQUIDATOR` only |
| `Active → Liquidating` | HF crossed `fullLiqBps` (skipping `Warned`); `LIQUIDATOR` only |
| `Active|Warned → Repaid` | `outstanding == 0` after repay; collateral release succeeds |
| `Active|Warned → Repaid_PendingCollateralRelease` | `outstanding == 0` but collateral release reverts (typed reason from hook) |
| `Repaid_PendingCollateralRelease → Repaid` | Borrower calls `claimUnreleasedCollateral` and transfer succeeds |
| `Liquidating → Liquidated` | `fullLiquidate` succeeds and `collateralValueAtClose >= debt+bonus+fee` |
| `Liquidating → Defaulted` | `fullLiquidate` succeeds but `collateralValueAtClose < debt+bonus+fee` |
| `Active → Matured` | `block.timestamp >= effectiveMaturityTs`; permissionless |
| `Matured → Liquidating` | Grace expired after maturity; `LIQUIDATOR` only |

### 9.2 Pause is an overlay, not a state

Pause is implemented as a boolean overlay on the existing state, not as a separate state in the DAG. A deal in any non-terminal state can be paused. While paused:
- `pauseStartedAt > 0` (the marker).
- Interest accrual halts (see [§19](#19-pause-hierarchy)).
- Only specific actions are callable (see [§19.1](#191-pause-behaviour-summary)).

---

## 10. User stories

(Unchanged from v1; reproduced here for completeness.)

- **Anna** (lender, regional bank treasury): lend idle USDC at institutional rates; see one position, one rate, one maturity; trust that counterparties are KYB'd.
- **Bruno** (borrower, crypto hedge fund treasurer): access cash without selling BTC; lock in rate up front; have a chance to cure before liquidation; receive surplus on liquidation.
- **Riccardo** (AMINA risk desk): tighten LTV without retroactively endangering live deals; monitor every deal's HF; onboard custodians through documented, timelocked process; liquidate using off-chain price data when oracle stale, with on-chain evidence.
- **Olivia** (AMINA OPS, runs liquidation bots): idempotent calls via step counter; per-wallet daily caps; fast token-pause without multisig.
- **Pierre** (P2P CTO): clear separation between governance and risk decisions; timelocked upgrades; loud events for every privileged call.
- **Cathy** (Fireblocks engineering): stable event schema with sequence numbers; sufficient context in compliance hooks; protocol-level token pause.
- **Adrian** (auditor): small focused codebase; documented blast radii; invariants as test targets.

---

## 11. Use cases

This section preserves the v1 sequence diagrams for KYB onboarding, issuer onboarding, pair onboarding, atomic activation, top-up, normal repay, warning, partial liquidation, full liquidation with surplus, force oracle override, engine recovery, and token freeze recovery. They are not reproduced here verbatim to save space; see Claude-architechture-1.md §11.

The v2 additions:

### 11.13 Batch atomic activation (optional, `ALLOCATOR` convenience)

When the matching engine produces N bilateral deals that should settle as a batch (one lender's order matched against N borrowers), the engine exposes `openAndActivateBatch`:

```mermaid
sequenceDiagram
    actor ALLOCATOR
    participant LendingEngine
    participant LoopGuard

    ALLOCATOR->>LendingEngine: openAndActivateBatch(terms[], sigs[], permits[])
    activate LendingEngine
    LendingEngine->>LoopGuard: enter (single nonReentrant guard for batch)
    loop for each deal in array
        LendingEngine->>LendingEngine: openAndActivateSingle (internal)
    end
    LendingEngine->>LoopGuard: exit
    deactivate LendingEngine

    Note over LendingEngine: All-or-nothing: any single failure<br/>reverts the entire batch.<br/>Counts against ALLOCATOR rate limit as N.
```

Constraints:
- Bounded by gas limit; practical batch size 5–10 deals.
- All deals in a batch must pass independently; one failure reverts all.
- Each deal still consumes one `ALLOCATOR` rate-limit slot.

This is a convenience, not a primitive. A future v2 may eliminate it in favour of single-deal calls at the matching engine.

### 11.14 KYB suspension mid-deal

If `CURATOR` suspends a wallet's KYB while it has live deals:

```mermaid
sequenceDiagram
    actor CURATOR
    participant KYBGateway
    participant LendingEngine

    CURATOR->>KYBGateway: setStatus(wallet, Suspended, ...)

    Note over KYBGateway,LendingEngine: Live deals continue.<br/>Wallet cannot open new deals.<br/>Wallet can still repay/top-up<br/>(self-rescue allowed even if KYB suspended,<br/>subject to token compliance hook).
```

Rationale: trapping a suspended wallet from repaying its own debt would be worse than letting it close the position cleanly. The compliance hook on the token may still reject the transfer if it requires KYB; that's the token's decision, not the protocol's.

### 11.15 Issuer-level pause (cascade)

```mermaid
sequenceDiagram
    actor GUARDIAN
    participant IssuerRegistry
    participant LendingEngine

    Note over GUARDIAN: Custodian reports operational incident
    GUARDIAN->>IssuerRegistry: setIssuerStatus(issuer, Paused)
    IssuerRegistry-->>LendingEngine: IssuerPaused event

    Note over LendingEngine: All tokens issued by this custodian<br/>are effectively paused for new deals.<br/>Existing deals continue if individual<br/>token transfers succeed.
```

---

## 12. Fund-flow diagrams

(Unchanged from v1; happy path, liquidation with surplus, default. See Claude-architechture-1.md §12.)

---

## 13. Settlement and off-chain integration

### 13.1 Event schema (v2)

Every settlement event carries:

- `dealId` (indexed)
- `settlementRef` — unique reference for off-chain ack
- `sequenceNumber` — monotonic per-router event counter for ordered processing
- Action-specific fields (token, amount, beneficiary, etc.)
- `expectedSettlementDeadline` where applicable

```solidity
event AdvanceIntent(
    bytes32 indexed dealId,
    address indexed supplyToken,
    uint256 amount,
    address indexed beneficiary,
    bytes32 settlementRef,
    uint64 sequenceNumber,
    uint64 expectedSettlementDeadline
);

event RedemptionIntent(...);          // similar shape
event CollateralTopUpIntent(...);
event LiquidationIntent(
    bytes32 indexed dealId,
    LiquidationPhase phase,
    address indexed collateralToken,
    uint256 amount,
    address indexed aminaSettlement,
    bytes32 settlementRef,
    uint64 sequenceNumber,
    bytes32 reasonCode
);
event SurplusReturned(...);
event Defaulted(
    bytes32 indexed dealId,
    uint256 shortfallUsd,
    bytes32 detailsHash,
    uint64 sequenceNumber
);
event UnreleasedCollateral(
    bytes32 indexed dealId,
    address indexed borrower,
    address indexed token,
    uint256 amount,
    bytes32 reasonCode,
    uint64 sequenceNumber
);
event StaleOraclePriceUsed(
    bytes32 indexed dealId,
    bytes32 sourceId,
    uint256 collateralPrice,
    uint256 supplyPrice,
    uint64 observationTs,
    bytes32 reasonCode
);
```

### 13.2 Sequence number discipline

`sequenceNumber` is a single monotonically-increasing counter on `SettlementRouter` shared across event types. Custodian listeners process strictly in sequence-number order; gaps trigger a reconciliation alert.

### 13.3 Reconciliation invariant

For every event at sequence `s` with `dealId d`:

1. Custodian acknowledgement arrives within `expectedSettlementDeadline - 4h` or AMINA OPS is paged.
2. Custodian's `settlementRef` echoes the protocol's `settlementRef`.
3. Daily reconciliation: protocol's `(d, s, amount, token)` tuples sum to the custodian's net flow for the day, per token.

---

## 14. Liquidation engine deep dive

### 14.1 Three-phase state machine

(Unchanged from v1; same warn → partial → full with step counter and grace clocks.)

### 14.2 Dual-price attestation (v2)

`AMINASignedPriceAttestation` now signs both collateral and supply prices:

```solidity
struct AMINASignedPriceAttestation {
    bytes32 dealId;
    bytes32 sourceId;
    uint256 observedCollateralPrice;
    uint256 observedSupplyPrice;
    uint64 observationTs;
    bytes32 reasonCode;
    bytes signature;
}
```

Why both: a custody-issued stablecoin can deviate from $1.00 under stress (Silicon Valley Bank week, March 2023, etc.). If AMINA liquidates against a stale on-chain oracle for a collateral token, they must also commit to the price they used for the supply token. Otherwise AMINA could implicitly profit by assuming supply token = $1.00 even when it's trading at $0.97.

The signature is over the EIP-712 hash of the entire struct (excluding the signature field).

### 14.3 Surplus computation (unchanged)

```
debtUsd            = outstanding × observedSupplyPrice
payoutNeededUsd    = debtUsd × (10000 + bonusBps + aminaFeeBps) / 10000
collateralValueUsd = collateralPosted × observedCollateralPrice
amountToAmina      = min(collateralPosted, payoutNeededUsd / observedCollateralPrice)
surplusToBorrower  = collateralPosted - amountToAmina

if collateralValueUsd >= payoutNeededUsd:
    state = Liquidated; surplus returned to borrower
else:
    state = Defaulted; shortfallUsd = payoutNeededUsd - collateralValueUsd; surplus = 0
```

---

## 15. Risk parameters and versioning

(Unchanged from v1. Oracle source is part of `Params`. Version bump archives old version atomically to `ParameterArchive`. Live deals read from archive. Only `EMERGENCY.forceOracleOverride` can alter a live deal's oracle binding.)

---

## 16. Oracle architecture

(Unchanged from v1. Composite adapters with CAPO caps. Heartbeat enforced. Stale = block new deals, allow repay/top-up at last sane price, require attestation for liquidation. Circuit breaker on per-feed and global tiers.)

---

## 17. Compliance hooks

(Unchanged from v1. Pre-hook `staticcall` view + 50k gas cap. Post-hook best-effort + 30k gas cap + try/catch. Typed reason codes. Default fallback is `DefaultPassHook`.)

---

## 18. Caps and limits

(Unchanged from v1. Nine cap dimensions enforced at `openAndActivate`. Per-liquidator-daily cap enforced at `LiquidationHandler`. Cap accounting locations per [§18 of v1](Claude-architechture-1.md#18-caps-and-limits).)

---

## 19. Pause hierarchy

```mermaid
flowchart TB
    classDef level1 fill:#7f1d1d,stroke:#dc2626,color:#fff,stroke-width:2px
    classDef level2 fill:#ffe4e6,stroke:#dc2626,color:#111
    classDef level3 fill:#fff4e6,stroke:#f59e0b
    classDef level4 fill:#fffbf0,stroke:#fbbf24
    classDef level5 fill:#f0faf3,stroke:#22c55e

    Sealed["LEVEL 0 — Emergency Sealed Mode<br/>EMERGENCY 2-of-2<br/><br/>Blocks: EVERYTHING (incl. rescue actions)<br/>Use: catastrophic incident,<br/>before recovery ceremony"]

    Global["LEVEL 1 — Global Halt<br/>EMERGENCY 2-of-2<br/><br/>Blocks: most state changes<br/>Allows: repay, top-up,<br/>claimSurplus, claimUnreleasedCollateral"]

    Token["LEVEL 2 — Token / Issuer Pause<br/>GUARDIAN<br/><br/>Blocks: new deals using this token/issuer<br/>Existing deals: settle if transfers succeed"]

    Pair["LEVEL 3 — Pair Pause<br/>GUARDIAN<br/><br/>Blocks: new deals on this pair<br/>Existing deals: unaffected"]

    Deal["LEVEL 4 — Deal Pause<br/>GUARDIAN (with reason hash)<br/><br/>Locks: clock, most actions<br/>Allows: top-up, repay,<br/>claimSurplus, claimUnreleasedCollateral"]

    Sealed --> Global
    Global --> Token
    Token --> Pair
    Pair --> Deal

    class Sealed level1
    class Global level2
    class Token level3
    class Pair level4
    class Deal level5
```

### 19.1 Pause behaviour summary

| Action | Sealed | Global halt | Token/Issuer pause | Pair pause | Deal pause |
|---|:---:|:---:|:---:|:---:|:---:|
| `openAndActivate` | blocked | blocked | blocked* | blocked* | n/a |
| `topUpCollateral` | **blocked** | allowed | blocked† | allowed | allowed |
| `repay` | **blocked** | allowed | blocked† | allowed | allowed |
| `claimUnreleasedCollateral` | **blocked** | allowed | allowed | allowed | allowed |
| `claimSurplus` (where applicable) | **blocked** | allowed | allowed | allowed | allowed |
| `warn` / liquidation | blocked | blocked | blocked | blocked | blocked |
| `pauseDeal` | n/a | n/a | n/a | n/a | already paused |
| `unpauseDeal` | blocked | blocked | blocked | blocked | allowed (+TL) |

\* if any token in the deal is paused, or its issuer is `Paused`.
† only if the specific token's pause prevents the transfer.

### 19.2 Why `emergencySealedMode` exists

It's the lever for the worst case: discovered exploit being actively used. The protocol freezes completely; even borrower-favourable rescues are paused while a recovery ceremony is prepared. The expectation is that this mode is exercised at most once per protocol lifetime, if ever, but its existence prevents ad-hoc "should we add more pause" debates during an incident.

### 19.3 Pause-clock economics

Unchanged from v1:

```
state.pauseStartedAt = block.timestamp    // on pause
state.totalPausedTime += elapsed          // on unpause

effectiveElapsed     = (now - lastTouchTs) - currentPauseDuration
accruedInterest      = principal × rateBps × effectiveElapsed / (365 days × 10000)
effectiveMaturityTs  = terms.maturityTs + state.totalPausedTime
```

---

## 20. Upgradeability and recovery

### 20.1 Per-contract policy

(Same diagram as v1; reproduced here.)

```mermaid
flowchart LR
    classDef immut fill:#ffe4e6,stroke:#dc2626,stroke-width:2px
    classDef uups fill:#dbeafe,stroke:#2563eb

    DR["DealRegistry<br/>IMMUTABLE"]
    EV["EscrowVault<br/>IMMUTABLE"]
    PA["ParameterArchive<br/>IMMUTABLE"]
    DPH["DefaultPassHook<br/>IMMUTABLE"]
    PL["PortfolioLens<br/>IMMUTABLE (redeploy)"]

    RM["RoleManager<br/>UUPS"]
    KYB["KYBGateway<br/>UUPS"]
    IR["IssuerRegistry<br/>UUPS"]
    CR["ComplianceRegistry<br/>UUPS"]
    CollR["CollateralRegistry<br/>UUPS"]
    LE["LendingEngine<br/>UUPS + timelock"]
    LH["LiquidationHandler<br/>UUPS + timelock"]
    SR["SettlementRouter<br/>UUPS"]

    class DR,EV,PA,DPH,PL immut
    class RM,KYB,IR,CR,CollR,LE,LH,SR uups
```

### 20.2 Storage discipline

Every UUPS contract uses ERC-7201 namespaced storage. The storage slot constant is included in CI checks; any change between releases is a build failure that must be explicitly approved.

### 20.3 Recovery scenarios

(Unchanged from v1. Key invariant: `DealRegistry`, `EscrowVault`, `ParameterArchive` immutability means engine bugs do not destroy funds or terms; recovery is a proxy upgrade with storage-layout verification.)

---

## 21. Reentrancy posture and gas budgets

### 21.1 Reentrancy posture

```mermaid
flowchart LR
    classDef guarded fill:#d1f2db,stroke:#15803d
    classDef external fill:#fff4e6,stroke:#f59e0b

    LE["LendingEngine<br/>ReentrancyGuard on every entry"]
    EV["EscrowVault<br/>ReentrancyGuard;<br/>onlyEngine modifier"]
    LH["LiquidationHandler<br/>ReentrancyGuard"]

    Hook["Compliance hook<br/>(external)<br/>preTransfer: STATICCALL<br/>postTransfer: try/catch + gas cap"]

    Token["ERC-20 token<br/>(external)<br/>SafeERC20 + balance-delta checks"]

    LE -->|"calls"| Hook
    LE -->|"calls"| Token
    LE -->|"calls"| EV
    EV -->|"calls"| Token
    LH -->|"calls"| LE
    LH -->|"calls"| Token

    class LE,EV,LH guarded
    class Hook,Token external
```

Rules:

1. Every state-changing external entry point on `LendingEngine` and `LiquidationHandler` is `nonReentrant`.
2. `EscrowVault` is `nonReentrant` and gated by `onlyEngine`.
3. Pre-hooks are `staticcall` — by construction cannot reenter.
4. Post-hooks are `try/catch` with a 30k gas cap — limited reentrancy attack surface.
5. Token transfers happen *after* state updates within each entry point (checks-effects-interactions).
6. The protocol bans rebasing tokens at the `IssuerRegistry` admission stage; this removes an entire class of reentrancy / accounting confusion.
7. SafeERC20 with explicit balance-delta verification handles non-standard ERC-20s (fee-on-transfer, USDT-style return-vs-revert quirks).

### 21.2 Gas budgets

| Entry point | Target gas | Notes |
|---|---|---|
| `openAndActivate` | ≤ 250,000 | Two pulls + one release + three hook calls + state writes |
| `repay` (full, normal collateral release) | ≤ 150,000 | Pull supply + release collateral |
| `repay` (full, blocked release → `Repaid_PendingCollateralRelease`) | ≤ 120,000 | Pull supply only |
| `topUpCollateral` | ≤ 100,000 | Pull collateral + HF recheck |
| `claimUnreleasedCollateral` | ≤ 100,000 | Single release |
| `warn` | ≤ 80,000 | State write + event |
| `partialLiquidate` | ≤ 200,000 | Compute + release collateral |
| `fullLiquidate` | ≤ 250,000 | Compute + release + surplus + state |
| `openAndActivateBatch` (5 deals) | ≤ 1,000,000 | Bounded by block gas in practice |

Gas snapshots are part of CI; deviations > 10% require explicit approval.

---

## 22. Risk allocation

The protocol assigns each risk class to the actor best positioned to manage it. This table is the canonical risk-allocation record and supersedes the v0.7 brief's "we have no risks" wording.

| Risk class | Primary owner | Contract support | Off-chain support |
|---|---|---|---|
| Borrower credit / default | AMINA + collateral economics | Collateral, LTV, three-phase liquidation, AMINA-only liquidator role | AMINA underwriting under FINMA banking licence |
| Custody insolvency | Custodian | `IssuerStatus` lifecycle, per-issuer caps, legal attestation hash | AMINA custody runbook; counsel-led recovery |
| Liquidation execution | AMINA | Privileged `LIQUIDATOR` role, step counter, signed price attestations | AMINA OPS bots, monitoring, escalation |
| Identity / KYB | AMINA | `KYBGateway`, jurisdictionCode, compliance hooks | AMINA KYB review under FINMA banking licence |
| Smart-contract bug | P2P | Audits (2 in parallel), immutable vault / registry / archive, halt + upgrade ceremony, ERC-7201 storage discipline | P2P engineering on-call, Immunefi bounty |
| Off-chain matching bug | P2P + AMINA | Three signatures, `ALLOCATOR` rate limit, cap pre-checks, legal hash | P2P matching engine tests, AMINA review |
| Oracle failure | AMINA + P2P | Snapshotted oracle sources, heartbeat checks, signed attestations, `forceOracleOverride` | AMINA risk desk, Chainlink ops, redundant adapters |
| Token transfer restriction | Custodian + P2P integration | Hook reason codes, `Repaid_PendingCollateralRelease` recovery state | Custodian allowlist coordination |
| Key compromise | Role holder | Multisigs for sensitive roles, rate limits on hot wallets, no single role drains | Multisig signer rotation, ceremony processes |
| Regulatory classification | AMINA + counsel | AMINA broker signature, KYB provenance | AMINA legal, FINMA / MiCA dialogue |
| Reputational | Both | Loud events, transparent state, public bug bounty | Joint incident response |

The architecture's job is to make this allocation legible. Each row has both *contract-side* and *off-chain-side* enforcement, and the contract side never tries to do what only the off-chain side can.

---

## 23. Operational monitoring and alerts

### 23.1 Required monitors (from day 1)

| Monitor | Cadence | Source |
|---|---|---|
| `SettlementRouter` event sequence-number gap detection | Real-time | Indexer |
| Per-deal health factor | 5 min (1 min for volatile collateral) | `LendingEngine.getHealthFactor` view |
| Oracle freshness (per feed) | 1 min | `OracleRouter` view (within `CollateralRegistry`) |
| Oracle deviation (per feed) | 5 min | Cross-check vs external reference |
| Cap utilisation (all 9 dimensions) | 5 min | `LendingEngine` views |
| `EscrowVault` per-deal vs token-balance reconciliation | 1 h | `EscrowVault.syncCheck` |
| Hook failure events by `(token, action, reason)` | Real-time | `HookFailure` events |
| Role-change and upgrade events | Real-time | `RoleGranted`, `RoleRevoked`, `Upgraded` events |
| Liquidation step counter divergence (bot vs chain) | Real-time | `LiqState` view |
| Deals approaching maturity (7d / 1d / 1h) | Hourly | `DealRegistry` view |
| Paused deals and paused-time accumulation | Hourly | `LendingEngine` views |
| `Repaid_PendingCollateralRelease` queue depth | Hourly | `LendingEngine` views |
| KYB expiry approaching (30d / 7d) | Daily | `KYBGateway` views |

### 23.2 Alert severities

| Alert | Severity | Owner | SLA |
|---|---|---|---|
| `EscrowVault` reconciliation mismatch | **critical** | P2P engineering + AMINA OPS | 15 min response |
| Oracle circuit breaker tripped | **high** | AMINA risk + `ORACLE_ADMIN` | 30 min |
| Liquidation bot offline > 5 min | **high** | AMINA OPS | 15 min |
| Hook failure spike (> 10/min) | **high** | P2P + custodian | 30 min |
| Token / issuer paused unexpectedly | **high** | AMINA risk | 1 h |
| Cap utilisation > 80% on any dimension | **medium** | AMINA risk | 4 h |
| KYB expiry approaching | **medium** | AMINA compliance | 24 h |
| Maturity within 7 days, no repay activity | **medium** | borrower / lender / AMINA | 24 h |
| Sequence-number gap | **medium** | P2P engineering | 4 h |
| `Repaid_PendingCollateralRelease` deal > 24 h old | **medium** | AMINA OPS | 24 h |
| Storage-layout snapshot mismatch in CI | **critical (pre-merge)** | P2P engineering | block merge |

### 23.3 Dashboard surfaces

Three dashboards are required from launch:

1. **AMINA risk dashboard**: per-deal HF, oracle status, cap utilisation, paused deals, defaults.
2. **AMINA OPS dashboard**: bot status, reconciliation status, settlement queue, hook failures.
3. **Counterparty dashboard**: each counterparty's own positions (lender or borrower view), maturity calendar, settlement status.

---

## 24. Deployment order

```mermaid
flowchart TD
    D0["1. Deploy RoleManager (OZ AccessManager)"]
    D1["2. Deploy DefaultPassHook (immutable)"]
    D2["3. Deploy KYBGateway proxy"]
    D3["4. Deploy IssuerRegistry proxy"]
    D4["5. Deploy ComplianceRegistry proxy<br/>(bind DefaultPassHook as fallback)"]
    D5["6. Deploy ParameterArchive (immutable)"]
    D6["7. Deploy CollateralRegistry proxy<br/>(bind ParameterArchive address)"]
    D7["8. Deploy DealRegistry (immutable)<br/>EIP-712 domain pinned"]
    D8["9. Deploy EscrowVault (immutable)<br/>engine address bound via one-time setter"]
    D9["10. Deploy LendingEngine implementation"]
    D10["11. Deploy LendingEngine proxy<br/>initialise with all registry + vault addresses"]
    D11["12. Bind LendingEngine to EscrowVault (one-time)"]
    D12["13. Deploy LiquidationHandler proxy<br/>bind to engine"]
    D13["14. Deploy SettlementRouter proxy"]
    D14["15. Deploy PortfolioLens (immutable)"]
    D15["16. Grant production roles to multisigs<br/>revoke deployer privileges"]
    D16["17. Register first issuer + first token"]
    D17["18. Register first pair + oracle sources + hooks"]
    D18["19. Set initial caps (conservative)"]
    D19["20. Run smoke test with mock tokens"]
    D20["21. Run mainnet-fork lifecycle reconciliation"]

    D0 --> D1 --> D2 --> D3 --> D4 --> D5 --> D6 --> D7 --> D8 --> D9 --> D10 --> D11 --> D12 --> D13 --> D14 --> D15 --> D16 --> D17 --> D18 --> D19 --> D20
```

### 24.1 Deployment ceremony

The deployment is performed by a designated ceremony account with `DEPLOYER` privileges revoked at step 15. All addresses are computed via CREATE2 with vanity prefixes for the immutable contracts (so the addresses are deterministic and pre-publishable).

After step 20, the deployment is frozen except via the documented upgrade path. The smoke-test bundle and the mainnet-fork reconciliation demo are the gating evidence for the formal launch announcement.

### 24.2 One-time `EscrowVault` binding

`EscrowVault` is immutable, so it cannot have a constructor parameter referencing a yet-to-be-deployed `LendingEngine` proxy. The pattern:

```solidity
contract EscrowVault {
    address public engine;
    bool private engineBound;

    function bindEngine(address _engine) external {
        require(!engineBound, "ALREADY_BOUND");
        require(_engine != address(0), "ZERO");
        require(msg.sender == DEPLOYER, "ONLY_DEPLOYER");
        engine = _engine;
        engineBound = true;
    }
}
```

Step 11 is the one and only call to `bindEngine`. After step 15, `DEPLOYER` no longer exists, so the binding is permanent.

---

## 25. Invariants

The canonical 21-invariant list. These are the test targets for Phase 6 (internal hardening) and the formal-verification candidates for Phase 7 (external audit).

### 25.1 Per-deal invariants

1. **Terms write-once**: `DealRegistry.terms[dealId]` is never modified after `record`.
2. **Terminal finality**: deals in `Repaid`, `Liquidated`, or `Defaulted` cannot transition further. (`Repaid_PendingCollateralRelease` is non-terminal.)
3. **Recovery transition**: `Repaid_PendingCollateralRelease` can only transition to `Repaid`.
4. **State-machine DAG**: every state transition matches the documented DAG in [§9](#9-deal-state-machine).
5. **Atomic activation**: a deal cannot become `Active` unless both lender and borrower transfers succeeded in the same transaction.
6. **3-signature requirement**: `openAndActivate` is impossible without valid lender, borrower, and AMINA signatures over the same `termsHash`.
7. **No sig replay**: a signature cannot be replayed across deal IDs, chains, or contract deployments.
8. **Param snapshot stability**: live deals always read params from `ParameterArchive[pair][versionKey]`, which is immutable.
9. **Oracle snapshot stability**: live deals always read the oracle binding from the same snapshot, unless `EMERGENCY.forceOracleOverride` was called (in which case a loud event was emitted).
10. **Liquidation step monotonicity**: a partial or full liquidation call with `expectedStep < liqState.step` reverts.
11. **Bounded liquidation transfer**: `fullLiquidate` cannot transfer more collateral to AMINA than `(debt + explicit bonus + explicit fee) / collateralPrice`.
12. **Surplus to borrower**: any surplus collateral after liquidation is returned to the borrower and cannot be seized by governance.
13. **No interest during pause**: interest accrues for `elapsedTime − totalPausedTime`, never for paused intervals.
14. **Pause restrictiveness**: during a deal pause, only `topUpCollateral`, `repay`, `claimSurplus`, and `claimUnreleasedCollateral` are callable.

### 25.2 Global invariants

15. **Vault reconciliation**: `sum over deals of EscrowVault.balanceOf[d][token] == IERC20(token).balanceOf(EscrowVault)` at the end of every external call.
16. **Token pause carve-out**: token or issuer pause blocks new deals but does not trap safe repay / top-up paths for existing deals (subject to compliance hooks).
17. **Borrower-rescue carve-out**: global halt cannot prevent borrower-favourable rescue actions unless `emergencySealedMode` is active.
18. **Hook atomicity**: a `preTransfer` hook returning `ok=false` reverts the entire transaction with no partial state changes. A `postTransfer` hook reverting does not roll back state but emits `HookFailure`.
19. **Decimal coherence**: oracle decimals are normalised identically in HF, liquidation, and surplus math; differential tests against a Python reference produce wei-identical results across 10k random inputs.
20. **Cap enforcement**: `openAndActivate` reverts if any of the 9 cap dimensions would be exceeded.
21. **Privilege separation**: no role can both (a) modify risk parameters in `CollateralRegistry` and (b) cause funds to leave `EscrowVault`. (Enforced by role separation in `RoleManager` and the `onlyEngine` modifier on `EscrowVault`.)

---

## 26. Failure modes

(Unchanged structurally from v1; reorganised to align with §22 risk allocation.)

| ID | Failure | Architectural absorber |
|---|---|---|
| F1 | Bug in `LendingEngine` | EMERGENCY halt + UUPS upgrade; `EscrowVault` and `DealRegistry` immutable |
| F2 | EIP-712 sig replay attempt | Per-counterparty nonce + domain-bound hash + dealId in domain |
| F3 | Compliance hook misbehaves | View-only preHook + staticcall + 50k gas cap + try/catch on postHook |
| F4 | Oracle stall | `openAndActivate` reverts; liquidations require AMINA-signed dual-price attestation |
| F5 | Oracle manipulation | CAPO adapter caps + circuit breaker + manual override |
| F6 | Custody mint fails after `AdvanceIntent` | Borrower already holds the token in-wallet — the off-chain event is for *real-asset* redemption, not for token mint |
| F7 | AMINA fails to liquidate | Monitoring + escalation; ultimately EMERGENCY halt; lender's loss is AMINA's contractual obligation |
| F8 | KYB schema needs to change | UUPS `KYBGateway` + ERC-7201 storage |
| F9 | Custodian insolvency | `IssuerRegistry.setIssuerStatus(Paused/Deactivated)`; existing deals continue settling; counsel-led recovery off-chain |
| F10 | Privileged role key compromise | Multisigs for sensitive roles; rate-limited bot wallets; GOVERNOR + EMERGENCY can revoke |
| F11 | Storage layout collision on upgrade | ERC-7201 namespaced storage + CI snapshot diff |
| F12 | Token issuer freezes `EscrowVault` mid-deal | `Repaid_PendingCollateralRelease` state + `claimUnreleasedCollateral` recovery |
| F13 | Counterparty reneges between sign and submit | Atomic `openAndActivate` — partial settlement impossible; matching engine blacklists repeat offenders |
| F14 | Regulatory reclassification | Matching under AMINA licence; P2P is tech provider; AMINA's jurisdiction portfolio (FINMA + MiCA + SFC + FSRA) |
| F15 | Stablecoin depeg during liquidation | Dual-price attestation forces AMINA to commit to both legs' prices |
| F16 | Discovered exploit being actively used | `emergencySealedMode` freezes everything until recovery |

---

## 27. Audit surface

(Same risk-tier organisation as v1, expanded with v2 additions.)

### 27.1 High-risk areas

- `LendingEngine.openAndActivate`: 3-sig verification, nonce handling, atomic settlement order (records before transfers, hooks before transfers), cap enforcement, compliance-hook invocation order.
- `LiquidationHandler` surplus computation: rounding direction, decimal normalisation, dual-price signed-attestation verification, step counter.
- `EscrowVault` per-deal ledger: reconciliation invariant under reentrancy attempts; `onlyEngine` enforcement.
- EIP-712 domain construction: chain ID binding, contract address binding, dealId binding in attestations.

### 27.2 Medium-risk areas

- `CollateralRegistry` version bump atomicity: archive write must complete before version increment.
- `ComplianceRegistry` hook gas accounting: staticcall gas forwarding, try/catch revert handling.
- Storage layout discipline across all UUPS contracts: ERC-7201 namespacing, CI diff validation.
- `KYBGateway` expiry interactions with long-running deals (self-rescue still allowed when suspended).
- Pause hierarchy: ensure no escalated tier accidentally permits a lower-tier action.

### 27.3 Lower-risk but worth checking

- Event schema completeness for off-chain reconciliation.
- `PortfolioLens` arithmetic for aggregated views.
- Role grant / revoke semantics during a recovery ceremony.
- `IssuerStatus.Deactivated` cleanup paths.

### 27.4 Formal-verification candidates

Within budget, target Certora or Halmos rules on:

1. **HF monotonicity under `_accrue`**.
2. **Repay-implies-closed**: `repay(d, x)` with `x >= outstanding` implies `state ∈ {Repaid, Repaid_PendingCollateralRelease}`.
3. **Surplus-to-borrower**: `fullLiquidate` post-condition.
4. **No replay**: signatures unique per `(dealId, party)`.
5. **Vault reconciliation**.
6. **Pause-time excluded**: interest depends only on `elapsedTime - totalPausedTime`.
7. **Privilege separation**: no execution path lets a single role both write risk params and remove funds from vault.

---

## 28. v2 extension paths

Explicitly out of v1 but deliberately not foreclosed by v1 design.

| Extension | v1 preparation | v2 shape |
|---|---|---|
| ERC-7540 lender-side wrapper | Engine exposes view subset; events shaped for async settlement | Async vault aggregating many lender-side deals into one share token; ERC-4626 / 7540 compatible |
| Mellow-style queue wrapper | Clean deal lifecycle + `PortfolioLens` aggregation | Queue-based institutional distribution vault with custom curator workflows |
| Aave v4 Spoke integration | Immutable deal positions, ERC-7540 views | Specialised Spoke accepting deal notes or wrapper shares as collateral |
| Morpho MetaMorpho integration | Deal isolation + oracle clarity | Curated vault that allocates to P2PxAmina lender positions |
| AMINA first-loss bond | Explicit no-bond v1 decision | Separate `BondVault` with real economics; deliberate product redesign |
| Multi-collateral deals | Single-collateral v1 keeps interfaces clean | Portfolio-margin extension with new risk engine; likely also new HF formula |
| ZK / private registry | `legalTermsHash` and `dealId` abstraction | Hidden-party or commitment-based deal registry; engine interface unchanged |
| Cross-chain deployment | No assumption of chain-specific settlement except Ethereum v1 | Router + adapters for Base / Arbitrum / institutional chains |
| `DualUse` tokens as same-deal supply + collateral | Banned in v1 (`require(supply != collateral)`) | Self-collateralised structured products with explicit risk model |
| Permissionless rate discovery | No on-chain rate negotiation in v1 | Auction module that produces signed rate quotes for `openAndActivate` |

---

## 29. Appendix A — Glossary

(Same as v1; supplemented with the v2 additions below.)

| New term | Meaning |
|---|---|
| `IssuerStatus` | Lifecycle of a custodian's overall acceptance: `Active`, `Paused`, `Deactivated`. |
| `TokenKind.DualUse` | A token that may serve as either supply or collateral leg, but not both within the same deal. |
| `emergencySealedMode` | The most extreme pause tier; blocks every state-changing call including borrower-favourable rescues. |
| `legalAttestationHash` | Hash of the master agreement between AMINA and a custodian, anchored on the issuer record. |
| `jurisdictionCode` | Bytes32 country / regulator tag on each KYB record. |
| `sequenceNumber` | Monotonic counter on `SettlementRouter` events for deterministic off-chain ordering. |
| `settlementRef` | Unique reference per settlement event for custodian acknowledgement. |

(Other terms unchanged from v1.)

---

## 30. Appendix B — EIP-712 typed data

### 30.1 Domain

```
{
  name: "P2PxAmina Lending",
  version: "1",
  chainId: <block.chainid>,
  verifyingContract: <DealRegistry address>
}
```

### 30.2 `DealTerms` type

```solidity
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
```

### 30.3 `AMINASignedPriceAttestation` type (v2: dual price)

```solidity
struct AMINASignedPriceAttestation {
    bytes32 dealId;
    bytes32 sourceId;
    uint256 observedCollateralPrice;
    uint256 observedSupplyPrice;
    uint64 observationTs;
    bytes32 reasonCode;
}
```

### 30.4 Signature semantics

- **Lender's signature** = commitment to lend `principal` of `supplyToken` at `rateBps` until `maturityTs`.
- **Borrower's signature** = commitment to post `collateralAmount` of `collateralToken`, repay `principal + interest` by `maturityTs`, accept the LTV / liquidation schedule at `paramVersion`.
- **AMINA's signature** = brokerage attestation under FINMA Securities Dealer licence that this trade was matched under AMINA's brokerage.

All three are over the same `termsHash`. Any disagreement = no deal.

---

## 31. Appendix C — Event schema reference

```
RoleManager:
  RoleGranted(uint64 role, address account, address sender)
  RoleRevoked(uint64 role, address account, address sender)

KYBGateway:
  KybStatusUpdated(address indexed wallet, KybStatus status, uint64 expiryTs, bytes32 docsHash, bytes32 jurisdictionCode)

IssuerRegistry:
  IssuerAdded(address indexed issuer, address custodian, bytes32 legalAttestationHash, uint256 globalCapUsd)
  IssuerStatusChanged(address indexed issuer, IssuerStatus oldStatus, IssuerStatus newStatus)
  TokenAdded(address indexed token, address indexed issuer, TokenKind kind, uint128 cap, bytes32 redemptionAttestationHash)
  TokenPaused(address indexed token)
  TokenUnpaused(address indexed token)
  CapUpdated(address indexed token, uint128 oldCap, uint128 newCap)

ComplianceRegistry:
  HookRegistered(address indexed token, bytes32 indexed action, address hook)
  HookFailure(bytes32 indexed dealId, address indexed token, bytes32 reasonCode)

CollateralRegistry:
  PairAdded(bytes32 indexed pairKey, uint32 version, Params params)
  PairUpdated(bytes32 indexed pairKey, uint32 oldVersion, uint32 newVersion)
  PairPaused(bytes32 indexed pairKey)

DealRegistry:
  DealRecorded(bytes32 indexed dealId, address indexed lender, address indexed borrower, bytes32 termsHash, uint32 paramVersion)

LendingEngine:
  DealActivated(bytes32 indexed dealId, uint64 startTs, uint64 maturityTs)
  CollateralToppedUp(bytes32 indexed dealId, uint256 amount)
  Repaid(bytes32 indexed dealId, uint256 amount, bool finalRepay)
  DealPaused(bytes32 indexed dealId, bytes32 reason)
  DealUnpaused(bytes32 indexed dealId)
  GlobalHalted(address indexed by, bytes32 reason)
  EmergencySealedModeEntered(address indexed by, bytes32 reason)
  EmergencySealedModeExited(address indexed by)
  OracleOverridden(bytes32 indexed dealId, address newCollOracle, address newSuppOracle, bytes32 reason)

LiquidationHandler:
  WarningIssued(bytes32 indexed dealId, uint64 graceDeadline)
  PartialLiquidated(bytes32 indexed dealId, uint8 step, uint256 collateralSeized, uint256 debtCovered, bytes32 settlementRef)
  FullLiquidated(bytes32 indexed dealId, uint256 collateralSeized, uint256 debtCovered, bytes32 settlementRef)
  Defaulted(bytes32 indexed dealId, uint256 shortfallUsd, bytes32 detailsHash)
  StaleOraclePriceUsed(bytes32 indexed dealId, bytes32 sourceId, uint256 collateralPrice, uint256 supplyPrice, uint64 ts)

SettlementRouter (all events carry indexed sequenceNumber):
  AdvanceIntent, RedemptionIntent, CollateralTopUpIntent,
  LiquidationIntent, SurplusReturned, Defaulted,
  UnreleasedCollateral, RepaymentBlocked
```

---

## 32. Appendix D — Open questions

Five questions remain genuinely open. The other twelve from `Claude-thoughts-1.md` §6 are resolved in this document.

| # | Question | Default position | Owner |
|---|---|---|---|
| Q2 | Is liquidation surplus legally borrower property in all supported jurisdictions? | yes | AMINA legal |
| Q6 | Exact legal status of AMINA's third EIP-712 signature? | brokerage attestation under FINMA licence | AMINA legal / FINMA counsel |
| Q7 | Can a lender or borrower use a fresh custody sub-account per deal by default? | yes; custodians manage allocation | Custodians + AMINA OPS |
| Q10 | Minimum data required in `SettlementRouter` events? | see [§13.1](#131-event-schema-v2) | AMINA integration team |
| Q16 | DeFi liquidity channel: ERC-7540 wrapper, Mellow-style queue wrapper, or both? | defer to v2 | Product / partnerships |

---

End of canonical architecture v0.4.

— Claude (Opus 4.7), 2026-05-26
