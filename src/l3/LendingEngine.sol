// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessManagedUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {IKYBGateway} from "../interfaces/IKYBGateway.sol";
import {IIssuerRegistry} from "../interfaces/IIssuerRegistry.sol";
import {IComplianceRegistry, HookAction} from "../interfaces/IComplianceRegistry.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IParameterArchive} from "../interfaces/IParameterArchive.sol";
import {IDealRegistry} from "../interfaces/IDealRegistry.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {ISettlementRouter} from "../interfaces/ISettlementRouter.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";
import {EIP712Hashes} from "../libraries/EIP712Hashes.sol";
import {MathLib} from "../libraries/Math.sol";

/// @title LendingEngine — heart of the protocol.
/// @notice Orchestrates deal recording, atomic activation, simple
///         interest accrual, repay, top-up, and the state-machine hooks
///         for liquidation. Reads risk params from ParameterArchive via
///         CollateralRegistry. Authority is the RoleManager.
contract LendingEngine is
    ILendingEngine,
    Initializable,
    UUPSUpgradeable,
    AccessManagedUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable
{
    using MathLib for uint256;

    /// @custom:storage-location erc7201:p2pxamina.lendingengine.v1
    struct Storage {
        IKYBGateway kyb;
        IIssuerRegistry issuers;
        IComplianceRegistry compliance;
        ICollateralRegistry collateral;
        IParameterArchive archive;
        IDealRegistry deals;
        IEscrowVault vault;
        ISettlementRouter router;
        address handler; // LiquidationHandler proxy
        // deal state
        mapping(bytes32 => Types.DealState) state;
        mapping(bytes32 => Types.OracleOverride) oracleOverride;
        // caps that live with the engine (not with IssuerRegistry):
        uint256 globalCapUsd;
        uint256 globalUsedUsd;
        mapping(address => uint256) borrowerCapUsd;
        mapping(address => uint256) borrowerUsedUsd;
        mapping(address => uint256) lenderCapUsd;
        mapping(address => uint256) lenderUsedUsd;
        // principal USD captured at activation; used to release caps without
        // re-reading the oracle (which may have grown stale).
        mapping(bytes32 => uint256) dealPrincipalUsd;
        // pause / halt flags
        bool globalHalt;
        bool emergencySealed;
    }

    bytes32 private constant STORAGE_SLOT =
        0x88a8b3c2c5b9bda9e6f3aaa3b7d9e7b8a3f2b9d8c5b7a5f4d3c2b1a0fee9dd00;

    uint256 public constant EMERGENCY_GRACE = 30 minutes;

    event DealActivated(bytes32 indexed dealId, address indexed lender, address indexed borrower, uint128 principal);
    event DealRepaid(bytes32 indexed dealId, uint128 amount, bool collateralReleased);
    event TopUp(bytes32 indexed dealId, uint256 amount);
    event UnreleasedCollateralClaimed(bytes32 indexed dealId, uint256 amount);
    event DealPaused(bytes32 indexed dealId, bytes32 reason);
    event DealUnpaused(bytes32 indexed dealId, uint64 totalPausedTime);
    event GlobalHalt(bool halted);
    event EmergencySealed(bool sealed_);
    event OracleOverridden(bytes32 indexed dealId, address newColl, address newSupp, bytes32 reason, uint64 effectiveAt);
    event GlobalCapSet(uint256 cap);
    event ActorCapSet(address indexed who, uint256 cap, bool isLender);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct InitParams {
        address authority;
        address kyb;
        address issuers;
        address compliance;
        address collateral;
        address archive;
        address deals;
        address vault;
        address router;
        address handler;
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessManaged_init(p.authority);
        __UUPSUpgradeable_init();
        __EIP712_init("P2PxAmina", "1");
        __ReentrancyGuard_init();
        Storage storage $ = _store();
        $.kyb = IKYBGateway(p.kyb);
        $.issuers = IIssuerRegistry(p.issuers);
        $.compliance = IComplianceRegistry(p.compliance);
        $.collateral = ICollateralRegistry(p.collateral);
        $.archive = IParameterArchive(p.archive);
        $.deals = IDealRegistry(p.deals);
        $.vault = IEscrowVault(p.vault);
        $.router = ISettlementRouter(p.router);
        $.handler = p.handler;
    }

    // ================================================================
    // SETTERS — caps, pauses
    // ================================================================

    function setGlobalCapUsd(uint256 cap) external restricted {
        _store().globalCapUsd = cap;
        emit GlobalCapSet(cap);
    }

    function setBorrowerCapUsd(address borrower, uint256 cap) external restricted {
        _store().borrowerCapUsd[borrower] = cap;
        emit ActorCapSet(borrower, cap, false);
    }

    function setLenderCapUsd(address lender, uint256 cap) external restricted {
        _store().lenderCapUsd[lender] = cap;
        emit ActorCapSet(lender, cap, true);
    }

    function pauseDeal(bytes32 dealId, bytes32 reason) external restricted {
        Storage storage $ = _store();
        Types.DealState storage st = $.state[dealId];
        if (st.state != Types.DealStateEnum.Active && st.state != Types.DealStateEnum.Warned) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        if (st.pauseStartedAt != 0) revert Errors.DealPausedFor(dealId, st.lastPauseReason);
        st.pauseStartedAt = uint64(block.timestamp);
        st.lastPauseReason = reason;
        emit DealPaused(dealId, reason);
    }

    function unpauseDeal(bytes32 dealId) external restricted {
        Storage storage $ = _store();
        Types.DealState storage st = $.state[dealId];
        if (st.pauseStartedAt == 0) revert Errors.DealNotPaused(dealId);
        uint64 elapsed = uint64(block.timestamp) - st.pauseStartedAt;
        st.totalPausedTime += elapsed;
        st.pauseStartedAt = 0;
        emit DealUnpaused(dealId, st.totalPausedTime);
    }

    function setGlobalHalt(bool halted) external restricted {
        _store().globalHalt = halted;
        emit GlobalHalt(halted);
    }

    function setEmergencySealed(bool sealed_) external restricted {
        _store().emergencySealed = sealed_;
        emit EmergencySealed(sealed_);
    }

    function forceOracleOverride(bytes32 dealId, address newColl, address newSupp, bytes32 reason) external restricted {
        Storage storage $ = _store();
        Types.DealState storage st = $.state[dealId];
        if (_isTerminal(st.state)) revert Errors.DealNotTerminal(dealId);
        uint64 effectiveAt = uint64(block.timestamp + EMERGENCY_GRACE);
        $.oracleOverride[dealId] = Types.OracleOverride({
            overrideCollateralOracle: newColl,
            overrideSupplyOracle: newSupp,
            effectiveAt: effectiveAt,
            reason: reason
        });
        $.router.emitOracleOverridden(dealId, newColl, newSupp, reason, effectiveAt);
        emit OracleOverridden(dealId, newColl, newSupp, reason, effectiveAt);
    }

    // ================================================================
    // CORE FLOW — openAndActivate (atomic)
    // ================================================================

    function dealIdFor(Types.DealIntent memory intent) public view returns (bytes32) {
        // Bind to contract + chain via the EIP-712 domain.
        return keccak256(abi.encode(_domainSeparatorV4(), intent.lender, intent.borrower, intent.nonceAmina));
    }

    function hashDealIntent(Types.DealIntent calldata intent) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712Hashes.hashDealIntent(intent));
    }

    /// @notice Atomic 3-sig settlement.
    /// @dev    Caller is ALLOCATOR (matching engine). Provides lender,
    ///         borrower, AMINA signatures. The engine:
    ///           1) verifies KYB, issuers, token kinds, params
    ///           2) verifies all three signatures over EIP-712
    ///           3) burns nonces
    ///           4) records DealTerms (write-once)
    ///           5) pulls supply from lender → vault
    ///           6) pulls collateral from borrower → vault
    ///           7) seeds DealState
    ///           8) emits AdvanceIntent + DealActivated
    function openAndActivate(
        Types.DealIntent calldata intent,
        bytes calldata lenderSig,
        bytes calldata borrowerSig,
        bytes calldata aminaSig,
        address aminaSigner,
        bytes32 settlementRef
    ) external restricted nonReentrant returns (bytes32 dealId) {
        Storage storage $ = _store();
        if ($.globalHalt) revert Errors.GloballyHalted();
        if ($.emergencySealed) revert Errors.EmergencySealed();

        // ----- pre-flight: KYB + issuer + token kind -----
        if (!$.kyb.isApproved(intent.lender)) revert Errors.NotKybApproved(intent.lender);
        if (!$.kyb.isApproved(intent.borrower)) revert Errors.NotKybApproved(intent.borrower);
        if (!$.issuers.isTokenActive(intent.supplyToken)) revert Errors.TokenNotAdmitted(intent.supplyToken);
        if (!$.issuers.isTokenActive(intent.collateralToken)) revert Errors.TokenNotAdmitted(intent.collateralToken);
        if (!$.issuers.isTokenKind(intent.supplyToken, Types.TokenKind.Supply)) revert Errors.WrongTokenKind();
        if (!$.issuers.isTokenKind(intent.collateralToken, Types.TokenKind.Collateral)) revert Errors.WrongTokenKind();

        // ----- pair + params -----
        bytes32 expectedPair = $.collateral.pairKey(intent.collateralToken, intent.supplyToken);
        if (expectedPair != intent.pairKey) revert Errors.TermsMismatch();
        if (!$.collateral.isPairActive(intent.pairKey)) revert Errors.PairNotActive(intent.pairKey);
        Types.ParamsV1 memory params = $.archive.readDecodedV1(intent.pairKey, intent.paramVersion);
        if (intent.rateBps == 0 || intent.rateBps > params.maxRateBps) revert Errors.InvalidParams(bytes32("RATE"));
        if (intent.maturityTs <= intent.startTs) revert Errors.InvalidParams(bytes32("MATURITY"));
        if (uint256(intent.maturityTs) - uint256(intent.startTs) > uint256(params.maxMaturity)) {
            revert Errors.InvalidParams(bytes32("MAX_MATURITY"));
        }
        if (block.timestamp < intent.startTs || block.timestamp > intent.maturityTs) {
            revert Errors.MaturityExpired();
        }

        // ----- signatures -----
        bytes32 typedHash = _hashTypedDataV4(EIP712Hashes.hashDealIntent(intent));
        if (!SignatureChecker.isValidSignatureNow(intent.lender, typedHash, lenderSig)) {
            revert Errors.InvalidSignature(intent.lender);
        }
        if (!SignatureChecker.isValidSignatureNow(intent.borrower, typedHash, borrowerSig)) {
            revert Errors.InvalidSignature(intent.borrower);
        }
        if (!SignatureChecker.isValidSignatureNow(aminaSigner, typedHash, aminaSig)) {
            revert Errors.InvalidSignature(aminaSigner);
        }

        // ----- nonces -----
        if ($.deals.nonceUsed(intent.lender, intent.nonceLender)) revert Errors.NonceUsed(intent.lender, intent.nonceLender);
        if ($.deals.nonceUsed(intent.borrower, intent.nonceBorrower)) revert Errors.NonceUsed(intent.borrower, intent.nonceBorrower);
        if ($.deals.nonceUsed(aminaSigner, intent.nonceAmina)) revert Errors.NonceUsed(aminaSigner, intent.nonceAmina);
        $.deals.markNonceUsed(intent.lender, intent.nonceLender);
        $.deals.markNonceUsed(intent.borrower, intent.nonceBorrower);
        $.deals.markNonceUsed(aminaSigner, intent.nonceAmina);

        // ----- compliance pre-hooks -----
        dealId = keccak256(abi.encode(_domainSeparatorV4(), intent.lender, intent.borrower, intent.nonceAmina));
        (bool ok, bytes32 reason) = $.compliance.preCheck(
            intent.supplyToken, HookAction.ACTIVATE, intent.lender, intent.borrower, intent.principal, dealId
        );
        if (!ok) revert Errors.InvalidParams(reason);
        (ok, reason) = $.compliance.preCheck(
            intent.collateralToken, HookAction.ACTIVATE, intent.borrower, address($.vault), intent.collateralAmount, dealId
        );
        if (!ok) revert Errors.InvalidParams(reason);

        // ----- record terms (write-once) -----
        $.deals.record(dealId, _termsFromIntent(intent));

        // ----- caps -----
        uint256 principalUsd = _tokenToUsd(intent.principal, intent.supplyToken, params.priceSourceSupply, params.oracleDecimalsSupply, params.heartbeatSupply);
        _chargeCaps($, intent.lender, intent.borrower, principalUsd);
        $.issuers.chargeCap(intent.supplyToken, principalUsd);
        $.dealPrincipalUsd[dealId] = principalUsd;

        // ----- atomic transfers -----
        // supply: lender → vault → borrower
        $.vault.pull(dealId, intent.supplyToken, intent.lender, intent.principal);
        $.vault.debit(dealId, intent.supplyToken, intent.borrower, intent.principal);
        // collateral: borrower → vault
        $.vault.pull(dealId, intent.collateralToken, intent.borrower, intent.collateralAmount);

        // ----- seed state -----
        $.state[dealId] = Types.DealState({
            state: Types.DealStateEnum.Active,
            outstanding: intent.principal,
            collateralPosted: intent.collateralAmount,
            lastTouchTs: uint64(block.timestamp),
            liquidationStep: 0,
            pauseStartedAt: 0,
            totalPausedTime: 0,
            lastPauseReason: bytes32(0),
            versionKey: intent.paramVersion
        });

        // ----- events -----
        $.router.emitAdvanceIntent(dealId, intent.supplyToken, intent.principal, intent.borrower, settlementRef, uint64(block.timestamp + 7 days));
        $.router.emitDealActivated(dealId, intent.lender, intent.borrower, intent.principal);
        emit DealActivated(dealId, intent.lender, intent.borrower, intent.principal);

        // ----- post-notify (try/catch in registry) -----
        $.compliance.postNotify(intent.supplyToken, HookAction.ACTIVATE, intent.lender, intent.borrower, intent.principal, dealId);
        $.compliance.postNotify(intent.collateralToken, HookAction.ACTIVATE, intent.borrower, address($.vault), intent.collateralAmount, dealId);
    }

    // ================================================================
    // CORE FLOW — repay + top-up
    // ================================================================

    /// @notice Borrower repays principal + accrued simple interest.
    ///         Once outstanding hits 0, attempts a non-reverting
    ///         collateral release (D18); on freeze, state goes to
    ///         `Repaid_PendingCollateralRelease` and the borrower can
    ///         later call `claimUnreleasedCollateral`.
    function repay(bytes32 dealId, uint128 amount) external nonReentrant {
        Storage storage $ = _store();
        if ($.emergencySealed) revert Errors.EmergencySealed();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState storage st = $.state[dealId];
        if (
            st.state != Types.DealStateEnum.Active && st.state != Types.DealStateEnum.Warned
                && st.state != Types.DealStateEnum.PartialLiquidated
        ) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        if (msg.sender != terms.borrower) revert Errors.InvalidCaller(msg.sender);
        if (amount == 0) revert Errors.ZeroAmount();

        // accrue interest into outstanding
        uint128 outstanding = _accrue(terms, st);
        uint128 toRepay = amount > outstanding ? outstanding : amount;

        // compliance pre
        (bool ok, bytes32 reason) =
            $.compliance.preCheck(terms.supplyToken, HookAction.REPAY, msg.sender, terms.lender, toRepay, dealId);
        if (!ok) revert Errors.InvalidParams(reason);

        // pull supply from borrower → vault, then debit to lender
        $.vault.pull(dealId, terms.supplyToken, msg.sender, toRepay);
        $.vault.debit(dealId, terms.supplyToken, terms.lender, toRepay);

        outstanding -= toRepay;
        st.outstanding = outstanding;
        st.lastTouchTs = uint64(block.timestamp);

        bool collateralReleased = false;
        if (outstanding == 0) {
            // try non-reverting collateral release
            uint256 coll = $.vault.getBalance(dealId, terms.collateralToken);
            if (coll > 0) {
                (bool relOk, ) = $.vault.tryReleaseCollateral(dealId, terms.collateralToken, terms.borrower, coll);
                if (relOk) {
                    st.state = Types.DealStateEnum.Repaid;
                    collateralReleased = true;
                } else {
                    st.state = Types.DealStateEnum.Repaid_PendingCollateralRelease;
                }
            } else {
                st.state = Types.DealStateEnum.Repaid;
                collateralReleased = true;
            }
            // release caps (use captured USD value; no oracle call needed)
            uint256 principalUsd = $.dealPrincipalUsd[dealId];
            _releaseCaps($, terms.lender, terms.borrower, principalUsd);
            $.issuers.releaseCap(terms.supplyToken, principalUsd);
            $.dealPrincipalUsd[dealId] = 0;
        }

        $.router.emitRepaid(dealId, toRepay, collateralReleased);
        emit DealRepaid(dealId, toRepay, collateralReleased);
        $.compliance.postNotify(terms.supplyToken, HookAction.REPAY, msg.sender, terms.lender, toRepay, dealId);
    }

    /// @notice Borrower posts additional collateral.
    function topUpCollateral(bytes32 dealId, uint256 amount) external nonReentrant {
        Storage storage $ = _store();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState storage st = $.state[dealId];
        if (st.state != Types.DealStateEnum.Active && st.state != Types.DealStateEnum.Warned) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        if (msg.sender != terms.borrower) revert Errors.InvalidCaller(msg.sender);
        if (amount == 0) revert Errors.ZeroAmount();
        $.vault.pull(dealId, terms.collateralToken, msg.sender, amount);
        st.collateralPosted += uint128(amount);
        // recover from warned if HF is healthy again
        if (st.state == Types.DealStateEnum.Warned) {
            uint256 hf = _hfBps(dealId);
            Types.ParamsV1 memory p = _readEffectiveParams(terms);
            if (hf > p.warningBps) {
                st.state = Types.DealStateEnum.Active;
            }
        }
        emit TopUp(dealId, amount);
    }

    /// @notice Recovery path — borrower claims collateral that was
    ///         stuck in `Repaid_PendingCollateralRelease`.
    function claimUnreleasedCollateral(bytes32 dealId) external nonReentrant {
        Storage storage $ = _store();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState storage st = $.state[dealId];
        if (st.state != Types.DealStateEnum.Repaid_PendingCollateralRelease) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        if (msg.sender != terms.borrower) revert Errors.InvalidCaller(msg.sender);
        uint256 coll = $.vault.getBalance(dealId, terms.collateralToken);
        if (coll == 0) revert Errors.ZeroAmount();
        (bool ok, bytes32 reason) =
            $.vault.tryReleaseCollateral(dealId, terms.collateralToken, terms.borrower, coll);
        if (!ok) revert Errors.TokenAdmissionFailed(terms.collateralToken, reason);
        st.state = Types.DealStateEnum.Repaid;
        emit UnreleasedCollateralClaimed(dealId, coll);
    }

    // ================================================================
    // HANDLER HOOKS — called by LiquidationHandler
    // ================================================================

    modifier onlyHandler() {
        if (msg.sender != _store().handler) revert Errors.InvalidCaller(msg.sender);
        _;
    }

    /// @notice Privileged passthrough that lets the LiquidationHandler
    ///         move funds out of the vault. The engine is the only
    ///         caller the vault accepts; the handler funnels through here.
    function debitForHandler(bytes32 dealId, address token, address to, uint256 amount) external onlyHandler {
        _store().vault.debit(dealId, token, to, amount);
    }

    function setWarned(bytes32 dealId) external onlyHandler {
        Storage storage $ = _store();
        Types.DealState storage st = $.state[dealId];
        if (st.state != Types.DealStateEnum.Active) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        st.state = Types.DealStateEnum.Warned;
        st.liquidationStep = 0;
        st.lastTouchTs = uint64(block.timestamp);
    }

    function applyPartialLiquidation(bytes32 dealId, uint128 debtCovered, uint128 collateralSeized)
        external
        onlyHandler
    {
        Storage storage $ = _store();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState storage st = $.state[dealId];
        if (st.state != Types.DealStateEnum.Warned && st.state != Types.DealStateEnum.Active) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        uint128 outstanding = _accrue(terms, st);
        if (debtCovered > outstanding) revert Errors.PrincipalTooHigh();
        if (collateralSeized > st.collateralPosted) revert Errors.CollateralTooLow();
        st.outstanding = outstanding - debtCovered;
        st.collateralPosted -= collateralSeized;
        st.state = Types.DealStateEnum.PartialLiquidated;
        if (st.liquidationStep < 1) st.liquidationStep = 1;
        st.lastTouchTs = uint64(block.timestamp);
    }

    function applyFullLiquidation(
        bytes32 dealId,
        uint128 debtCovered,
        uint128 collateralSeized,
        uint128 surplusToBorrower
    ) external onlyHandler {
        Storage storage $ = _store();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState storage st = $.state[dealId];
        if (
            st.state != Types.DealStateEnum.Active && st.state != Types.DealStateEnum.Warned
                && st.state != Types.DealStateEnum.PartialLiquidated
        ) {
            revert Errors.DealStateForbidden(dealId, uint8(st.state));
        }
        uint128 outstanding = _accrue(terms, st);
        if (debtCovered > outstanding) revert Errors.PrincipalTooHigh();
        if (collateralSeized > st.collateralPosted) revert Errors.CollateralTooLow();
        if (surplusToBorrower > st.collateralPosted - collateralSeized) revert Errors.CollateralTooLow();
        st.outstanding = outstanding - debtCovered;
        st.collateralPosted = st.collateralPosted - collateralSeized - surplusToBorrower;
        st.state = st.outstanding == 0 ? Types.DealStateEnum.Liquidated : Types.DealStateEnum.Defaulted;
        st.liquidationStep = 2;
        st.lastTouchTs = uint64(block.timestamp);

        // release caps using captured USD (no oracle call)
        uint256 principalUsd = $.dealPrincipalUsd[dealId];
        if (principalUsd > 0) {
            _releaseCaps($, terms.lender, terms.borrower, principalUsd);
            $.issuers.releaseCap(terms.supplyToken, principalUsd);
            $.dealPrincipalUsd[dealId] = 0;
        }
    }

    // ================================================================
    // VIEWS
    // ================================================================

    function getDealState(bytes32 dealId) external view returns (Types.DealState memory) {
        return _store().state[dealId];
    }

    function getOracleOverride(bytes32 dealId) external view returns (Types.OracleOverride memory) {
        return _store().oracleOverride[dealId];
    }

    function getEffectiveOracles(bytes32 dealId)
        external
        view
        returns (address collateralOracle, address supplyOracle)
    {
        Storage storage $ = _store();
        Types.OracleOverride storage o = $.oracleOverride[dealId];
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        if (o.effectiveAt != 0 && block.timestamp >= o.effectiveAt) {
            return (o.overrideCollateralOracle, o.overrideSupplyOracle);
        }
        Types.ParamsV1 memory params = $.archive.readDecodedV1(terms.pairKey, terms.paramVersion);
        return (params.priceSourceCollateral, params.priceSourceSupply);
    }

    function computeOutstanding(bytes32 dealId) external view returns (uint128) {
        Storage storage $ = _store();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState memory st = $.state[dealId];
        return _accrueView(terms, st);
    }

    /// @notice HF = collateralValueUsd * 1e4 / debtValueUsd. > 1e4 means healthy.
    function healthFactorBps(bytes32 dealId) external view returns (uint256) {
        return _hfBps(dealId);
    }

    function totals()
        external
        view
        returns (uint256 globalCap, uint256 globalUsed, bool halted, bool sealed_)
    {
        Storage storage $ = _store();
        return ($.globalCapUsd, $.globalUsedUsd, $.globalHalt, $.emergencySealed);
    }

    function getActorCap(address who, bool isLender) external view returns (uint256 cap, uint256 used) {
        Storage storage $ = _store();
        cap = isLender ? $.lenderCapUsd[who] : $.borrowerCapUsd[who];
        used = isLender ? $.lenderUsedUsd[who] : $.borrowerUsedUsd[who];
    }

    function handler() external view returns (address) {
        return _store().handler;
    }

    function vault() external view returns (address) {
        return address(_store().vault);
    }

    function router() external view returns (address) {
        return address(_store().router);
    }

    function deals() external view returns (address) {
        return address(_store().deals);
    }

    // ================================================================
    // INTERNALS
    // ================================================================

    function _readEffectiveParams(Types.DealTerms memory terms) internal view returns (Types.ParamsV1 memory) {
        Storage storage $ = _store();
        Types.ParamsV1 memory p = $.archive.readDecodedV1(terms.pairKey, terms.paramVersion);
        Types.OracleOverride storage o = $.oracleOverride[_dealIdForTerms(terms)];
        if (o.effectiveAt != 0 && block.timestamp >= o.effectiveAt) {
            p.priceSourceCollateral = o.overrideCollateralOracle;
            p.priceSourceSupply = o.overrideSupplyOracle;
        }
        return p;
    }

    function _dealIdForTerms(Types.DealTerms memory t) internal view returns (bytes32) {
        // Mirrors openAndActivate.
        return keccak256(abi.encode(_domainSeparatorV4(), t.lender, t.borrower, t.nonceAmina));
    }

    function _accrue(Types.DealTerms memory terms, Types.DealState storage st) internal view returns (uint128) {
        return _accrueCore(
            terms, st.outstanding, st.lastTouchTs, st.totalPausedTime, st.pauseStartedAt
        );
    }

    function _accrueView(Types.DealTerms memory terms, Types.DealState memory st) internal view returns (uint128) {
        return _accrueCore(terms, st.outstanding, st.lastTouchTs, st.totalPausedTime, st.pauseStartedAt);
    }

    function _accrueCore(
        Types.DealTerms memory terms,
        uint128 outstanding,
        uint64 lastTouchTs,
        uint64 totalPausedTime,
        uint64 pauseStartedAt
    ) internal view returns (uint128) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 effEnd = nowTs > terms.maturityTs ? terms.maturityTs : nowTs;
        uint64 effStart = lastTouchTs == 0 ? terms.startTs : lastTouchTs;
        if (effEnd <= effStart) return outstanding;
        uint64 elapsed = effEnd - effStart;
        // Total paused time = accumulated unpaused windows + current open window (if any).
        uint64 currentPause = pauseStartedAt != 0 ? (nowTs - pauseStartedAt) : 0;
        uint64 pauseAdj = totalPausedTime + currentPause;
        uint64 effElapsed = elapsed > pauseAdj ? elapsed - pauseAdj : 0;
        uint256 interest =
            (uint256(outstanding) * uint256(terms.rateBps) * uint256(effElapsed)) / (10_000 * 365 days);
        return uint128(uint256(outstanding) + interest);
    }

    function _hfBps(bytes32 dealId) internal view returns (uint256) {
        Storage storage $ = _store();
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.DealState memory st = $.state[dealId];
        if (st.outstanding == 0) return type(uint256).max;
        Types.ParamsV1 memory p = $.archive.readDecodedV1(terms.pairKey, terms.paramVersion);

        (address co, address so) = (p.priceSourceCollateral, p.priceSourceSupply);
        Types.OracleOverride storage o = $.oracleOverride[dealId];
        if (o.effectiveAt != 0 && block.timestamp >= o.effectiveAt) {
            (co, so) = (o.overrideCollateralOracle, o.overrideSupplyOracle);
        }

        uint256 collateralUsd = _tokenToUsd(st.collateralPosted, terms.collateralToken, co, p.oracleDecimalsCollateral, p.heartbeatCollateral);
        uint128 out = _accrueView(terms, st);
        uint256 debtUsd = _tokenToUsd(out, terms.supplyToken, so, p.oracleDecimalsSupply, p.heartbeatSupply);
        if (debtUsd == 0) return type(uint256).max;
        return (collateralUsd * 10_000) / debtUsd;
    }

    function _tokenToUsd(
        uint256 amount,
        address token,
        address feed,
        uint8 priceDecimals,
        uint32 heartbeat
    ) internal view returns (uint256) {
        if (amount == 0) return 0;
        AggregatorV3Interface oracle = AggregatorV3Interface(feed);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        if (answer <= 0) revert Errors.OracleStale(feed);
        if (block.timestamp - updatedAt > heartbeat) revert Errors.OracleStale(feed);
        uint8 tokenDecimals = _tokenDecimals(token);
        return MathLib.tokenToUsd(amount, uint256(answer), tokenDecimals, priceDecimals);
    }

    function _tokenDecimals(address token) internal view returns (uint8) {
        Storage storage $ = _store();
        Types.TokenInfo memory info = $.issuers.getTokenInfo(token);
        return info.decimals;
    }

    function _termsFromIntent(Types.DealIntent calldata intent) internal pure returns (Types.DealTerms memory) {
        return Types.DealTerms({
            lender: intent.lender,
            borrower: intent.borrower,
            supplyToken: intent.supplyToken,
            collateralToken: intent.collateralToken,
            principal: intent.principal,
            collateralAmount: intent.collateralAmount,
            rateBps: intent.rateBps,
            startTs: intent.startTs,
            maturityTs: intent.maturityTs,
            pairKey: intent.pairKey,
            paramVersion: intent.paramVersion,
            nonceLender: intent.nonceLender,
            nonceBorrower: intent.nonceBorrower,
            nonceAmina: intent.nonceAmina,
            legalTermsHash: intent.legalTermsHash
        });
    }

    function _chargeCaps(Storage storage $, address lender, address borrower, uint256 amountUsd) internal {
        uint256 newGlobal = $.globalUsedUsd + amountUsd;
        if ($.globalCapUsd != 0 && newGlobal > $.globalCapUsd) revert Errors.CapExceeded(bytes32("GLOBAL_CAP"));
        $.globalUsedUsd = newGlobal;

        uint256 newBorrower = $.borrowerUsedUsd[borrower] + amountUsd;
        uint256 borrowerCap = $.borrowerCapUsd[borrower];
        if (borrowerCap != 0 && newBorrower > borrowerCap) revert Errors.CapExceeded(bytes32("BORROWER_CAP"));
        $.borrowerUsedUsd[borrower] = newBorrower;

        uint256 newLender = $.lenderUsedUsd[lender] + amountUsd;
        uint256 lenderCap = $.lenderCapUsd[lender];
        if (lenderCap != 0 && newLender > lenderCap) revert Errors.CapExceeded(bytes32("LENDER_CAP"));
        $.lenderUsedUsd[lender] = newLender;
    }

    function _releaseCaps(Storage storage $, address lender, address borrower, uint256 amountUsd) internal {
        $.globalUsedUsd = amountUsd >= $.globalUsedUsd ? 0 : $.globalUsedUsd - amountUsd;
        $.borrowerUsedUsd[borrower] = amountUsd >= $.borrowerUsedUsd[borrower] ? 0 : $.borrowerUsedUsd[borrower] - amountUsd;
        $.lenderUsedUsd[lender] = amountUsd >= $.lenderUsedUsd[lender] ? 0 : $.lenderUsedUsd[lender] - amountUsd;
    }

    function _isTerminal(Types.DealStateEnum s) internal pure returns (bool) {
        return s == Types.DealStateEnum.Repaid || s == Types.DealStateEnum.Repaid_PendingCollateralRelease
            || s == Types.DealStateEnum.Liquidated || s == Types.DealStateEnum.Defaulted;
    }

    function _authorizeUpgrade(address) internal override restricted {}

    function _store() private pure returns (Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
