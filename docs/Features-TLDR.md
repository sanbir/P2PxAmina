# P2PxAmina — Features TL;DR (per actor)

> One-minute read. What each actor can do, in plain product terms. Every item traces to the original product brief (`P2PxAmina-lending-protocol-for-banks.html`). Full detail lives in `User-flows.md`; the clickable mockup is `UI-mockup.html`.

**The product in one line:** a permissioned, bilateral, fixed-term crypto repo rail for institutions — lenders earn yield on USDC, borrowers raise USDC against tokenized BTC/ETH collateral, AMINA Bank brokers and de-risks it under its license, and assets never leave regulated custody.

| Actor | One-line role | Fee |
|---|---|---|
| **Lender** | Institutional cash provider — earns yield on USDC | — |
| **Borrower** | Institution raising USDC against real-asset collateral | — |
| **AMINA Bank** | Broker + Curator + Liquidator (regulated) | 20 bps + liquidation bonus |
| **P2P Staking** | Technology provider — the platform itself | 20 bps |
| **Custodian** | Holds assets, issues the tokens, settles redemptions | existing custody fee |

---

## Lender — main features

- **Onboard once** — submit KYB, link a custody account with tokenized USDC.
- **See the market** — current average rate and available borrow demand, at a glance.
- **Place a lend order** — pick amount, term, and supply token; see expected yield before committing.
- **Get matched automatically** — one order is matched across one or several borrowers behind the scenes.
- **Review and approve in one step** — confirm the matched terms with a single signature.
- **Hold one simple position** — see principal, rate, yield accruing, and days to maturity; the underlying deals stay hidden.
- **Stay private** — counterparties are never named; matches are shown as AMINA-verified and asset-backed.
- **Handle partial fills** — if only part of the order fills, the rest stays pending and visible.
- **Get repaid at maturity** — principal plus interest returns automatically.
- **Pull statements** — download position statements and activity history; receive notifications on fills and upcoming maturities.

## Borrower — main features

- **Onboard once** — submit KYB, link a custody account with tokenized collateral (BTC/ETH/etc.).
- **See the market** — current borrow rate and available liquidity.
- **Place a borrow order** — pick amount, collateral type, and term.
- **Preview collateral up front** — see required collateral, coverage (LTV, e.g. 85%), and max borrowable before committing.
- **Get matched and approve** — review matched terms and confirm with a single signature.
- **Receive cash** — USDC settled to you via custody.
- **Track the live loan** — collateral posted, outstanding balance, accrued interest, and a collateral-coverage (health) indicator.
- **Top up collateral** — add collateral anytime to improve coverage.
- **Repay early or in full** — partial or full repayment; collateral is released on full repay.
- **Manage margin calls safely** — warning at 85% with 48h to act, partial liquidation at 90%, full at 95% or at maturity; any surplus collateral is returned to you.
- **Stay private** — the lenders who funded you are never disclosed.

## AMINA Bank — main features (Broker + Curator + Liquidator)

- **Approve counterparties** — screen and approve KYB under its FINMA license (the only party that approves).
- **Broker the matches** — run matching legally under its Securities Dealer license.
- **Set the rates** — publish the base rate (revised about quarterly).
- **Set the risk parameters** — LTV and risk limits per issuer/asset.
- **Monitor the book** — risk-desk dashboards for portfolio risk, per-deal health, oracle status, cap utilisation, and the settlement queue.
- **Act on distress** — issue warnings, partial-liquidate, full-liquidate.
- **Recover instantly** — redeem seized collateral at custody, with no court process.
- **Earns** 20 bps plus a liquidation bonus.

## P2P Staking — main features (Technology Provider)

- **Operates the platform** — the app, matching engine, rate engine, order book, dashboards, and onboarding UI.
- **Collects onboarding data** — gathers KYB through the UI (but does **not** approve — AMINA does).
- **Routes settlement** — sends settlement instructions to custody and surfaces their status.
- **Provides the records** — statements, activity logs, and notifications for all users.
- **Never touches assets and makes no credit or risk decisions** — it is the rails, not a party to the loan.
- **Earns** 20 bps as an infrastructure fee.

## Custodian — main features (Token Issuer)

- **Holds the real assets** — BTC, ETH, USDC, stablecoins in segregated accounts.
- **Issues the tokens** — mints the supply token against lender USDC and the collateral token against borrower assets, 1:1 and attested.
- **Processes redemptions** — converts a supply token back into real USDC.
- **Executes settlement** — moves assets between custody accounts.
- **Anchors identity** — the KYC/KYB identity layer; only the custodian maps a wallet to a real entity.
- **Is the trust anchor** — the protocol itself never holds the real assets.
- **Earns** its existing custody fee.

---

**Not in v1** (future considerations from the brief §14): undercollateralized lending via debt-obligation tokens, a DeFi liquidity channel, and tokenized real-world-asset (RWA) collateral.
