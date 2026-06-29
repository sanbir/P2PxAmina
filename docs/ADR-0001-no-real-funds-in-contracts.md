# ADR-0001 — Real assets never touch a contract (Model A is Core). **HARD INVARIANT.**

- **Status:** Accepted — **supersedes the Model-B "CollateralBridge over Morpho" decision** in
  `Triora-Core-Tech-Spec.md` (S0.2 D-1/D-2/D-3) and `Triora-Core-vs-Optional-3.md` (Part 1).
- **Date:** 2026-06-29
- **Decided by:** product owner (absolute requirement)

## The invariant (non-negotiable)

> **Real assets — BTC, ETH, and USDC — stay in regulated custody wallets at all times and MUST
> NEVER be held, custodied, routed, or transferred by any Triora smart contract. The only movement
> of real value is a single, direct custody-to-custody transfer (lender custody → borrower custody
> at funding; borrower custody → lender custody at repayment; custody → AMINA desk at liquidation),
> executed OFF-CHAIN under AMINA's mandatory co-signature. On-chain, Triora is a pure ledger that
> operates ONLY restricted accounting tokens (cBTC, cUSDC) and signed settlement instructions/acks.**

A contract that takes custody of, or transfers, a real ERC-20 of value (e.g. real USDC) is a
**violation of this ADR** and a build defect.

## Why (the consequences this protects)

1. **Regulatory posture.** Touching client funds makes P2P a custodian / money-transmitter — exactly
   the classification Triora's four-party split exists to avoid. The contract must remain "not a
   custodian in any layer" (canonical `Triora.html`).
2. **Counterparty/smart-contract risk.** Lender USDC must not sit in a DeFi pool or a Triora
   contract; it sits in the lender's own qualified custody until the single co-signed settlement.
3. **Settlement reliability comes from AMINA (a regulated co-signer), not from contract code** — the
   BNY-Mellon tri-party model. The "off-chain settlement" is the design, not a gap.

## What this rejects

- **Model B (`CollateralBridge` over Morpho) is removed from Core.** Borrowing real USDC from an
  on-chain Morpho pool and routing it through a bridge **violates the invariant** (USDC lives in a
  contract and transits ours). Morpho/on-chain-liquidity becomes an **explicitly opt-in OPTIONAL
  connector** for borrowers who knowingly accept DeFi-liquidity posture — never the Core, never the
  default, and clearly labelled as leaving the pure-custody model.

## What Core becomes (Model A — pure tri-party ledger)

The on-chain engine is a **settlement-instruction state machine** over accounting tokens:

- `cBTC` — borrower's collateral claim (1:1, custody-attested, secure-minted). Held by the borrower; posted to a deal.
- `cUSDC` — lender's **reservation** of their own custodied USDC (1:1, custody-attested, secure-minted). NOT real USDC, never accepted as settlement. Held by the lender; posted to a deal; **burned at funding** (the real USDC has moved in custody).
- The engine pulls/locks these accounting tokens, records the deal, and **emits settlement
  instructions**. Real USDC moves once, custody→custody, off-chain, AMINA-co-signed; a **dual
  (custodian + AMINA) signed ack** drives the on-chain state to `Active` (interest starts only then).
- Repayment + collateral release + liquidation all run as signed instructions/acks + state-derived
  release vouchers for the cBTC claim. **No contract ever holds or moves real USDC or real BTC.**

The custody-tokenization safety spine is unchanged and still mandatory: dual-signed custody
attestations (`SignedCustodyAdapter`), secure-mint reserve guard (`ReserveGuard`), pledge/reserve
binding, KYB gate, objective oracle-gated liquidation with cure window + surplus-to-borrower,
state-derived one-use release vouchers, role separation, monitoring.

## Enforcement (how the invariant is made true, not just asserted)

- The Core engine and every Core contract import **no real-value ERC-20** (no real USDC address).
  The only `IERC20` instances they touch are `PermissionedCollateralToken` (cBTC) and
  `ReserveToken` (cUSDC) — both restricted accounting tokens that are valueless off the ledger.
- Test/invariant: assert no Core contract holds a nonzero balance of any token other than cBTC/cUSDC,
  and that real settlement is represented only by signed acks + `SettlementRouter` events.
- `grep` gate in CI: no `import {IERC20}` of a real stablecoin, no Morpho imports, in `src/` Core.

## Migration

- Remove `CollateralBridge`, `MorphoAdapter`, `FixedRateIRM`, `IMorpho`/`IProtocolAdapter` from Core.
- Add `ReserveToken` (cUSDC), `ReserveRegistry` (lender reserves), `SettlementAcker` (dual-signed
  funding/repayment acks), and replace the bridge with `LendingEngine` (Model A).
- Adjust the restricted-token transfer rule to **"at least one side is a protocol address (engine/
  vault)"** so counterparties can post/withdraw accounting tokens to/from the engine (user↔user still
  blocked). (The Model-B "both sides protocol" rule was an artifact of cBTC only ever living among
  protocol contracts; it does not fit the counterparty-held ledger model.)
- Spec + ADRs updated; Triora/docs/ADR-0002 Morpho-self-deploy decision is downgraded to the
  optional connector track.
