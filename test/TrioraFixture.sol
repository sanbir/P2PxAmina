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

import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @notice Deploys + wires the full Triora Core (MODEL A — pure tri-party ledger, ADR-0001) and
///         provides EIP-712 signing helpers. No real funds, no Morpho: the engine moves only cBTC/cUSDC
///         accounting tokens; real USDC settlement is represented by dual-signed acks.
abstract contract TrioraFixture is Test {
    // actors
    address internal amina = makeAddr("amina");
    address internal issuer = makeAddr("issuer");
    address internal aminaBot = makeAddr("aminaBot");
    address internal custodyListener = makeAddr("custodyListener");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal aminaDesk = makeAddr("aminaDesk");
    address internal stranger = makeAddr("stranger");

    uint256 internal custodianPk = 0xA11CE;
    uint256 internal aminaSignerPk = 0xB0B;
    uint256 internal oraclePk = 0xC0FFEE;
    address internal custodianSigner;
    address internal aminaSigner;
    address internal oracleSigner;

    RoleManager internal rm;
    KYBGateway internal kyb;
    SignedCustodyAdapter internal custody;
    ReserveGuard internal guard;
    PledgeRegistry internal pledges;
    ReserveRegistry internal reserves;
    PositionRegistry internal positions;
    PermissionedCollateralToken internal cbtc;
    ReserveToken internal cusdc;
    OracleAdapter internal oracle;
    MockAggregator internal feed;
    RiskConfig internal risk;
    SettlementRouter internal router;
    ReleaseAuthorizer internal release;
    SettlementAcker internal acker;
    LendingEngine internal engine;
    LiquidationModule internal module;
    PortfolioLens internal lens;

    bytes32 internal marketId = keccak256("cBTC/USDC");
    uint256 internal constant BTC_PRICE_1E8 = 100000 * 1e8;
    uint32 internal constant RATE_BPS = 500;

    function setUp() public virtual {
        vm.warp(1700000000);
        custodianSigner = vm.addr(custodianPk);
        aminaSigner = vm.addr(aminaSignerPk);
        oracleSigner = vm.addr(oraclePk);

        rm = new RoleManager(address(this));
        kyb = new KYBGateway(address(rm));
        custody = new SignedCustodyAdapter(address(rm), custodianSigner, aminaSigner);
        guard = new ReserveGuard(address(rm));
        pledges = new PledgeRegistry(address(rm));
        reserves = new ReserveRegistry(address(rm));
        positions = new PositionRegistry(address(rm));
        release = new ReleaseAuthorizer(address(rm));
        cbtc = new PermissionedCollateralToken(address(rm));
        cusdc = new ReserveToken(address(rm));
        oracle = new OracleAdapter(address(rm), address(cbtc), address(custody));
        feed = new MockAggregator(8, int256(BTC_PRICE_1E8), block.timestamp);
        risk = new RiskConfig(address(rm));
        router = new SettlementRouter(address(rm));
        engine = new LendingEngine(address(rm), aminaDesk);
        acker = new SettlementAcker(address(rm), address(engine), custodianSigner, aminaSigner);
        module = new LiquidationModule(address(rm), address(engine), address(risk), marketId, oracleSigner);
        lens = new PortfolioLens(address(engine), address(pledges));

        _grantRoles();
        _wire();
        _config();
    }

    function _grantRoles() internal {
        rm.grantRole(Roles.CURATOR, address(this));
        rm.grantRole(Roles.CURATOR, amina);
        rm.grantRole(Roles.ALLOCATOR, amina);
        rm.grantRole(Roles.LIQUIDATOR, aminaBot);
        rm.grantRole(Roles.ISSUER_MINTER, issuer);
        rm.grantRole(Roles.SETTLEMENT, custodyListener);
        rm.grantRole(Roles.GUARDIAN, amina);
        rm.grantRole(Roles.EMERGENCY, amina);
        rm.grantRole(Roles.ORACLE_ADMIN, address(this));
        rm.grantRole(Roles.ENGINE, address(engine));
        rm.grantRole(Roles.LIQUIDATION_MODULE, address(module));
        rm.grantRole(Roles.TOKEN, address(cbtc));
        rm.grantRole(Roles.TOKEN, address(cusdc));
    }

    function _wire() internal {
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
    }

    function _config() internal {
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
        kyb.setStatus(borrower, KYBGateway.Status.Approved, 0, bytes32("CH"), bytes32("docs"));
        kyb.setStatus(lender, KYBGateway.Status.Approved, 0, bytes32("CH"), bytes32("docs"));
        oracle.setFeed(address(feed), 1 hours);
    }

    // ── custody attestation helpers ─────────────────────────────────────────────
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

    function _dualCustody(bytes32 structHash) internal view returns (bytes memory c, bytes memory a) {
        bytes32 d = keccak256(
            abi.encodePacked("\x19\x01", _domainSep("TrioraCustodyAdapter", "1", address(custody)), structHash)
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(custodianPk, d);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aminaSignerPk, d);
        c = abi.encodePacked(r1, s1, v1);
        a = abi.encodePacked(r2, s2, v2);
    }

    function attestReserve(address token, uint256 amount, uint8 dec) internal {
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "ReserveProof(address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt)"
                ),
                token,
                amount,
                dec,
                uint64(block.timestamp),
                uint64(block.timestamp + 1 days)
            )
        );
        (bytes memory c, bytes memory a) = _dualCustody(sh);
        custody.submitReserveProof(token, amount, dec, uint64(block.timestamp), uint64(block.timestamp + 1 days), c, a);
    }

    function attestPledge(bytes32 id, address token, uint256 amount, uint8 dec) internal {
        SignedCustodyAdapter.PledgeProof memory p = SignedCustodyAdapter.PledgeProof({
            custodyAccountRef: bytes32("acct"),
            token: token,
            amount: amount,
            decimals: dec,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days),
            controlAgreementHash: bytes32("ctrl")
        });
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "PledgeProof(bytes32 pledgeId,bytes32 custodyAccountRef,address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt,bytes32 controlAgreementHash)"
                ),
                id,
                p.custodyAccountRef,
                p.token,
                p.amount,
                p.decimals,
                p.observedAt,
                p.expiresAt,
                p.controlAgreementHash
            )
        );
        (bytes memory c, bytes memory a) = _dualCustody(sh);
        custody.submitPledgeProof(id, p, c, a);
    }

    /// @notice Borrower path: attest cBTC reserve + pledge, register pledge, mint cBTC TO BORROWER.
    function setupBorrowerCbtc(bytes32 pledgeId, uint256 amount8) internal {
        attestReserve(address(cbtc), amount8 * 100, 8);
        attestPledge(pledgeId, address(cbtc), amount8, 8);
        vm.prank(amina);
        pledges.registerPledge(pledgeId, borrower, bytes32("acct"), amount8, bytes32("ctrl"));
        vm.prank(issuer);
        cbtc.mintForPledge(borrower, pledgeId, amount8);
    }

    /// @notice Lender path: attest cUSDC reserve + pledge, register reserve, mint cUSDC TO LENDER.
    function setupLenderCusdc(bytes32 reserveId, uint256 amount6) internal {
        attestReserve(address(cusdc), amount6 * 100, 6);
        attestPledge(reserveId, address(cusdc), amount6, 6);
        vm.prank(amina);
        reserves.registerReserve(reserveId, lender, bytes32("acct"), amount6, bytes32("ctrl"));
        vm.prank(issuer);
        cusdc.mintForReserve(lender, reserveId, amount6);
    }

    /// @notice Open a matched deal end-to-end up to SettlementPending (approvals + openMatchedDeal).
    function openDeal(bytes32 pledgeId, bytes32 reserveId, uint256 cbtcAmt, uint256 principal, uint64 maturity)
        internal
        returns (bytes32 positionId)
    {
        setupBorrowerCbtc(pledgeId, cbtcAmt);
        setupLenderCusdc(reserveId, principal);
        vm.prank(borrower);
        cbtc.approve(address(engine), cbtcAmt);
        vm.prank(lender);
        cusdc.approve(address(engine), principal);
        vm.prank(amina);
        positionId = engine.openMatchedDeal(
            lender, borrower, pledgeId, reserveId, principal, RATE_BPS, maturity, bytes32("legal")
        );
    }

    // ── settlement-ack signing ──────────────────────────────────────────────────
    function _ackSig(bytes32 typeHash, bytes32 positionId, uint256 amount, bytes32 ref)
        internal
        view
        returns (SettlementAcker.Ack memory ack, bytes memory c, bytes memory a)
    {
        ack = SettlementAcker.Ack({
            positionId: positionId,
            amount: amount,
            settlementRef: ref,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 7 days)
        });
        bytes32 sh = keccak256(abi.encode(typeHash, positionId, amount, ref, ack.observedAt, ack.expiresAt));
        bytes32 d =
            keccak256(abi.encodePacked("\x19\x01", _domainSep("TrioraSettlementAcker", "1", address(acker)), sh));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(custodianPk, d);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aminaSignerPk, d);
        c = abi.encodePacked(r1, s1, v1);
        a = abi.encodePacked(r2, s2, v2);
    }

    function ackFunding(bytes32 positionId, uint256 amount, bytes32 ref) internal {
        (SettlementAcker.Ack memory ack, bytes memory c, bytes memory a) = _ackSig(
            keccak256(
                "FundingAck(bytes32 positionId,uint256 amount,bytes32 settlementRef,uint64 observedAt,uint64 expiresAt)"
            ),
            positionId,
            amount,
            ref
        );
        acker.ackFunding(ack, c, a);
    }

    function ackRepayment(bytes32 positionId, uint256 amount, bytes32 ref) internal {
        (SettlementAcker.Ack memory ack, bytes memory c, bytes memory a) = _ackSig(
            keccak256(
                "RepaymentAck(bytes32 positionId,uint256 amount,bytes32 settlementRef,uint64 observedAt,uint64 expiresAt)"
            ),
            positionId,
            amount,
            ref
        );
        acker.ackRepayment(ack, c, a);
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
        bytes32 d =
            keccak256(abi.encodePacked("\x19\x01", _domainSep("TrioraLiquidationModule", "1", address(module)), sh));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(oraclePk, d);
        return abi.encodePacked(rr, ss, v);
    }
}
