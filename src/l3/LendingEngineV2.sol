// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IKYBGateway} from "../interfaces/IKYBGateway.sol";
import {IAccountingVaultV2} from "../interfaces/IAccountingVaultV2.sol";
import {ILendingEngineV2} from "../interfaces/ILendingEngineV2.sol";
import {IPledgeRegistry} from "../interfaces/IPledgeRegistry.sol";
import {IReleaseAuthorizer} from "../interfaces/IReleaseAuthorizer.sol";
import {IReserveRegistry} from "../interfaces/IReserveRegistry.sol";
import {ISettlementRouterV2} from "../interfaces/ISettlementRouterV2.sol";
import {DealRegistryV2} from "./DealRegistryV2.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {EIP712HashesV2} from "../libraries/EIP712HashesV2.sol";
import {Errors} from "../libraries/Errors.sol";
import {MathLib} from "../libraries/Math.sol";

/// @title LendingEngineV2 -- Triora BitGo staged custody-backed loan state machine.
contract LendingEngineV2 is AccessManaged, EIP712, ReentrancyGuard, ILendingEngineV2 {
    using MathLib for uint256;

    struct InitParams {
        address authority;
        address kyb;
        address pledgeRegistry;
        address reserveRegistry;
        address deals;
        address vault;
        address router;
        address releaseAuthorizer;
        address aminaSigner;
    }

    IKYBGateway public immutable kyb;
    IPledgeRegistry public immutable pledgeRegistry;
    IReserveRegistry public immutable reserveRegistry;
    DealRegistryV2 public immutable deals;
    IAccountingVaultV2 public immutable vault;
    ISettlementRouterV2 public immutable router;

    IReleaseAuthorizer public releaseAuthorizer;
    address public settlementAcker;
    address public liquidationHandler;
    address public aminaSigner;

    uint32 public maxRateBps = 2_000;
    uint64 public settlementTtl = 2 days;
    bool public globalHalt;

    mapping(bytes32 dealId => TypesV2.DealRuntimeV2) private _runtime;

    event SettlementAckerSet(address indexed settlementAcker);
    event LiquidationHandlerSet(address indexed liquidationHandler);
    event ReleaseAuthorizerSet(address indexed releaseAuthorizer);
    event AminaSignerSet(address indexed aminaSigner);
    event MaxRateSet(uint32 maxRateBps);
    event SettlementTtlSet(uint64 settlementTtl);
    event GlobalHaltSet(bool halted);
    event DealSettlementPending(bytes32 indexed dealId, bytes32 indexed pledgeId, bytes32 indexed reserveId);
    event DealFunded(bytes32 indexed dealId, uint256 amount);
    event DealCancelled(bytes32 indexed dealId, bytes32 reasonCode);
    event RepaymentRequested(bytes32 indexed dealId, uint256 amount, bytes32 routeHash);
    event RepaymentConfirmed(bytes32 indexed dealId, uint256 amount, uint256 outstanding);
    event ReleaseConfirmed(bytes32 indexed dealId, bytes32 indexed voucherId);
    event DealWarned(bytes32 indexed dealId);
    event LiquidationPending(bytes32 indexed dealId, bytes32 indexed voucherId);

    error UnauthorizedEngineCaller(address caller);
    error RouteMismatch(bytes32 expected, bytes32 actual);
    error AckReplay(bytes32 ackNonce);
    error DealAlreadyLive(bytes32 dealId);
    error FundingDeadlineLive(bytes32 dealId);

    mapping(bytes32 ackNonce => bool) public ackUsed;

    constructor(InitParams memory p) AccessManaged(p.authority) EIP712("TrioraLendingEngineV2", "1") {
        if (
            p.authority == address(0) || p.kyb == address(0) || p.pledgeRegistry == address(0)
                || p.reserveRegistry == address(0) || p.deals == address(0) || p.vault == address(0)
                || p.router == address(0) || p.releaseAuthorizer == address(0) || p.aminaSigner == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        kyb = IKYBGateway(p.kyb);
        pledgeRegistry = IPledgeRegistry(p.pledgeRegistry);
        reserveRegistry = IReserveRegistry(p.reserveRegistry);
        deals = DealRegistryV2(p.deals);
        vault = IAccountingVaultV2(p.vault);
        router = ISettlementRouterV2(p.router);
        releaseAuthorizer = IReleaseAuthorizer(p.releaseAuthorizer);
        aminaSigner = p.aminaSigner;
    }

    function setSettlementAcker(address settlementAcker_) external restricted {
        if (settlementAcker_ == address(0)) revert Errors.ZeroAddress();
        settlementAcker = settlementAcker_;
        emit SettlementAckerSet(settlementAcker_);
    }

    function setLiquidationHandler(address liquidationHandler_) external restricted {
        if (liquidationHandler_ == address(0)) revert Errors.ZeroAddress();
        liquidationHandler = liquidationHandler_;
        emit LiquidationHandlerSet(liquidationHandler_);
    }

    function setReleaseAuthorizer(address releaseAuthorizer_) external restricted {
        if (releaseAuthorizer_ == address(0)) revert Errors.ZeroAddress();
        releaseAuthorizer = IReleaseAuthorizer(releaseAuthorizer_);
        emit ReleaseAuthorizerSet(releaseAuthorizer_);
    }

    function setAminaSigner(address aminaSigner_) external restricted {
        if (aminaSigner_ == address(0)) revert Errors.ZeroAddress();
        aminaSigner = aminaSigner_;
        emit AminaSignerSet(aminaSigner_);
    }

    function setMaxRateBps(uint32 maxRateBps_) external restricted {
        if (maxRateBps_ == 0 || maxRateBps_ > 10_000) revert Errors.InvalidParams(bytes32("RATE"));
        maxRateBps = maxRateBps_;
        emit MaxRateSet(maxRateBps_);
    }

    function setSettlementTtl(uint64 settlementTtl_) external restricted {
        if (settlementTtl_ == 0) revert Errors.InvalidParams(bytes32("SETTLEMENT_TTL"));
        settlementTtl = settlementTtl_;
        emit SettlementTtlSet(settlementTtl_);
    }

    function setGlobalHalt(bool halted) external restricted {
        globalHalt = halted;
        emit GlobalHaltSet(halted);
    }

    function dealIdFor(TypesV2.DealIntentV2 memory intent) public view returns (bytes32) {
        return keccak256(abi.encode(_domainSeparatorV4(), intent.lender, intent.borrower, intent.nonceAmina));
    }

    function hashDealIntent(TypesV2.DealIntentV2 calldata intent) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashDealIntent(intent));
    }

    function createMatchedDeal(
        TypesV2.DealIntentV2 calldata intent,
        bytes calldata lenderSig,
        bytes calldata borrowerSig,
        bytes calldata aminaSig,
        bytes32 settlementRef
    ) external restricted nonReentrant returns (bytes32 dealId) {
        if (globalHalt) revert Errors.GloballyHalted();
        if (!kyb.isApproved(intent.lender)) revert Errors.NotKybApproved(intent.lender);
        if (!kyb.isApproved(intent.borrower)) revert Errors.NotKybApproved(intent.borrower);
        if (intent.principal == 0 || intent.collateralAmount == 0) revert Errors.ZeroAmount();
        if (intent.rateBps == 0 || intent.rateBps > maxRateBps) revert Errors.InvalidParams(bytes32("RATE"));
        if (intent.maturityTs <= block.timestamp) revert Errors.MaturityExpired();

        dealId = dealIdFor(intent);
        if (_runtime[dealId].state != TypesV2.DealStateV2.None) revert DealAlreadyLive(dealId);
        _checkIntentSignatures(intent, lenderSig, borrowerSig, aminaSig);
        _burnNonces(intent);

        TypesV2.Pledge memory pledge = pledgeRegistry.getPledge(intent.pledgeId);
        TypesV2.Reserve memory reserve = reserveRegistry.getReserve(intent.reserveId);
        if (pledge.collateralToken != intent.collateralToken || reserve.reserveToken != intent.reserveToken) {
            revert Errors.TermsMismatch();
        }
        if (pledge.freeAmount < intent.collateralAmount || reserve.available < intent.principal) {
            revert Errors.InsufficientLedger();
        }

        deals.record(dealId, _termsFromIntent(intent));

        vault.pull(dealId, intent.collateralToken, intent.borrower, intent.collateralAmount);
        vault.pull(dealId, intent.reserveToken, intent.lender, intent.principal);
        pledgeRegistry.lockForDeal(intent.pledgeId, dealId, intent.collateralAmount);
        reserveRegistry.lockForDeal(intent.reserveId, dealId, intent.principal);

        bytes32 routeHash = keccak256(
            abi.encode(block.chainid, address(this), dealId, intent.reserveId, intent.lenderSettlementRef, settlementRef)
        );
        uint64 deadline = uint64(block.timestamp + settlementTtl);
        _runtime[dealId] = TypesV2.DealRuntimeV2({
            state: TypesV2.DealStateV2.SettlementPending,
            outstanding: 0,
            collateralLocked: intent.collateralAmount,
            interestStartTs: 0,
            lastAccrualTs: 0,
            settlementDeadline: deadline,
            lastTouchTs: uint64(block.timestamp),
            routeHash: routeHash,
            voucherId: bytes32(0)
        });
        router.emitFundingInstruction(
            dealId,
            intent.pledgeId,
            intent.reserveId,
            reserve.asset,
            intent.principal,
            routeHash,
            settlementRef,
            deadline
        );
        emit DealSettlementPending(dealId, intent.pledgeId, intent.reserveId);
    }

    function confirmFunding(TypesV2.FundingAck calldata ack) external nonReentrant {
        _onlyAcker();
        _useAck(ack.ackNonce);
        TypesV2.DealTermsV2 memory terms = deals.getTerms(ack.dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[ack.dealId];
        if (rt.state != TypesV2.DealStateV2.SettlementPending) revert Errors.DealStateForbidden(ack.dealId, uint8(rt.state));
        if (ack.reserveId != terms.reserveId || ack.amount != terms.principal) revert Errors.TermsMismatch();
        if (ack.routeHash != rt.routeHash) revert RouteMismatch(rt.routeHash, ack.routeHash);

        reserveRegistry.markFunded(terms.reserveId, ack.dealId, ack.amount);
        vault.burnReserve(ack.dealId, terms.reserveToken, ack.amount);
        rt.state = TypesV2.DealStateV2.Active;
        rt.outstanding = terms.principal;
        rt.interestStartTs = uint64(block.timestamp);
        rt.lastAccrualTs = uint64(block.timestamp);
        rt.lastTouchTs = uint64(block.timestamp);
        router.emitFundingConfirmed(ack.dealId, ack.settlementRef, ack.amount);
        emit DealFunded(ack.dealId, ack.amount);
    }

    function cancelUnfundedDeal(bytes32 dealId, bytes32 reasonCode) external restricted nonReentrant {
        TypesV2.DealTermsV2 memory terms = deals.getTerms(dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[dealId];
        if (rt.state != TypesV2.DealStateV2.SettlementPending) revert Errors.DealStateForbidden(dealId, uint8(rt.state));
        _cancelSettlement(dealId, terms, rt, reasonCode);
    }

    function requestRepayment(bytes32 dealId, uint256 amount, bytes32 routeHash, uint64 deadline) external nonReentrant {
        TypesV2.DealTermsV2 memory terms = deals.getTerms(dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[dealId];
        if (msg.sender != terms.borrower) revert Errors.InvalidCaller(msg.sender);
        if (rt.state != TypesV2.DealStateV2.Active && rt.state != TypesV2.DealStateV2.Warned) {
            revert Errors.DealStateForbidden(dealId, uint8(rt.state));
        }
        uint128 out = _accrue(terms, rt);
        if (amount == 0 || amount > out) revert Errors.PrincipalTooHigh();
        rt.outstanding = out;
        rt.state = TypesV2.DealStateV2.RepaymentPending;
        rt.routeHash = routeHash;
        rt.lastAccrualTs = uint64(block.timestamp);
        rt.lastTouchTs = uint64(block.timestamp);
        router.emitRepaymentInstruction(dealId, amount, routeHash, deadline);
        emit RepaymentRequested(dealId, amount, routeHash);
    }

    function confirmRepayment(TypesV2.RepaymentAck calldata ack) external nonReentrant {
        _onlyAcker();
        _useAck(ack.ackNonce);
        TypesV2.DealTermsV2 memory terms = deals.getTerms(ack.dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[ack.dealId];
        if (rt.state != TypesV2.DealStateV2.RepaymentPending) revert Errors.DealStateForbidden(ack.dealId, uint8(rt.state));
        if (ack.routeHash != rt.routeHash) revert RouteMismatch(rt.routeHash, ack.routeHash);

        uint128 out = _accrue(terms, rt);
        uint128 paid = ack.amount > out ? out : uint128(ack.amount);
        rt.outstanding = out - paid;
        rt.lastAccrualTs = uint64(block.timestamp);
        rt.lastTouchTs = uint64(block.timestamp);
        TypesV2.Reserve memory reserve = reserveRegistry.getReserve(terms.reserveId);
        uint256 returnedReserve = paid > reserve.funded ? reserve.funded : paid;
        if (returnedReserve > 0) {
            reserveRegistry.markReturned(terms.reserveId, ack.dealId, returnedReserve);
        }

        if (rt.outstanding == 0) {
            pledgeRegistry.unlockFromDeal(terms.pledgeId, ack.dealId, rt.collateralLocked);
            rt.state = TypesV2.DealStateV2.Repaid;
            bytes32 voucherId = releaseAuthorizer.issueRepaymentRelease(ack.dealId);
            rt.voucherId = voucherId;
            rt.state = TypesV2.DealStateV2.ReleasePending;
        } else {
            rt.state = TypesV2.DealStateV2.Active;
        }
        router.emitRepaymentConfirmed(ack.dealId, paid, rt.outstanding);
        emit RepaymentConfirmed(ack.dealId, paid, rt.outstanding);
    }

    function confirmRelease(TypesV2.ReleaseAck calldata ack) external nonReentrant {
        _onlyAcker();
        _useAck(ack.ackNonce);
        TypesV2.DealTermsV2 memory terms = deals.getTerms(ack.dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[ack.dealId];
        TypesV2.ReleaseVoucher memory voucher = releaseAuthorizer.getVoucher(ack.voucherId);
        if (voucher.dealId != ack.dealId || voucher.pledgeId != terms.pledgeId || voucher.amount != ack.amount) {
            revert Errors.TermsMismatch();
        }
        if (ack.destinationRef != voucher.destinationRef) revert Errors.TermsMismatch();

        vault.burnCollateralForRelease(ack.dealId, terms.collateralToken, terms.pledgeId, ack.amount, ack.voucherId);
        releaseAuthorizer.consumeVoucher(ack.voucherId, ack.ackNonce);
        if (rt.state == TypesV2.DealStateV2.ReleasePending) {
            pledgeRegistry.markReleased(terms.pledgeId, ack.ackNonce);
            rt.state = TypesV2.DealStateV2.Closed;
        } else if (rt.state == TypesV2.DealStateV2.LiquidationPending) {
            pledgeRegistry.markLiquidated(terms.pledgeId, ack.ackNonce);
            rt.state = TypesV2.DealStateV2.Liquidated;
        } else {
            revert Errors.DealStateForbidden(ack.dealId, uint8(rt.state));
        }
        rt.collateralLocked = 0;
        rt.lastTouchTs = uint64(block.timestamp);
        router.emitReleaseConfirmed(ack.dealId, ack.voucherId, ack.ackNonce);
        emit ReleaseConfirmed(ack.dealId, ack.voucherId);
    }

    function markSettlementFailed(TypesV2.FailureAck calldata ack) external nonReentrant {
        _onlyAcker();
        _useAck(ack.ackNonce);
        TypesV2.DealTermsV2 memory terms = deals.getTerms(ack.dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[ack.dealId];
        if (ack.routeHash != rt.routeHash) revert RouteMismatch(rt.routeHash, ack.routeHash);
        if (rt.state == TypesV2.DealStateV2.SettlementPending) {
            _cancelSettlement(ack.dealId, terms, rt, ack.reasonCode);
        } else {
            rt.state = TypesV2.DealStateV2.Failed;
            router.emitSettlementFailed(ack.dealId, ack.reasonCode);
        }
    }

    function topUpCollateral(bytes32 dealId, bytes32 pledgeId, uint256 amount) external nonReentrant {
        TypesV2.DealTermsV2 memory terms = deals.getTerms(dealId);
        TypesV2.DealRuntimeV2 storage rt = _runtime[dealId];
        if (msg.sender != terms.borrower) revert Errors.InvalidCaller(msg.sender);
        if (rt.state != TypesV2.DealStateV2.Active && rt.state != TypesV2.DealStateV2.Warned) {
            revert Errors.DealStateForbidden(dealId, uint8(rt.state));
        }
        if (pledgeId != terms.pledgeId) revert Errors.TermsMismatch();
        vault.pull(dealId, terms.collateralToken, msg.sender, amount);
        pledgeRegistry.lockForDeal(pledgeId, dealId, amount);
        rt.collateralLocked += uint128(amount);
        rt.state = TypesV2.DealStateV2.Active;
    }

    function setWarned(bytes32 dealId) external {
        _onlyLiquidationHandler();
        TypesV2.DealRuntimeV2 storage rt = _runtime[dealId];
        if (rt.state != TypesV2.DealStateV2.Active) revert Errors.DealStateForbidden(dealId, uint8(rt.state));
        rt.state = TypesV2.DealStateV2.Warned;
        rt.lastTouchTs = uint64(block.timestamp);
        emit DealWarned(dealId);
    }

    function markLiquidationPending(bytes32 dealId, bytes32 voucherId) external {
        _onlyLiquidationHandler();
        TypesV2.DealRuntimeV2 storage rt = _runtime[dealId];
        if (rt.state == TypesV2.DealStateV2.LiquidationPending && voucherId != bytes32(0)) {
            rt.voucherId = voucherId;
            emit LiquidationPending(dealId, voucherId);
            return;
        }
        if (rt.state != TypesV2.DealStateV2.Active && rt.state != TypesV2.DealStateV2.Warned) {
            revert Errors.DealStateForbidden(dealId, uint8(rt.state));
        }
        rt.state = TypesV2.DealStateV2.LiquidationPending;
        rt.voucherId = voucherId;
        rt.lastTouchTs = uint64(block.timestamp);
        emit LiquidationPending(dealId, voucherId);
    }

    function stateOf(bytes32 dealId) external view returns (TypesV2.DealStateV2) {
        return _runtime[dealId].state;
    }

    function getTerms(bytes32 dealId) external view returns (TypesV2.DealTermsV2 memory) {
        return deals.getTerms(dealId);
    }

    function getRuntime(bytes32 dealId) external view returns (TypesV2.DealRuntimeV2 memory) {
        return _runtime[dealId];
    }

    function computeOutstanding(bytes32 dealId) public view returns (uint128) {
        TypesV2.DealRuntimeV2 memory rt = _runtime[dealId];
        if (rt.state == TypesV2.DealStateV2.SettlementPending || rt.state == TypesV2.DealStateV2.None) return 0;
        return _accrueView(deals.getTerms(dealId), rt);
    }

    function healthFactorBpsFromPrices(
        bytes32 dealId,
        uint256 collateralPrice,
        uint256 reservePrice,
        uint8 collateralPriceDecimals,
        uint8 reservePriceDecimals
    ) public view returns (uint256) {
        TypesV2.DealTermsV2 memory terms = deals.getTerms(dealId);
        TypesV2.DealRuntimeV2 memory rt = _runtime[dealId];
        uint128 out = _accrueView(terms, rt);
        if (out == 0) return type(uint256).max;
        uint256 collateralUsd = MathLib.tokenToUsd(
            rt.collateralLocked,
            collateralPrice,
            IERC20Metadata(terms.collateralToken).decimals(),
            collateralPriceDecimals
        );
        uint256 debtUsd =
            MathLib.tokenToUsd(out, reservePrice, IERC20Metadata(terms.reserveToken).decimals(), reservePriceDecimals);
        if (debtUsd == 0) return type(uint256).max;
        return (collateralUsd * 10_000) / debtUsd;
    }

    function _checkIntentSignatures(
        TypesV2.DealIntentV2 calldata intent,
        bytes calldata lenderSig,
        bytes calldata borrowerSig,
        bytes calldata aminaSig
    ) internal view {
        bytes32 digest = _hashTypedDataV4(EIP712HashesV2.hashDealIntent(intent));
        if (!SignatureChecker.isValidSignatureNow(intent.lender, digest, lenderSig)) {
            revert Errors.InvalidSignature(intent.lender);
        }
        if (!SignatureChecker.isValidSignatureNow(intent.borrower, digest, borrowerSig)) {
            revert Errors.InvalidSignature(intent.borrower);
        }
        if (!SignatureChecker.isValidSignatureNow(aminaSigner, digest, aminaSig)) {
            revert Errors.InvalidSignature(aminaSigner);
        }
    }

    function _burnNonces(TypesV2.DealIntentV2 calldata intent) internal {
        if (deals.nonceUsed(intent.lender, intent.nonceLender)) revert Errors.NonceUsed(intent.lender, intent.nonceLender);
        if (deals.nonceUsed(intent.borrower, intent.nonceBorrower)) {
            revert Errors.NonceUsed(intent.borrower, intent.nonceBorrower);
        }
        if (deals.nonceUsed(aminaSigner, intent.nonceAmina)) revert Errors.NonceUsed(aminaSigner, intent.nonceAmina);
        deals.markNonceUsed(intent.lender, intent.nonceLender);
        deals.markNonceUsed(intent.borrower, intent.nonceBorrower);
        deals.markNonceUsed(aminaSigner, intent.nonceAmina);
    }

    function _cancelSettlement(
        bytes32 dealId,
        TypesV2.DealTermsV2 memory terms,
        TypesV2.DealRuntimeV2 storage rt,
        bytes32 reasonCode
    ) internal {
        pledgeRegistry.unlockFromDeal(terms.pledgeId, dealId, rt.collateralLocked);
        reserveRegistry.releaseLocked(terms.reserveId, dealId, terms.principal);
        vault.release(dealId, terms.collateralToken, terms.borrower, rt.collateralLocked);
        vault.release(dealId, terms.reserveToken, terms.lender, terms.principal);
        rt.state = TypesV2.DealStateV2.Cancelled;
        rt.lastTouchTs = uint64(block.timestamp);
        router.emitFundingCancelled(dealId, reasonCode);
        emit DealCancelled(dealId, reasonCode);
    }

    function _accrue(TypesV2.DealTermsV2 memory terms, TypesV2.DealRuntimeV2 storage rt)
        internal
        view
        returns (uint128)
    {
        return _accrueCore(terms, rt.outstanding, rt.lastAccrualTs);
    }

    function _accrueView(TypesV2.DealTermsV2 memory terms, TypesV2.DealRuntimeV2 memory rt)
        internal
        view
        returns (uint128)
    {
        return _accrueCore(terms, rt.outstanding, rt.lastAccrualTs);
    }

    function _accrueCore(TypesV2.DealTermsV2 memory terms, uint128 outstanding, uint64 lastAccrualTs)
        internal
        view
        returns (uint128)
    {
        if (outstanding == 0 || lastAccrualTs == 0) return outstanding;
        uint64 end = block.timestamp > terms.maturityTs ? terms.maturityTs : uint64(block.timestamp);
        if (end <= lastAccrualTs) return outstanding;
        uint256 interest = (uint256(outstanding) * terms.rateBps * (end - lastAccrualTs)) / (10_000 * 365 days);
        return uint128(uint256(outstanding) + interest);
    }

    function _termsFromIntent(TypesV2.DealIntentV2 calldata intent) internal pure returns (TypesV2.DealTermsV2 memory) {
        return TypesV2.DealTermsV2({
            lender: intent.lender,
            borrower: intent.borrower,
            reserveToken: intent.reserveToken,
            collateralToken: intent.collateralToken,
            principal: intent.principal,
            collateralAmount: intent.collateralAmount,
            rateBps: intent.rateBps,
            maturityTs: intent.maturityTs,
            pledgeId: intent.pledgeId,
            reserveId: intent.reserveId,
            legalTermsHash: intent.legalTermsHash,
            borrowerReleaseRef: intent.borrowerReleaseRef,
            lenderSettlementRef: intent.lenderSettlementRef,
            aminaLiquidationRef: intent.aminaLiquidationRef
        });
    }

    function _useAck(bytes32 ackNonce) internal {
        if (ackUsed[ackNonce]) revert AckReplay(ackNonce);
        ackUsed[ackNonce] = true;
    }

    function _onlyAcker() internal view {
        if (msg.sender != settlementAcker) revert UnauthorizedEngineCaller(msg.sender);
    }

    function _onlyLiquidationHandler() internal view {
        if (msg.sender != liquidationHandler) revert UnauthorizedEngineCaller(msg.sender);
    }
}
