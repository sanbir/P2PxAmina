// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {RoleManager} from "../src/access/RoleManager.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {Types} from "../src/libraries/Types.sol";
import {KYBGateway} from "../src/identity/KYBGateway.sol";
import {SignedCustodyAdapter} from "../src/custody/SignedCustodyAdapter.sol";
import {ReserveGuard} from "../src/reserves/ReserveGuard.sol";
import {PledgeRegistry} from "../src/registry/PledgeRegistry.sol";
import {ReserveRegistry} from "../src/registry/ReserveRegistry.sol";
import {PositionRegistry} from "../src/registry/PositionRegistry.sol";
import {PermissionedCollateralToken} from "../src/tokens/PermissionedCollateralToken.sol";
import {ReserveToken} from "../src/tokens/ReserveToken.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {RiskConfig} from "../src/config/RiskConfig.sol";
import {SettlementRouter} from "../src/settlement/SettlementRouter.sol";
import {ReleaseAuthorizer} from "../src/settlement/ReleaseAuthorizer.sol";
import {SettlementAcker} from "../src/settlement/SettlementAcker.sol";
import {LendingEngine} from "../src/engine/LendingEngine.sol";
import {LiquidationModule} from "../src/liquidation/LiquidationModule.sol";
import {PortfolioLens} from "../src/lens/PortfolioLens.sol";
import {IReserveSource} from "../src/interfaces/ITriora.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";

/// @notice Deploys the full Triora Core (MODEL A — ADR-0001: no real funds in contracts) to a LOCAL
///         chain (anvil): pure ledger over cBTC/cUSDC + a settable mock price feed. Wires roles, creates
///         the market, and writes {OUT_DIR}/addresses.local.json + keys.local.json for the off-chain stack.
contract DeployLocal is Script {
    uint256 constant GOVERNOR_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant CURATOR_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant ALLOCATOR_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant LIQUIDATOR_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 constant ISSUER_PK = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 constant SETTLEMENT_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 constant CUSTODIAN_SIGNER_PK = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    uint256 constant AMINA_SIGNER_PK = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
    uint256 constant ORACLE_SIGNER_PK = 0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;
    uint256 constant BORROWER_PK = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
    uint256 constant LENDER_PK = 0xf214f2b2cd398c806f84e317254e0f0b801d0643303237d97a22a48e01628897;

    function run() external {
        address governor = vm.addr(GOVERNOR_PK);
        address custodianSigner = vm.addr(CUSTODIAN_SIGNER_PK);
        address aminaSigner = vm.addr(AMINA_SIGNER_PK);
        address oracleSigner = vm.addr(ORACLE_SIGNER_PK);
        address aminaDesk = vm.addr(CURATOR_PK);
        bytes32 marketId = keccak256("cBTC/USDC");

        vm.startBroadcast(GOVERNOR_PK);

        RoleManager rm = new RoleManager(governor);
        KYBGateway kyb = new KYBGateway(address(rm));
        SignedCustodyAdapter custody = new SignedCustodyAdapter(address(rm), custodianSigner, aminaSigner);
        ReserveGuard guard = new ReserveGuard(address(rm));
        PledgeRegistry pledges = new PledgeRegistry(address(rm));
        ReserveRegistry reserves = new ReserveRegistry(address(rm));
        PositionRegistry positions = new PositionRegistry(address(rm));
        ReleaseAuthorizer release = new ReleaseAuthorizer(address(rm));
        PermissionedCollateralToken cbtc = new PermissionedCollateralToken(address(rm));
        ReserveToken cusdc = new ReserveToken(address(rm));
        OracleAdapter oracle = new OracleAdapter(address(rm), address(cbtc), address(custody));
        MockAggregator feed = new MockAggregator(8, int256(100000 * 1e8), block.timestamp);
        RiskConfig risk = new RiskConfig(address(rm));
        SettlementRouter router = new SettlementRouter(address(rm));
        LendingEngine engine = new LendingEngine(address(rm), aminaDesk);
        SettlementAcker acker = new SettlementAcker(address(rm), address(engine), custodianSigner, aminaSigner);
        LiquidationModule module =
            new LiquidationModule(address(rm), address(engine), address(risk), marketId, oracleSigner);
        PortfolioLens lens = new PortfolioLens(address(engine), address(pledges));

        rm.grantRole(Roles.CURATOR, governor);
        rm.grantRole(Roles.CURATOR, vm.addr(CURATOR_PK));
        rm.grantRole(Roles.ALLOCATOR, vm.addr(ALLOCATOR_PK));
        rm.grantRole(Roles.LIQUIDATOR, vm.addr(LIQUIDATOR_PK));
        rm.grantRole(Roles.ISSUER_MINTER, vm.addr(ISSUER_PK));
        rm.grantRole(Roles.SETTLEMENT, vm.addr(SETTLEMENT_PK));
        rm.grantRole(Roles.GUARDIAN, vm.addr(CURATOR_PK));
        rm.grantRole(Roles.EMERGENCY, vm.addr(CURATOR_PK));
        rm.grantRole(Roles.ORACLE_ADMIN, governor);
        rm.grantRole(Roles.ENGINE, address(engine));
        rm.grantRole(Roles.LIQUIDATION_MODULE, address(module));
        rm.grantRole(Roles.TOKEN, address(cbtc));
        rm.grantRole(Roles.TOKEN, address(cusdc));

        pledges.bind(address(custody), address(cbtc));
        reserves.bind(address(custody), address(cusdc));
        cbtc.bind(address(guard), address(pledges), address(release));
        cusdc.bind(address(guard), address(reserves));
        cbtc.setProtocol(address(engine), true);
        cusdc.setProtocol(address(engine), true);
        engine.wire(
            LendingEngine.Wiring({
                kyb: address(kyb),
                pledges: address(pledges),
                reserves: address(reserves),
                cbtc: address(cbtc),
                cusdc: address(cusdc),
                oracle: address(oracle),
                releaseAuth: address(release),
                router: address(router),
                riskConfig: address(risk),
                positions: address(positions),
                acker: address(acker),
                marketId: marketId
            })
        );

        ReserveGuard.Policy memory pol = ReserveGuard.Policy({
            primary: IReserveSource(address(custody)),
            secondary: IReserveSource(address(0)),
            maxAge: 1 days,
            marginBps: 50,
            maxDiscrepancyBps: 0,
            active: true
        });
        guard.setReservePolicy(address(cbtc), pol);
        guard.setReservePolicy(address(cusdc), pol);
        risk.setMarket(
            marketId,
            Types.MarketParams({
                ltvBps: 7000,
                aminaWarningBps: 7500,
                aminaLiquidationBps: 7800,
                cureWindowSecs: 1 days,
                maxRateBps: 2000,
                maxMaturity: 365 days,
                liquidationBonusBps: 500,
                aminaFeeBps: 100,
                perBorrowerCapUsdc: 100000000e6,
                marketCapUsdc: 1000000000e6,
                active: true
            })
        );
        oracle.setFeed(address(feed), 1 hours);

        vm.stopBroadcast();

        _writeAddresses(
            address(rm),
            address(kyb),
            address(custody),
            address(guard),
            address(pledges),
            address(reserves),
            address(positions),
            address(cbtc),
            address(cusdc),
            address(oracle),
            address(feed),
            address(engine),
            address(acker),
            address(module),
            address(release),
            address(router),
            address(risk),
            address(lens),
            marketId
        );
        _writeKeys();
    }

    function _writeAddresses(
        address rm,
        address kyb,
        address custody,
        address guard,
        address pledges,
        address reserves,
        address positions,
        address cbtc,
        address cusdc,
        address oracle,
        address feed,
        address engine,
        address acker,
        address module,
        address release,
        address router,
        address risk,
        address lens,
        bytes32 marketId
    ) internal {
        string memory o = "addr";
        vm.serializeString(o, "network", "local");
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "model", "A");
        vm.serializeAddress(o, "roleManager", rm);
        vm.serializeAddress(o, "kybGateway", kyb);
        vm.serializeAddress(o, "custodyAdapter", custody);
        vm.serializeAddress(o, "reserveGuard", guard);
        vm.serializeAddress(o, "pledgeRegistry", pledges);
        vm.serializeAddress(o, "reserveRegistry", reserves);
        vm.serializeAddress(o, "positionRegistry", positions);
        vm.serializeAddress(o, "cbtc", cbtc);
        vm.serializeAddress(o, "cusdc", cusdc);
        vm.serializeAddress(o, "oracleAdapter", oracle);
        vm.serializeAddress(o, "priceFeed", feed);
        vm.serializeAddress(o, "lendingEngine", engine);
        vm.serializeAddress(o, "settlementAcker", acker);
        vm.serializeAddress(o, "liquidationModule", module);
        vm.serializeAddress(o, "releaseAuthorizer", release);
        vm.serializeAddress(o, "settlementRouter", router);
        vm.serializeAddress(o, "riskConfig", risk);
        vm.serializeAddress(o, "portfolioLens", lens);
        string memory out = vm.serializeBytes32(o, "marketId", marketId);
        vm.writeJson(out, string.concat(vm.envString("OUT_DIR"), "/addresses.local.json"));
    }

    function _writeKeys() internal {
        string memory k = "keys";
        vm.serializeBytes32(k, "deployer", bytes32(GOVERNOR_PK));
        vm.serializeBytes32(k, "curator", bytes32(CURATOR_PK));
        vm.serializeBytes32(k, "allocator", bytes32(ALLOCATOR_PK));
        vm.serializeBytes32(k, "liquidator", bytes32(LIQUIDATOR_PK));
        vm.serializeBytes32(k, "issuerMinter", bytes32(ISSUER_PK));
        vm.serializeBytes32(k, "settlement", bytes32(SETTLEMENT_PK));
        vm.serializeBytes32(k, "custodianSigner", bytes32(CUSTODIAN_SIGNER_PK));
        vm.serializeBytes32(k, "aminaSigner", bytes32(AMINA_SIGNER_PK));
        vm.serializeBytes32(k, "oracleSigner", bytes32(ORACLE_SIGNER_PK));
        vm.serializeBytes32(k, "borrower", bytes32(BORROWER_PK));
        string memory out = vm.serializeBytes32(k, "lender", bytes32(LENDER_PK));
        vm.writeJson(out, string.concat(vm.envString("OUT_DIR"), "/keys.local.json"));
    }
}
