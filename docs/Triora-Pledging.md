# Triora — Pledging, Custody Locks, and Token Peg Enforcement

> **Scope.** How a borrower's BTC (and a lender's USDC) is *pledged* and *locked* while it never
> leaves the custody wallet, with the exact technical mechanisms for **Fordefi** and **BitGo**; how
> the on-chain contracts bind to that off-chain lock; and how the cBTC / cUSDC **peg** (1:1 backing)
> is enforced, what could break it, and the adjacent risks.
> **Companion docs:** `ADR-0001-no-real-funds-in-contracts.md` (the hard invariant), `Triora-Core-Tech-Spec.md` (S3 custody, S4 token/pledge, S5 oracle), `Triora-architecture.md`.
> **Governing invariant (ADR-0001):** real assets stay in custody and never touch a contract. The chain holds only restricted accounting tokens (cBTC, cUSDC); pledging is therefore *not* an on-chain escrow — it is an **off-chain custody lock** that the chain **mirrors and gates on**.

---

## 1. The core idea: pledging = lock + attest + state-bound release, across two domains

A pledge must make **three guarantees hold simultaneously**, each enforced in a different layer:

| Guarantee | Plain meaning | Enforced by | On-chain? |
|-----------|---------------|-------------|-----------|
| **Backing** | 1 cBTC ⇔ 1 BTC actually in custody; supply ≤ reserves. | `ReserveGuard` secure-mint reading a dual-signed reserve attestation / PoR. | **Yes** (mint path) |
| **Exclusive lock** | The borrower **cannot move** the pledged BTC while it backs a loan; only a quorum incl. AMINA can. | The **custodian's signing policy / key quorum** + a legal **control agreement**. | **No** — this is the hard part, and it lives in Fordefi/BitGo, not in Solidity. |
| **State-bound release** | The asset can leave custody **only** to the destination the deal state dictates (repay→borrower, liquidate→AMINA desk). | On-chain `ReleaseAuthorizer` voucher (state-derived, one-use) + the off-chain custody listener that refuses any movement without a matching voucher + AMINA co-sign. | **Bridged** (voucher on-chain, execution off-chain) |

The smart contract proves **backing** and authorizes **release**; it **cannot** enforce the **lock** —
a smart contract has no authority over a Bitcoin UTXO sitting in BitGo or a key share held by Fordefi.
The lock is enforced where the keys live. Everything in §2–§4 is about making that lock real and then
**binding the chain to it** so cBTC can never out-live its backing.

> **Why "connect address & read balance" is not a pledge.** The UI's first step ("we read the
> on-chain balance, nothing moves") proves the asset *exists*. It does **not** lock anything — the
> borrower could withdraw the next block. The lock only exists after the **tri-party / control-agreement
> step**: AMINA becomes a required co-signer in the custodian's policy (or a key-share holder). Reading a
> balance is *backing evidence*; the co-signer policy is the *lock*. Conflating them is the classic
> "PoR ≠ control" error.

---

## 2. How the lock is enforced — Fordefi

Fordefi is an institutional **MPC/TSS** wallet platform: a "vault" is a key whose shares are split
between the org's device / API-Signer share and Fordefi's server share (the server share runs in AWS
Nitro enclaves with hardware attestation). **A full private key never exists on any device.** Every
outbound signature is gated by the org's **Transaction Policy**, which Fordefi evaluates *before* the
threshold-signing ceremony. ([Fordefi MPC security](https://fordefi.com/solutions/mpc-security))

### 2.1 The lock is cryptographic, not just a UI gate

Fordefi "enforces policy before every signature": the server share **will not participate** in the MPC
ceremony unless the Transaction Policy's approval requirements for that specific transaction are
satisfied. So a borrower who holds the device share **cannot produce a valid BTC signature alone** — the
second (Fordefi) share co-signs only after the policy quorum (which includes AMINA) approves. That is the
lock, and it is enforced at the cryptographic signing layer, not merely a permission flag.

### 2.2 The Transaction Policy (the configurable lock)

Policy is an **ordered, first-match rule list** with a non-deletable default rule. The factory default
requires **no** approvals, so the **first deployment step is to set the default rule to Block / Require-
Approval** ([policies](https://docs.fordefi.com/user-guide/policies),
[rule conditions](https://docs.fordefi.com/user-guide/policies/policy-rules-conditions-and-actions)).
Rule conditions used to build a pledge lock:

- **Origin** = the pledged BTC vault (scope the rule to exactly that vault/vault-group).
- **Initiator** = the borrower's user / API user (who may *request* a spend).
- **Transaction Type** = `utxo_transaction` (BTC transfer).
- **Recipient** = an **allowlisted address group** — the only permitted destinations are the borrower's
  pre-registered return address and the AMINA liquidation/recovery address. Anything else falls through
  to a Block rule. Address-book entries are stored in verifiable storage "signed by the customer's device
  keys to prevent tampering."
- **Transaction Amount** / **Periodic Amount** = per-tx and rolling spend caps.
- **Action** = `Require Approval` with **M-of-N approvers**: you specify the number of approvers and which
  users/API-users may approve. **AMINA occupies a mandatory approver slot** (e.g. require 1 approval from
  the AMINA approver group). The **borrower as initiator is an implicit self-approval**, so AMINA must be
  a *separate* approver — never the initiator.
  ([create rule](https://docs.fordefi.com/user-guide/policies/create-a-policy-rule))

### 2.3 How AMINA becomes a required co-signer

Two supported patterns (Triora uses #2 for automation, #1 as the human backstop):

1. **AMINA as a quorum approver.** AMINA is a user / API-user in the org and is required in the approval
   rule. Human approvals happen in the Fordefi **mobile app**; programmatic approvals via
   `POST /api/v1/transactions/{id}/approve` (P-256 signed). The borrower can't meet quorum alone.
2. **AMINA as a programmatic Custom Co-Signer.** AMINA runs a co-signer service added to the quorum as an
   API-user that *never initiates*. On each borrower-initiated tx Fordefi pushes a **Transactions-V2
   webhook**; AMINA's service inspects destination/amount/calldata and calls `/approve` or `/abort`,
   enforcing "approve only allowlisted returns; block everything else."
   ([custom co-signer](https://docs.fordefi.com/developers/transaction-types/build-custom-cosigner))

### 2.4 Keeping the lock from being removed (the load-bearing detail)

The *per-transaction* lock is cryptographic, but "AMINA is a required approver" lives in a **mutable
policy**. Persistence is enforced by the **Admin Quorum**: publishing policy changes, editing the address
book, and changing user/vault-group assignments all require quorum sign-off
([admin quorum](https://docs.fordefi.com/user-guide/admin-quorum)). Triora configures a **multi-group
admin quorum** — e.g. "N Triora admins **and** M AMINA admins" — so the borrower side **cannot** publish a
policy edit that drops AMINA. **If AMINA is not embedded in the admin quorum, lock removal is contractual-
only, not cryptographically prevented** (see §7).

### 2.5 API surface, monitoring, liquidation

- **Create / approve / abort:** `POST /api/v1/transactions` (`vault_id`, `signer_type:"api_signer"`,
  `type:"utxo_transaction"`), `…/approve`, `…/abort`. Auth = API-user **JWT bearer** + per-request
  **P-256 (NIST P-256)** signature over `${path}|${timestamp}|${body}` in `x-signature`/`x-timestamp`.
- **Monitoring / proof-of-lock:** subscribe to webhooks; every borrower outbound enters
  `waiting_for_approval` and never reaches `signed` without AMINA's `/approve` — that observable
  transition *is* live proof the lock is intercepting withdrawals. The **binding** proof of control is
  reading the published **policy + admin-quorum composition** (AMINA present), not the balance.
- **Liquidation:** a dedicated rule whose Recipient = the allowlisted recovery-address group and whose
  approver set = AMINA-only lets AMINA move the collateral to the recovery destination **without** the
  borrower, while normal operations always require AMINA's co-sign.

---

## 3. How the lock is enforced — BitGo

BitGo offers **three independent layers**; a robust pledge stacks all three.

| Layer | Mechanism | Strength |
|-------|-----------|----------|
| **Cryptographic (key quorum)** | Every BitGo wallet (multisig & MPC/TSS) signs **2-of-3** (user, backup, BitGo keys); no party holds the full key. | Strongest — owner physically cannot sign alone *if they don't hold 2-of-3*. |
| **Policy (server-enforced)** | BitGo's signing service applies the BitGo key only if wallet policy passes (whitelist, velocity, webhook, approval). | Strong, **but only binds txns that route through BitGo's co-signer**. |
| **Contractual (legal)** | BitGo Trust (chartered trust co.) holds assets under a **Custodial Services / Account Control Agreement (ACA)**; acts only on confirmed instructions. | Legally binding, not self-executing. |

### 3.1 THE critical caveat (drives the whole wallet-type choice)

> *"Policy rules for withdrawals apply only to transactions that involve BitGo. Recovery transactions
> that use the user key and the backup key bypass any policies."*
> — [BitGo Policies Overview](https://developers.bitgo.com/guides/policies/overview)

So policy is only as strong as the key custody beneath it. **If the borrower controls 2-of-3 keys
(a self-managed self-custody wallet), they can co-sign a recovery transaction without BitGo and bypass
every policy rule** — the pledge degrades to contractual-only. For a genuinely crypto-enforced pledge the
borrower must **not** control 2-of-3. Use one of:

- **BitGo Trust custodial wallet** — BitGo holds **all three** keys; the owner has *zero* signing keys,
  only an instruction relationship. No recovery bypass exists. *(Best for an enforced pledge.)*
- **Go Account** — single-key omnibus custody wallet where **BitGo holds the sole key**; owner can't
  withdraw without BitGo. Substrate for Go Network "held" locks (§3.4 B).
- **Self-custody wallet with a key moved to AMINA** — AMINA holds the backup key (or the BitGo-side key),
  so the borrower controls only 1-of-3 and can never reach a 2-of-3 quorum alone.
([wallet types](https://developers.bitgo.com/docs/wallet-types), [MPC](https://developers.bitgo.com/guides/get-started/concepts/mpc))

### 3.2 Wallet policy rules (the configurable lock)

`POST /api/v2/{coin}/wallet/{walletId}/policy/rule` — body `{ id, type, action, condition, lockDate? }`
([createpolicy](https://developers.bitgo.com/api/v2.wallet.createpolicy),
[policy rules](https://developers.bitgo.com/docs/crypto-as-a-service-policies)). Rule **types**:
`coinAddressWhitelist` (only listed destinations), `coinAddressBlacklist`, `advancedWhitelist`,
`velocityLimit`, `allTx` / `allTxNoFiat` (match every outbound), `webhook` (defer to an external approver).
Rule **actions**: `deny`, `getApproval`, `getGroupApproval`, `getFinalApproval`, `getCustodianApproval`,
`getIdVerification`, `noop`. A `getApproval` action carries `userIds` + `minRequired` — the **quorum**.

Triora's pledge policy:
- **`allTx` → `getApproval` { userIds:[AMINA], minRequired:1 }`** — every borrower withdrawal goes to a
  **pending approval** and stalls until AMINA approves.
- **`coinAddressWhitelist`** pinned to the loan repayment/liquidation address — collateral can't be
  misrouted even on a default release.
- Optional `velocityLimit` as defence-in-depth.

### 3.3 How AMINA becomes a required co-signer (strongest first)

1. **AMINA as a key-share holder.** Restructure so AMINA holds one 2-of-3 key (e.g. backup key, BitGo
   holds the BitGo key). Borrower holds 1 key → physically cannot withdraw; also kills the recovery
   bypass. Added via wallet **share**: `POST /api/v2/{coin}/wallet/{walletId}/share` with a `keychain`
   object. ([createshare](https://developers.bitgo.com/api/v2.wallet.sharing.createshare))
2. **AMINA as a mandatory approver.** Add AMINA as an enterprise user with `admin`; the `allTx`→
   `getApproval` rule makes every spend a **pending approval** resolved by AMINA via
   `PUT /api/v2/pendingApprovals/{id}` `{state:"approved"|"rejected", otp}`
   ([pending approvals](https://developers.bitgo.com/api/express.pendingapprovals)). A creator **cannot
   approve their own** policy change, and **BitGo locks policies 48h after creation** (+ per-rule
   `lockDate` for immutability), so the borrower cannot quietly remove AMINA.
3. **AMINA as an external `webhook` approver.** A `webhook` rule POSTs every withdrawal to AMINA's HTTPS
   endpoint (HMAC-signed `x-signature-sha256`); **non-200 ⇒ denied / forced to pending** (fail-closed),
   200 ⇒ proceeds. ([webhook policy](https://developers.bitgo.com/docs/policies-webhook))

Plus a **`freeze` permission** ("freeze a wallet, which disables all withdrawals") held by AMINA as an
instant kill-switch, and the **ACA** as the legal backstop. ([wallet users](https://developers.bitgo.com/guides/wallets/users/add))

### 3.4 Release / liquidation

- **A. Wallet/policy model.** On default AMINA approves (or, if it holds a keyshare, co-signs) a withdrawal
  to the whitelisted recovery address. Happy-path repayment release = the `allTx` approval rule is
  expired/removed (second-admin approval + 48h semantics) and the borrower regains spend.
- **B. Go Network "held" model.** For a Go Account the lock is a **settlement hold**: *"Signing a
  settlement places the assets in your Go Account into a held state, preventing them from use in other
  transactions"*; assets *"remain with BitGo in qualified custody until time of settlement."* On default
  the settlement executes to AMINA/lender **within custody — no on-chain withdrawal**.
  ([settlements](https://developers.bitgo.com/guides/go-network/settle/overview),
  [allocate](https://www.bitgo.com/resource-center/go-network-allocate-off-exchange-settlement/)) BitGo's
  own **Digital Asset Financing** ("borrow against assets remaining held in BitGo regulated custody")
  confirms native support for collateral-held-in-custody lending.

### 3.5 Monitoring

Wallet webhooks (`transfer`, `transaction`, `pendingapproval`, `wallet_confirmation`; HMAC-signed,
retried 7×). A `pendingapproval` event is live proof the lock intercepted a borrower withdrawal. AMINA
polls the policy resource to confirm the `allTx`/whitelist/webhook rules are still `ACTIVE`, that it
remains in `userIds`, and that it still holds `admin`/`freeze`/keyshare; the 48h lock + `lockDate`
themselves attest the lock can't be silently removed.

---

## 4. Binding the off-chain lock to the chain (the Triora contracts)

The custody lock (§2/§3) and the on-chain ledger are kept in lock-step by **dual-signed attestations** +
the **secure-mint** + **pledge registry** + **release voucher** primitives:

```
 Custody lock established (Fordefi policy/quorum or BitGo keys+policy+ACA)
        │  custodian ops + AMINA build a proof packet
        ▼
 SignedCustodyAdapter.submitPledgeProof(pledgeId, {custodyAccountRef, token=cBTC, amount,
        decimals, observedAt, expiresAt, controlAgreementHash}, custodianSig, aminaSig)   ← BOTH sign
        │  (custodianSig proves the balance+lock; aminaSig proves AMINA is the co-signer/control agent;
        │   controlAgreementHash binds the legal ACA / policy config)
        ▼
 PledgeRegistry.registerPledge(...)   → requires adapter.verifyPledge(pledgeId, cBTC, amount)
        │  status = Pledged
        ▼
 cBTC.mintForPledge(borrower, pledgeId, amount)
        ├─ ReserveGuard.checkMint(cBTC, amount): totalSupply+amount ≤ min(PoR, attestation) − margin  (fail-closed)
        └─ PledgeRegistry.recordMint: mintedAmount ≤ pledgedAmount
        ▼
 LendingEngine.openMatchedDeal → PledgeRegistry.lockForDeal (one active deal per pledge; encumbered ≤ minted)
        ▼  ... loan lives ...  (operator continuously RE-ATTESTS: adapter.isLockActive(pledgeId) must stay true & fresh)
        ▼
 Repay → ReleaseAuthorizer.issueRepaymentRelease (destination = borrower, one-use voucher)
 Liquidate → ReleaseAuthorizer.issueLiquidationRelease (destination = AMINA desk)  ← destination DERIVED FROM STATE, never caller-supplied
        ▼
 Off-chain: custody listener sees the voucher, verifies it, AMINA co-signs the SINGLE custody transfer to the voucher's destination
        ▼
 cBTC.burnForRelease(voucher)  → supply falls as the BTC leaves custody → backing stays 1:1
```

What each contract element proves / enforces:

- **`SignedCustodyAdapter`** — the only bridge for custody facts; **no contract calls a custodian API**.
  `verifyPledge` (amount + token), `isLockActive` (lock present + attestation fresh), `attestedReserves`
  (the PoR figure for `ReserveGuard`). Dual sig = *both* the custodian (holds/locks the BTC) and AMINA
  (the control agent) must agree. `controlAgreementHash` anchors the legal ACA / the Fordefi-policy or
  BitGo-policy configuration that constitutes the lock.
- **`ReserveGuard`** — secure-mint in the *actual mint path*; fail-closed on stale/missing/negative data.
  This is the only thing standing between "1:1 claim" and over-issuance.
- **`PledgeRegistry`** — `mintedAmount ≤ pledgedAmount`, one active deal per pledge, encumbrance; the
  on-chain accounting twin of the custody lock; `freezePledge` halts a disputed pledge.
- **`ReleaseAuthorizer`** — state-derived, one-use vouchers; the *only* authority that lets BTC leave
  custody, and only to the state-dictated destination.
- **Continuous re-attestation** — because a single attestation only proves the lock *at that instant*,
  the operator re-submits fresh proofs on a cadence; `isLockActive` staleness → mints blocked + alert.

---

## 5. The pledge lifecycle, end-to-end (per custodian)

| Step | Fordefi | BitGo |
|------|---------|-------|
| **1. Segregate** | Borrower's BTC sits in a dedicated **vault** in the Triora org. | BTC in a dedicated **BitGo Trust custodial wallet** or **Go Account** (owner holds 0 keys), or a self-custody wallet with a key moved to AMINA. |
| **2. Lock** | Transaction Policy: default=Block; pledged-vault rule = Require-Approval, recipient allowlist, **AMINA required approver**; **multi-group admin quorum** incl. AMINA so the rule can't be removed. | `allTx`→`getApproval{userIds:[AMINA]}` + `coinAddressWhitelist`; AMINA holds `admin` (+ ideally a keyshare) + `freeze`; `lockDate` set; ACA signed. |
| **3. Attest** | Ops build the proof packet; **Fordefi-side signer** + **AMINA signer** EIP-712 sign `PledgeProof` (+ `ReserveProof`). | BitGo balance + policy read; **custodian signer** + **AMINA signer** EIP-712 sign the same `PledgeProof`/`ReserveProof`. |
| **4. Register** | `PledgeRegistry.registerPledge` (verifies `verifyPledge`). | same |
| **5. Mint** | `cBTC.mintForPledge(borrower, pledgeId, amount)` — secure-mint + pledge-bound. | same |
| **6. Borrow** | `LendingEngine.openMatchedDeal` → `lockForDeal`. | same |
| **7. Monitor** | Webhooks: every outbound `waiting_for_approval`; poll policy/admin-quorum. Re-attest on cadence. | Webhooks: `pendingapproval`; poll policy `ACTIVE` + AMINA in `userIds`. Re-attest on cadence. |
| **8. Repay → release** | Voucher (→borrower) → AMINA approves the single custody transfer → `burnForRelease`. | Voucher → AMINA approves pending approval / Go-Network settlement release → `burnForRelease`. |
| **9. Default → liquidate** | AMINA-only recovery rule moves BTC to the recovery address → `burnForRelease` (seized→AMINA desk, surplus→borrower). | AMINA approves/ co-signs withdrawal to whitelisted recovery address, or executes the Go-Network held settlement → `burnForRelease`. |

---

## 6. Peg enforcement: cBTC and cUSDC

### 6.1 What "peg" means here — and why it is NOT a stablecoin peg

cBTC and cUSDC are **restricted accounting receipts**, not market-traded assets:

- **1 cBTC ⇔ 1 BTC in custody; 1 cUSDC ⇔ 1 USDC reserved in the lender's custody.** Decimals match the
  underlying exactly (**cBTC = 8** = satoshis, **cUSDC = 6** = USDC base units) so the unit mapping is 1:1
  with no scaling.
- They are **non-transferable except on protocol paths** (`_update`: a transfer needs at least one
  protocol-address side; **user↔user is blocked**). There is **no secondary market, no AMM, no order
  book, no price discovery** for cBTC/cUSDC. They are minted, locked, and burned at par inside the ledger,
  never *traded*.
- **Therefore the classic "depeg" — a market price drifting away from \$1 / from BTC — cannot occur,
  because there is no market price.** The "peg" is a **backing invariant**, not a quoted price. The risk
  is not "price ≠ par"; it is "**supply > reserves**" (an unbacked claim). The peg is enforced as an
  *accounting* property, not defended by arbitrage.

### 6.2 The mechanisms that hold the peg

| Mechanism | Contract | Guarantees |
|-----------|----------|-----------|
| **Secure-mint (anti-inflation)** | `ReserveGuard.checkMint`: `supply+amount ≤ min(freshPoR, freshAttestation) − margin`, fail-closed | Can never mint **more** cBTC/cUSDC than the attested custodied reserves. The single most important peg control. |
| **Pledge/reserve binding** | `PledgeRegistry`/`ReserveRegistry`: `minted ≤ pledged`/`reserved`; one active deal | A specific deposit backs a specific mint; no double-mint against one deposit. |
| **Burn-on-exit** | `cBTC.burnForRelease` (voucher), `cUSDC.burnLocked` (at funding) | Supply falls in lock-step as the real asset leaves custody → backing stays 1:1 downward too. |
| **Restricted transfer** | token `_update` | No market ⇒ no price-based depeg; claims stay inside the protocol. |
| **Oracle peg-cap (valuation)** | `OracleAdapter.collateralValueUsd`: value = `min(market×amount, reserves×price)`; scaled by `reserves/supply` if reserves < supply | Even in valuation/liquidation math, cBTC is **never valued above its real backing**; if reserves dip below supply, collateral is marked down proportionally. |
| **cUSDC is never settlement** | engine never treats cUSDC as real USDC; it is burned at funding | cUSDC is a *reservation*, not money; it cannot be "spent" as USDC. Its peg only matters in the short window between reservation-mint and funding-burn. |

**cUSDC nuance.** cUSDC exists only from the moment the lender tokenizes their reserved USDC until the
deal funds (then it is burned, because the real USDC has moved custody→borrower). Its backing window is
short, and it is reserve-guarded the same way as cBTC against the lender's attested USDC custody balance.

### 6.3 Depeg risks (i.e., the 1:1 backing breaking) and mitigations

> The peg breaks **iff `supply > genuinely-locked reserves`**. Every risk below is a path to that state.

| # | Risk (depeg path) | How it would break backing | Mitigation in Triora | Residual |
|---|-------------------|----------------------------|----------------------|----------|
| D1 | **Over-mint / infinite-mint** (PYUSD, uniBTC class) | Issuer mints beyond reserves | `ReserveGuard` secure-mint in the mint path; dual attestation; fail-closed staleness; `min(PoR, attestation)` | Guard misconfig / a mint path that skips the guard (tested against) |
| D2 | **Lock failure — pledged BTC withdrawn while cBTC outstanding** (the §2/§3 gaps: Fordefi policy-removal w/o AMINA in admin quorum; **BitGo self-custody recovery bypass**; org control) | Real BTC leaves custody but cBTC not burned → unbacked | Custodial / Go-Account (borrower holds 0 keys) **or** AMINA keyshare; AMINA in admin quorum; `freeze`; continuous re-attestation (`isLockActive` staleness → halt mints); on-chain backing-ratio markdown | Strong but ultimately custody-config-dependent (see §7) |
| D3 | **Stale / false reserve attestation (PoR)** | Attestation overstates reserves → over-mint; or stale data used | Freshness window + `answeredInRound`/positivity checks; dual custodian+AMINA sig; discrepancy threshold; fail-closed (stale ⇒ new mints blocked) | Both signers colluding / a compromised attestation key |
| D4 | **Custodian insolvency / hack / fraud** | BTC gone from custody, cBTC outstanding | Qualified, segregated, bankruptcy-remote custody (BitGo Trust / Fordefi MPC + Nitro); ACA; PoR | Pure custodian counterparty risk — **not** eliminable on-chain (one custodian in v1) |
| D5 | **Decimal / scaling bug** (uniBTC valued ETH 1:1 as BTC) | Mis-scaled mint/value → effective over-issue | Fixed decimals (cBTC=8, cUSDC=6); explicit decimal normalization in `TrioraMath`/`OracleAdapter`; tests | Implementation bug (audit + invariant tests) |
| D6 | **cUSDC: lender USDC moves/double-spent after reservation, before funding** | cUSDC briefly unbacked | Same custody lock on the lender's USDC account; reserve-guard; short window; burn-at-funding | Lender custody-lock strength |
| D7 | **Forced-transfer / ledger desync** (why we rejected CMTAT generic forcedTransfer) | A balance moved without updating internal ledger → accounting vs supply mismatch | No generic forced-transfer; burns are voucher-gated and registry-recorded | N/A by design |

### 6.4 Adjacent (non-peg) risks the user should weigh

| Risk | Mechanism | Mitigation |
|------|-----------|-----------|
| **Underlying-price oracle failure** (BTC/USD stale/manipulated) | Not a cBTC-backing issue, but mis-prices collateral → bad LTV/liquidation | Chainlink staleness + positivity + `answeredInRound`; liquidation may use a signed oracle report when the feed is stale; **CAPO** for the future ETH/LST leg (heed the Mar-2026 Aave CAPO stale-ratio incident) |
| **Double-pledge / pledge reuse** | One deposit backing two deals | `PledgeRegistry`: one active deal per pledge; `markReleased`/`markLiquidated` prevent re-mint/re-bind |
| **Release misrouting / voucher replay** | Collateral sent to wrong destination or twice | `ReleaseAuthorizer`: destination **derived from state** (never caller), one-use sequence-numbered vouchers |
| **Off-chain settlement non-execution** (BNY-Mellon trust gap) | AMINA gets collateral on default but fails to credit the lender; or funding USDC never moves | Accepted, regulated-party trust model: AMINA is the FINMA-licensed co-signer; on-chain records + ACA give the legal remedy. Funding `Active` only on a dual-signed ack ⇒ no interest/active before the real USDC moved. |
| **Co-signer / attestation liveness** | AMINA down ⇒ legitimate withdrawals stall (safe-fail); attestation stale ⇒ mints halt | Operational SLA; redundant signers; fail-closed is the *safe* direction (favours lender/solvency) |
| **Frozen/Tier-changed account mid-deal** | Custodian freeze blocks release | `freezePledge` + recovery flow; release tolerated as a state, not a brick |
| **Governance / key compromise of a privileged role** | A role mints, mis-prices, or releases | Role separation (no role both moves collateral and sets params); hot keys reduce-risk-only; pause hierarchy; EMERGENCY oracle override is a delayed sidecar |

---

## 7. What is cryptographically enforced vs contractual-only (read this before trusting the lock)

- **Per-transaction lock:** **cryptographic** on both Fordefi (server share won't co-sign without quorum)
  and BitGo (2-of-3 quorum) — *provided* the borrower does not control the signing threshold alone
  (BitGo self-custody **recovery bypass** is the trap; Fordefi requires AMINA to actually sit in the
  approver quorum).
- **Persistence of the lock** ("AMINA can't be removed"): **only as strong as governance** — Fordefi's
  **Admin Quorum** (AMINA must be a required admin group) / BitGo's **second-admin approval + 48h policy
  lock + `lockDate`** (AMINA must hold `admin`). If AMINA is *not* embedded in that governance layer,
  removal of the lock is **contractual-only**.
- **The control agreement (ACA)** and the legal pledge/lien are **contractual, not self-executing** —
  the court-enforceable backstop, anchored on-chain only as `controlAgreementHash`. Neither custodian
  provides a native on-chain lien primitive.
- **Backing (peg) is enforced on-chain** by `ReserveGuard` — but it can only be as truthful as the
  reserve attestation feeding it, which is **off-chain evidence** (custodian + AMINA signed). The chain
  guarantees *supply ≤ attested*, not *attested = reality*; the latter is the custodian's job.

**Net:** Triora makes the lock and the peg **as strong as the weakest of {custody key-configuration,
custodian governance, the control agreement, the attestation honesty}** — and binds the chain so that
**cBTC can never be minted beyond, or out-live, what those layers attest is locked.** The contracts make
the off-chain lock *legible and gating*; they do not — and by ADR-0001 must not — replace it.

---

## 8. Configuration requirements (the non-negotiables for a safe pledge)

1. **Borrower must not control the signing threshold alone** — Fordefi: AMINA is a required approver *and*
   in the admin quorum; BitGo: custodial/Go-Account (0 borrower keys) **or** AMINA holds a 2-of-3 key.
2. **Default-deny** — Fordefi default rule = Block/Require-Approval; BitGo `allTx`→`getApproval`.
3. **Destination allowlist** — only the borrower's return address + AMINA recovery address.
4. **Lock-removal requires AMINA** — Fordefi multi-group admin quorum; BitGo AMINA-`admin` + `lockDate`.
5. **Fail-closed everywhere** — stale attestation ⇒ mints blocked; webhook non-200 ⇒ deny.
6. **Continuous re-attestation + monitoring** — `isLockActive` freshness, balance vs supply, policy/quorum
   composition, voucher sequence, unacknowledged vouchers.
7. **One custodian, fully integrated, before adding a second** (v1). cBTC/cUSDC stay non-transferable.
