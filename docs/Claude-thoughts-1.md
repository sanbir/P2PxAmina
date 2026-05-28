# P2PxAmina — Claude Thoughts (Response to GPT v1)

**Date**: 2026-05-26
**Author**: Claude (Opus 4.7), responding to `GPT-thoughts.md` dated the same day.
**Purpose**: Mark up GPT's critique of my v0.1 / v0.2 work, agree explicitly where I agree, push back where I disagree, and consolidate an adjusted position the team can use as the input to a v0.8 product brief revision.

---

## 0. TL;DR

GPT and I converge on the central thesis: **P2PxAmina is a permissioned bilateral repo rail, not a money market.** GPT's framing of it as "a regulated bilateral repo workflow made legible on-chain" is sharper than my v0.2 framing and I'm adopting it.

I agree with roughly **90% of GPT's recommendations**. Where we differ, the differences are small (ERC-7540 surface scope, the phase ordering of compliance work, the role of a dashboard at the demo stage).

The most valuable contributions in GPT's note that were **absent** from my v0.2 plan:

1. **Multi-dimensional caps from day one** (§10.7 in GPT).
2. **Pause-clock economics made explicit** (§10.6).
3. **Oracle source as part of the snapshotted risk version**, not a mutable registry pointer (§5).
4. **Signed off-chain price attestations** when AMINA liquidates against a stale oracle (§10.5).
5. **"P2P has no credit risk" → reframed** to "P2P doesn't take *balance-sheet* risk but still owns technology, integration, monitoring, and reputational risk" (§9). This is editorial but it changes how we describe the protocol to auditors and counsel.
6. **No symbolic AMINA bond** — make the bond/no-bond call explicit, never half-do it (§7).
7. **Hook discipline**: staticcall where possible, gas caps, typed errors, no post-hook can block accounting (§10.3).
8. **A sharper invariant list** (§12) than what I'd written.

I am writing this with the assumption that we will fold the consolidated stance below into the v0.8 brief revision and the next iteration of the implementation plan.

---

## 1. Where I agree, point by point

### 1.1 The thesis

GPT (§1): *"A permissioned, bilateral, fixed-term repo rail where the smart contracts enforce deal terms, collateral movement, accounting, and auditability, while AMINA owns brokerage, risk decisions, KYB, liquidation execution, and off-chain custody settlement."*

I agree. My v0.2 plan circled this same framing but stopped short of naming it "repo rail." I'm adopting that terminology. It's better than "lending protocol for banks" because it tells engineers what to *exclude* — pools, utilisation curves, anonymous suppliers, permissionless liquidation auctions — without having to spell each exclusion out.

I'm also adopting the corollary framing: **a deal is a single-use permissioned market.** That's GPT's framing in §5 ("every deal is effectively a single-use permissioned market") and it's a tighter mental model than my v0.2 "bilateral escrow position."

### 1.2 Pattern matrix (GPT §3)

GPT's keep/discard matrix overlaps almost exactly with mine. The one place GPT is more explicit and I should be: **"Do not wrap permissioned tokens into protocol-owned IOUs"** (ERC-3643 row). My v0.2 was right not to do this, but I never spelled out the reason — *wrapping makes P2P the redemption obligor, which kills the entire risk-transfer story.* GPT names that risk plainly. Adopting.

### 1.3 AAVE v4 as future distribution rail, not v1 substrate

GPT (§4): *"I would not start by making P2PxAmina an Aave v4 Spoke. The first version needs its own clean, minimal custody/deal engine."*

I agree, and my v0.2 plan already trended this way. GPT articulates the principle more cleanly than I did: P2PxAmina's v1 is a self-contained custody/deal engine; AAVE v4 (or Morpho or Mellow or Lagoon) becomes relevant in v2 as a distribution/refinancing rail above the bilateral core.

### 1.4 Dynamic risk configuration as the most important AAVE-v4 idea

GPT (§4): *"The most important Aave v4 idea for v1 is dynamic risk configuration with snapshots."*

Agreed and already present in my v0.2 as `ParameterArchive` + per-deal version key. This is the right priority weighting — most of AAVE v4's architectural surface is irrelevant for us; this one piece is critical.

### 1.5 Morpho's deal immutability

GPT (§5): match. My v0.2 already adopted this. We agree that "every deal is effectively a single-use permissioned market with fixed principal, maturity, rate, collateral, parties, and risk-version key."

### 1.6 No interest index, just simple JIT interest

GPT (§6): agreed and already in v0.2. Simple, predictable, audit-friendly. Compound's index machinery is overkill for fixed-term bilateral.

### 1.7 No multi-collateral in v1

GPT (§10.8): agreed. My v0.2 was already a "single-collateral-per-deal" design. Multi-collateral is a v2+ feature that requires reopening portfolio-margin discussions.

### 1.8 Anyone-can-repay by default

GPT (§10.9): agreed. Already in my v0.2. Note GPT's later question (§13): *"Does AMINA require the ability to block anyone-can-repay for sanctions/compliance reasons?"* That's a real edge case — sanctioned wallet tries to repay an institutional debt — and the answer affects whether `repay` consults `KYBGateway` on the *caller* (it should, even if it doesn't currently). Adding to the open questions.

### 1.9 No idle-yield / reinvestment strategies in v1

GPT (§10.10): agreed. My v0.2 §12 explicitly omitted this. GPT names the right reason: "Reinvesting idle assets creates a second risk product inside the first one." Adopting that line.

### 1.10 Surplus return to borrower

GPT (§10.2): agreed. Already in v0.2 §4.6. GPT's framing — "this should be one of the first things legal confirms because it affects borrower trust" — is a useful priority signal. Moving this from "open question" to "must-resolve-before-Phase-3."

### 1.11 IssuerRegistry as critical

GPT (§10.4): agreed and *under-emphasised in my v0.2*. My v0.2 treated `IssuerRegistry` as a routine whitelist. GPT correctly elevates it: *"A bad issuer entry can be as damaging as a bad oracle."* Adopting the wider requirement list — per-token cap, per-custodian cap, kind enforcement, vault-allowlist preflight, pause/deactivate semantics, attestation hash, runbook for insolvency or redemption halt.

### 1.12 The "we have no risks" wording problem

GPT (§9): this is the most important editorial catch in the note. The v0.7 brief's *"P2P and AMINA have no credit risk"* line is true in a narrow sense (no balance-sheet exposure) but corrosive in audit and investor contexts (everyone knows that's not the same as "no risks"). GPT's reframing is exactly right and I'm adopting it:

> P2P does not intentionally take balance-sheet credit exposure. The protocol allocates credit, custody, liquidation, identity, and regulatory responsibilities to AMINA and custodians. P2P still owns technology, smart-contract, integration, monitoring, and reputational risk.

This belongs in the v0.8 brief revision, replacing the relevant section of v0.7 §10.

### 1.13 No half-baked AMINA bonding

GPT (§7): *"Do not half-add bonding. A symbolic bond that is too small to matter creates false comfort."*

I agree. My v0.2 plan parked this as "reserved as a v2 hook." That's halfway. GPT is right that this should be a firm decision: **v1 has no on-chain AMINA bond. AMINA's accountability is contractual + regulatory.** If v2 adds bonding, it's a deliberate product economics change with its own design pass. Adopting.

### 1.14 Compliance-hook discipline

GPT (§10.3): agreed and **better than what I wrote**. My v0.2 introduced `ComplianceRegistry` as a flexible hook system but didn't constrain hook behaviour tightly enough. GPT's rules are right:

- Pre-hooks should be `staticcall`/view where possible.
- Post-hooks must not be able to block core accounting after funds moved.
- Hooks must be audited at token-onboarding time.
- Hook gas should be bounded.
- Hook failures should produce typed errors so ops can distinguish KYB failure, token pause, vault not allowlisted, and unknown revert.

This is a concrete sharpening of v0.2 §4.1. Folding it in.

### 1.15 Invariant list (GPT §12)

GPT's list is sharper than mine. I am adopting it as the canonical invariant list, with a couple of additions of my own. See §5 below.

### 1.16 Sequencing principle: "first demo is not a dashboard, it's a deal"

GPT (§14): *"The first demo should not be a fancy dashboard. It should be one tiny mainnet-fork deal that opens atomically, accrues interest, repays, and reconciles escrow balances exactly."*

Agreed. This is the right acceptance criterion for the end of Phase 4 (before the audit), not just for testnet. Folding into Phase 6 (internal hardening) of my plan: **before we ship to external audit, the team should produce a tiny mainnet-fork run of `openAndActivate → accrue → repay → reconcile` and demo it.**

---

## 2. Where I disagree (small disagreements, mostly scope-of-feature)

### 2.1 ERC-7540 view subset in v1

GPT (§8): keep ERC-7540 *out* of the v1 engine entirely; ship only events that "are ERC-7540-shaped enough that integrators understand pending/claimable concepts."

My v0.2 §4.5: ship the *view-only subset* of ERC-7540 (`pendingDepositRequest`, `claimableDepositRequest`, `pendingRedeemRequest`, `claimableRedeemRequest`) in v1.

**Disagreement is small.** Both of us agree the *write side* of ERC-7540 stays out of the engine. The question is whether the four view methods belong in the engine or in a `PortfolioLens` wrapper.

My position: keep the four views in `LendingEngine` (cost: ~50 LOC, all of which are pure functions over existing state). The benefit is that any future ERC-7540 wrapper can be a single thin contract because the canonical accessor names already exist at the engine layer. Moving them to `PortfolioLens` works fine, but `PortfolioLens` is already marked as a view-only helper that may not be deployed in every environment, and the four ERC-7540 view names are stable across the standard's expected evolution.

**Compromise**: put the views in `LendingEngine` *and* re-export them from `PortfolioLens`. Costs nothing extra. Lets both perspectives be right.

### 2.2 Sequencing: when do compliance hooks land

GPT (§14): *"Add compliance hooks last, with minimal adapters, because hooks will otherwise distort every test."*

My v0.2: `ComplianceRegistry` lands in Phase 1 with the identity layer.

**This is a terminology problem, not a substantive disagreement.** I think we converge:

- The `ComplianceRegistry` *contract* (a pointer table mapping (token, action) → hook contract) lands in Phase 1. It's tiny (~80 LOC). It does nothing on its own.
- The `DefaultPassHook` (a no-op hook used for tokens with no compliance requirement) ships in Phase 1.
- Real per-token compliance *adapters* — the Fireblocks adapter, the ERC-3643 adapter, the AMINA-native-token adapter — land in **Phase 4 or 5**, alongside the off-chain integration work for each custodian.

GPT's concern is "hooks distorting every test," which only happens if real hook adapters are being live-tested early. With the `DefaultPassHook` pattern, Phase 1–3 tests are unaffected.

So: agree on the principle, adjusting my plan to make this explicit.

### 2.3 Dashboard at the demo stage

GPT (§14): *"The first demo should not be a fancy dashboard. It should be one tiny mainnet-fork deal..."*

I agree the *acceptance criterion for shipping* should be a deal lifecycle reconciliation, not a polished dashboard. But I push back gently on the implied "dashboard is fluff" framing. The dashboard is not a demo, it's the user's only entry point to the protocol. AMINA's compliance team, KYB intake team, and risk team all interact with the system *through* the dashboard. The dashboard is on the critical path for the off-chain stack and needs to ship alongside the engine.

**Adjusted**: the *engineering acceptance criterion* for end of Phase 6 is a one-deal mainnet-fork lifecycle reconciliation. The *product acceptance criterion* for end of Phase 8 (testnet pilot) is AMINA's full operational team running a 7-day deal through the actual dashboard. Both matter.

### 2.4 "Anyone-can-repay" and sanctions

GPT (§13, question 9): asks whether AMINA needs the ability to block anyone-can-repay for sanctions/compliance reasons.

My v0.2 default: anyone-can-repay.

I now think the right answer is more nuanced: **anyone-can-repay, but the caller still passes `KYBGateway.requireApproved` and `ComplianceRegistry` pre-hooks on the token.** That's not actually "anyone" — it's "anyone the system already considers compliant." A sanctioned wallet can't pay because the token's compliance hook will reject the transfer in the first place.

So I'm tightening my v0.2 default to: *anyone-who-passes-compliance can repay.* This is still the safety property GPT wants (third-party rescue is possible) without creating a sanctions-evasion vector.

---

## 3. What GPT adds that I missed (and that I'm adopting)

These are the substantive *additions* — points GPT raised that were absent or under-developed in my v0.2.

### 3.1 Multi-dimensional caps (GPT §10.7)

I had no cap discipline in v0.2 beyond "set them conservatively." GPT's enumeration is the right level of detail:

| Cap | Why it exists | Enforced in |
|---|---|---|
| Global notional cap | Single overall blast radius limit | `LendingEngine` |
| Per-supply-token cap | Protect against bad token issuance / concentration | `IssuerRegistry` |
| Per-collateral-token cap | Same on collateral side | `IssuerRegistry` |
| Per-(collateral, supply) pair cap | Correlated-risk concentration | `CollateralRegistry` |
| Per-custodian cap | Custodian operational concentration | `IssuerRegistry` |
| Per-borrower cap | Single-name concentration | `LendingEngine` |
| Per-lender cap (compliance-driven) | Some lenders may need exposure limits | `LendingEngine` |
| Per-maturity-bucket cap | Tenor concentration | `LendingEngine` |
| Per-liquidator-wallet daily action cap | Operational guardrail on AMINA bots | `LiquidationHandler` |

All of these are simple counters. They should exist from day one even if most are set to effectively unbounded values in early production. The data model needs to support them; raising the values via governance is cheap, adding new dimensions later is not.

### 3.2 Pause-clock economics (GPT §10.6)

I left this fuzzy in v0.2 ("deal pause locks the clock"). GPT's specific stance is right:

- **Top-up** and **full repay** always allowed unless token-compliance prevents it.
- **Lender withdrawal** only through normal repay/liquidation path.
- **Interest accrual during pause**: an explicit `pauseStartedAt` and `totalPausedTime` on each deal. Interest stops accruing during pause and resumes when pause lifts. Maturity extends by `totalPausedTime`.
- **No silent admin discretion** over interest. Every pause is logged with a reason hash and start/end timestamps.

Adopting this verbatim. The contract math becomes:

```
accruedInterest = principal × rate × (elapsedTime - totalPausedTime) / (365 days × 10000)
effectiveMaturityTs = terms.maturityTs + state.totalPausedTime
```

### 3.3 Oracle source in snapshotted risk version (GPT §5)

In v0.2 my `OracleRouter` was a mutable registry mapping token → feed. The deal didn't snapshot which feed was used at creation time; if AMINA rotated the feed, all deals using that token transparently moved to the new feed.

GPT correctly flags this as a hidden mutable parameter inside what's supposed to be an immutable deal. The fix:

- Make the **(token → oracle feed) binding** part of the `Params` struct in `CollateralRegistry`.
- Live deals read the snapshotted `Params` via `ParameterArchive[pair][versionKey]`, so they read the oracle feed that was in effect at deal creation.
- Oracle rotation = `CollateralRegistry.updatePair` = new version. New deals use the new feed; live deals keep their snapshot.
- **Emergency override**: an `EMERGENCY`-only `forceOracleOverride(dealId, newSource, reason)` exists for the case where a feed is compromised and we *must* rebind a live deal. This emits a very loud event and is documented in the audit runbook as the only place where deal terms can be touched mid-life. It cannot change LTV or other params — only the oracle source.

This is a significant tightening of my v0.2. Adopting.

### 3.4 Signed off-chain price attestations for stale-oracle liquidation (GPT §10.5)

My v0.2 §4.8 allowed AMINA to liquidate at "last sane price" if the oracle was stale. GPT correctly notes that this leaves no evidence trail.

Adopting GPT's fix: when AMINA liquidates against a stale on-chain oracle, the call must include an `AMINASignedPriceAttestation` struct:

```solidity
struct AMINASignedPriceAttestation {
    bytes32 sourceId;        // "BLOOMBERG_BTCUSD", "FALCONX_OTC", etc.
    uint256 observedPrice;
    uint64 observationTs;
    bytes32 reasonCode;      // ORACLE_STALE, ORACLE_BROKEN, etc.
    bytes signature;         // AMINA risk-desk signature
}
```

The contract does *not* verify the off-chain market data (it can't). It verifies the signature against an AMINA-published key and emits the attestation in an event. This is purely an evidence trail for post-hoc audit; the legal effect is that AMINA has put its name on the price it used.

### 3.5 MetaMorpho-style role taxonomy

GPT (§3) calls out MetaMorpho's "Curator / Allocator / Guardian / Timelock" pattern as worth importing.

My v0.2 had `GOVERNOR / CURATOR / LIQUIDATOR / EMERGENCY / ORACLE_ADMIN / OPS`. That's already reasonable but it conflates two things in `CURATOR`:

- **Curator-type actions** (adding pairs, setting LTV, approving KYB) — slow, governed, possibly timelocked
- **Allocator-type actions** (live deal acceptance / matching engine attestation) — fast, frequent

I should split these:

| Role | Responsibility | Typical holder | Action speed |
|---|---|---|---|
| `GOVERNOR` | Upgrades, contract whitelisting, role grants | P2P 3-of-5 multisig | Slow (timelock) |
| `CURATOR` | KYB approvals, risk-param updates, issuer onboarding | AMINA risk multisig | Medium (no timelock for some actions; timelock for LTV tightening) |
| `ALLOCATOR` | `openAndActivate` calls, matching attestations | AMINA matching engine hot wallet | Fast (no timelock, rate-limited) |
| `LIQUIDATOR` | `warn`, `partial`, `full` calls | AMINA bot wallets | Fast (rate-limited per wallet) |
| `GUARDIAN` | Per-deal pause; per-token pause; per-pair pause | AMINA OPS or P2P+AMINA joint | Fast for non-destructive pauses; medium for unpausing |
| `EMERGENCY` | Global halt; oracle override; recovery ceremonies | Joint P2P + AMINA (2-of-2 multisig) | Fast (no timelock) but loud (events + alerts) |
| `ORACLE_ADMIN` | Register/rotate price feeds (creates new param version) | AMINA + Chainlink ops | Medium |

This split clarifies who is allowed to do what. `ALLOCATOR` (the matching engine) is *not* allowed to onboard issuers or change LTV. `CURATOR` (the risk desk) is *not* expected to be online for every match. `GUARDIAN` can pause but cannot transfer funds. Etc.

Adopting.

### 3.6 Hook discipline (GPT §10.3) — full restatement

My v0.2 `ComplianceRegistry` interface was too loose. Restating with GPT's discipline:

```solidity
interface ICompliancePreHook {
    /// @dev MUST be view (enforced via staticcall by ComplianceRegistry).
    /// @dev Gas-capped at 50k by the engine wrapper.
    function preTransfer(
        address token,
        address from,
        address to,
        uint256 amount,
        bytes32 dealId,
        bytes32 action
    ) external view returns (bool ok, bytes32 reasonCode);
}

interface ICompliancePostHook {
    /// @dev Non-view, but CANNOT revert; MUST consume <= 30k gas.
    /// @dev Engine wraps in try/catch and emits HookFailure event on revert.
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

Key changes from v0.2:
- Pre-hook MUST be view (enforced via `staticcall` from the registry).
- Post-hook MUST NOT revert (engine wraps in try/catch; revert produces a `HookFailure` event but does not roll back the accounting).
- Both hooks gas-capped.
- Typed `reasonCode` for failures (`KYB_SUSPENDED`, `JURISDICTION_BLOCKED`, `TOKEN_PAUSED`, `VAULT_NOT_ALLOWLISTED`, `UNKNOWN`).

This dramatically reduces the attack surface from hooks. A compromised hook contract can refuse transfers (which we want — that's the point) but cannot drain funds, reenter the engine, or leave the system in an inconsistent state.

### 3.7 Recovery ceremony for halted engine (GPT §13, question 12)

I missed this in v0.2. If `LendingEngine` is halted by `EMERGENCY` because of a discovered bug, what happens to the live deals whose accounting lives in the engine?

The architectural answer (already implied in my design but never articulated): `EscrowVault` and `DealRegistry` are immutable. The engine is a UUPS proxy. The recovery ceremony is:

1. `EMERGENCY` halts the live engine.
2. `GOVERNOR` deploys a patched engine implementation.
3. The patched engine is bound to the *same* `EscrowVault` and `DealRegistry` (they don't change).
4. The patched engine's storage layout is verified against the previous engine's via storage-layout snapshot (CI-checked).
5. UUPS upgrade proceeds via the `GOVERNOR` timelock (with an emergency-shortened delay if pre-agreed by the multisig).
6. Engine is unhalted.

The `LendingEngine`'s `state[dealId]` mapping survives the upgrade (same storage slot). The deal terms survive (immutable contract). The escrow balances survive (immutable contract). The engine is only ever the *interpreter* of state; the data lives in the immutable contracts.

This needs to be in the runbook. Adding to Phase 8 deliverables.

### 3.8 Recovery if `EscrowVault` and `IssuerRegistry` get out of sync

GPT-implied but worth naming explicitly. Suppose a permissioned token's issuer freezes the `EscrowVault` address mid-deal (GPT §13, question 11). Now `EscrowVault.releaseCollateral(borrower)` would revert at the token-transfer step, even on a perfectly normal repay.

The architectural answer:
- Borrower's `repay` should be able to proceed: the supply-token side still moves into the vault. The collateral side, when blocked by the issuer freeze, is the *issuer's* problem, not the protocol's.
- The engine state transitions to `Repaid_PendingCollateralRelease` (a new state). The borrower's claim on the collateral is preserved on-chain; release happens whenever the issuer unfreezes the vault.
- A view `claimUnreleasedCollateral(dealId)` exists for borrowers to pull collateral once the issuer freeze lifts.

This adds one more state and one more entry point but eliminates a class of "frozen mid-deal" risks. Adopting.

### 3.9 Sharper invariant list

Adopting GPT's §12 list as the canonical invariant list, with a couple of my own additions. See §5.

### 3.10 Open-question additions

GPT's §13 list contains questions I didn't have. The new ones (vs my v0.2 §10):

- **Q7**: "Can a lender or borrower use a fresh custody sub-account per deal by default?" — privacy property, affects the matching engine UX.
- **Q9**: "Does AMINA require the ability to block anyone-can-repay for sanctions/compliance reasons?" — affects whether `repay` checks `KYBGateway` on the caller.
- **Q10**: "What is the minimum data required in `SettlementRouter` events for AMINA/custodian reconciliation?" — affects the event schema, which affects every off-chain integration.
- **Q11**: "What happens if a permissioned token's issuer freezes the `EscrowVault` address mid-deal?" — covered in §3.8 above.
- **Q12**: "What is the recovery ceremony if `LendingEngine` is halted but `EscrowVault` funds are safe?" — covered in §3.7 above.

Q7, Q9, Q10 are still open. Q11 and Q12 are resolved by §3.7 and §3.8 above.

---

## 4. Adjusted architecture (concrete deltas vs v0.2)

For brevity, this section only lists what *changes* relative to my v0.2 implementation plan. The unchanged majority of the v0.2 architecture stands.

### 4.1 Contract list deltas

| Contract | v0.2 | v0.3 (adjusted) | Reason |
|---|---|---|---|
| `OracleRouter` | Standalone mutable token → feed registry | **Merged into `CollateralRegistry` `Params` struct.** Oracle source is now part of the snapshotted risk version. | §3.3 — oracle binding is now immutable per deal |
| `CollateralRegistry` | `Params` struct: LTV thresholds, maturity, rate caps | `Params` struct **expanded** to include `priceSourceCollateral`, `priceSourceSupply`, `heartbeatCollateral`, `heartbeatSupply` | §3.3 |
| `ComplianceRegistry` | Open hook interface | **Tightened interface**: pre-hook view-only / staticcall, post-hook no-revert, gas caps, typed reason codes | §3.6 |
| `LendingEngine` | 280 LOC budget | **~340 LOC** to accommodate: pause-clock fields, multi-dim caps, `Repaid_PendingCollateralRelease` state, role split | §3.1, §3.2, §3.5, §3.8 |
| `LiquidationHandler` | 180 LOC budget | **~220 LOC** to accommodate: `AMINASignedPriceAttestation` verification path | §3.4 |
| `RoleManager` | 6 roles | **8 roles** (split `CURATOR` → `CURATOR` + `ALLOCATOR`; split `EMERGENCY` actions to include `GUARDIAN`) | §3.5 |
| **Total LOC** | ~1,640 | **~1,780** | Net growth concentrated in `LendingEngine` and `LiquidationHandler` |

We've spent ~140 LOC of budget to harden a half-dozen specific properties (oracle immutability, pause-clock economics, signed price attestations, mid-deal recovery state, role separation, hook discipline). Tradable.

### 4.2 New state in `LendingEngine.state[dealId]`

```solidity
struct DealState {
    DealStateEnum state;           // existing
    uint128 outstanding;           // existing
    uint128 collateralPosted;      // existing
    uint64 lastTouchTs;            // existing
    uint8 liquidationStep;         // existing
    uint32 versionKey;             // existing

    // NEW in v0.3:
    uint64 pauseStartedAt;         // 0 if not paused
    uint64 totalPausedTime;        // accumulated paused seconds
    bytes32 lastPauseReason;       // for audit trail
}
```

### 4.3 New entry points

```solidity
// Engine
function openAndActivate(...) external onlyRole(ALLOCATOR);  // role change vs v0.2
function repay(bytes32 dealId, uint256 amount) external;     // unchanged
function topUpCollateral(...) external;                       // unchanged

function pauseDeal(bytes32 dealId, bytes32 reason) external onlyRole(GUARDIAN);
function unpauseDeal(bytes32 dealId) external onlyRole(GUARDIAN);
function claimUnreleasedCollateral(bytes32 dealId) external;  // borrower pulls if vault was frozen

// Liquidation
function partialLiquidate(
    bytes32 dealId,
    uint256 amount,
    uint8 expectedStep,
    AMINASignedPriceAttestation calldata attestation  // optional; only used if oracle stale
) external onlyRole(LIQUIDATOR);

// Emergency
function forceOracleOverride(
    bytes32 dealId,
    address newCollateralOracle,
    address newSupplyOracle,
    bytes32 reason
) external onlyRole(EMERGENCY);
```

### 4.4 Sequencing adjustment

The v0.2 phase order is mostly preserved. The single change is **moving real compliance-hook adapters from Phase 1 to Phases 4–5**, while keeping `ComplianceRegistry` + `DefaultPassHook` in Phase 1. Concrete:

- **Phase 1** (Identity, Registry, Roles) ships: `RoleManager`, `KYBGateway`, `IssuerRegistry`, `ComplianceRegistry`, `DefaultPassHook`. No real per-token compliance adapters yet.
- **Phase 4** (Liquidation + Settlement) gains a sub-deliverable: build the *first* real compliance adapter (Fireblocks or ERC-3643 reference) and run integration tests against it.
- **Phase 5** (Off-chain integration) gains a sub-deliverable: the second and third real compliance adapters.
- **Phase 6** (Internal hardening) gains a test deliverable: the mainnet-fork one-deal lifecycle reconciliation that GPT named.

No phase deadlines change.

---

## 5. Adjusted invariant list

Adopting GPT's §12 list with three additions of my own. The canonical v0.3 invariants:

**Per-deal invariants**
1. Deal terms are write-once.
2. Terminal deals (`Repaid`, `Liquidated`, `Defaulted`) cannot transition further. (`Repaid_PendingCollateralRelease` is not terminal — it transitions to `Repaid` on collateral release.)
3. Every state transition follows the documented DAG.
4. A deal cannot become active unless both lender and borrower transfers succeeded.
5. AMINA cannot open a deal without valid lender, borrower, and AMINA signatures.
6. A signature cannot be replayed across deal IDs, chains, or contract deployments.
7. Live deals keep their risk-version snapshot after registry updates.
8. Live deals keep their oracle binding after registry updates (unless `EMERGENCY.forceOracleOverride` was called, in which case the override event is emitted).
9. Liquidation step counter prevents duplicate partial/full actions.
10. Full liquidation cannot transfer more collateral to AMINA than `debt + explicit fee + explicit bonus`.
11. Surplus, if any, is claimable by the borrower and cannot be seized by governance.
12. **(New)** Interest accrues for `elapsedTime − totalPausedTime`, never for paused intervals.
13. **(New)** During pause, top-up and full repay remain callable (subject to token compliance); all other state-changing operations revert.

**Global invariants**

14. `sum(deal balances for token) == EscrowVault token balance` after every external call. (GPT's invariant 4; restated for clarity.)
15. Token pause blocks new deals but does not trap safe repay/top-up paths for existing deals.
16. Global halt cannot prevent borrower-favourable rescue actions (top-up, repay, claim surplus, claim unreleased collateral) unless explicitly in emergency mode.
17. Compliance hook failure cannot leave partial state changes.
18. Oracle decimals are normalized identically in health-factor, liquidation, and surplus math. (GPT's invariant 14.)
19. **(New)** Multi-dimensional cap enforcement: a deal cannot open if any of {global, per-token, per-pair, per-custodian, per-borrower, per-maturity-bucket} caps would be exceeded.

The 19 invariants above are the test targets for Phase 6.

---

## 6. Adjusted open questions for v0.8 brief revision

Merging my v0.2 §10 with GPT's §13, deduping, and resolving the ones we now have positions on. Open questions remaining for the product / legal / partnership side:

| # | Question | v0.3 default | Status |
|---|---|---|---|
| Q1 | Is AMINA posting any on-chain first-loss/bond capital in v1? | **No.** Bonding is a deliberate v2 product decision. | **Resolved** by Claude+GPT consensus; confirm with AMINA. |
| Q2 | Is liquidation surplus legally borrower property in all supported jurisdictions? | **Yes, default.** | **Must resolve before Phase 3** (legal confirmation). |
| Q3 | During a deal pause, does interest accrue? Does maturity extend? | **No accrual during pause; maturity extends by `totalPausedTime`.** | **Resolved** in §3.2; confirm with AMINA legal. |
| Q4 | Is off-chain master agreement hash per deal or per counterparty onboarding? | **Per deal**, via `termsHash`. | **Resolved**; confirm OK. |
| Q5 | Are oracle sources snapshotted per deal or only indirectly via risk version? | **Per risk version, snapshotted per deal.** | **Resolved** in §3.3. |
| Q6 | What is the exact legal status of AMINA's third EIP-712 signature? | **Brokerage attestation** under FINMA Securities Dealer licence. | **Must resolve before audit** (legal opinion). |
| Q7 | Can a lender or borrower use a fresh custody sub-account per deal by default? | **Yes, default.** Custodians manage sub-account allocation. | Open. |
| Q8 | Are partial fills purely off-chain until matched, or can a user have an on-chain pending order? | **Purely off-chain.** | **Resolved**; confirm with product. |
| Q9 | Does AMINA require the ability to block anyone-can-repay for sanctions/compliance reasons? | Caller passes `KYBGateway` + token compliance, so sanctioned wallets cannot repay anyway. No additional gate. | **Resolved** in §2.4; confirm with AMINA compliance. |
| Q10 | What is the minimum data required in `SettlementRouter` events for AMINA/custodian reconciliation? | Open. | **Must resolve before Phase 4** (AMINA integration). |
| Q11 | What happens if a permissioned token's issuer freezes the `EscrowVault` address mid-deal? | New `Repaid_PendingCollateralRelease` state. | **Resolved** in §3.8. |
| Q12 | What is the recovery ceremony if `LendingEngine` is halted but `EscrowVault` funds are safe? | UUPS upgrade with storage-layout verification. | **Resolved** in §3.7; document in Phase 8 runbook. |
| Q13 | Multi-collateral deals: v1 or v2? | **v2.** Single collateral per deal in v1. | **Resolved**; confirm. |
| Q14 | Maximum maturity cap. | **365 days.** | Confirm with product. |
| Q15 | Cross-chain (Arbitrum/Base for small EU deals). | **v2+.** Ethereum mainnet only in v1. | **Resolved**; confirm. |
| Q16 | DeFi liquidity channel: ERC-7540 wrapper, Mellow-style queue wrapper, or both? | **v2.** ERC-7540 view subset shipped in v1 to make it easy. | Open for product. |
| Q17 | Privacy upgrade path: commit publicly to a future ZK deal registry? | Open. Not foreclosed by current design. | Open for product. |

12 of 17 questions now have a default position. Five require external confirmation. Two remain genuinely open.

---

## 7. Risk reframing (adopting GPT §9)

Replacing the v0.7 brief's "we have no risks" language. Proposed wording for the v0.8 brief revision:

> **Risk allocation.** The protocol allocates responsibilities and corresponding risks to the parties best positioned to manage them.
>
> | Risk class | Owner | Why |
> |---|---|---|
> | Credit risk (borrower default) | AMINA Bank + collateral economics | AMINA holds the brokerage licence and the relationship; collateral is asset-backed via custody. |
> | Custody risk (asset loss / insolvency) | Custodians (Fireblocks, AMINA, BitGo, etc.) | The protocol does not hold real assets; tokens are claims on custody. |
> | Liquidation execution risk | AMINA Bank | AMINA is the privileged liquidator; off-chain settlement and asset redemption happen under AMINA's regulated operations. |
> | Identity / KYB risk | AMINA Bank | KYB review under FINMA banking licence. |
> | Regulatory classification risk | AMINA Bank (for matching, brokerage, custody) | All licensed activity is under AMINA. |
> | Smart-contract risk | P2P Staking | Code, audit, monitoring. Mitigated via multiple audits, formal verification on critical properties, immunefi bounty, immutable critical contracts. |
> | Off-chain stack risk | P2P Staking | Matching engine, dashboard, KYB intake, settlement listeners. |
> | Reputational risk | Both | Either party's failure damages the joint product. |
> | Oracle risk | Shared, mostly AMINA | AMINA carries off-chain market data and can override stale on-chain feeds via signed attestation. |
> | Operational risk (key compromise, bot failure) | Whichever party operates the affected component. | Each party's hot wallets are multisig and rate-limited. |
>
> No party in this allocation is risk-free. The intent is that *each* risk is assigned to the actor who can best price and manage it, and that the protocol's smart contracts make that allocation transparent and enforceable.

This replaces the v0.7 brief §10. It's also the section that the audit kickoff document should open with.

---

## 8. Adjusted phase plan summary

The v0.2 phase plan stands with these adjustments:

- **Phase 0** (Foundations, weeks 1–2): unchanged.
- **Phase 1** (Identity/Registry/Roles, weeks 2–4): ships `ComplianceRegistry` + `DefaultPassHook`; real per-token compliance adapters are *deferred* to Phase 4/5. New roles (`ALLOCATOR`, `GUARDIAN`) defined.
- **Phase 2** (Risk engine, weeks 4–6): `OracleRouter` is *merged* into `CollateralRegistry`. `ParameterArchive` now stores oracle binding alongside risk params.
- **Phase 3** (Deal engine, weeks 6–10): adds pause-clock state, `Repaid_PendingCollateralRelease` state, `claimUnreleasedCollateral` entry point, multi-dim cap enforcement.
- **Phase 4** (Liquidation + Settlement, weeks 10–12): adds `AMINASignedPriceAttestation` verification path, first real compliance adapter.
- **Phase 5** (Off-chain integration, weeks 10–14): unchanged in shape; adds second and third compliance adapters.
- **Phase 6** (Internal hardening, weeks 14–16): adds "mainnet-fork one-deal lifecycle reconciliation" as gating demo before external audit. Adds the 19 invariants from §5 above as test targets.
- **Phases 7–10**: unchanged.

Total timeline is unchanged at 28 weeks. LOC budget grew from ~1,640 to ~1,780.

---

## 9. Bottom line

GPT's note is the kind of careful adversarial review you want before locking interfaces. Two contributions matter most:

1. **Reframing.** "Repo rail" is a stronger product framing than "lending protocol." "P2P doesn't take balance-sheet risk but still owns tech/integration/monitoring/reputational risk" is a stronger risk story than "we have no risk."
2. **Tightening.** Caps from day one. Pause-clock economics. Oracle source in the snapshot. Signed price attestations. Hook discipline. These are all sharpenings, not rewrites.

The bilateral, fixed-term, AMINA-curated repo design is the right design. The next iteration of the brief and the implementation plan should:

- Adopt the "repo rail" framing.
- Adopt the risk reframing in §7.
- Adopt the 19 canonical invariants in §5.
- Adopt the 8-role taxonomy in §3.5.
- Resolve the 12 default-resolved open questions in §6 by getting written confirmation from AMINA and counsel.
- Push the remaining 5 open questions to a product / legal session before Phase 3 starts.

If those are done by end of Phase 1, the rest of the plan stands.

— Claude, 2026-05-26
