# Triora Pledging, Part 2 — State-Gated Custody, Liveness, Lock Synchronization, and Liquidation Abuse Resistance

> **Status:** Design analysis + reference architecture. Companion to [`Triora-Pledging.md`](./Triora-Pledging.md) (which covers the base lock mechanics on Fordefi/BitGo and the cBTC/cUSDC peg). Read that first.
> **Invariant context:** This document assumes [ADR-0001](./ADR-0001-no-real-funds-in-contracts.md) — **real BTC/USDC never touch a Triora contract.** The chain holds only restricted accounting tokens (cBTC, cUSDC), signed attestations, and one-use release vouchers. Everything below is about how the *off-chain* custody decision can be **bound to** *on-chain* state without ever moving the real asset on-chain.
> **Date:** 2026-06-29

This doc answers four questions that sit at the boundary between the smart contracts and the MPC/multisig custody:

1. **[Q1](#q1)** Can the custody lock be enforced from blockchain state (storage proofs / Chainlink attestation) instead of blind multisig discretion?
2. **[Q2](#q2)** What are the risks of funds becoming permanently unlockable if a required signer refuses or disappears?
3. **[Q3](#q3)** AMINA's signature is *added* to the lock at borrowing and *removed* at repayment — how is that synchronization enforced against on-chain deal state?
4. **[Q4](#q4)** Can AMINA liquidate without a real reason, or does the lock use proofs of contract state to prevent that abuse?

The short version, up front:

- **Yes**, the custody lock can be gated on contract state — via a **proof-carrying co-signer**: a service that holds a Fordefi/BitGo approver credential and approves a release **only after** it independently verifies an EIP-1186 storage proof (or a Chainlink-DON-signed report) of the relevant `LendingEngine` / `ReleaseAuthorizer` / `SignedCustodyAdapter` slots against a finalized Ethereum block. This converts AMINA's signature from *discretion* into a *function of on-chain state*.
- **The liveness risk is real and is the hardest part.** Neither Fordefi nor BitGo has a native "auto-release after N days" action. A naïve "AMINA must sign" design where AMINA is a *uniquely required* signer can brick funds forever. The fix is redundancy (AMINA as one-of-N, never 2-of-2) plus an **on-chain timeout voucher** that an independent fallback approver honors — but every such escape hatch reintroduces a discretion the gate was trying to remove. This is an irreducible tension, not a bug we can fully eliminate.
- **The add-at-borrow / remove-at-repay synchronization** is the *policy-drift* problem. Doing it with static policy rules is fragile (manual, asynchronous, subject to BitGo's 48h policy lock). The robust answer is to **not** rely on adding/removing a static rule at all: make AMINA's approval flow through the **state-gated co-signer** so the *signing decision itself* reads live on-chain state — a stale rule then can't authorize a wrong release, and a missing rule can't strand a repaid borrower (the co-signer simply approves once the repayment voucher exists on-chain).
- **AMINA cannot liquidate without an objective reason** as long as the BTC release is gated on `ReleaseAuthorizer`'s liquidation voucher, which the `LendingEngine` only mints after `LiquidationModule` finalized a liquidation — and finalization requires **two distinct, fresh, signed oracle reports** straddling a cure window, with a **permissionless cancel** if AMINA stalls. The residual trust is the *oracle signer*, which is why that signer should be independent of AMINA (ideally a Chainlink DON or n-of-m set), not AMINA's own key.

---

## 0. The on-chain surface the lock can be gated on

Everything in this document gates on four contracts that already exist in `src/`. The off-chain co-signer never calls them; it **reads their storage** (via a proof) and decides whether to sign.

| Contract | State the co-signer reads | Meaning for the lock |
|---|---|---|
| `LendingEngine` | `getPosition(positionId).state` (`SettlementPending`/`Active`/`Warned`/`RepaymentPending`/`ReleasePending`/`LiquidationPending`/`Closed`/`Liquidated`/`Defaulted`/`Cancelled`), `.pledgeId`, `.borrower`, `.collateral` | The authoritative deal lifecycle. A BTC release is only legitimate in `ReleasePending` (repayment) or post-`executeLiquidation` (liquidation). |
| `SignedCustodyAdapter` | `isLockActive(pledgeId)`, `verifyPledge(pledgeId, token, amount)`, `pledgeProof[pledgeId]` | The on-chain mirror of the off-chain lock — dual (custodian + AMINA) EIP-712 attestation that the BTC is locked, with `expiresAt` and a `controlAgreementHash`. Fail-closed on expiry. |
| `ReleaseAuthorizer` | `getVoucher(voucherId)` → `{positionId, pledgeId, amount, destinationType, destination, reason, issuedAt, consumed}` | The one-use **release voucher**. Destination is *derived from state*, never from a caller: repayment → `Borrower`, liquidation → `AminaDesk`, surplus → `Borrower`. This is the single most important slot to prove. |
| `LiquidationModule` | `firstReportRef[positionId]`, `usedReport[reportRef]` | Proof that an objective, signed, two-report liquidation actually ran. |

These four reads are what make a "proof-carrying co-signer" possible: the BTC-release authority is fully encoded in publicly-provable EVM storage.

---

<a name="q1"></a>
## Q1 — Can the custody lock be enforced from blockchain state instead of blind multisig?

**Yes.** There are four trust-minimization tiers. Triora Core V1 ships the dual-signed attestation (tier 0, already built); the recommended V1.x hardening is the **proof-carrying co-signer** (tier 3 below, built on tier 1). DLCs (tier 4) are research/Optional and only apply if the BTC ever leaves MPC custody for a native Bitcoin contract.

### Tier 1 — EIP-1186 storage proofs (most trust-minimized, custody stays in MPC)

`eth_getProof(address, storageKeys[], blockTag)` returns a Merkle-Patricia proof that a contract's storage slot held a specific value **as of a specific block's state root**. A verifier that has a *trusted block hash* can check the proof with pure hashing — a lying RPC cannot forge trie nodes that hash to the state root. ([EIP-1186](https://eips.ethereum.org/EIPS/eip-1186))

For Triora, the co-signer proves statements like:

- `LendingEngine.getPosition(positionId).state == ReleasePending` (repayment authorized), **and**
- `ReleaseAuthorizer.getVoucher(voucherId).destination == <the custody tx's destination>` **and** `.destinationType == Borrower` **and** `.consumed == false` **and** `.amount == <the release amount>`.

The slot index for a Solidity mapping is `keccak256(abi.encode(key, baseSlot))`; struct fields are `slot + fieldOffset`. So "prove `_vouchers[voucherId].destination`" is a concrete, deterministic slot computation against `ReleaseAuthorizer`.

**The crux is the trusted block hash** (see [Limits](#limits)):
- *Best:* an Ethereum **sync-committee light client** (Altair / Helios-style) — follow the 512-validator committee's BLS-signed beacon headers to a recent *finalized* header, from which the execution `stateRoot` is reachable, with no full node. ([Altair light-client spec](https://ethereum.github.io/consensus-specs/specs/altair/light-client/sync-protocol/))
- *Cheaper:* require k-of-n independent RPC providers to agree on the finalized block hash. Weaker (honest-majority-of-providers), operationally trivial.
- **Always prove against `finalized`, never `latest`** — a reorg can erase a `latest` slot value. On Ethereum this adds ~12.8 min between "deal marked `ReleasePending` on-chain" and "release approvable." Acceptable for institutional settlement; must be specced.

### Tier 2 — Chainlink CRE / Functions DON-signed report

A Chainlink CRE workflow reads `LendingEngine.getPosition(positionId)` via the `EVMClient` capability at the finalized block, and emits a **DON-signed report** (`runtime.report()`), authenticated on-chain by a Forwarder/Verifier that rejects unsigned/forged reports. ([CRE part 4](https://docs.chain.link/cre/getting-started/part-4-writing-onchain-ts), [Data Streams on-chain verification](https://docs.chain.link/data-streams/reference/data-streams-api/onchain-verification))

The report is a **portable signed artifact**: the co-signer can verify the DON's aggregate signature over "position X is `ReleasePending`" the same way the on-chain Verifier does, without re-deriving Merkle proofs. Trust shifts from "Ethereum consensus + Merkle math" to "the Chainlink DON's honest quorum." Strictly *more* trust than tier 1 for a co-signer that can do Merkle math itself, but a good fit for Triora because **we already run a CRE workflow for Proof-of-Reserve** (`cre/triora-reserve`) — reusing it for a deal-state attestation is incremental.

### Tier 3 — The proof-carrying co-signer (the practical Triora design)

This is the pattern that fits Fordefi/BitGo custody **today**. A service holds a custody-approver credential and approves a custody transaction **only after** verifying tier 1 (or tier 2). Its power is primarily a **veto**: it cannot move funds, but it can refuse/abort any release that isn't backed by on-chain state.

**Fordefi — custom co-signer** ([build guide](https://docs.fordefi.com/developers/transaction-types/build-custom-cosigner), [webhooks](https://docs.fordefi.com/developers/webhooks)):
1. Create an **API User (Trader role)** and place it in a transaction-rule **approval quorum** in the Fordefi policy. It acts as a required co-signer.
2. Run a **webhook server** subscribed to `Transactions V2`. Fordefi POSTs each pending tx — exposing `type`, `recipient`, `value`, raw call data / EIP-712 message, initiator.
3. **Verify the Fordefi signature** on the payload (`X-Signature` header, **ECDSA-P256 + SHA-256, DER-encoded**, against Fordefi's published public key) before trusting it.
4. **Gate:** run the tier-1 EIP-1186 verification — "does `LendingEngine` say this deal is `ReleasePending`, and does the custody tx destination == the `ReleaseAuthorizer` voucher's `Borrower` destination for this `pledgeId` and `amount`?" If yes → leave it to be approved by the quorum. If no → `POST /api/v1/transactions/{id}/abort` to actively kill it.
5. **Operational constraints (load-bearing):** restrict inbound to Fordefi's egress IP; the co-signer API User must **never initiate** transactions (initiators get implicit approval, defeating the gate); the policy rule must be `Type=Any, Recipient=Any, Origin=<BTC vault group>` and **ranked top** so it evaluates *every* release.

**BitGo — webhook policy approver** ([Policy Builder](https://developers.bitgo.com/guides/policy-builder/overview), [webhook rules](https://developers.bitgo.com/docs/policies-webhook)):
```json
{ "type": "webhook",
  "condition": { "url": "https://triora-cosigner/..." },
  "action": { "type": "getApproval" } }   // or "deny"
```
BitGo POSTs `walletId`, `ruleId`, `spendAmount`, `halfSigned`, and `outputs[]` (destination + value per output). **Response semantics:** HTTP **200** → BitGo proceeds; **non-200** → BitGo runs the action (`deny`, or `getApproval` → pending approval). The co-signer returns 200 **only after** the EIP-1186 / DON proof verifies that the release is state-authorized. A second state-verifying approver can also gate at the pending-approval layer (`PUT /api/v2/pendingApprovals/{id}`).

### Tier 4 — Bitcoin-native DLC + adaptor signatures (custodian-free, Optional/research)

A Discreet Log Contract locks BTC in a 2-of-2 and pre-commits settlement to an **oracle attestation**, with **no custodian touching funds**; Bitcoin consensus enforces that only a completed (witness-revealed) Contract Execution Transaction is valid. ([Optech DLCs](https://bitcoinops.org/en/topics/discreet-log-contracts/), [adaptor signatures](https://bitcoinops.org/en/topics/adaptor-signatures/)) The oracle attests "Repaid vs Liquidatable" (the binary outcome routing BTC to borrower vs lender), and crucially **a lying oracle cannot itself move the funds** — it can only attest, once.

This is the **only** design where no custodian can refuse or unilaterally seize. But it requires the BTC to sit in a native Bitcoin DLC, **not** in Fordefi/BitGo MPC — so it's out of scope for Core V1 (which is MPC-custodial by ADR-0001's "regulated custody wallet" framing). Note even DLCs don't read EVM state natively: you still need an oracle that decides the outcome *from* Ethereum state — so the robust composition is **tier-1 EIP-1186 verifier → DLC oracle attestation**. DLC trust-minimizes *custody*, not *state observation*.

### Trust gradient summary

| Tier | Cryptographically enforced | Trusted (off-chain) | Custody stays in MPC? |
|---|---|---|---|
| 1 — EIP-1186 | Merkle proof → state root unforgeable | Source of the trusted block hash; the verifier operator | ✅ |
| 2 — CRE/DON | DON aggregate signature | The DON's honest quorum; CRE liveness | ✅ |
| 3 — co-signer (Fordefi/BitGo) | Webhook payload authenticity; inherits tier 1/2 crypto | The operator running the co-signer (holds an approver credential) | ✅ |
| 4 — DLC | Bitcoin 2-of-2 + completed-CET-only | The DLC oracle attests correct outcome once | ❌ (native BTC contract) |

**Recommendation for Triora:** tiers 1+3 (EIP-1186 proof-carrying co-signer) as the V1.x hardening over the already-shipped tier-0 dual-signed attestation. Reuse the CRE PoR workflow (tier 2) as the block-hash/state-attestation source if running a light client is operationally heavy. Tier 4 is Optional/future.

---

<a name="q2"></a>
## Q2 — Risk of funds becoming permanently unlockable if a signer refuses

This is the **central liveness risk** and the hardest constraint in the whole design. **Neither Fordefi nor BitGo has a native "release after N days" action.** Fordefi's policy engine has exactly three actions — Allow / Block / Require-Approval — and no time-delay/scheduled/cooldown action. BitGo's `freeze` is a one-way *block* until expiry, not a delayed *release*. So a "dead-man switch" cannot be a custody policy rule; it must live on-chain or in the recovery procedure.

### What each platform gives you

**Fordefi (MPC / threshold signing):**
- **Device backup/restore** — recovers a *lost device* for an existing signer (encrypted backup on Fordefi servers, decryption key in user iCloud/Drive or a 12-word mnemonic). Does **not** help when a human *refuses*.
- **Org disaster recovery + Station70** — periodic encrypted `.json` of org keys to a backup email; opening needs the **combined recovery phrases of designated recovery-key-holder admins** (a quorum). Reconstructs keys and sweeps funds **fully outside Fordefi** if Fordefi disappears.
- **Admin Quorum** — all sensitive changes (incl. modifying who can approve) need approval of a configurable admin set ("> 2 administrators"). If an approver disappears, the surviving Admin Quorum re-publishes a policy that **drops** the missing approver. **No documented auto-timeout if a quorum admin is unreachable** — so size the quorum with spare admins.

**BitGo (2-of-3 multisig / TSS):**
- **Wallet Recovery Wizard — Non-BitGo Recovery** — signs a recovery tx with **user key + backup key only**, BitGo's third signature bypassed, and **bypasses all BitGo policies**. This is the canonical "BitGo refuses / disappears" escape — *but see the tension below.*
- **Key Recovery Service (KRS)** — an independent third party holds the *backup* key; on a stuck event the borrower + KRS sign without BitGo.
- **Offline Vault Console (OVC)** — air-gapped self-custody where the client always holds 2 of 3 keys.
- **Custodial (qualified-custody) mode** — BitGo holds all 3 keys; "BitGo refuses" is then a **contractual** 24h-SLA + video-verification risk, with **no cryptographic client override**. (If Triora uses BitGo qualified custody, liveness here is contractual, not cryptographic — confirm which product is in use.)

### The two hard truths

**1. AMINA as a *uniquely required* signer can brick funds.** Pure 2-of-2 with AMINA, or any scheme where AMINA holds a uniquely-required share, makes AMINA's refusal/disappearance terminal on **both** platforms. There is no cryptographic refund. **Mitigation:** AMINA is **one of N** approvers / one of 3 keys, with a borrower+backup recovery path, and AMINA is **excluded from the recovery quorum** (Fordefi Admin Quorum / BitGo user+backup) so it cannot also block the fallback.

**2. The recovery path *defeats* the on-chain gate (the irreducible tension).** BitGo Non-BitGo Recovery and Fordefi Station70 both move funds **bypassing all policies**. So whatever on-chain gate AMINA's co-sign enforces, the borrower's own user+backup keys can sweep around it. *"AMINA cannot release without an objective on-chain reason"* is only as strong as *"the borrower does not control enough keys to reach the recovery threshold alone."* For a true **tri-party** gate, the borrower must **not** unilaterally reach the recovery threshold — which **directly conflicts** with stuck-funds protection. You cannot have both "borrower can always self-recover" and "borrower can never release without AMINA." Triora must pick a point on this spectrum **per custody product**:

| Custody arrangement | Borrower can self-recover? | AMINA gate is bypassable? | Fit for Triora |
|---|---|---|---|
| BitGo self-custody 2-of-3 (borrower holds 2) | ✅ | ✅ (WRW) | ❌ — borrower defeats the lock |
| BitGo self-custody 2-of-3 (borrower holds 1, AMINA 1, KRS/BitGo 1) | only with KRS/BitGo | ❌ unless 2 collude | ✅ — **recommended** |
| BitGo qualified custody (BitGo holds all 3) | ❌ (contractual SLA only) | ❌ | ✅ — strongest gate, weakest borrower liveness |
| Fordefi MPC, AMINA one approver, borrower not in recovery quorum | only via Admin Quorum (excl. AMINA) | ❌ unless quorum colludes | ✅ |

### Triora's dead-man switch — on-chain, not in custody

Because custody can't express a timeout, Triora places the fallback on-chain and has the custody honor it:

- **Liquidation already has one.** `LiquidationModule.cancelPendingLiquidation(positionId)` is **permissionless** after the cure deadline — anyone can cancel a stalled pending liquidation, returning the position to `Active`. AMINA cannot leave a position frozen in `LiquidationPending` indefinitely.
- **For repayment release**, add a **maturity-plus-grace timeout voucher**: if a borrower has demonstrably repaid (off-chain custody→custody USDC settlement acked, position → `ReleasePending`) but AMINA stalls the BTC release, an **independent fallback approver** (not AMINA, e.g. a regulated escrow agent or a time-locked break-glass key in the custody policy) honors the `ReleaseAuthorizer` repayment voucher after a grace window. The voucher's destination is hard-coded to `Borrower` and state-derived, so the fallback approver has **zero discretion** — it either sees a valid unconsumed repayment voucher on-chain or it doesn't.

Every such escape hatch is itself a discretion the design was trying to remove (tension between censorship-resistance and trust-minimization). The honest framing: Triora minimizes *blind* discretion and bounds *how long* any party can stall, but a fully trustless "funds can never be stuck and never be wrongly released" does not exist for MPC custody — only DLCs (tier 4) get there, by leaving MPC.

---

<a name="q3"></a>
## Q3 — Synchronizing "add AMINA at borrow, remove at repay" with on-chain state

The naïve reading is: at loan open, **add** an AMINA-required approval rule to the custody policy; at repayment, **remove** it. Done with static policy rules, this is fragile — it's the **policy-drift** problem.

### Why static add/remove is fragile

Adding/removing a policy rule is a **manual, asynchronous** operation on each platform, **not atomic** with the `LendingEngine` state transition:
- **Fordefi:** admin drafts the rule on the console → submits to **Admin Quorum** → quorum approves on mobile → rule active. Purely off-chain human workflow; no on-chain trigger.
- **BitGo:** `update policy rule` → **PENDING_APPROVAL** (a *different* admin must approve; no self-approval) → ACTIVE — and **BitGo locks all policies 48h after creation**, after which changes need a `support@bitgo.com` ticket. Whitelists lock 48h too.

So the custody policy can lag or lead the on-chain deal state, opening two failure windows:
- **Loan `Active` but the AMINA-approval rule isn't live yet** → a release could happen *without* the intended gate.
- **Loan `Closed`/`Repaid` but the rule is still locked/pending** → funds gated *after* the obligation cleared → the borrower's BTC is **stuck** behind a rule that should have been removed (and BitGo's 48h lock can make removal need a support ticket).

### The robust answer: don't toggle a static rule — gate on live state

Make AMINA's approval flow through the **state-gated co-signer from [Q1](#q1)** instead of a rule you add and remove:

- The co-signer is a **permanent** approver in the policy (added once, never toggled).
- It **approves a release only when on-chain state authorizes it** — for a repayment release, when `LendingEngine.state == ReleasePending` and a matching unconsumed `Borrower` voucher exists in `ReleaseAuthorizer`. For any other state, it vetoes.

This **dissolves** the synchronization problem:
- A **stale rule can't authorize a wrong release** — the co-signer reads live state at signing time, not a rule snapshot.
- A **missing/removed rule can't strand a repaid borrower** — once the repayment voucher exists on-chain, the co-signer approves; nothing needs to be "removed."
- "AMINA's signature is added at borrow and removed at repay" becomes **emergent from state**: before `ReleasePending`, the co-signer (acting as AMINA's programmatic approver) will only approve a release into a *liquidation* destination if the liquidation flow finalized; after `ReleasePending`, it approves the *borrower* release. The "signature" is present or absent as a **function of `deals[positionId].state`**, exactly as desired — with no manual rule lifecycle.

### Where Triora already does the reconciliation

For the parts that *do* still need a policy/attestation lifecycle (e.g. submitting the dual-signed `PledgeProof` to `SignedCustodyAdapter` at open, refreshing it before `expiresAt`, releasing the lock at close), the **operator service** is the keeper that binds custody to chain:

- The operator's **settlement** and **risk** workers watch `LendingEngine` events (`PositionOpened`, `Funded`, `RepaymentConfirmed`, `Closed`, `Liquidated`) and the `SignedCustodyAdapter` proof freshness, and drive the custody API accordingly.
- `SignedCustodyAdapter` is itself **fail-closed and monotonic**: `isLockActive` returns false once `expiresAt` passes; `submitPledgeProof` rejects any `observedAt` older-or-equal to the stored one. So a *stale* proof automatically reads as "no active lock" rather than a wrong-but-confident one — the on-chain mirror degrades safely if the keeper lags.
- A **reconciliation loop** compares on-chain position/voucher/lock state against the custody policy/approval state and **alerts on divergence** (loan active but no live lock; loan closed but lock still active). Divergence is an operational alarm, not a silent state.

**BitGo 48h-lock playbook:** publish the *final intended* policy (including the permanent state-gated co-signer rule) **within the unlocked window at wallet setup**, and prefer the **webhook co-signer** (which is state-driven and never edited) over per-loan static rules that must be added/removed inside the lock window.

---

<a name="q4"></a>
## Q4 — Can AMINA liquidate without a real reason?

**No — not if the BTC release is gated on the on-chain liquidation flow.** AMINA *operates* liquidation (it's the desk that ends up with the seized cBTC voucher), but **eligibility is objective and enforced by `LiquidationModule` + `LendingEngine`**, and the custody release is gated on the resulting voucher. Walk the chain of gates:

### On-chain: objective, signed, two-report, time-boxed

`LiquidationModule` (already in `src/liquidation/`) makes AMINA prove eligibility, not assert it:

1. **`warn(positionId)`** — starts the cure clock; reverts with `StillHealthy` unless `engine.healthLtvBps(positionId) >= aminaWarningBps`. AMINA can't even start the clock on a healthy position.
2. **`requestLiquidation(report, oracleSig)`** — requires a **signed oracle report** (EIP-712, `oracleSigner`), fresh (`MAX_REPORT_SKEW` 5 min, `expiresAt` enforced), single-use (`usedReport[reportRef]`). Eligibility is a hard inequality: `matured || (thresholdBps == aminaLiquidationBps && debtValue*BPS >= thresholdBps*collateralValue)`. No breach and not matured → `StillHealthy` revert. Sets `LiquidationPending` with a `cureDeadline`.
3. **Cure window** — the borrower can repay/top-up during `cureWindowSecs`.
4. **`finalizeLiquidation(report2, oracleSig)`** — requires a **second, distinct, fresh** signed report (`r.reportRef != firstReportRef[positionId]` → `ReportReused`), and only after `block.timestamp >= cureDeadline`. Only then does it call `engine.executeLiquidation`.
5. **`cancelPendingLiquidation(positionId)`** — **permissionless** after the deadline: if AMINA requested a liquidation and then sat on it (e.g. price recovered, or it was opportunistic), *anyone* can cancel it back to `Active`. AMINA cannot weaponize a stale pending liquidation.

So a single AMINA key cannot fabricate a liquidation: it needs the **oracle signer's** signature over a real LTV breach (or genuine maturity), **two** of them straddling a cure window, and it races a permissionless cancel.

### Custody: the release voucher binds the BTC move to that flow

The BTC release for a liquidation is gated by the **release voucher**, not by AMINA's say-so:

- `LendingEngine.executeLiquidation` (callable **only** by `LIQUIDATION_MODULE`, only from `LiquidationPending`) calls `ReleaseAuthorizer.issueLiquidationRelease(...)`, which mints a voucher with **`destinationType = AminaDesk`, `reason = 1`, destination derived from state** — AMINA cannot redirect it elsewhere, and a *repayment* path can never mint an `AminaDesk` voucher.
- The **proof-carrying co-signer** ([Q1](#q1)) then approves the actual BTC custody transaction **only if** an EIP-1186 proof shows: position state ∈ {`Liquidated`,`Defaulted`}, a matching `ReleaseAuthorizer` voucher with `destinationType == AminaDesk`, `consumed == false`, and the custody tx destination == the voucher's `destination` and amount == voucher `amount`.

Net: **AMINA cannot move the borrower's BTC to the AMINA desk unless the on-chain liquidation objectively finalized.** A liquidation "without a real reason" would require forging the oracle report (needs the oracle signer's key) *and* getting past the second-report/cure-window logic — which the contract rejects.

### Residual trust (and how to shrink it)

- **The oracle signer.** If `oracleSigner` is an AMINA-controlled key, AMINA could in principle sign false LTV reports. **Mitigation:** make `oracleSigner` independent of AMINA — ideally a **Chainlink DON / Data Streams** report (verifiable on-chain) or an **n-of-m** oracle set, set via `setOracleSigner` (gated by `ORACLE_ADMIN`, which should not be AMINA). This is the single highest-value hardening for Q4.
- **The co-signer operator.** Same trust as Q1 tier 3 — it holds an approver credential and runs verifier code; compromise re-introduces discretion. It's a *veto* primitive, robust against false approvals, but not a substitute for a clean oracle.
- **The recovery-quorum tension** from [Q2](#q2) still applies: if the borrower could self-recover the BTC, they could also dodge a *legitimate* liquidation — so the same key-distribution choice protects both the borrower (against false liquidation, via the on-chain gates) and the lender (against liquidation-dodging, via no unilateral borrower recovery).

---

<a name="limits"></a>
## Limits, failure modes, and what is *not* trustless

1. **Trusted-block-hash bootstrap is the weak link of tier 1.** A storage proof is only as good as the `stateRoot` it's anchored to. A co-signer trusting a single RPC's `latest` answer is trusting that RPC — the Merkle math is decorative without an independent block-hash source. Use a sync-committee light client or k-of-n RPC agreement, and prove against `finalized`. The sync committee itself assumes an honest supermajority of 512 validators and is **not slashable** for light-client equivocation in current specs.
2. **No native time-lock on either custody platform.** The dead-man switch is *necessarily* on-chain (`ReleaseAuthorizer` timeout voucher + independent fallback approver) or in the Admin-Quorum reconfiguration procedure — not a custody policy rule.
3. **The proof-carrying co-signer is still a trusted operator.** It mitigates *blind* multisig discretion; it does not make release *trustless*. Its strength is veto (abort / non-200); its weakness is operator compromise/coercion and slot-derivation bugs. The custody MPC quorum still holds the actual key shares.
4. **The recovery path can defeat the gate** (Q2's irreducible tension). The on-chain gate is only as strong as the custody key distribution that prevents unilateral borrower recovery. Document the chosen custody product and key split explicitly per deployment.
5. **Chainlink CRE/DON (tier 2) layers a new honest-quorum + cost + latency assumption.** Its advantage is a portable, on-chain-re-verifiable signed artifact (and we already run it for PoR); its disadvantage vs tier 1 is trusting the DON's reading of state rather than the state root directly.
6. **DLCs (tier 4) remove the custodian but keep an oracle and require leaving MPC.** DLCs don't read EVM state natively — you still need an oracle deciding the outcome from Ethereum state, so the robust shape is `EIP-1186 verifier → DLC oracle`. Out of scope for MPC-custodial Core V1.
7. **No off-the-shelf product wires EVM storage proofs into Fordefi/BitGo.** Both expose a *generic* webhook/co-signer hook (return 200 / abort). The EIP-1186 verification, slot derivation, finality choice, and block-hash trust are **Triora's code**, and their correctness is entirely on us — this is the main net-new engineering for the V1.x hardening.

---

## Recommendation for Triora (Core V1 vs hardening vs Optional)

| Capability | Tier | Status |
|---|---|---|
| Dual (custodian + AMINA) EIP-712 attestation of lock + reserves, fail-closed + monotonic | 0 | **Shipped** (`SignedCustodyAdapter`) |
| Objective, signed, two-report, cure-windowed liquidation with permissionless cancel | 0 | **Shipped** (`LiquidationModule`) |
| State-derived one-use release vouchers (no caller discretion over destination) | 0 | **Shipped** (`ReleaseAuthorizer`) |
| Operator keeper: event-driven custody reconciliation + divergence alerts | 0 | **In services** (`services/operator` workers) |
| **Proof-carrying co-signer** (EIP-1186) gating Fordefi/BitGo release on `state` + voucher | 1+3 | **Recommended V1.x hardening** |
| Independent / Chainlink-DON oracle signer for liquidation reports | 2 | **Recommended hardening** (shrinks Q4 residual trust) |
| On-chain repayment-release timeout voucher + independent fallback approver | — | **Recommended** (Q2 dead-man switch) |
| Custodian-free release (DLC + adaptor sigs) | 4 | **Optional / research** (requires leaving MPC) |

**Bottom line:** Triora can and should bind the custody lock to on-chain state. With MPC custody the realistic ceiling is a *proof-carrying co-signer* that converts AMINA's signature into a function of `LendingEngine`/`ReleaseAuthorizer` state, plus an *independent oracle* for liquidation and an *on-chain timeout* for liveness. That removes blind discretion and bounds how long any party can stall — but it does not, and with MPC cannot, make release fully trustless. The only fully-trustless release is a Bitcoin-native DLC, which is a deliberate Optional/future direction, not Core V1.

---

## Source references

**State proofs / attestation:** [EIP-1186](https://eips.ethereum.org/EIPS/eip-1186) · [Altair light-client sync](https://ethereum.github.io/consensus-specs/specs/altair/light-client/sync-protocol/) · [Chainlink CRE writing on-chain](https://docs.chain.link/cre/getting-started/part-4-writing-onchain-ts) · [Chainlink Functions](https://docs.chain.link/chainlink-functions) · [Data Streams on-chain verification](https://docs.chain.link/data-streams/reference/data-streams-api/onchain-verification)
**Fordefi:** [custom co-signer](https://docs.fordefi.com/developers/transaction-types/build-custom-cosigner) · [webhooks + signature verification](https://docs.fordefi.com/developers/webhooks) · [approve via API](https://docs.fordefi.com/developers/transaction-types/approve-transactions-api) · [Admin Quorum](https://docs.fordefi.com/user-guide/admin-quorum) · [policy rules/conditions/actions](https://docs.fordefi.com/user-guide/policies/policy-rules-conditions-and-actions) · [Station70 recovery](https://docs.fordefi.com/user-guide/backup-and-recover-private-keys/backup-private-keys-station70)
**BitGo:** [Policy Builder](https://developers.bitgo.com/guides/policy-builder/overview) · [webhook policy rules](https://developers.bitgo.com/docs/policies-webhook) · [update pending approval](https://developers.bitgo.com/api/v2.approval.update) · [Wallet Recovery Wizard](https://github.com/BitGo/wallet-recovery-wizard) · [recover docs](https://developers.bitgo.com/docs/wallets-recover) · [Key Recovery Service](https://github.com/BitGo/key-recovery-service) · [freeze](https://developers.bitgo.com/docs/wallets-manage-freeze) · [CaaS policies / 48h lock](https://developers.bitgo.com/docs/crypto-as-a-service-policies) · [Custodial Services Agreement](https://www.bitgo.com/legal/bitgo-custodial-services-agreement/)
**DLC / adaptor signatures:** [Optech DLCs](https://bitcoinops.org/en/topics/discreet-log-contracts/) · [Optech adaptor signatures](https://bitcoinops.org/en/topics/adaptor-signatures/) · [Conduition adaptor-sig deep dive](https://conduition.io/scriptless/adaptorsigs/) · [secure DLCs open problem](https://bitcoinproblems.org/problems/secure-dlcs.html)
