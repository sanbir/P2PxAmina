# Triora Core — Model B reference implementation

Institutional, custody-backed BTC→USDC borrowing on on-chain rails. This repo implements the
**Core (minimal-yet-prod-safe)** design from `docs/Triora-Core-Tech-Spec.md`, using the
**Model B** loan rail decided in `docs/Triora-Core-vs-Optional-3.md`: a `CollateralBridge`
over an isolated Morpho market, with custody-backed `cBTC`, on-chain Proof-of-Reserve
secure-mint, AMINA-gated objective liquidation, and state-derived release vouchers.

> Real BTC never enters a contract. It stays in a qualified custodian under a tri-party
> control agreement; the chain holds only the 1:1 restricted `cBTC` accounting token.
>
> The previous bilateral-escrow prototype (the `l1..l5` / `simple` layout) was replaced;
> it remains in git history.

## Architecture (`src/`)

| Layer | Contracts |
|-------|-----------|
| access | `RoleManager` (OZ AccessControl), `TrioraAccess` (role + pause base) |
| identity | `KYBGateway` |
| custody | `ICustodyAdapter`, `SignedCustodyAdapter` (dual custodian+AMINA EIP-712 attestations) |
| reserves | `ReserveGuard` (secure-mint: `supply ≤ min(sources) − margin`, fail-closed) |
| tokens | `PermissionedCollateralToken` (cBTC, 8 dec, transfer-restricted both-sides) |
| registry | `PledgeRegistry` (pledge↔cBTC↔deal), `PositionRegistry` (write-once terms) |
| oracle | `OracleAdapter` (Chainlink price + staleness + backing-ratio peg cap) |
| morpho | `IMorpho`, `IProtocolAdapter`, `MorphoAdapter`, `FixedRateIRM` |
| engine | `CollateralBridge` (per-borrower sub-ledger, full lifecycle) |
| liquidation | `LiquidationModule` (objective signed-report trigger + cure window + 2-report finalize) |
| settlement | `ReleaseAuthorizer` (state-derived one-use vouchers), `SettlementRouter` (event stream) |
| config | `RiskConfig` (versioned, ladder-validated params + archive) |
| lens | `PortfolioLens` |
| libraries | `Types`, `Errors`, `Roles`, `TrioraMath` |

### Lifecycle
`KYB → custody deposit + dual attestation → registerPledge → secure-mint cBTC to bridge →
openPosition (supply cBTC to Morpho, borrow USDC to borrower) → accrue (fixed APR) →
repay → state-derived release voucher → custody ack → burn cBTC → Closed`. Liquidation:
`objective oracle report + cure window → AMINA finalize → seize+surplus vouchers → surplus to borrower`.
AMINA's liquidation threshold is set strictly tighter than the Morpho LLTV, with Morpho's
permissionless liquidation as a backstop.

## Key invariants enforced
- `cBTC.totalSupply ≤ min(PoR, attestation) − margin` (secure-mint; fuzzed in `test/invariant/`)
- `mintedAmount ≤ pledgedAmount`; one active position per pledge
- cBTC moves only among allowlisted protocol addresses (both `from` and `to` checked)
- release destination derived from state (repay→borrower, liquidation→AMINA desk); vouchers one-use
- interest accrues only from `Active`; surplus on liquidation → borrower
- no role both moves collateral and sets risk params

## Test & build

```bash
forge build
forge test            # 51 tests: lifecycle, secure-mint, transfers, access, custody, liquidation, fuzz, invariant
forge test --gas-report
```

Tests use a deterministic `MockMorpho` + mock Chainlink feed (no RPC needed). The
`MorphoAdapter`/`IMorpho` seam is written so the production adapter binds the real Morpho
Blue `MarketParams`; fork tests against live Morpho can be added behind `MAINNET_RPC_URL`.

## Notes / scope
- Reference implementation: contracts are non-upgradeable + constructor/`wire`-bound for
  testability. Production wraps the engine in UUPS behind a timelock per the spec (S0.2 D-9).
- Reserve data source at launch = `SignedCustodyAdapter`; a Chainlink PoR / CRE `IReserveSource`
  drops in behind the same `ReserveGuard` interface (no mint-path re-audit).
- Optional/v2 (not in Core): bilateral OTC engine + cUSDC, loan-position token, ETH/SOL/RWA,
  multi-custodian, partial liquidation. See `docs/Triora-Core-vs-Optional-3.md`.
