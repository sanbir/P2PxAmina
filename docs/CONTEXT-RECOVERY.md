# P2PxAmina — Context Recovery Dump

**Generated**: 2026-06-09. Purpose: fast recovery of working state for this project (resume in a new session without re-deriving context). Read this first.

---

## 1. What the project is

**P2PxAmina** = a permissioned, bilateral, fixed-term **crypto tri-party repo rail for institutions**. Lenders earn yield on USDC; borrowers raise USDC against tokenized BTC/ETH collateral; **AMINA Bank** is the regulated broker + curator + liquidator (FINMA Securities Dealer license); **P2P Staking** is the technology provider (no asset custody, no credit decisions); **custodians** (BitGo / Fireblocks / AMINA-via-Tokeny / etc.) hold the real assets and issue the tokens. Assets never leave regulated custody. Fee split: 40 bps total = 20 bps P2P + 20 bps AMINA (+ AMINA liquidation bonus).

Original product brief (authoritative, mixed Russian/English): `docs/P2PxAmina-lending-protocol-for-banks.html`.

---

## 2. Document inventory (docs/)

| File | Purpose | Status |
|---|---|---|
| `P2PxAmina-lending-protocol-for-banks.html` | **Original product brief — the source of truth for scope** | given |
| `P2PxAmina-lending-protocol-for-banks-Contracts.html` | v0.1 architecture sketch (Claude) | done |
| `P2PxAmina-lending-protocol-for-banks-Implementation-Plan.md` | v0.2 implementation plan + peer-protocol research | done |
| `GPT-thoughts.md` / `Claude-thoughts-1.md` | critique exchange that shaped the design | done |
| `Claude-architechture-1/2/3.md` | Claude architecture passes; **v3 (Claude-architechture-3.md) is CANONICAL** | done |
| `GPT-architechture-1/2/3.md` | GPT's parallel architecture passes (cross-checked into Claude v2/v3) | done |
| `User-flows.md` | Product/UI user stories + use cases + 17 Mermaid diagrams + traceability matrix (49 stories, 26 UCs) | done |
| `Features-TLDR.md` | 1-minute per-actor feature list | done |
| `UI-mockup.html` | 3,211-line clickable mockup, 49 pages, persona switcher | done (v1; ~70 deferred items) |
| `tokenization-of-collateral.md` | **Collateral tokenization technical design** (pledge-bound mint, voucher-gated release) | done v0.1 |
| `tokenization-of-collateral-state-of-the-art.md` | SOTA research report on BTC/RWA/non-EVM tokenization | **IN FLIGHT — workflow wtpri7fjj** |
| `CONTEXT-RECOVERY.md` | this file | — |

> Note: there are TWO architecture lineages (Claude-* and GPT-*) that were cross-checked against each other. **Claude-architechture-3.md is the canonical merged architecture (v0.5).** GPT-architechture-3.md exists (103KB) but Claude v3 already folded in GPT's accepted deltas.

---

## 3. Contract scaffold (src/) — built, compiles

Foundry project. `pragma solidity 0.8.28`, OZ upgradeable, ERC-7201 namespaced storage. Git: initial commit `b5b3eff "Initial implementation of P2PxAmina v0.5"`.

```
src/interfaces/   I{CollateralRegistry,ComplianceRegistry,DealRegistry,DefaultPassHook,
                    EscrowVault,IssuerRegistry,KYBGateway,LendingEngine,ParameterArchive,SettlementRouter}.sol
src/l1/           RoleManager, KYBGateway, IssuerRegistry, ComplianceRegistry, DefaultPassHook
src/l2/           CollateralRegistry, ParameterArchive (immutable)
src/l3/           DealRegistry (immutable), EscrowVault (immutable), LendingEngine (UUPS+timelock)
src/l4/           LiquidationHandler (UUPS+timelock), SettlementRouter
src/l5/           PortfolioLens (immutable)
src/libraries/    EIP712Hashes, Errors, Math, Roles, Types
src/test_hooks/   BlockingPreHook, FrozenToken, RevertingPostHook
```

**Immutable contracts (7):** DealRegistry, EscrowVault, ParameterArchive, DefaultPassHook, PortfolioLens, RoleManager, SettlementRouter.
**UUPS (6):** KYBGateway, IssuerRegistry, ComplianceRegistry, CollateralRegistry, LendingEngine, LiquidationHandler.

Key built behaviors verified by reading source:
- `IssuerRegistry`: `runAdmissionChecks` (transfer-exactness — rejects fee-on-transfer/rebasing), `TokenKind {Unknown,Supply,Collateral,DualUse_DisabledByDefault}`, caps via `chargeCap`/`releaseCap`, `legalAttestationHash` + `redemptionAttestationHash`.
- `EscrowVault`: immutable, per-deal ledger `_balanceOf[dealId][token]` + `_ledgerSum`, `pull`/`credit`/`debit`, **`tryReleaseCollateral` (non-reverting, returns `ISSUER_FREEZE`)**, `getUnattributedBalance`/`sweepUnattributedBalance` (governor only), `onlyEngine`.

---

## 4. Canonical design decisions

1. **Architecture canon** = `Claude-architechture-3.md` (v0.5). 13 contracts, 8 roles, 21 invariants, 5 pause tiers, 9 cap dimensions.
2. **Roles (8):** GOVERNOR (P2P 3/5), EMERGENCY (joint P2P+AMINA 2/2), CURATOR (AMINA risk 2/3), ALLOCATOR (AMINA matching hot wallet), LIQUIDATOR (AMINA bots), GUARDIAN (AMINA OPS), OPS, ORACLE_ADMIN. Hot keys can reduce risk/pause, never increase exposure.
3. **Atomic settlement** — `openAndActivate` is all-or-nothing; no `Pending` deal state.
4. **Collateral tokenization design** (`tokenization-of-collateral.md`): **pledge-bound mint, voucher-gated release.** On-chain deal state is the only thing that unlocks BTC; AMINA is mandatory co-signer on the custody door. Release destination is fixed by state (Repaid→borrower, Liquidated→AMINA, Active→nobody). New contracts proposed: `PledgeRegistry`, permissioned collateral-token template, `ICollateralCustodyAdapter`, voucher extension to `SettlementRouter`.

---

## 5. User-stated constraints (must honor)

- **No existing BTC wrappers** (no WBTC/LBTC/cbBTC). Each custodian tokenizes on its own platform.
- **No path to move the underlying asset out except via liquidation.**
- **Only AMINA can liquidate.** AMINA has custody access (lien holder).
- Must **extend to ETH and RWA**.
- **Custodian is a distinct role** in the brief (§6 "Supply Token issuer = Custodian (AMINA / Fireblocks / etc.)") — confirmed against source; AMINA may also BE the custodian in the simplest deployment.
- User-facing docs (User-flows, mockup) = **product/UI perspective, not deep tech**. Technical docs (architecture, tokenization) = full technical depth.
- Every user story/use case must **trace to the original brief** (fidelity is the top gate).

---

## 6. In-flight / background work

**Workflow `wtpri7fjj`** (run id `wf_38528d0d-92b`) — SOTA tokenization research report.
- Output: `docs/tokenization-of-collateral-state-of-the-art.md` (NOT yet written).
- 9 parallel research agents → opus author → 3 reviewers (accuracy re-verify / completeness / P2P-relevance) → finalizer.
- Resume if needed: `Workflow({scriptPath: "<session>/workflows/scripts/tokenization-sota-research-wf_38528d0d-92b.js", resumeFromRunId: "wf_38528d0d-92b"})`
- On completion: spot-check line count, sources section, §3 (custody mint) and §12 (P2PxAmina implications).

---

## 7. Completed workflows (this session)

- **UI mockup** (`wv4oaq1g7`): wrote `UI-mockup.html` (3,211 lines, 49 routes, persona switcher, EIP-712-style signing screens, HF gauges, top-up/repay/liquidation flows). 27 review fixes applied; ~70 items DEFERRED to v2 (empty states, AMINA OPS persona, maturity-notification inbox, partial-repay slider, sign-in role fork, role-fork at o1, position context propagation).
- **User-flows** (`wyzwu7hrr`, resumed from `wf_1b29ea3a-74f`): wrote `User-flows.md` (1,219 lines). Originally tech-framed; STOPPED and relaunched with product/UI lens after user instruction. Fidelity verdict HIGH; removed several invented mechanics; no leaked contract names/emoji (grep-verified).

---

## 8. Environment / tooling changes (this session)

- **CLI upgraded** to v2.1.150 at `~/.local/bin/claude` (via `claude install latest`). Old `/usr/local/bin/claude` is v2.1.68 (root-owned, npm). **PATH caveat:** `claude` resolves to the OLD one unless `~/.local/bin` precedes `/usr/local/bin` in PATH, or you `sudo npm i -g @anthropic-ai/claude-code@latest`. The new CLI was needed because the old one rejects the new `.claude-plugin/marketplace.json` schema.
- **Plugins installed (user scope):**
  - `superpowers@superpowers-marketplace` (added marketplace `obra/superpowers-marketplace`)
  - `code-simplifier@claude-plugins-official` (re-added the official marketplace with the new CLI)
  - `frontend-design@claude-plugins-official`
  - **GSD (get-shit-done-redux)** via `npx @opengsd/get-shit-done-redux@latest --claude --global` — 67 skills + hooks into `~/.claude/`, `gsd-sdk` linked at `~/.local/bin/gsd-sdk`. (Full profile; can slim with `--profile=core`.) Many `gsd-*` skills now show in the skill list.
- New plugins/agents activate on Claude Code restart; GSD skills already live (plain files).

---

## 9. Open threads / offered-but-not-done

1. Fold `Features-TLDR.md` into `User-flows.md` as an opening section (offered).
2. Pick up the ~70 deferred UI-mockup items (v2 pass).
3. Cross-link mockup `#meta` page ↔ `User-flows.md` ↔ `Features-TLDR.md`.
4. Adversarial security review (red-team) of the pledge + voucher mechanism in `tokenization-of-collateral.md` (offered).
5. Implement Phase A of tokenization: `IPledgeRegistry` + `PledgeRegistry.sol` + `SettlementRouter` voucher extension + tests (offered).
6. After research report lands: reconcile its §12 recommendations back into `tokenization-of-collateral.md` if it surfaces new techniques to adopt.

---

## 10. Quick orientation for a fresh session

1. Read this file.
2. Read `docs/P2PxAmina-lending-protocol-for-banks.html` (the brief) + `docs/Claude-architechture-3.md` (canonical arch).
3. For collateral/custody work: `docs/tokenization-of-collateral.md` (+ the SOTA report once `wtpri7fjj` finishes).
4. Code is in `src/` (Foundry); `Claude-architechture-3.md` §5 maps every contract.
5. Check running workflows with `/workflows`; resume command for the research report is in §6 above.
