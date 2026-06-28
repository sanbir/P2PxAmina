// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "../src/access/RoleManager.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {Types} from "../src/libraries/Types.sol";
import {KYBGateway} from "../src/identity/KYBGateway.sol";
import {SignedCustodyAdapter} from "../src/custody/SignedCustodyAdapter.sol";
import {ReserveGuard} from "../src/reserves/ReserveGuard.sol";
import {PledgeRegistry} from "../src/registry/PledgeRegistry.sol";
import {PositionRegistry} from "../src/registry/PositionRegistry.sol";
import {PermissionedCollateralToken} from "../src/tokens/PermissionedCollateralToken.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {FixedRateIRM} from "../src/morpho/FixedRateIRM.sol";
import {MorphoAdapter} from "../src/morpho/MorphoAdapter.sol";
import {RiskConfig} from "../src/config/RiskConfig.sol";
import {SettlementRouter} from "../src/settlement/SettlementRouter.sol";
import {ReleaseAuthorizer} from "../src/settlement/ReleaseAuthorizer.sol";
import {CollateralBridge} from "../src/engine/CollateralBridge.sol";
import {LiquidationModule} from "../src/liquidation/LiquidationModule.sol";
import {PortfolioLens} from "../src/lens/PortfolioLens.sol";
import {IReserveSource} from "../src/interfaces/ITriora.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockMorpho} from "./mocks/MockMorpho.sol";

/// @notice Deploys + wires the full Triora Core (Model B) and provides EIP-712 signing helpers.
abstract contract TrioraFixture is Test {
    // actors
    address internal amina = makeAddr("amina");
    address internal issuer = makeAddr("issuer");
    address internal aminaBot = makeAddr("aminaBot");
    address internal custodyListener = makeAddr("custodyListener");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal aminaTreasury = makeAddr("aminaTreasury");
    address internal aminaDesk = makeAddr("aminaDesk");
    address internal stranger = makeAddr("stranger");

    uint256 internal custodianPk = 0xA11CE;
    uint256 internal aminaSignerPk = 0xB0B;
    uint256 internal oraclePk = 0xC0FFEE;
    address internal custodianSigner;
    address internal aminaSigner;
    address internal oracleSigner;

    // contracts
    RoleManager internal rm;
    KYBGateway internal kyb;
    SignedCustodyAdapter internal custody;
    ReserveGuard internal guard;
    PledgeRegistry internal pledges;
    PositionRegistry internal positions;
    PermissionedCollateralToken internal cbtc;
    OracleAdapter internal oracle;
    MockAggregator internal feed;
    FixedRateIRM internal irm;
    MockMorpho internal morpho;
    MorphoAdapter internal adapter;
    RiskConfig internal risk;
    SettlementRouter internal router;
    ReleaseAuthorizer internal release;
    CollateralBridge internal bridge;
    LiquidationModule internal module;
    PortfolioLens internal lens;
    MockERC20 internal usdc;

    bytes32 internal marketId = keccak256("cBTC/USDC");
    uint256 internal constant BTC_PRICE_1E8 = 100000 * 1e8; // $100,000
    uint32 internal constant RATE_BPS = 500; // 5% fixed APR

    function setUp() public virtual {
        vm.warp(1700000000);
        custodianSigner = vm.addr(custodianPk);
        aminaSigner = vm.addr(aminaSignerPk);
        oracleSigner = vm.addr(oraclePk);

        rm = new RoleManager(address(this)); // test contract = GOVERNOR
        kyb = new KYBGateway(address(rm));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        custody = new SignedCustodyAdapter(address(rm), custodianSigner, aminaSigner);
        guard = new ReserveGuard(address(rm));
        pledges = new PledgeRegistry(address(rm));
        positions = new PositionRegistry(address(rm));
        release = new ReleaseAuthorizer(address(rm));
        cbtc = new PermissionedCollateralToken(address(rm));
        oracle = new OracleAdapter(address(rm), address(cbtc), address(custody));
        feed = new MockAggregator(8, int256(BTC_PRICE_1E8), block.timestamp);
        irm = new FixedRateIRM(RATE_BPS);
        morpho = new MockMorpho(address(cbtc), address(usdc), address(irm));
        adapter = new MorphoAdapter(address(rm), address(morpho), address(cbtc), address(usdc));
        risk = new RiskConfig(address(rm));
        router = new SettlementRouter(address(rm));
        bridge = new CollateralBridge(address(rm), address(usdc), aminaTreasury, aminaDesk);
        module = new LiquidationModule(address(rm), address(bridge), address(risk), marketId, oracleSigner);
        lens = new PortfolioLens(address(bridge), address(pledges));

        _grantRoles();
        _wire();
        _config();
    }

    function _grantRoles() internal {
        rm.grantRole(Roles.CURATOR, address(this));
        rm.grantRole(Roles.CURATOR, amina);
        rm.grantRole(Roles.ALLOCATOR, amina);
        rm.grantRole(Roles.ORACLE_ADMIN, address(this));
        rm.grantRole(Roles.ISSUER_MINTER, issuer);
        rm.grantRole(Roles.LIQUIDATOR, aminaBot);
        rm.grantRole(Roles.SETTLEMENT, custodyListener);
        rm.grantRole(Roles.GUARDIAN, amina);
        rm.grantRole(Roles.EMERGENCY, amina);
        rm.grantRole(Roles.ENGINE, address(bridge));
        rm.grantRole(Roles.LIQUIDATION_MODULE, address(module));
        rm.grantRole(Roles.TOKEN, address(cbtc));
    }

    function _wire() internal {
        pledges.bind(address(custody), address(cbtc));
        cbtc.bind(address(guard), address(pledges), address(release));
        cbtc.setProtocol(address(bridge), true);
        cbtc.setProtocol(address(adapter), true);
        cbtc.setProtocol(address(morpho), true); // the isolated market holds cBTC collateral
        bridge.wire(
            CollateralBridge.Wiring({
                kyb: address(kyb),
                pledges: address(pledges),
                cbtc: address(cbtc),
                adapter: address(adapter),
                oracle: address(oracle),
                releaseAuth: address(release),
                router: address(router),
                riskConfig: address(risk),
                positions: address(positions),
                marketId: marketId
            })
        );
    }

    function _config() internal {
        guard.setReservePolicy(
            address(cbtc),
            ReserveGuard.Policy({
                primary: IReserveSource(address(custody)),
                secondary: IReserveSource(address(0)),
                maxAge: 1 days,
                marginBps: 50,
                maxDiscrepancyBps: 0,
                active: true
            })
        );
        risk.setMarket(
            marketId,
            Types.MarketParams({
                ltvBps: 7000,
                aminaWarningBps: 7500,
                aminaLiquidationBps: 7800,
                morphoLltvBps: 8000,
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
        kyb.setStatus(borrower, KYBGateway.Status.Approved, 0, bytes32("CH"), bytes32("docs"));
        oracle.setFeed(address(feed), 1 hours);
        usdc.mint(address(morpho), 10000000e6); // lender USDC liquidity in the market
    }

    // ── EIP-712 signing helpers ────────────────────────────────────────────────

    function _domainSep(string memory name, string memory version, address verifying) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifying
            )
        );
    }

    function _dualSign(bytes32 structHash, address verifying)
        internal
        view
        returns (bytes memory custSig, bytes memory amSig)
    {
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _domainSep("TrioraCustodyAdapter", "1", verifying), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(custodianPk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aminaSignerPk, digest);
        custSig = abi.encodePacked(r1, s1, v1);
        amSig = abi.encodePacked(r2, s2, v2);
    }

    function attestReserve(uint256 amount8) internal {
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "ReserveProof(address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt)"
                ),
                address(cbtc),
                amount8,
                uint8(8),
                uint64(block.timestamp),
                uint64(block.timestamp + 1 days)
            )
        );
        (bytes memory cs, bytes memory as_) = _dualSign(sh, address(custody));
        custody.submitReserveProof(
            address(cbtc), amount8, 8, uint64(block.timestamp), uint64(block.timestamp + 1 days), cs, as_
        );
    }

    function attestPledge(bytes32 pledgeId, uint256 amount8) internal {
        SignedCustodyAdapter.PledgeProof memory p = SignedCustodyAdapter.PledgeProof({
            custodyAccountRef: bytes32("acct-1"),
            token: address(cbtc),
            amount: amount8,
            decimals: 8,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days),
            controlAgreementHash: bytes32("ctrl")
        });
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "PledgeProof(bytes32 pledgeId,bytes32 custodyAccountRef,address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt,bytes32 controlAgreementHash)"
                ),
                pledgeId,
                p.custodyAccountRef,
                p.token,
                p.amount,
                p.decimals,
                p.observedAt,
                p.expiresAt,
                p.controlAgreementHash
            )
        );
        (bytes memory cs, bytes memory as_) = _dualSign(sh, address(custody));
        custody.submitPledgeProof(pledgeId, p, cs, as_);
    }

    /// @notice Full collateral path: attest reserve+pledge, register pledge, mint cBTC to the bridge.
    function setupPledgeAndMint(bytes32 pledgeId, address owner, uint256 amount8) internal {
        attestReserve(amount8 * 100); // ample reserve
        attestPledge(pledgeId, amount8);
        vm.prank(amina);
        pledges.registerPledge(pledgeId, owner, bytes32("acct-1"), amount8, bytes32("ctrl"));
        vm.prank(issuer);
        cbtc.mintForPledge(address(bridge), pledgeId, amount8);
    }

    function signLiqReport(LiquidationModule.LiquidationReport memory r) internal view returns (bytes memory) {
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "LiquidationReport(bytes32 positionId,uint256 collateralValue,uint256 debtValue,uint32 thresholdBps,uint64 observedAt,uint64 expiresAt,bytes32 reportRef)"
                ),
                r.positionId,
                r.collateralValue,
                r.debtValue,
                r.thresholdBps,
                r.observedAt,
                r.expiresAt,
                r.reportRef
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _domainSep("TrioraLiquidationModule", "1", address(module)), sh));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(oraclePk, digest);
        return abi.encodePacked(rr, ss, v);
    }
}
