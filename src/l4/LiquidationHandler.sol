// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessManagedUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {ISettlementRouter} from "../interfaces/ISettlementRouter.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {IDealRegistry} from "../interfaces/IDealRegistry.sol";
import {IParameterArchive} from "../interfaces/IParameterArchive.sol";
import {IComplianceRegistry, HookAction} from "../interfaces/IComplianceRegistry.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";
import {EIP712Hashes} from "../libraries/EIP712Hashes.sol";
import {MathLib} from "../libraries/Math.sol";

interface ILendingEngineDebit {
    function debitForHandler(bytes32 dealId, address token, address to, uint256 amount) external;
}

/// @title LiquidationHandler — three-phase liquidation flow.
/// @notice Only LIQUIDATOR (AMINA) can call. Dual-price attestation
///         signed by AMINA's oracle key in EIP-712 binds the
///         (collateralPrice, supplyPrice) to a specific deal so it
///         cannot be replayed across deals. Steps:
///           0 → warn
///           1 → partial (cover up to half the debt, seize equiv collateral + bonus + fee)
///           2 → full (cover all debt, refund surplus to borrower)
contract LiquidationHandler is
    Initializable,
    UUPSUpgradeable,
    AccessManagedUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable
{
    using MathLib for uint256;

    /// @custom:storage-location erc7201:p2pxamina.liqhandler.v1
    struct Storage {
        ILendingEngine engine;
        ISettlementRouter router;
        IEscrowVault vault;
        IDealRegistry deals;
        IParameterArchive archive;
        IComplianceRegistry compliance;
        address attestor; // AMINA's signing key for dual-price attestation
        address aminaTreasury; // where AMINA fee + bonus + seized collateral go
        uint64 attestationStaleSecs;
    }

    bytes32 private constant STORAGE_SLOT =
        0xd1c2b3a4958685746362514a3b2c1d0fe9e8d7c6b5a4938271605f4e3d2c1b00;

    event WarnIssued(bytes32 indexed dealId, uint256 hfBps);
    event PartialIssued(bytes32 indexed dealId, uint256 debtCovered, uint256 collateralSeized);
    event FullIssued(bytes32 indexed dealId, uint256 debtCovered, uint256 collateralSeized, uint256 surplus);
    event AttestorSet(address indexed who);
    event AminaTreasurySet(address indexed who);
    event AttestationStaleSecsSet(uint64 secs);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct InitParams {
        address authority;
        address engine;
        address router;
        address vault;
        address deals;
        address archive;
        address compliance;
        address attestor;
        address aminaTreasury;
        uint64 attestationStaleSecs;
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessManaged_init(p.authority);
        __UUPSUpgradeable_init();
        __EIP712_init("P2PxAmina", "1");
        __ReentrancyGuard_init();
        Storage storage $ = _store();
        $.engine = ILendingEngine(p.engine);
        $.router = ISettlementRouter(p.router);
        $.vault = IEscrowVault(p.vault);
        $.deals = IDealRegistry(p.deals);
        $.archive = IParameterArchive(p.archive);
        $.compliance = IComplianceRegistry(p.compliance);
        $.attestor = p.attestor;
        $.aminaTreasury = p.aminaTreasury;
        $.attestationStaleSecs = p.attestationStaleSecs == 0 ? 10 minutes : p.attestationStaleSecs;
    }

    // ---------------- admin ----------------

    function setAttestor(address who) external restricted {
        _store().attestor = who;
        emit AttestorSet(who);
    }

    function setAminaTreasury(address who) external restricted {
        _store().aminaTreasury = who;
        emit AminaTreasurySet(who);
    }

    function setAttestationStaleSecs(uint64 secs) external restricted {
        _store().attestationStaleSecs = secs;
        emit AttestationStaleSecsSet(secs);
    }

    // ---------------- liquidation steps ----------------

    /// @notice Step 0 — warn. AMINA observes HF < warningBps and flags
    ///         the deal; borrower gets a grace window to top up.
    function warn(bytes32 dealId, Types.DualPriceAttestation calldata att, bytes calldata aminaSig)
        external
        restricted
        nonReentrant
    {
        Storage storage $ = _store();
        _checkAttestation(att, aminaSig, dealId);
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.ParamsV1 memory p = $.archive.readDecodedV1(terms.pairKey, terms.paramVersion);
        uint256 hf = _hfBpsFromAtt(terms, att, p);
        if (hf >= p.warningBps) revert Errors.LiquidationNotAllowedYet();
        $.engine.setWarned(dealId);
        $.router.emitLiquidationWarn(dealId, hf);
        emit WarnIssued(dealId, hf);
    }

    /// @notice Step 1 — partial. Cover up to half the debt; seize
    ///         equivalent collateral + bonus + fee; route to AMINA
    ///         treasury (which then settles with the lender off-chain).
    function partialLiquidate(
        bytes32 dealId,
        Types.DualPriceAttestation calldata att,
        bytes calldata aminaSig,
        uint128 debtToCover
    ) external restricted nonReentrant {
        Storage storage $ = _store();
        _checkAttestation(att, aminaSig, dealId);
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.ParamsV1 memory p = $.archive.readDecodedV1(terms.pairKey, terms.paramVersion);
        uint256 hf = _hfBpsFromAtt(terms, att, p);
        if (hf >= p.partialLiqBps) revert Errors.LiquidationNotAllowedYet();
        if (debtToCover == 0) revert Errors.ZeroAmount();

        uint128 outstanding = $.engine.computeOutstanding(dealId);
        uint128 cap = outstanding / 2;
        if (debtToCover > cap) debtToCover = cap;

        uint256 collForDebt = _collateralForDebt(uint256(debtToCover), att, p, terms);
        uint256 bonus = MathLib.bps(collForDebt, p.liquidationBonusBps);
        uint256 fee = MathLib.bps(collForDebt, p.aminaFeeBps);
        uint256 totalSeized = collForDebt + bonus + fee;

        Types.DealState memory st = $.engine.getDealState(dealId);
        if (totalSeized > st.collateralPosted) revert Errors.LiquidationBoundExceeded();

        ILendingEngine($.engine).applyPartialLiquidation(dealId, debtToCover, uint128(totalSeized));
        ILendingEngineDebit(address($.engine)).debitForHandler(
            dealId, terms.collateralToken, $.aminaTreasury, totalSeized
        );

        $.router.emitLiquidationPartial(dealId, totalSeized, debtToCover);
        emit PartialIssued(dealId, debtToCover, totalSeized);
    }

    /// @notice Step 2 — full. Repay all outstanding, seize what's
    ///         needed + bonus + fee, refund surplus to borrower.
    function fullLiquidate(bytes32 dealId, Types.DualPriceAttestation calldata att, bytes calldata aminaSig)
        external
        restricted
        nonReentrant
    {
        Storage storage $ = _store();
        _checkAttestation(att, aminaSig, dealId);
        Types.DealTerms memory terms = $.deals.getTerms(dealId);
        Types.ParamsV1 memory p = $.archive.readDecodedV1(terms.pairKey, terms.paramVersion);
        uint256 hf = _hfBpsFromAtt(terms, att, p);
        if (hf >= p.fullLiqBps) revert Errors.LiquidationNotAllowedYet();

        uint128 outstanding = $.engine.computeOutstanding(dealId);
        Types.DealState memory st = $.engine.getDealState(dealId);
        uint256 collForDebt = _collateralForDebt(uint256(outstanding), att, p, terms);
        uint256 bonus = MathLib.bps(collForDebt, p.liquidationBonusBps);
        uint256 fee = MathLib.bps(collForDebt, p.aminaFeeBps);
        uint256 totalCost = collForDebt + bonus + fee;

        uint128 collateralToSeize;
        uint128 surplus;
        if (totalCost >= st.collateralPosted) {
            collateralToSeize = st.collateralPosted;
            surplus = 0;
        } else {
            collateralToSeize = uint128(totalCost);
            surplus = uint128(st.collateralPosted - totalCost);
        }

        ILendingEngine($.engine).applyFullLiquidation(dealId, outstanding, collateralToSeize, surplus);
        if (collateralToSeize > 0) {
            ILendingEngineDebit(address($.engine)).debitForHandler(
                dealId, terms.collateralToken, $.aminaTreasury, collateralToSeize
            );
        }
        if (surplus > 0) {
            ILendingEngineDebit(address($.engine)).debitForHandler(
                dealId, terms.collateralToken, terms.borrower, surplus
            );
        }

        $.router.emitLiquidationFull(dealId, collateralToSeize, outstanding, surplus);
        emit FullIssued(dealId, outstanding, collateralToSeize, surplus);
    }

    // ---------------- views ----------------

    function attestor() external view returns (address) {
        return _store().attestor;
    }

    function aminaTreasury() external view returns (address) {
        return _store().aminaTreasury;
    }

    function attestationStaleSecs() external view returns (uint64) {
        return _store().attestationStaleSecs;
    }

    function hashAttestation(Types.DualPriceAttestation calldata att) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712Hashes.hashAttestation(att));
    }

    // ---------------- internals ----------------

    function _checkAttestation(
        Types.DualPriceAttestation calldata att,
        bytes calldata aminaSig,
        bytes32 dealId
    ) internal view {
        if (att.dealId != dealId) revert Errors.AttestationDealIdMismatch();
        if (block.timestamp - uint256(att.observationTs) > uint256(_store().attestationStaleSecs)) {
            revert Errors.AttestationStale();
        }
        bytes32 typedHash = _hashTypedDataV4(EIP712Hashes.hashAttestation(att));
        address signer = _store().attestor;
        if (!SignatureChecker.isValidSignatureNow(signer, typedHash, aminaSig)) {
            revert Errors.AttestationSignerMismatch(signer, address(0));
        }
    }

    function _hfBpsFromAtt(
        Types.DealTerms memory terms,
        Types.DualPriceAttestation calldata att,
        Types.ParamsV1 memory p
    ) internal view returns (uint256) {
        Storage storage $ = _store();
        Types.DealState memory st = $.engine.getDealState(att.dealId);
        if (st.outstanding == 0) return type(uint256).max;
        uint128 outstanding = $.engine.computeOutstanding(att.dealId);
        uint8 collDecimals = IERC20Metadata(terms.collateralToken).decimals();
        uint8 suppDecimals = IERC20Metadata(terms.supplyToken).decimals();
        uint256 collUsd = MathLib.tokenToUsd(
            st.collateralPosted, att.observedCollateralPrice, collDecimals, p.oracleDecimalsCollateral
        );
        uint256 debtUsd =
            MathLib.tokenToUsd(outstanding, att.observedSupplyPrice, suppDecimals, p.oracleDecimalsSupply);
        if (debtUsd == 0) return type(uint256).max;
        return (collUsd * 10_000) / debtUsd;
    }

    function _collateralForDebt(
        uint256 debtAmount,
        Types.DualPriceAttestation calldata att,
        Types.ParamsV1 memory p,
        Types.DealTerms memory terms
    ) internal view returns (uint256) {
        uint8 collDecimals = IERC20Metadata(terms.collateralToken).decimals();
        uint8 suppDecimals = IERC20Metadata(terms.supplyToken).decimals();
        uint256 debtUsd =
            MathLib.tokenToUsd(debtAmount, att.observedSupplyPrice, suppDecimals, p.oracleDecimalsSupply);
        return MathLib.usdToToken(debtUsd, att.observedCollateralPrice, collDecimals, p.oracleDecimalsCollateral);
    }

    function _authorizeUpgrade(address) internal override restricted {}

    function _store() private pure returns (Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
