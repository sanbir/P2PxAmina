# Triora — Core vs Optional (Independent Vision v3)

> **Author:** Plamen (independent synthesis)
> **Date:** 2026-06-28
> **Status:** Opinionated. This is a *from-first-principles* decision about what the
> minimal, production-safe Triora must contain and what must wait — derived from the
> canonical product spec (`Triora.html`, `Triora — Lend & Borrow.html`, `image-1.png`),
> the full P2PxAmina corpus, the Taurus/Anchorage/Kiln custody material, the existing
> `src/` implementation, and external research into tri-party repo, securities-lending
> collateral management, and the crypto/RWA lending landscape.
> **Note:** This document was written *before* reading `Triora-Core-vs-Optional.md`.
> The comparison against that document is appended at the end (Part 7).

---

## Part 0 — What "Core" means here (the decision rule)

Triora is not a normal DeFi protocol. It is **regulated financial infrastructure**: an
institution posts BTC it does not want to sell, keeps it in a qualified custodian, and
borrows USDC against a 1:1 on-chain claim. Real assets never enter the smart contract;
they move **once**, at settlement, under a licensed broker's (AMINA's) co-signature.

For a product like this, "minimal viable" is the wrong frame. The right frame is
**"minimal *safe*"** — the smallest system that does not have a way to (a) lose a
client's custodied asset, (b) mint a collateral claim that is not backed 1:1, (c) let
the wrong party take the collateral, or (d) make P2P legally a custodian, issuer, or
unlicensed broker. A feature is **Core** if and only if **its absence creates one of
those four failures, or its absence makes the product not the product** (i.e. it stops
being institutional, custody-backed lending).

I apply three tests to every candidate feature:

1. **Solvency test** — without it, can the protocol show a collateral claim that is not
   actually backed by a locked, exclusively-controlled real asset? If yes → Core.
2. **Liability test** — without it, does P2P (the tech provider) absorb custody,
   issuance, credit, or matching liability that the design says belongs to AMINA,
   Chainlink, or the custodian? If yes → Core.
3. **Reversibility test** — if we ship without it and add it later, is the later
   addition cheap and non-breaking? If yes → Optional. If adding it later forces a
   migration, a re-audit of the spine, or a change to the legal/custody agreements →
   Core (build the data model and boundaries now, even if values start trivial).

A fourth, overriding principle: **prefer reusing an audited, immutable primitive over
building bespoke machinery.** Every line of novel Solidity is novel attack surface that
must be audited and insured. The Core should contain *only* the machinery that does not
yet exist anywhere — the custody-tokenization and AMINA-control layer — and should
borrow everything else (the lending market, liquidation math, oracle plumbing) from
something already battle-tested.

---

## Part 1 — The one architectural decision that drives everything

The corpus contains **two liquidity models**, and the entire Core/Optional split hinges
on which one is the Core loan mechanism:

- **Model A — Bilateral OTC tri-party.** A specific institutional **lender** supplies
  USDC; the protocol tokenizes their reserved liquidity as **cUSDC**; a **matching
  engine** pairs lender and borrower; real USDC settles **once, off-chain**, between
  tri-party custody addresses under AMINA's co-signature. This is the headline framing
  of `Triora.html` and what the existing `src/l2-l5` + `src/simple` implement.

- **Model B — CollateralBridge over a curated on-chain market.** A **CollateralBridge**
  contract (owned by a Risk Curator = AMINA) holds the tokenized BTC, opens a position
  on an **isolated, immutable Morpho market**, borrows USDC from that market, and routes
  it to the borrower. This is exactly `image-1.png` and the "native connector into
  on-chain liquidity" of `Triora.html` §06.

### My ruling: **Model B is the Core loan mechanism. Model A is the first Optional extension.**

This is the most contrarian call in this document, so here is the full argument.

**The novel, dangerous, never-audited work is identical in both models:** custody-backed
BTC tokenization, Proof-of-Reserve secure-mint, exclusive lock, state-bound release,
AMINA-co-signed collateral movement. That spine is Core no matter what. The *only*
difference between A and B is the **cash/loan leg**.

Model A's cash leg requires Triora to **build, from scratch and audit, a bespoke
bilateral lending + settlement engine**: a `cUSDC` reserve token, a `ReserveRegistry`, a
matching engine, a staged funding-acknowledgement flow (`SettlementAcker` with dual
custodian+AMINA signatures), lender onboarding/KYB, and — critically — an **off-chain
real-USDC settlement that the chain cannot enforce**. In Model A, if AMINA receives the
borrower's collateral claim but the lender never wires the USDC (or vice-versa), the
only remedy is a regulated complaint. That is a deliberate accepted risk in the
corpus, but it is *unenforced settlement risk that we are building bespoke code to
operate*.

Model B's cash leg is **Morpho**: immutable, isolated, audited, with proven oracle,
health-factor, liquidation-incentive, and accounting logic. The USDC moves **on-chain,
atomically** when the bridge calls `borrow` — real delivery-versus-payment, for free,
exactly the property TradFi tri-party works hard to achieve (JPMorgan TCN, Broadridge
DLR). No cUSDC, no matching engine, no off-chain cash settlement, no `SettlementAcker`
for the cash leg, no unenforceable trust gap on the money.

So Model B is **smaller, has less novel attack surface, and gives strictly stronger
settlement guarantees on the cash leg.** For a "minimal yet production-safe" core, that
is decisive.

**Does Model B abandon the tri-party / institutional-lender story?** No. The
institutional **lenders supply the USDC liquidity to the curated Morpho market** (or to
a thin MetaMorpho-style vault that AMINA curates). The four-party model is preserved:
the lender provides cash liquidity, the borrower provides BTC collateral, AMINA is the
collateral agent + risk curator + co-signer + liquidator, and the custodian holds the
real BTC. The economics are tri-party; the *rail* is an audited on-chain market instead
of a bespoke engine. This is precisely the "two liquidity sources in one system"
unification that `Triora.html` §06 calls the natural end-state.

**The one thing Model B must get right** (and the Core spec must specify): on a Morpho
market, liquidation is **permissionless** — anyone can liquidate the bridge's position
when health < the market's LLTV. To preserve AMINA's role as the controlled liquidator
*and* keep a safety backstop, Triora sets **AMINA's internal liquidation threshold
strictly tighter than Morpho's LLTV.** AMINA always acts first (cure window, orderly
custody redemption, surplus to borrower); Morpho's permissionless liquidation exists
only as a last-resort backstop if AMINA is unavailable. This is *strictly safer* than
the corpus's "AMINA-only liquidation with no backstop," which has an unmanaged liveness
risk (if the AMINA bot is down, bad debt sits unliquidated).

> **Net:** Model B Core = the irreducible custody-tokenization spine + a thin bridge
> over an audited market. Model A (bilateral OTC + cUSDC + matching + off-chain
> settlement) is a large, bespoke, lower-settlement-guarantee feature set → Optional.

Everything below follows from this ruling.

---

## Part 2 — CORE (minimal yet production-safe)

Organized by layer. Each item: **what it is**, **why Core** (which test it passes), and
**what breaks if omitted**.

### 2.1 Legal & custody foundation (off-chain, but Core)

| # | Component | Why Core | If omitted |
|---|-----------|----------|-----------|
| C-1 | **Qualified custodian + segregated account per borrower/asset** (one custodian for v1) | Solvency + Liability. The real BTC must sit somewhere bankruptcy-remote that the contract can mirror. | There is no asset to tokenize; "1:1 backed" is a lie; P2P becomes the de-facto custodian. |
| C-2 | **Collateral Control Agreement (ACA / tri-party)** giving AMINA enforcement rights and blocking unilateral borrower withdrawal | Solvency + Liability. This — not the token — is what actually perfects the security interest (UCC Art. 8/9 "control") and survives bankruptcy. | The lender/AMINA is an *unsecured creditor* (Lehman/MF-Global failure mode). The on-chain claim is unenforceable. |
| C-3 | **AMINA as mandatory co-signer** of every real custody movement (deposit acknowledgement, repayment release, liquidation release) | Liability. Reproduces the tri-party agent's "no movement without the agent." | A single key (borrower or custodian) can move the asset; the "exclusive lock" guarantee collapses. |
| C-4 | **AMINA KYB/AML approval** of every counterparty before they can transact | Liability (regulatory). Only AMINA's FINMA licence authorizes onboarding decisions. | Unlicensed onboarding; P2P risks reclassification as a broker; sanctioned/unscreened entities transact. |

### 2.2 Collateral tokenization + Proof of Reserve (the heart of the novelty)

| # | Component | Why Core | If omitted |
|---|-----------|----------|-----------|
| C-5 | **`PermissionedCollateralToken` (cBTC)** — restricted ERC-20, 8 decimals, transfers allowed *only* on protocol paths (allowlist checks **both** `from` and `to`) | Solvency + Liability. The on-chain claim. Restriction keeps it out of public DeFi where backing/freeze status is invisible. | A freely-transferable, unbacked-looking token leaks into DeFi; impossible to enforce KYB/freeze; P2P looks like an issuer of a public asset. |
| C-6 | **`ReserveGuard` secure-mint in the actual mint path** — `supply + amount ≤ min(freshPoR, freshCustodianAttestation) − positiveMargin`, fail-closed on stale/negative/missing data | Solvency. This is the single mechanical defence against the infinite-mint failure class (PYUSD, uniBTC). | The protocol can mint collateral claims with no backing; total loss of the 1:1 invariant; the entire product premise dies. |
| C-7 | **`PledgeRegistry`** — binds `pledge ↔ cBTC ↔ custody account ↔ deal`; enforces `mintedAmount ≤ pledgedAmount`, one active deal per pledge, encumbrance accounting | Solvency. Ties each minted token to a specific locked deposit; prevents double-minting against one deposit and double-spending one pledge across deals. | Two deals could claim the same collateral; mint could exceed what's actually locked; "tokenize once, borrow many times" becomes "tokenize once, over-borrow." |
| C-8 | **`ICustodyAdapter` + `SignedCustodyAdapter`** — normalizes custodian evidence via **dual (custodian + AMINA) EIP-712 attestations**; exposes `attestedReserves`, `verifyPledge`, `isLockActive` | Solvency + Liability. The on-chain bridge to off-chain custody facts; no contract can call a custodian API, so facts must arrive as signed evidence. Adapter pattern keeps the custodian swappable. | Custody facts enter via an unauthenticated `setAmount` (reserve-inflation footgun); or the protocol is hard-wired to one vendor with no audit boundary. |
| C-9 | **Reserve data source** — a **PoR consumer** (`CREReportReceiver` / `AggregatorV3` reader) that authenticates DON-signed reports, *plus* the signed-attestation path of C-8 as the launch source; `min()` of the two when both exist | Solvency. Makes the backing fact externally verifiable, not self-attested. Building the receiver now (even if the launch data path is signed attestations) keeps it non-breaking to add the real CRE/PoR feed. | Reserves are self-attested ("PoR theater"); no independent verification; and retrofitting a verifying receiver later means re-touching the mint path (a re-audit of the most sensitive contract). |

> **On Chainlink CRE specifically:** the canonical spec makes CRE the minter. I treat
> the **on-chain `ReserveGuard` secure-mint** as Core and **CRE-as-orchestrator** as a
> *Core-ready interface with an Optional launch data source*. CRE is Early Access and
> (per the Kiln Railnet evidence) "announced ≠ provably live." Core must be able to run
> on dual signed attestations on day one, with the CRE/PoR feed slotting in behind the
> same receiver. The security boundary is the consumer-side guard, not the producer.

### 2.3 The lending mechanism (Model B)

| # | Component | Why Core | If omitted |
|---|-----------|----------|-----------|
| C-10 | **`CollateralBridge`** (owned by Risk Curator = AMINA) — holds cBTC, opens/owns the Morpho position, maintains a **per-borrower sub-ledger**, exposes `mintAndDeposit`, `withdrawAndBurn`, `borrow`, `repayWithdrawAndBurn`, `liquidateWithdrawAndBurn`; rights split: collateral ops = CRE/issuer, loan ops = borrower, liquidation/repay = AMINA/custodian | This *is* the loan product (`image-1.png`). The sub-ledger is required because Morpho sees one position but Triora has many borrowers. | There is no loan; or per-borrower accounting/liquidation attribution is impossible (Morpho only tracks the aggregate position). |
| C-11 | **`MorphoAdapter` (ProtocolAdapter interface)** — thin wrapper over `supply/borrow/repay/withdraw/liquidate`, isolating the bridge from the external protocol | Reversibility. Lets the bridge target one audited market now and Aave/another market later without touching bridge logic. | Bridge is welded to one external ABI; swapping or adding a venue forces a bridge rewrite + re-audit. |
| C-12 | **One isolated, immutable Morpho market** (cBTC/USDC, fixed oracle, LLTV, IRM) curated by AMINA | Reuses audited liquidation/oracle/accounting; gives on-chain DvP for the cash leg. | We are back to building Model A's bespoke cash engine — more code, weaker settlement guarantee. |
| C-13 | **`OracleAdapter`** — Chainlink BTC/USD price read with staleness + decimal normalization + a **peg sanity check** (cBTC valued at min(market, attested-reserve value)) | Solvency. Drives the AMINA liquidation trigger and prevents valuing cBTC above its real backing. | Liquidation can't be triggered objectively; a depeg or stale feed mis-values collateral; over-lending. |

### 2.4 Liquidation & release (the safety valve)

| # | Component | Why Core | If omitted |
|---|-----------|----------|-----------|
| C-14 | **Objective, oracle-gated liquidation eligibility** — AMINA *operates* liquidation, but eligibility is an objective predicate (HF breach proven by a signed Chainlink/oracle report), **not** AMINA discretion; with a fixed **cure window** (e.g. 24–48h) | Liability + fairness. "AMINA may operate liquidation but must not be trusted to *determine* eligibility." Cure window protects the borrower; objective trigger protects everyone from an interested-party liquidation. | AMINA can liquidate at will (interested-party abuse) or be accused of it; no borrower protection; legal/reputational exposure. |
| C-15 | **AMINA threshold strictly tighter than Morpho LLTV + permissionless backstop** | Solvency liveness. AMINA acts first and orderly; Morpho's permissionless liquidation is the last-resort backstop if AMINA is unavailable. | Either bad debt sits unliquidated when the AMINA bot is down (AMINA-only, no backstop), or AMINA loses control of the redemption (Morpho liquidates first). |
| C-16 | **`ReleaseAuthorizer` — state-derived release vouchers** — destination is **derived from on-chain deal state** (Repaid → borrower; Liquidated → AMINA desk), never passed by the caller; one-use, sequence-numbered | Solvency + Liability. Both safety (borrower can't self-release without repaying) and liveness (AMINA can't hold a repaid borrower hostage). | An operator can redirect released collateral; or a repaid borrower can be denied their asset; the "asset moves only where state dictates" guarantee dies. |
| C-17 | **Surplus-to-borrower on liquidation** (proceeds − debt − bonus − fee → borrower) | Liability (legal). Over-collateralization surplus is the borrower's property; keeping it is conversion. | Legal liability for AMINA; borrower harmed; fails the "deterministic by the rules" promise. |
| C-18 | **Custody listener / settlement service** that acts on vouchers only, requires AMINA co-sign for any movement, and acknowledges back on-chain (idempotent, replay-safe) | Solvency + Liability. The off-chain executor of the on-chain decision; the only thing that actually moves the BTC. | On-chain decisions never execute, or execute without authorization; the ledger and custody desync silently. |

### 2.5 Identity, roles, governance, safety (cheap, but Core by the Reversibility test)

| # | Component | Why Core | If omitted |
|---|-----------|----------|-----------|
| C-19 | **`KYBGateway`** — entity/wallet approval with expiry; every state-changing user action gated | Liability. The regulatory entry control. | Unscreened entities transact; AMLA breach; broker reclassification. |
| C-20 | **`RoleManager` (AccessManager) with strict role separation** — no role can both move funds/collateral *and* set risk params; hot keys can only *reduce* risk; GOVERNOR(P2P) vs CURATOR(AMINA) vs LIQUIDATOR vs EMERGENCY(joint) | Liability. Encodes the P2P-vs-AMINA duty split on-chain and bounds blast radius of any one key. | One compromised key drains or mis-prices everything; the clean P2P/AMINA liability split is not actually enforced. |
| C-21 | **Pause hierarchy + global halt** (joint emergency) | Safety. The circuit breaker for a discovered bug or oracle failure. | A live exploit cannot be stopped; no incident response. |
| C-22 | **`RiskConfig` / `ParameterArchive` — versioned, snapshotted risk params** (LTV, AMINA threshold, cure window, caps, fees), live positions pinned to their version | Reversibility. Tightening LTV must not retroactively endanger/auto-liquidate live deals. Caps **data model** must exist day-one even if values start near-unbounded. | Param changes silently mutate live deals; adding a cap dimension later is a migration, not a config change. |
| C-23 | **Monitoring & alerting day-one** — supply>reserve, stale PoR/attestation, pledge lock inactive, AMINA removed from quorum, voucher sequence gaps, unacknowledged vouchers, custody/ledger drift | Solvency. The off-chain detection of every invariant the contracts assert. | An invariant breaks silently and is discovered after loss, not before. |
| C-24 | **Immutability of the spine** (token, pledge registry, reserve guard, deal/voucher records, settlement router) with upgradeable engine behind a timelock | Solvency. Immutability is the "strongest user-facing promise"; the spine's correctness can't be silently changed. | Backing/accounting rules can be changed under users; trust evaporates. |

### 2.6 Off-chain services (Core set)

1. **Web app / frontend** (borrower-facing): Tokenize, Markets/Borrow, Portfolio/Position, Account (evidence hub), KYB onboarding. *(Why Core: it is the product surface; without it there is no usable product. What breaks: no user can transact.)*
2. **AMINA Operator Console** (the surface the mockups omitted): KYB approve/reject, set risk params, warn/liquidate, oracle override, pause. *(Why Core: every privileged action needs an operable surface; what breaks: AMINA cannot run the protocol safely, or runs it by raw scripts with no controls.)*
3. **Backend API + indexer**: serves positions/evidence/portfolio from chain events; stores KYB intake + evidence hashes. *(Why Core: the UI and console need read state and the audit trail; what breaks: no portfolio view, no evidence hub, no reconciliation.)*
4. **KYB intake service**: collect docs, hash, route to AMINA. *(Core via Liability.)*
5. **Custody integration / attestation signer**: build proof packets, gather custodian+AMINA EIP-712 sigs, submit attestations; watch custody for deposits + 6-confirmation finality. *(Core via Solvency.)*
6. **Custody listener / settlement service** (C-18). *(Core.)*
7. **PoR / reserve attestation publisher** (or Chainlink CRE workflow). *(Core data source for C-9.)*
8. **Risk / liquidation bot (AMINA OPS)**: monitor HF, run the cure window, execute the gated liquidation through the bridge. *(Core via Solvency liveness.)*
9. **Monitoring/alerting** (C-23). *(Core.)*

### 2.7 Frontend (Core pages)

- **KYB onboarding** (5-step: entity, signatories+docs, custody link, legal click-throughs with AMINA-decision wording, submit) — Core (regulatory entry).
- **Tokenize collateral** (connect custody address → AMINA tri-party → Chainlink mints cBTC 1:1) — Core (the entry to the whole product).
- **Markets / Borrow** (rate as *AMINA's parameter*, LTV/threshold ladder, place borrow, sign) — Core (the loan).
- **Position / Portfolio** (one consolidated position, health factor with **correct** math `LIQ/currentLTV`, threshold ladder, repay, top-up) — Core (lifecycle management + margin awareness).
- **Account = evidence hub** (entity, AMINA client id, control-agreement hash, pledge id, PoR report id + freshness, reserve ratio, token address, transfer policy, settlement route, AMINA approval state) — Core (auditability is a product feature for institutions).
- **Margin-call / cure / liquidation lifecycle screens** — Core (the mockup's biggest omission; without them a borrower cannot respond to a margin call).

---

## Part 3 — OPTIONAL (deferred, with the trigger that promotes it)

### 3.1 Near-term (v1.1 — hardening, add once the Core loop is proven)

| Feature | Why deferred | Trigger to add |
|---------|-------------|----------------|
| **Chainlink CRE as the production minter/orchestrator** (replacing signed-attestation launch path) | CRE is Early Access; the on-chain guard is the real control | CRE production support is contractually clear + a PoR feed exists over the exact custody address set |
| **Second/independent PoR feed** (Chainlink PoR alongside custodian attestation) | One authenticated source is sufficient for a controlled pilot | Pilot proves out; counterparty size grows |
| **Partial liquidation + top-up + partial repayment** | Full-only liquidation + full repay is a complete, safe loop | Loan sizes grow enough that all-or-nothing liquidation is too blunt |
| **Full `ComplianceRegistry` hook routing** (per-token pre/post hooks) | The token's own allowlist + KYBGateway suffice for one custodian/asset | A token needs per-action compliance logic (e.g. ERC-3643 identity registry) |

### 3.2 v2 (new product surface — separate audit each)

| Feature | Why deferred | Trigger to add |
|---------|-------------|----------------|
| **Model A — bilateral OTC tri-party engine** (cUSDC, `ReserveRegistry`, matching engine, `SettlementAcker`, off-chain USDC settlement) | Large bespoke surface + unenforceable off-chain cash settlement; Model B gives the loan with on-chain DvP and far less code | An institutional lender insists on a direct GMRA bilateral deal with USDC kept in their own custody, not in a Morpho market |
| **Loan-position token** (sellable / re-pledgeable) | The leverage/rehypothecation surface — the exact Lehman/MF-Global risk; needs its own risk model, haircut, buyer-eligibility, and changes AMINA's legal posture | Demand for secondary-market position mobility, *with* a reuse cap (TradFi caps at ~140%) |
| **ETH / wstETH collateral** | Needs a CAPO-style exchange-rate oracle (heed the March-2026 Aave CAPO incident) | BTC loop is production-stable; LST oracle risk is understood |
| **Additional custodians** (BitGo / Fireblocks / Copper-as-non-minter) | One custodian, end-to-end, first | Second custodian onboarded with its own adapter + control-agreement parity verified |
| **MetaMorpho-style curated vault** for institutional lenders to supply liquidity | A single isolated market suffices to launch | Multiple lenders want managed, diversified supply |

### 3.3 v3+ (scale / advanced)

| Feature | Why deferred |
|---------|-------------|
| **SOL collateral** | Different chain, custody, oracle, verification path |
| **RWA collateral** (tokenized treasuries) | SPV / transfer-agent / NAV-oracle / bankruptcy-remoteness opinions per issuer |
| **Cross-chain (CCIP) cBTC** | Re-introduces the global-supply double-mint problem; Taurus CCIP PoC is explicitly unaudited |
| **Re-pledging / looping** | Cascading leverage risk; needs its own risk model |
| **AMINA on-chain first-loss bond** | "Do not half-add bonding — a symbolic bond is false comfort"; accountability is regulatory+contractual in Core |
| **Stronger custody locks** (Bitcoin Taproot multisig / DLC / Babylon) | Tier-1 custodian policy lock is sufficient for v1; the contracts are identical across tiers — only the off-chain lock primitive changes |
| **ZK / enhanced privacy registry**, **secondary-market / auction rate discovery**, **tranching** | Pure scale/feature additions, not safety-load-bearing |

---

## Part 4 — The contested decisions, ruled

| # | Decision | My ruling | Rationale |
|---|----------|-----------|-----------|
| D-1 | Loan mechanism: Model A (bespoke OTC) vs Model B (Morpho bridge) | **Model B Core, A Optional** | Less novel code, on-chain DvP, reuses audited liquidation; A's cash leg is the largest bespoke + unenforced-settlement surface |
| D-2 | Settlement: atomic `openAndActivate` vs staged `SettlementPending` | **Moot in Model B → atomic on-chain** | Morpho `borrow` delivers USDC on-chain in one tx (real DvP). The atomic-vs-staged debate only exists because Model A settles cash off-chain. Model B sidesteps it. |
| D-3 | Liquidation eligibility: AMINA discretion vs objective oracle trigger | **Objective oracle trigger + cure window; AMINA operates** | AMINA is an interested party; eligibility must be objective. This is the most recent decision in the corpus and the right one. |
| D-4 | Liquidation authority: AMINA-only vs permissionless | **AMINA-first (tighter threshold) + Morpho permissionless backstop** | Removes AMINA's liveness single-point-of-failure while keeping AMINA in control of the orderly path. Strictly safer than AMINA-only. |
| D-5 | Token base: custom minimal vs CMTAT vs ERC-3643 | **Custom minimal restricted ERC-20 for Core** | CMTAT/ERC-3643 generic mint/burn + forced-transfer are footguns that bypass the pledge/reserve/voucher hooks; the local CMTAT v3.1/3.2 are unaudited. Borrow CMTAT *concepts* (can-transfer views) later; reserve full CMTAT for future transferable instruments. |
| D-6 | cUSDC (lender reserve token) | **Optional (belongs to Model A)** | In Model B, USDC is real and on Morpho; no reserve token needed. Dropping cUSDC removes `ReserveRegistry` + reserve-side `ReserveGuard` + the funding-ack flow from Core. |
| D-7 | Assets at launch | **BTC only** | Every worked example is BTC; ETH needs CAPO, SOL needs a different stack. |
| D-8 | Custodian at launch | **One, behind `ICustodyAdapter`** | One end-to-end integration; adapter keeps it swappable. (Anchorage matches `image-1.png` + the Atlas/ACA/Chainlink-PoR precedent; BitGo is the strongest BTC-PoR alternative.) |
| D-9 | CRE | **Core-ready interface, Optional launch data source** | The on-chain secure-mint guard is the real control; CRE is Early Access and not proven live. |
| D-10 | AMINA first-loss bond | **Out of Core** | A symbolic bond is false comfort; accountability is contractual+regulatory. |

---

## Part 5 — The Core build inventory (what to actually construct)

**On-chain (≈13 contracts):**
1. `RoleManager` (AccessManager) · 2. `KYBGateway` · 3. `PledgeRegistry` · 4. `ReserveGuard` · 5. `ICustodyAdapter` + `SignedCustodyAdapter` · 6. PoR consumer (`CREReportReceiver`/`AggregatorV3` reader) · 7. `PermissionedCollateralToken` (cBTC) · 8. `OracleAdapter` · 9. `CollateralBridge` · 10. `MorphoAdapter` (ProtocolAdapter) · 11. `ReleaseAuthorizer` · 12. `SettlementRouter` (events) · 13. `RiskConfig`/`ParameterArchive` + `PortfolioLens` (views, no privilege).

**Off-chain (9 services):** Web app · AMINA Operator Console · Backend API + indexer · KYB intake · Custody attestation signer · Custody listener/settlement service · PoR/reserve publisher (or CRE workflow) · Risk/liquidation bot · Monitoring/alerting.

**Frontend (6 core surfaces):** KYB onboarding · Tokenize collateral · Markets/Borrow · Position/Portfolio · Account/evidence hub · Margin-call/cure/liquidation lifecycle.

---

## Part 6 — Definition of done (safe-prod acceptance gates)

The Core is "done" not when the dashboard renders, but when **one real deal completes
and reconciles exactly**:

1. **One-deal lifecycle on a mainnet fork**: deposit BTC in custody → dual attestation →
   secure-mint cBTC (reserve-guarded) → bridge `supplyCollateral` + `borrow` USDC to
   borrower → accrue → repay → state-derived voucher → custody release → burn cBTC →
   ledger and custody reconcile to the satoshi.
2. **Invariant suite passes** (fuzz + formal where possible): `cBTC.totalSupply ≤
   attestedReserves − margin` always; `minted ≤ pledged`; one deal per pledge; release
   destination derived from state, never caller; vouchers one-use; AMINA threshold <
   Morpho LLTV; surplus to borrower; no role both moves collateral and sets params.
3. **Negative tests pass**: stale/negative/missing PoR blocks new mint; transfer to a
   non-allowlisted address reverts (both `from` and `to`); liquidation below the cure
   deadline reverts; voucher replay reverts; an unauthorized custody instruction (no
   matching voucher / no AMINA co-sign) is rejected by the listener.
4. **External audit** of the spine + bridge, and a **legal opinion** that the control
   agreement perfects the security interest and that P2P is not a custodian/issuer/broker.
5. **Monitoring live** with paging on every invariant before the first mainnet pledge.

If those five hold, Triora can take a small real deal. Nothing else in Part 3 is
required to get there.

---

## Part 7 — Comparison with `Triora-Core-vs-Optional.md` and why this vision is better

*(Written after reading the existing `Triora-Core-vs-Optional.md`, dated 2026-06-26,
"revised based on manager feedback.")*

### 7.0 What the existing document decides

The existing document is a strong **system-scoping** document. It lands on a deliberately
narrow v1:

- **Loan rail:** a **bilateral 1-borrower : 1-lender** loan, AMINA-matched, settled
  **off-chain** with AMINA confirming funding and repayment (the simplified **Model A**).
- **Contracts:** exactly **two** — `TrioraAccountToken` (restricted accounting ERC-20,
  issuer-only mint) and `TrioraLendingSimple` (the bilateral state machine). It explicitly
  marks as **Optional**: custody adapter, **pledge registry**, **reserve registry**,
  settlement router, **release authorizer**, separate liquidation handler, loan token,
  **DeFi bridge**, CMTAT suite, upgrade stack.
- **Tokenization:** "minting **only by approved issuer after custody evidence**," with
  cBTC/cETH **and cUSDC** as core; reserve/pledge enforcement deferred.
- **Onboarding:** pre-provisioned users; KYB done offline and imported as a flag.
- **Strong agreements with my vision:** settlement-pending ≠ active; interest only from
  confirmed funding; **Chainlink-gated liquidation with a cure window**; restricted
  accounting tokens with no user-to-user transfers; AMINA-operated lifecycle; evidence
  refs + events; minimal UI; no matching engine; no secondary loan token; one custodian.

It is also genuinely better than my document on dimensions I did not fully cover: the
**minimal user model**, the **backend service decomposition**, the **core data model**,
and the **prioritized build plan**. My tech spec will adopt that system-level structure.

So we agree on most of the lifecycle and on "narrow is right." We diverge on **three**
things, and one of them matters a great deal.

### 7.1 Divergence 1 (decisive) — on-chain reserve backing is Core, not Optional

**The existing document puts the on-chain backing guarantee in the Optional column.**
Its core mint rule is "issuer-only mint after custody evidence"; `ReserveGuard`, the
`PledgeRegistry`, the `ReserveRegistry`, and the custody adapter are all listed as
*Optional / later*. In that design **nothing on-chain prevents the issuer key from
minting more cBTC than there is BTC in custody.** Backing is enforced only by trusting
the issuer to mint correctly and by off-chain monitoring.

This fails the **Solvency test** that should define "Core" for a custody-backed product,
and it is the exact failure class the rest of the corpus is most emphatic about:

- The tokenization SOTA and PoR plans call the on-chain secure-mint guard a **"launch
  blocker"** and warn against **"PoR theater"** (a feed that is read but not enforced in
  the mint path).
- The market-wide pattern (Chainlink PoR Secure Mint) exists precisely because **trusted
  minters over-mint** — PYUSD's accidental 300T mint, uniBTC's mispriced mint. An
  issuer-only access check is the control that those incidents *already had* and that
  *did not save them.*

The user's bar is explicitly **"run on prod safely,"** not "run a trusted pilot." For a
regulated product whose entire premise is "every token is backed 1:1 by a locked real
asset," shipping to production with **no mechanical backing check in the mint path** is
the single most dangerous cut you can make. `ReserveGuard` secure-mint is roughly one
contract plus a reserve data source — cheap — and it is the cheapest possible insurance
against the worst possible outcome (unbacked claims borrowed against real value).

> **My position:** the secure-mint guard (`supply + amount ≤ min(PoR, attestation) −
> margin`, fail-closed), the pledge-bound mint, and the dual-signed custody attestation
> that feeds them are **Core under any model**. This critique is *model-independent* — it
> applies whether the loan rail is Model A or Model B. It is the most important
> correction in this document.

### 7.2 Divergence 2 (decisive) — the loan rail: Morpho bridge (mine) vs bespoke off-chain-settled bilateral engine (theirs)

The existing document chooses the simplified **Model A** and defers the **DeFi bridge**
("different architecture; defer to v2"). I choose **Model B** (the `CollateralBridge`
over an isolated Morpho market) as Core. Three reasons mine is the safer Core:

1. **Settlement integrity.** Their loan's cash leg settles **off-chain**, with AMINA
   confirming. Their own document concedes "repayment is not complete until AMINA
   confirms real settlement." That is an **unenforceable trust gap** operated by bespoke
   code. Model B's `borrow` delivers USDC **on-chain, atomically** — real
   delivery-versus-payment, the property TradFi tri-party spends fortunes to approximate.
2. **Less *bespoke* attack surface where it counts.** Yes, my Core has more *contracts*
   (≈13 vs 2) — but that is because it includes the safety controls of §7.1 that their
   Core omits. On the **loan engine itself**, mine is *less* bespoke: interest accrual,
   health-factor math, liquidation incentive, and accounting are **Morpho's audited,
   immutable code**, not a hand-written `TrioraLendingSimple`. Novel Solidity is the thing
   you must audit and insure; Model B minimizes the novel portion of the *loan* logic.
3. **Liquidation liveness.** Their AMINA-gated liquidation has **no backstop** — if the
   AMINA bot is unavailable, bad debt sits unliquidated. Model B keeps AMINA as the
   orderly first-liquidator (threshold set tighter than Morpho's LLTV) **and** inherits
   Morpho's permissionless liquidation as a last-resort backstop. Strictly safer.
4. **Artifact alignment.** `image-1.png` — which the brief elevates as part of "the
   system to build" — *is* Model B (CollateralBridge owning a Morpho position, CRE
   mint/withdraw rights, Anchorage liquidate/repay). The existing document defers exactly
   that artifact to v2.

**Where the existing document's choice is legitimately better:** if the v1 **business
mandate** is "a *specific named institutional lender* lends USDC kept **in their own
custody**, never in a DeFi pool," then Model A is *required* and Model B does not satisfy
it — because Model B's USDC sits in a Morpho market, a different custody posture for the
lender. That is a real product/legal constraint, not a technical one. If that mandate is
firm, their Model A is the correct rail. (Even then, §7.1 still applies: their Model A
must add the secure-mint spine.)

### 7.3 Divergence 3 (minor) — release vouchers and custody-attestation binding

The existing document defers the `ReleaseAuthorizer` (state-derived release vouchers) and
the on-chain custody adapter. In a two-contract design where AMINA is the sole operator,
AMINA's `confirmCollateralReleased` burns directly — so an operator (or a compromised
operator key) can in principle release/redirect collateral on a path the deal state does
not dictate. The voucher mechanism (destination **derived from state**, never from the
caller; one-use) removes that power even from AMINA on the repayment path, and the
on-chain attestation binds each pledge to specific custody evidence. These are Liability-
test controls. They are cheaper to include now than to retrofit into a live mint/release
path later (a re-audit of the most sensitive code). **Core, in my view; reasonable to
call borderline.**

### 7.4 Where I concede the existing document is right (or leaner)

- **Onboarding can be manual.** Their "pre-provisioned users, KYB performed offline and
  imported as a flag" is leaner than treating the KYB *portal/UI* as Core. I concede the
  onboarding **UI** is Optional for a controlled launch; the **on-chain KYB gate** stays
  Core (we agree on that).
- **System scoping.** Their user model, backend-service decomposition, data model, and
  build plan are more complete than mine on those axes. My tech spec adopts that
  structure rather than reinventing it.
- **The lifecycle invariants.** We fully agree on the non-negotiables: settlement-pending
  ≠ active, interest-from-funding, Chainlink-gated liquidation + cure window, restricted
  tokens, AMINA-operated lifecycle, evidence/audit trail, no matching engine, no
  secondary loan token. Their document states these crisply.

### 7.5 Why, on balance, this vision is better

The existing document optimizes for **"smallest thing to build for a controlled pilot."**
This document optimizes for the brief's actual bar: **"minimal yet sufficient to run on
prod *safely*."** Those are different targets, and the difference is exactly the set of
controls the existing document moved to Optional:

- It achieves a 2-contract core by **deferring the only mechanical guarantee that the
  collateral claims are backed** (secure-mint). For a custody-backed lender, that is the
  one cut you cannot make for production. **Smaller is not safer.**
- It settles the **cash leg off-chain on trust**, where an audited on-chain market would
  give real DvP for free.
- It defers the very **DeFi-bridge artifact** the brief elevates.

My vision keeps the product just as narrow on *features* (one asset, one custodian, no
matching, no loan token, no secondary market — we agree) while refusing to defer the
*safety spine*. The result is a Core that is larger in contract count but **mechanically
solvent, settlement-atomic on the cash leg, liquidation-live with a backstop, and aligned
with the elevated `image-1.png` architecture.**

### 7.6 Recommended synthesis (best of both)

1. **Adopt the safety spine of this document unconditionally** (secure-mint guard,
   dual-signed custody attestation, pledge-bound mint, state-derived release vouchers,
   day-one monitoring). It is **model-independent** and non-negotiable for prod.
2. **Default the loan rail to Model B** (CollateralBridge over one isolated Morpho
   market), per §7.2 — unless a firm business mandate requires a specific lender to lend
   from their own custody, in which case use the existing document's **Model A** *with the
   safety spine added*.
3. **Adopt the existing document's system scoping** (user model, backend services, data
   model, build plan) and its lean onboarding (manual KYB for launch).
4. Keep everything both documents agree is Optional — matching engine, loan-position
   token, secondary market, multi-custodian, RWA/ETH/SOL, cUSDC-as-its-own-token (only
   needed under Model A) — Optional.

In one line: **their feature scope is right; their safety scope is too small. Keep the
narrow feature set, restore the safety spine to Core, and put the loan on an audited
market instead of a bespoke off-chain-settled engine.**

---

