// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {RoleManager} from "../../src/l1/RoleManager.sol";
import {KYBGateway} from "../../src/l1/KYBGateway.sol";
import {BitGoCustodyAdapter} from "../../src/l2/BitGoCustodyAdapter.sol";
import {CustodyAdapterRegistry} from "../../src/l2/CustodyAdapterRegistry.sol";
import {ReserveGuard} from "../../src/l2/ReserveGuard.sol";
import {PledgeRegistry} from "../../src/l2/PledgeRegistry.sol";
import {ReserveRegistry} from "../../src/l2/ReserveRegistry.sol";
import {PermissionedCollateralToken} from "../../src/tokens/PermissionedCollateralToken.sol";
import {PermissionedTokenBase} from "../../src/tokens/PermissionedTokenBase.sol";
import {ReserveToken} from "../../src/tokens/ReserveToken.sol";
import {AccountingVaultV2} from "../../src/l3/AccountingVaultV2.sol";
import {DealRegistryV2} from "../../src/l3/DealRegistryV2.sol";
import {LendingEngineV2} from "../../src/l3/LendingEngineV2.sol";
import {SettlementRouterV2} from "../../src/l4/SettlementRouterV2.sol";
import {ReleaseAuthorizer} from "../../src/l4/ReleaseAuthorizer.sol";
import {SettlementAcker} from "../../src/l4/SettlementAcker.sol";
import {LiquidationHandlerV2} from "../../src/l4/LiquidationHandlerV2.sol";
import {PortfolioLensV2} from "../../src/l5/PortfolioLensV2.sol";
import {Types} from "../../src/libraries/Types.sol";
import {TypesV2} from "../../src/libraries/TypesV2.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract TrioraBitGoV2Test is Test {
    uint64 internal constant TOKEN_MINTER = 20;
    uint64 internal constant TOKEN_BURNER = 21;

    uint256 internal constant LENDER_PK = 0xA11CE;
    uint256 internal constant BORROWER_PK = 0xB0B0B0;
    uint256 internal constant AMINA_PK = 0xA50A50;
    uint256 internal constant BITGO_PK = 0xB1700;
    uint256 internal constant PRICE_PK = 0xC0FFEE;

    address internal LENDER;
    address internal BORROWER;
    address internal AMINA;
    address internal BITGO;
    address internal PRICE_ATTESTOR;

    address internal GOVERNOR = makeAddr("Governor");
    address internal CURATOR = makeAddr("Curator");
    address internal ALLOCATOR = makeAddr("Allocator");
    address internal LIQUIDATOR = makeAddr("Liquidator");

    bytes32 internal constant BITGO_ID = bytes32("BITGO");
    bytes32 internal constant LENDER_ENTITY = bytes32("LENDER_ENTITY");
    bytes32 internal constant BORROWER_ENTITY = bytes32("BORROWER_ENTITY");
    bytes32 internal constant BTC = bytes32("BTC");
    bytes32 internal constant USDC_ASSET = bytes32("USDC");
    bytes32 internal constant BTC_TOTAL = bytes32("BITGO_BTC_TOTAL");
    bytes32 internal constant USDC_TOTAL = bytes32("BITGO_USDC_TOTAL");
    bytes32 internal constant PLEDGE_ID = bytes32("PLEDGE_1");
    bytes32 internal constant RESERVE_ID = bytes32("RESERVE_1");
    bytes32 internal constant BTC_ACCOUNT = bytes32("BTC_ACCOUNT_1");
    bytes32 internal constant USDC_ACCOUNT = bytes32("USDC_ACCOUNT_1");
    bytes32 internal constant BORROWER_BTC_DEST = bytes32("BORROWER_BTC_DEST");
    bytes32 internal constant LENDER_GO_DEST = bytes32("LENDER_GO_DEST");
    bytes32 internal constant AMINA_DESK = bytes32("AMINA_DESK");

    RoleManager internal roleManager;
    KYBGateway internal kyb;
    BitGoCustodyAdapter internal adapter;
    CustodyAdapterRegistry internal custodyRegistry;
    ReserveGuard internal reserveGuard;
    PledgeRegistry internal pledgeRegistry;
    ReserveRegistry internal reserveRegistry;
    PermissionedCollateralToken internal cBTC;
    ReserveToken internal cUSDC;
    AccountingVaultV2 internal vault;
    DealRegistryV2 internal dealRegistry;
    SettlementRouterV2 internal router;
    ReleaseAuthorizer internal releaseAuthorizer;
    LendingEngineV2 internal engine;
    SettlementAcker internal acker;
    LiquidationHandlerV2 internal liquidationHandler;
    PortfolioLensV2 internal lens;

    uint128 internal principal = 50_000e6;
    uint128 internal collateral = 1e8;

    function setUp() public {
        LENDER = vm.addr(LENDER_PK);
        BORROWER = vm.addr(BORROWER_PK);
        AMINA = vm.addr(AMINA_PK);
        BITGO = vm.addr(BITGO_PK);
        PRICE_ATTESTOR = vm.addr(PRICE_PK);

        roleManager = new RoleManager(address(this));
        _deploy();
        _grantRoles();
        _bootstrapConfig();
        _bootstrapKyb();
        _createPledgeAndReserve();
    }

    function test_BitGoLifecycle_FundingRepaymentRelease() public {
        bytes32 dealId = _openDeal();

        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.SettlementPending));
        assertEq(engine.computeOutstanding(dealId), 0, "no pre-ack debt");
        assertEq(cUSDC.balanceOf(LENDER), 50_000e6, "lender available cUSDC");
        assertEq(cUSDC.balanceOf(address(vault)), principal, "vault cUSDC");
        assertEq(cBTC.balanceOf(address(vault)), collateral, "vault cBTC");

        vm.warp(block.timestamp + 5 days);
        assertEq(engine.computeOutstanding(dealId), 0, "interest not started");

        _ackFunding(dealId);
        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.Active));
        assertEq(engine.computeOutstanding(dealId), principal, "funded principal");
        assertEq(cUSDC.balanceOf(address(vault)), 0, "cUSDC retired");

        vm.warp(block.timestamp + 30 days);
        uint128 outstanding = engine.computeOutstanding(dealId);
        assertGt(outstanding, principal, "interest accrued");
        _requestAndAckRepayment(dealId, outstanding);

        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.ReleasePending));
        bytes32 voucherId = releaseAuthorizer.latestVoucherForDeal(dealId);
        TypesV2.ReleaseVoucher memory voucher = releaseAuthorizer.getVoucher(voucherId);
        assertEq(uint8(voucher.destinationType), uint8(TypesV2.DestinationType.Borrower), "borrower voucher");
        assertEq(voucher.destinationRef, BORROWER_BTC_DEST, "borrower destination");

        _ackRelease(dealId, voucher);
        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.Closed));
        assertEq(cBTC.totalSupply(), 0, "cBTC burned");
        assertEq(cUSDC.balanceOf(LENDER), 100_000e6, "lender reserve fully restored");
        assertEq(uint8(pledgeRegistry.getPledge(PLEDGE_ID).status), uint8(TypesV2.PledgeStatus.Released));
    }

    function test_CannotActivateWithoutFundingAck_AndAckReplayFails() public {
        bytes32 dealId = _openDeal();
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(Errors.DealStateForbidden.selector, dealId, uint8(TypesV2.DealStateV2.SettlementPending)));
        engine.requestRepayment(dealId, principal, bytes32("REPAY"), uint64(block.timestamp + 1 days));

        TypesV2.FundingAck memory ack = _fundingAck(dealId, bytes32("FUND_ACK_1"));
        (bytes memory bSig, bytes memory aSig) = _signFundingAck(ack);
        acker.ackFunding(ack, bSig, aSig);

        vm.expectRevert(abi.encodeWithSelector(LendingEngineV2.AckReplay.selector, ack.ackNonce));
        acker.ackFunding(ack, bSig, aSig);
    }

    function test_RestrictedTokens_BlockUserTransfersAndOverMint() public {
        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedTokenBase.TransferRestricted.selector, BORROWER, LENDER)
        );
        cBTC.transfer(LENDER, 1);

        vm.prank(LENDER);
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedTokenBase.TransferRestricted.selector, LENDER, BORROWER)
        );
        cUSDC.transfer(BORROWER, 1);

        vm.prank(BITGO);
        vm.expectRevert(abi.encodeWithSelector(PermissionedCollateralToken.MintExceedsPledge.selector, PLEDGE_ID));
        cBTC.mintForPledge(BORROWER, PLEDGE_ID, 1);
    }

    function test_CancelUnfundedDealUnlocksCollateralAndReserve() public {
        bytes32 dealId = _openDeal();
        vm.prank(GOVERNOR);
        engine.cancelUnfundedDeal(dealId, bytes32("CANCEL"));

        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.Cancelled));
        assertEq(cBTC.balanceOf(BORROWER), collateral, "collateral back");
        assertEq(cUSDC.balanceOf(LENDER), 100_000e6, "reserve back");
        assertEq(pledgeRegistry.getPledge(PLEDGE_ID).freeAmount, collateral, "pledge free");
        assertEq(reserveRegistry.getReserve(RESERVE_ID).available, 100_000e6, "reserve available");
    }

    function test_LiquidationIssuesAminaVoucherAndBurnsCollateral() public {
        bytes32 dealId = _openDeal();
        _ackFunding(dealId);

        TypesV2.PriceAttestationV2 memory att = TypesV2.PriceAttestationV2({
            dealId: dealId,
            collateralPrice: 40_000e8,
            reservePrice: 1e8,
            collateralPriceDecimals: 8,
            reservePriceDecimals: 8,
            observationTs: uint64(block.timestamp),
            reasonCode: bytes32("BTC_DROP")
        });
        bytes memory sig = _signPrice(att);

        vm.prank(LIQUIDATOR);
        bytes32 voucherId = liquidationHandler.requestFullLiquidation(att, sig);
        TypesV2.ReleaseVoucher memory voucher = releaseAuthorizer.getVoucher(voucherId);

        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.LiquidationPending));
        assertEq(uint8(voucher.destinationType), uint8(TypesV2.DestinationType.AminaDesk), "amina voucher");
        assertEq(voucher.destinationRef, AMINA_DESK, "amina desk");

        _ackRelease(dealId, voucher);
        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.Liquidated));
        assertEq(cBTC.totalSupply(), 0, "liquidated cBTC burned");
        assertEq(uint8(pledgeRegistry.getPledge(PLEDGE_ID).status), uint8(TypesV2.PledgeStatus.Liquidated));
    }

    function test_ReserveGuardRejectsStaleReserveProof() public {
        bytes32 stalePledge = bytes32("STALE_PLEDGE");
        bytes32 staleAccount = bytes32("STALE_BTC_ACCOUNT");
        vm.prank(CURATOR);
        custodyRegistry.registerCustodyAccount(
            staleAccount,
            BITGO_ID,
            BORROWER_ENTITY,
            TypesV2.AssuranceTier.QualifiedCustody,
            bytes32("POLICY")
        );

        vm.prank(CURATOR);
        pledgeRegistry.requestPledge(
            TypesV2.PledgeRequest({
                pledgeId: stalePledge,
                entityId: BORROWER_ENTITY,
                custodyAccountRef: staleAccount,
                custodianId: BITGO_ID,
                collateralToken: address(cBTC),
                assetId: BTC,
                pledgedAmount: 1,
                controlAgreementHash: bytes32("CTRL")
            })
        );

        TypesV2.CustodyProof memory staleTotal =
            _proof(BTC_TOTAL, bytes32("TOTAL_BTC_ACCT"), address(cBTC), collateral, 8, bytes32("STALE_TOTAL"));
        staleTotal.expiresAt = uint64(block.timestamp + 1);
        _submitProof(staleTotal);
        vm.warp(block.timestamp + 2);

        TypesV2.CustodyProof memory pledgeProof =
            _proof(stalePledge, staleAccount, address(cBTC), 1, 8, bytes32("STALE_PLEDGE_OK"));
        bytes memory att = _submitProof(pledgeProof);
        vm.prank(CURATOR);
        pledgeRegistry.activatePledge(stalePledge, att);

        vm.prank(BITGO);
        vm.expectRevert(abi.encodeWithSelector(ReserveGuard.ReserveReportStale.selector, address(cBTC)));
        cBTC.mintForPledge(BORROWER, stalePledge, 1);
    }

    function test_CustodyProofRequiresBitGoAndAminaSignatures() public {
        TypesV2.CustodyProof memory proof =
            _proof(bytes32("BAD_SIG_PROOF"), BTC_ACCOUNT, address(cBTC), 1, 8, bytes32("BAD_SIG"));
        bytes32 digest = adapter.hashCustodyProof(proof);
        bytes memory bitgoSig = _sig(BITGO_PK, digest);
        bytes memory badAminaSig = _sig(LENDER_PK, digest);

        vm.expectRevert(abi.encodeWithSelector(BitGoCustodyAdapter.BadSigner.selector, AMINA));
        adapter.submitProof(proof, bitgoSig, badAminaSig);
    }

    function test_CreateMatchedDealRequiresAminaApproval() public {
        TypesV2.DealIntentV2 memory intent = _intent();
        vm.prank(BORROWER);
        cBTC.approve(address(vault), type(uint256).max);
        vm.prank(LENDER);
        cUSDC.approve(address(vault), type(uint256).max);

        bytes32 digest = engine.hashDealIntent(intent);
        bytes memory lenderSig = _sig(LENDER_PK, digest);
        bytes memory borrowerSig = _sig(BORROWER_PK, digest);
        bytes memory badAminaSig = _sig(PRICE_PK, digest);

        vm.prank(ALLOCATOR);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, AMINA));
        engine.createMatchedDeal(intent, lenderSig, borrowerSig, badAminaSig, bytes32("FUND_REF"));
    }

    function test_FundingAckRequiresBitGoSigner() public {
        bytes32 dealId = _openDeal();
        TypesV2.FundingAck memory ack = _fundingAck(dealId, bytes32("BAD_FUND_ACK"));
        bytes32 digest = acker.hashFundingAck(ack);
        bytes memory badBitgoSig = _sig(LENDER_PK, digest);
        bytes memory aminaSig = _sig(AMINA_PK, digest);

        vm.expectRevert(abi.encodeWithSelector(SettlementAcker.BadAckSigner.selector, BITGO));
        acker.ackFunding(ack, badBitgoSig, aminaSig);
    }

    function test_FailureAckCancelsSettlementAndUnlocksInventory() public {
        bytes32 dealId = _openDeal();
        TypesV2.DealRuntimeV2 memory rt = engine.getRuntime(dealId);
        TypesV2.FailureAck memory ack = TypesV2.FailureAck({
            dealId: dealId,
            routeHash: rt.routeHash,
            reasonCode: bytes32("BITGO_FAIL"),
            ackNonce: bytes32("FAIL_ACK_1"),
            observedAt: uint64(block.timestamp)
        });
        (bytes memory bitgoSig, bytes memory aminaSig) = _signFailureAck(ack);

        acker.ackFailure(ack, bitgoSig, aminaSig);

        assertEq(uint8(engine.stateOf(dealId)), uint8(TypesV2.DealStateV2.Cancelled));
        assertEq(cBTC.balanceOf(BORROWER), collateral, "collateral restored");
        assertEq(cUSDC.balanceOf(LENDER), 100_000e6, "reserve restored");
        assertEq(pledgeRegistry.getPledge(PLEDGE_ID).freeAmount, collateral, "pledge unlocked");
        assertEq(reserveRegistry.getReserve(RESERVE_ID).available, 100_000e6, "reserve unlocked");
    }

    function test_ExpiredReleaseVoucherBlocksCollateralBurn() public {
        vm.prank(GOVERNOR);
        releaseAuthorizer.setVoucherTtl(1);

        bytes32 dealId = _openDeal();
        _ackFunding(dealId);
        _requestAndAckRepayment(dealId, principal);

        bytes32 voucherId = releaseAuthorizer.latestVoucherForDeal(dealId);
        TypesV2.ReleaseVoucher memory voucher = releaseAuthorizer.getVoucher(voucherId);
        vm.warp(uint256(voucher.expiresAt) + 1);

        TypesV2.ReleaseAck memory ack = TypesV2.ReleaseAck({
            voucherId: voucher.voucherId,
            dealId: dealId,
            pledgeId: voucher.pledgeId,
            amount: voucher.amount,
            destinationRef: voucher.destinationRef,
            ackNonce: bytes32("EXPIRED_RELEASE_ACK"),
            observedAt: uint64(block.timestamp)
        });
        (bytes memory bitgoSig, bytes memory aminaSig) = _signReleaseAck(ack);

        vm.expectRevert(abi.encodeWithSelector(PermissionedCollateralToken.InvalidVoucher.selector, voucherId));
        acker.ackRelease(ack, bitgoSig, aminaSig);
    }

    function test_UserCannotIssueRepaymentReleaseVoucher() public {
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(ReleaseAuthorizer.UnauthorizedVoucherCaller.selector, BORROWER));
        releaseAuthorizer.issueRepaymentRelease(bytes32("NOT_ENGINE"));
    }

    function test_HealthyDealCannotBeLiquidated() public {
        bytes32 dealId = _openDeal();
        _ackFunding(dealId);

        TypesV2.PriceAttestationV2 memory att = TypesV2.PriceAttestationV2({
            dealId: dealId,
            collateralPrice: 100_000e8,
            reservePrice: 1e8,
            collateralPriceDecimals: 8,
            reservePriceDecimals: 8,
            observationTs: uint64(block.timestamp),
            reasonCode: bytes32("HEALTHY")
        });
        bytes memory sig = _signPrice(att);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(LiquidationHandlerV2.LiquidationNotAllowed.selector, 20_000));
        liquidationHandler.requestFullLiquidation(att, sig);
    }

    function _deploy() internal {
        KYBGateway kybImpl = new KYBGateway();
        kyb = KYBGateway(
            address(new ERC1967Proxy(address(kybImpl), abi.encodeCall(KYBGateway.initialize, (address(roleManager)))))
        );
        adapter = new BitGoCustodyAdapter(address(roleManager), BITGO, AMINA);
        custodyRegistry = new CustodyAdapterRegistry(address(roleManager));
        reserveGuard = new ReserveGuard(address(roleManager));
        pledgeRegistry = new PledgeRegistry(address(roleManager), address(custodyRegistry));
        reserveRegistry = new ReserveRegistry(address(roleManager), address(custodyRegistry), address(reserveGuard));
        cBTC = new PermissionedCollateralToken(
            "BitGo cBTC", "BitGo-cBTC", 8, address(roleManager), address(pledgeRegistry), address(reserveGuard)
        );
        cUSDC = new ReserveToken("Triora cUSDC", "cUSDC", 6, address(roleManager), address(reserveGuard));
        vault = new AccountingVaultV2(GOVERNOR);
        router = new SettlementRouterV2(address(this));

        uint256 nonce = vm.getNonce(address(this));
        address predictedEngine = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedRelease = vm.computeCreateAddress(address(this), nonce + 1);
        dealRegistry = new DealRegistryV2(predictedEngine);
        releaseAuthorizer =
            new ReleaseAuthorizer(address(roleManager), predictedEngine, address(pledgeRegistry), address(router));
        assertEq(address(releaseAuthorizer), predictedRelease, "release prediction");
        engine = new LendingEngineV2(
            LendingEngineV2.InitParams({
                authority: address(roleManager),
                kyb: address(kyb),
                pledgeRegistry: address(pledgeRegistry),
                reserveRegistry: address(reserveRegistry),
                deals: address(dealRegistry),
                vault: address(vault),
                router: address(router),
                releaseAuthorizer: address(releaseAuthorizer),
                aminaSigner: AMINA
            })
        );
        assertEq(address(engine), predictedEngine, "engine prediction");
        acker = new SettlementAcker(address(roleManager), address(engine), BITGO, AMINA);
        liquidationHandler =
            new LiquidationHandlerV2(address(roleManager), address(engine), address(releaseAuthorizer), PRICE_ATTESTOR);
        lens = new PortfolioLensV2(address(engine), address(pledgeRegistry), address(reserveRegistry), address(vault));

        vm.prank(GOVERNOR);
        vault.bindEngine(address(engine));
        router.bind(address(engine), address(acker), address(releaseAuthorizer), address(liquidationHandler));
    }

    function _grantRoles() internal {
        roleManager.labelRole(Roles.CURATOR, "CURATOR");
        roleManager.labelRole(Roles.ALLOCATOR, "ALLOCATOR");
        roleManager.labelRole(Roles.LIQUIDATOR, "LIQUIDATOR");
        roleManager.labelRole(Roles.GOVERNOR, "GOVERNOR");
        roleManager.labelRole(TOKEN_MINTER, "TOKEN_MINTER");
        roleManager.labelRole(TOKEN_BURNER, "TOKEN_BURNER");

        roleManager.grantRole(Roles.CURATOR, CURATOR, 0);
        roleManager.grantRole(Roles.ALLOCATOR, ALLOCATOR, 0);
        roleManager.grantRole(Roles.LIQUIDATOR, LIQUIDATOR, 0);
        roleManager.grantRole(Roles.GOVERNOR, GOVERNOR, 0);
        roleManager.grantRole(TOKEN_MINTER, BITGO, 0);
        roleManager.grantRole(TOKEN_BURNER, address(vault), 0);

        _bind(Roles.CURATOR, address(kyb), _selectors(KYBGateway.setStatus.selector));
        _bind(Roles.CURATOR, address(custodyRegistry), _custodySelectors());
        _bind(Roles.CURATOR, address(reserveGuard), _selectors(ReserveGuard.setReservePolicy.selector));
        _bind(Roles.CURATOR, address(pledgeRegistry), _pledgeAdminSelectors());
        _bind(Roles.CURATOR, address(reserveRegistry), _reserveAdminSelectors());
        _bind(Roles.CURATOR, address(cBTC), _collateralAdminSelectors());
        _bind(Roles.CURATOR, address(cUSDC), _reserveTokenAdminSelectors());
        _bind(TOKEN_MINTER, address(cBTC), _selectors(PermissionedCollateralToken.mintForPledge.selector));
        _bind(TOKEN_BURNER, address(cBTC), _selectors(PermissionedCollateralToken.burnForRelease.selector));
        _bind(TOKEN_BURNER, address(cUSDC), _selectors(ReserveToken.burnFromProtocol.selector));
        _bind(Roles.ALLOCATOR, address(engine), _selectors(LendingEngineV2.createMatchedDeal.selector));
        _bind(Roles.GOVERNOR, address(engine), _engineAdminSelectors());
        _bind(Roles.GOVERNOR, address(releaseAuthorizer), _releaseAdminSelectors());
        _bind(Roles.LIQUIDATOR, address(liquidationHandler), _liquidationSelectors());
    }

    function _bootstrapConfig() internal {
        vm.startPrank(CURATOR);
        custodyRegistry.addCustodian(
            BITGO_ID,
            TypesV2.CustodianConfig({
                adapter: address(adapter),
                active: true,
                legalHash: bytes32("BITGO_LEGAL"),
                minTier: TypesV2.AssuranceTier.QualifiedCustody
            })
        );
        custodyRegistry.registerCustodyAccount(
            BTC_ACCOUNT, BITGO_ID, BORROWER_ENTITY, TypesV2.AssuranceTier.QualifiedCustody, bytes32("BTC_POLICY")
        );
        custodyRegistry.registerCustodyAccount(
            USDC_ACCOUNT, BITGO_ID, LENDER_ENTITY, TypesV2.AssuranceTier.QualifiedCustody, bytes32("USDC_POLICY")
        );
        pledgeRegistry.setEngine(address(engine));
        pledgeRegistry.setReleaseAuthorizer(address(releaseAuthorizer));
        pledgeRegistry.setSettlementAcker(address(acker));
        reserveRegistry.setEngine(address(engine));
        cBTC.setReleaseAuthorizer(address(releaseAuthorizer));
        cUSDC.setReserveRegistry(address(reserveRegistry));
        cBTC.setProtocol(address(vault), true);
        cUSDC.setProtocol(address(vault), true);
        vm.stopPrank();

        vm.startPrank(GOVERNOR);
        engine.setSettlementAcker(address(acker));
        engine.setLiquidationHandler(address(liquidationHandler));
        releaseAuthorizer.setSettlementAcker(address(acker));
        vm.stopPrank();

        _submitProof(_proof(BTC_TOTAL, bytes32("TOTAL_BTC_ACCT"), address(cBTC), collateral, 8, bytes32("BTC_TOTAL_OK")));
        _submitProof(_proof(USDC_TOTAL, bytes32("TOTAL_USDC_ACCT"), address(cUSDC), 100_000e6, 6, bytes32("USDC_TOTAL_OK")));

        vm.startPrank(CURATOR);
        reserveGuard.setReservePolicy(
            address(cBTC),
            ReserveGuard.ReservePolicy({
                adapter: address(adapter),
                subjectId: BTC_TOTAL,
                margin: 0,
                maxStaleness: 1 days,
                active: true
            })
        );
        reserveGuard.setReservePolicy(
            address(cUSDC),
            ReserveGuard.ReservePolicy({
                adapter: address(adapter),
                subjectId: USDC_TOTAL,
                margin: 0,
                maxStaleness: 1 days,
                active: true
            })
        );
        vm.stopPrank();
    }

    function _bootstrapKyb() internal {
        vm.startPrank(CURATOR);
        kyb.setStatus(LENDER, Types.KybStatus.Approved, 0, bytes32("LENDER_DOCS"), bytes32("CH"));
        kyb.setStatus(BORROWER, Types.KybStatus.Approved, 0, bytes32("BORROWER_DOCS"), bytes32("CH"));
        vm.stopPrank();
    }

    function _createPledgeAndReserve() internal {
        vm.startPrank(CURATOR);
        pledgeRegistry.requestPledge(
            TypesV2.PledgeRequest({
                pledgeId: PLEDGE_ID,
                entityId: BORROWER_ENTITY,
                custodyAccountRef: BTC_ACCOUNT,
                custodianId: BITGO_ID,
                collateralToken: address(cBTC),
                assetId: BTC,
                pledgedAmount: collateral,
                controlAgreementHash: bytes32("CTRL")
            })
        );
        reserveRegistry.requestReserve(
            TypesV2.ReserveRequest({
                reserveId: RESERVE_ID,
                owner: LENDER,
                entityId: LENDER_ENTITY,
                custodyAccountRef: USDC_ACCOUNT,
                custodianId: BITGO_ID,
                reserveToken: address(cUSDC),
                asset: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
                amount: 100_000e6
            })
        );
        vm.stopPrank();

        bytes memory pledgeAtt = _submitProof(_proof(PLEDGE_ID, BTC_ACCOUNT, address(cBTC), collateral, 8, bytes32("PLEDGE_OK")));
        bytes memory reserveAtt =
            _submitProof(_proof(RESERVE_ID, USDC_ACCOUNT, address(cUSDC), 100_000e6, 6, bytes32("RESERVE_OK")));

        vm.startPrank(CURATOR);
        pledgeRegistry.activatePledge(PLEDGE_ID, pledgeAtt);
        reserveRegistry.activateReserve(RESERVE_ID, reserveAtt);
        vm.stopPrank();

        vm.prank(BITGO);
        cBTC.mintForPledge(BORROWER, PLEDGE_ID, collateral);
    }

    function _openDeal() internal returns (bytes32 dealId) {
        TypesV2.DealIntentV2 memory intent = _intent();
        vm.prank(BORROWER);
        cBTC.approve(address(vault), type(uint256).max);
        vm.prank(LENDER);
        cUSDC.approve(address(vault), type(uint256).max);
        (bytes memory lSig, bytes memory bSig, bytes memory aSig) = _signIntent(intent);
        vm.prank(ALLOCATOR);
        dealId = engine.createMatchedDeal(intent, lSig, bSig, aSig, bytes32("FUND_REF"));
    }

    function _intent() internal view returns (TypesV2.DealIntentV2 memory) {
        return TypesV2.DealIntentV2({
            lender: LENDER,
            borrower: BORROWER,
            reserveToken: address(cUSDC),
            collateralToken: address(cBTC),
            principal: principal,
            collateralAmount: collateral,
            rateBps: 1_000,
            maturityTs: uint64(block.timestamp + 90 days),
            pledgeId: PLEDGE_ID,
            reserveId: RESERVE_ID,
            nonceLender: keccak256(abi.encode("L", block.timestamp)),
            nonceBorrower: keccak256(abi.encode("B", block.timestamp)),
            nonceAmina: keccak256(abi.encode("A", block.timestamp)),
            legalTermsHash: bytes32("LEGAL"),
            borrowerReleaseRef: BORROWER_BTC_DEST,
            lenderSettlementRef: LENDER_GO_DEST,
            aminaLiquidationRef: AMINA_DESK
        });
    }

    function _ackFunding(bytes32 dealId) internal {
        TypesV2.FundingAck memory ack = _fundingAck(dealId, bytes32("FUND_ACK_1"));
        (bytes memory bSig, bytes memory aSig) = _signFundingAck(ack);
        acker.ackFunding(ack, bSig, aSig);
    }

    function _fundingAck(bytes32 dealId, bytes32 nonce_) internal view returns (TypesV2.FundingAck memory) {
        TypesV2.DealRuntimeV2 memory rt = engine.getRuntime(dealId);
        return TypesV2.FundingAck({
            dealId: dealId,
            reserveId: RESERVE_ID,
            amount: principal,
            routeHash: rt.routeHash,
            settlementRef: bytes32("FUND_SETTLED"),
            ackNonce: nonce_,
            observedAt: uint64(block.timestamp)
        });
    }

    function _requestAndAckRepayment(bytes32 dealId, uint128 amount) internal {
        bytes32 routeHash = keccak256(abi.encode("REPAY", dealId, block.timestamp));
        vm.prank(BORROWER);
        engine.requestRepayment(dealId, amount, routeHash, uint64(block.timestamp + 1 days));
        _submitProof(
            _proof(USDC_TOTAL, bytes32("TOTAL_USDC_ACCT"), address(cUSDC), 100_000e6, 6, bytes32("USDC_RETURN_OK"))
        );
        TypesV2.RepaymentAck memory ack = TypesV2.RepaymentAck({
            dealId: dealId,
            amount: amount,
            routeHash: routeHash,
            settlementRef: bytes32("REPAY_SETTLED"),
            ackNonce: bytes32("REPAY_ACK_1"),
            observedAt: uint64(block.timestamp)
        });
        (bytes memory bSig, bytes memory aSig) = _signRepaymentAck(ack);
        acker.ackRepayment(ack, bSig, aSig);
    }

    function _ackRelease(bytes32 dealId, TypesV2.ReleaseVoucher memory voucher) internal {
        TypesV2.ReleaseAck memory ack = TypesV2.ReleaseAck({
            voucherId: voucher.voucherId,
            dealId: dealId,
            pledgeId: voucher.pledgeId,
            amount: voucher.amount,
            destinationRef: voucher.destinationRef,
            ackNonce: keccak256(abi.encode("RELEASE_ACK", voucher.voucherId)),
            observedAt: uint64(block.timestamp)
        });
        (bytes memory bSig, bytes memory aSig) = _signReleaseAck(ack);
        acker.ackRelease(ack, bSig, aSig);
    }

    function _proof(
        bytes32 subjectId,
        bytes32 accountRef,
        address token,
        uint256 amount,
        uint8 decimals_,
        bytes32 evidence
    ) internal view returns (TypesV2.CustodyProof memory) {
        return TypesV2.CustodyProof({
            subjectId: subjectId,
            custodyAccountRef: accountRef,
            token: token,
            amount: amount,
            decimals: decimals_,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days),
            evidenceHash: evidence
        });
    }

    function _submitProof(TypesV2.CustodyProof memory proof) internal returns (bytes memory attestation) {
        bytes32 digest = adapter.hashCustodyProof(proof);
        bytes memory bSig = _sig(BITGO_PK, digest);
        bytes memory aSig = _sig(AMINA_PK, digest);
        adapter.submitProof(proof, bSig, aSig);
        return abi.encode(proof, bSig, aSig);
    }

    function _signIntent(TypesV2.DealIntentV2 memory intent)
        internal
        view
        returns (bytes memory lSig, bytes memory bSig, bytes memory aSig)
    {
        bytes32 digest = engine.hashDealIntent(intent);
        return (_sig(LENDER_PK, digest), _sig(BORROWER_PK, digest), _sig(AMINA_PK, digest));
    }

    function _signFundingAck(TypesV2.FundingAck memory ack) internal view returns (bytes memory, bytes memory) {
        bytes32 digest = acker.hashFundingAck(ack);
        return (_sig(BITGO_PK, digest), _sig(AMINA_PK, digest));
    }

    function _signRepaymentAck(TypesV2.RepaymentAck memory ack) internal view returns (bytes memory, bytes memory) {
        bytes32 digest = acker.hashRepaymentAck(ack);
        return (_sig(BITGO_PK, digest), _sig(AMINA_PK, digest));
    }

    function _signReleaseAck(TypesV2.ReleaseAck memory ack) internal view returns (bytes memory, bytes memory) {
        bytes32 digest = acker.hashReleaseAck(ack);
        return (_sig(BITGO_PK, digest), _sig(AMINA_PK, digest));
    }

    function _signFailureAck(TypesV2.FailureAck memory ack) internal view returns (bytes memory, bytes memory) {
        bytes32 digest = acker.hashFailureAck(ack);
        return (_sig(BITGO_PK, digest), _sig(AMINA_PK, digest));
    }

    function _signPrice(TypesV2.PriceAttestationV2 memory att) internal view returns (bytes memory) {
        return _sig(PRICE_PK, liquidationHandler.hashPriceAttestation(att));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _bind(uint64 role, address target, bytes4[] memory selectors) internal {
        roleManager.setTargetFunctionRole(target, selectors, role);
    }

    function _selectors(bytes4 selector) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = selector;
    }

    function _custodySelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = CustodyAdapterRegistry.addCustodian.selector;
        s[1] = CustodyAdapterRegistry.setAdapter.selector;
        s[2] = CustodyAdapterRegistry.setCustodianActive.selector;
        s[3] = CustodyAdapterRegistry.registerCustodyAccount.selector;
        s[4] = CustodyAdapterRegistry.setAccountActive.selector;
        s[5] = CustodyAdapterRegistry.setAssuranceTier.selector;
    }

    function _pledgeAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = PledgeRegistry.setEngine.selector;
        s[1] = PledgeRegistry.setReleaseAuthorizer.selector;
        s[2] = PledgeRegistry.setSettlementAcker.selector;
        s[3] = PledgeRegistry.requestPledge.selector;
        s[4] = PledgeRegistry.activatePledge.selector;
    }

    function _reserveAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = ReserveRegistry.setEngine.selector;
        s[1] = ReserveRegistry.setReserveGuard.selector;
        s[2] = ReserveRegistry.requestReserve.selector;
        s[3] = ReserveRegistry.activateReserve.selector;
    }

    function _collateralAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = PermissionedTokenBase.setProtocol.selector;
        s[1] = PermissionedTokenBase.setFrozen.selector;
        s[2] = PermissionedTokenBase.setPaused.selector;
        s[3] = PermissionedCollateralToken.setReleaseAuthorizer.selector;
        s[4] = PermissionedTokenBase.protocolBurn.selector;
    }

    function _reserveTokenAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = PermissionedTokenBase.setProtocol.selector;
        s[1] = PermissionedTokenBase.setFrozen.selector;
        s[2] = PermissionedTokenBase.setPaused.selector;
        s[3] = ReserveToken.setReserveRegistry.selector;
        s[4] = PermissionedTokenBase.protocolBurn.selector;
    }

    function _engineAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = LendingEngineV2.setSettlementAcker.selector;
        s[1] = LendingEngineV2.setLiquidationHandler.selector;
        s[2] = LendingEngineV2.setReleaseAuthorizer.selector;
        s[3] = LendingEngineV2.setAminaSigner.selector;
        s[4] = LendingEngineV2.setMaxRateBps.selector;
        s[5] = LendingEngineV2.setSettlementTtl.selector;
        s[6] = LendingEngineV2.cancelUnfundedDeal.selector;
    }

    function _releaseAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ReleaseAuthorizer.setSettlementAcker.selector;
        s[1] = ReleaseAuthorizer.setVoucherTtl.selector;
    }

    function _liquidationSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = LiquidationHandlerV2.warn.selector;
        s[1] = LiquidationHandlerV2.requestFullLiquidation.selector;
    }
}
