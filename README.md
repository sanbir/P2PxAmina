# P2PxAmina — Repo Rail (Foundry implementation)

Implementation of `docs/Claude-architechture-3.md` v0.5: a permissioned,
bilateral, fixed-term repo rail for institutional crypto lending.

## Contract inventory (13)

| Layer | Contract | Pattern | LOC |
|-------|----------|---------|-----|
| L1 | RoleManager | Immutable (OZ AccessManager) | ~10 |
| L1 | DefaultPassHook | Immutable | 31 |
| L1 | KYBGateway | UUPS | 88 |
| L1 | IssuerRegistry | UUPS | 262 |
| L1 | ComplianceRegistry | UUPS | 103 |
| L2 | ParameterArchive | Immutable | 55 |
| L2 | CollateralRegistry | UUPS | 147 |
| L3 | DealRegistry | Immutable | 51 |
| L3 | EscrowVault | Immutable | 161 |
| L3 | LendingEngine | UUPS + timelock | 729 |
| L4 | LiquidationHandler | UUPS + timelock | 303 |
| L4 | SettlementRouter | Immutable / versioned | 167 |
| L5 | PortfolioLens | Immutable | 53 |
| | **shared libs / interfaces / errors / types** | | ~470 |
| | **total** | | **~2,810** |

## Build

```shell
forge build
```

## Test (mainnet fork, no mocks)

Tests run against a live Ethereum mainnet fork using real USDC / USDT /
WBTC / WETH tokens and real Chainlink price feeds. They follow the HEAD
of the chain by default, but you can pin a specific block via
`FORK_BLOCK`. For private archive RPCs (better latency, no pruning) set
`MAINNET_RPC_URL`:

```shell
export MAINNET_RPC_URL=...           # optional; defaults to publicnode
export FORK_BLOCK=25192800           # optional; defaults to HEAD
forge test
```

### Test coverage (65 fork tests, 9 suites)

| Suite | Scope |
|-------|-------|
| `HappyPathTest` | Full open → accrue → repay cycle (USDC/WBTC); top-ups; partial repay |
| `LiquidationFlowTest` | warn / partial / full liquidation; attestation safety |
| `SafetyChecksTest` | Access control, replay protection, KYB, caps, pause clock |
| `AdmissionTest` | D22 transfer-exactness for USDC/USDT/WBTC; dual-use disabled by default |
| `RiskAndOracleTest` | D15 ParameterArchive schema versioning, D16 oracle override sidecar, D17 unattributed balance, PortfolioLens, SettlementRouter |
| `ComplianceHooksTest` | Pre-hook blocking, post-hook non-rollback |
| `MultiPairTest` | WETH-collateral + USDT-supply with 18/6-decimal asymmetry |
| `RecoveryFlowTest` | `Repaid_PendingCollateralRelease` recovery state for issuer freeze (F12) |
| `InvariantSpotChecksTest` | Spot checks of canonical invariants 1, 2, 5, 7, 8, 11, 15, 18, 19, 20 |

**No `vm.mockCall` anywhere.** Tokens are real mainnet ERC-20s funded
with `vm.deal` (or, where stdStorage can't probe, via the token's own
`mint`/`deposit`). Prices come from live Chainlink aggregators.
Liquidation tests sign their own dual-price attestation against the
real EIP-712 domain — no oracle mocking.

## Deploy

```shell
forge script script/Deploy.s.sol --broadcast --rpc-url $MAINNET_RPC_URL
```

The script follows the deployment order in `docs/Claude-architechture-3.md` §24:
RoleManager → DefaultPassHook → KYBGateway → IssuerRegistry → ComplianceRegistry
→ ParameterArchive → CollateralRegistry → DealRegistry → EscrowVault →
SettlementRouter → LendingEngine → LiquidationHandler → PortfolioLens, with the
necessary `bindEngine` / `router.bind` / `issuers.bindEngine` glue.
