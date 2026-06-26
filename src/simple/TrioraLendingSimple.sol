// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrioraAccountToken} from "./TrioraAccountToken.sol";

/// @title TrioraLendingSimple
/// @notice Minimal AMINA-operated loan state machine for custody-backed accounting tokens.
contract TrioraLendingSimple is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant YEAR = 365 days;
    uint64 public constant LIQUIDATION_DELAY = 24 hours;
    bytes32 public constant LIQUIDATION_ORACLE_REPORT_TYPEHASH = keccak256(
        "LiquidationOracleReport(bytes32 dealId,bytes32 legalTermsHash,address collateralToken,address principalToken,uint256 debtValue,uint256 collateralValue,uint32 liquidationThresholdBps,uint64 observedAt,uint64 expiresAt,bytes32 reportRef)"
    );

    enum DealState {
        None,
        SettlementPending,
        Active,
        RepaymentRequested,
        ReleasePending,
        Closed,
        LiquidationPending,
        Liquidated,
        Cancelled
    }

    struct OpenDealParams {
        address lender;
        address borrower;
        TrioraAccountToken collateralToken;
        TrioraAccountToken principalToken;
        uint256 principalAmount;
        uint256 collateralAmount;
        uint32 rateBps;
        uint64 maturityTs;
        bytes32 legalTermsHash;
        bytes32 collateralRef;
        bytes32 reserveRef;
        bytes32 borrowerReleaseRef;
        bytes32 lenderSettlementRef;
        bytes32 aminaLiquidationRef;
    }

    struct Deal {
        address lender;
        address borrower;
        TrioraAccountToken collateralToken;
        TrioraAccountToken principalToken;
        uint256 principalAmount;
        uint256 collateralAmount;
        uint32 rateBps;
        uint64 maturityTs;
        uint64 fundedAt;
        uint256 repayQuote;
        DealState state;
        bytes32 legalTermsHash;
        bytes32 collateralRef;
        bytes32 reserveRef;
        bytes32 borrowerReleaseRef;
        bytes32 lenderSettlementRef;
        bytes32 aminaLiquidationRef;
    }

    struct LiquidationOracleReport {
        bytes32 dealId;
        bytes32 legalTermsHash;
        address collateralToken;
        address principalToken;
        uint256 debtValue;
        uint256 collateralValue;
        uint32 liquidationThresholdBps;
        uint64 observedAt;
        uint64 expiresAt;
        bytes32 reportRef;
    }

    struct PendingLiquidation {
        DealState previousState;
        uint64 requestedAt;
        bytes32 initialReportRef;
        uint256 initialDebtValue;
        uint256 initialCollateralValue;
        uint32 liquidationThresholdBps;
    }

    address public immutable amina;
    address public immutable chainlinkOracle;
    uint256 public dealNonce;

    mapping(address account => bool isApproved) public approved;
    mapping(bytes32 dealId => Deal deal) private _deals;
    mapping(bytes32 dealId => PendingLiquidation pending) private _pendingLiquidations;

    event EntityApproved(address indexed account, bool approved, bytes32 indexed evidenceRef);
    event DealOpened(
        bytes32 indexed dealId,
        address indexed lender,
        address indexed borrower,
        address collateralToken,
        address principalToken,
        uint256 principalAmount,
        uint256 collateralAmount
    );
    event FundingInstruction(
        bytes32 indexed dealId,
        bytes32 indexed reserveRef,
        bytes32 indexed lenderSettlementRef,
        uint256 amount,
        uint64 deadline
    );
    event FundingConfirmed(bytes32 indexed dealId, bytes32 indexed settlementRef, uint64 fundedAt);
    event DealCancelled(bytes32 indexed dealId, bytes32 indexed reasonRef);
    event RepaymentInstruction(
        bytes32 indexed dealId, bytes32 indexed reserveRef, uint256 amount, bytes32 indexed lenderSettlementRef
    );
    event RepaymentConfirmed(bytes32 indexed dealId, bytes32 indexed settlementRef, uint256 amount);
    event CollateralReleaseInstruction(
        bytes32 indexed dealId, bytes32 indexed collateralRef, bytes32 indexed borrowerReleaseRef, uint256 amount
    );
    event CollateralReleased(bytes32 indexed dealId, bytes32 indexed releaseRef);
    event LiquidationInstruction(
        bytes32 indexed dealId,
        bytes32 indexed collateralRef,
        bytes32 indexed aminaLiquidationRef,
        uint256 amount,
        bytes32 reportRef,
        uint64 cureDeadline
    );
    event LiquidationFinalized(bytes32 indexed dealId, bytes32 indexed settlementRef, bytes32 indexed reportRef);
    event LiquidationCancelled(bytes32 indexed dealId, address indexed caller, bytes32 indexed reasonRef);

    error ZeroAddress();
    error ZeroAmount();
    error OnlyAmina(address caller);
    error OnlyBorrower(address caller);
    error NotApproved(address account);
    error DealMissing(bytes32 dealId);
    error DealAlreadyExists(bytes32 dealId);
    error BadState(bytes32 dealId, DealState actual);
    error BadParams(bytes32 reason);
    error InvalidOracleSigner(address recovered);
    error InvalidOracleReport(bytes32 reportRef, bytes32 reason);
    error LiquidationDelayLive(bytes32 dealId, uint64 cureDeadline);

    constructor(address amina_, address chainlinkOracle_) EIP712("TrioraLendingSimple", "1") {
        if (amina_ == address(0) || chainlinkOracle_ == address(0)) revert ZeroAddress();
        amina = amina_;
        chainlinkOracle = chainlinkOracle_;
    }

    modifier onlyAmina() {
        if (msg.sender != amina) revert OnlyAmina(msg.sender);
        _;
    }

    function setApproved(address account, bool isApproved, bytes32 evidenceRef) external onlyAmina {
        if (account == address(0)) revert ZeroAddress();
        _requireRef(evidenceRef);
        approved[account] = isApproved;
        emit EntityApproved(account, isApproved, evidenceRef);
    }

    function openDeal(OpenDealParams calldata p) external onlyAmina nonReentrant returns (bytes32 dealId) {
        _validateOpenDeal(p);

        dealId =
            keccak256(abi.encode(block.chainid, address(this), ++dealNonce, p.lender, p.borrower, p.legalTermsHash));
        if (_deals[dealId].state != DealState.None) revert DealAlreadyExists(dealId);

        _deals[dealId] = Deal({
            lender: p.lender,
            borrower: p.borrower,
            collateralToken: p.collateralToken,
            principalToken: p.principalToken,
            principalAmount: p.principalAmount,
            collateralAmount: p.collateralAmount,
            rateBps: p.rateBps,
            maturityTs: p.maturityTs,
            fundedAt: 0,
            repayQuote: 0,
            state: DealState.SettlementPending,
            legalTermsHash: p.legalTermsHash,
            collateralRef: p.collateralRef,
            reserveRef: p.reserveRef,
            borrowerReleaseRef: p.borrowerReleaseRef,
            lenderSettlementRef: p.lenderSettlementRef,
            aminaLiquidationRef: p.aminaLiquidationRef
        });

        IERC20(address(p.collateralToken)).safeTransferFrom(p.borrower, address(this), p.collateralAmount);
        IERC20(address(p.principalToken)).safeTransferFrom(p.lender, address(this), p.principalAmount);

        emit DealOpened(
            dealId,
            p.lender,
            p.borrower,
            address(p.collateralToken),
            address(p.principalToken),
            p.principalAmount,
            p.collateralAmount
        );
        emit FundingInstruction(dealId, p.reserveRef, p.lenderSettlementRef, p.principalAmount, p.maturityTs);
    }

    function confirmFunding(bytes32 dealId, bytes32 settlementRef) external onlyAmina {
        _requireRef(settlementRef);
        Deal storage deal = _requireDeal(dealId);
        _requireState(dealId, deal, DealState.SettlementPending);

        deal.state = DealState.Active;
        deal.fundedAt = _now64();

        emit FundingConfirmed(dealId, settlementRef, deal.fundedAt);
    }

    function cancelBeforeFunding(bytes32 dealId, bytes32 reasonRef) external onlyAmina nonReentrant {
        _requireRef(reasonRef);
        Deal storage deal = _requireDeal(dealId);
        _requireState(dealId, deal, DealState.SettlementPending);

        deal.state = DealState.Cancelled;
        IERC20(address(deal.collateralToken)).safeTransfer(deal.borrower, deal.collateralAmount);
        IERC20(address(deal.principalToken)).safeTransfer(deal.lender, deal.principalAmount);

        emit DealCancelled(dealId, reasonRef);
    }

    function outstanding(bytes32 dealId) public view returns (uint256) {
        Deal storage deal = _requireDeal(dealId);

        if (deal.state == DealState.Active || deal.state == DealState.LiquidationPending) {
            return _computedOutstanding(deal);
        }
        if (deal.state == DealState.RepaymentRequested || deal.state == DealState.ReleasePending) {
            return deal.repayQuote;
        }
        return 0;
    }

    function requestRepayment(bytes32 dealId) external nonReentrant returns (uint256 repayQuote) {
        Deal storage deal = _requireDeal(dealId);
        if (msg.sender != deal.borrower) revert OnlyBorrower(msg.sender);
        _requireState(dealId, deal, DealState.Active);

        repayQuote = _computedOutstanding(deal);
        deal.repayQuote = repayQuote;
        deal.state = DealState.RepaymentRequested;

        emit RepaymentInstruction(dealId, deal.reserveRef, repayQuote, deal.lenderSettlementRef);
    }

    function confirmRepayment(bytes32 dealId, bytes32 settlementRef) external onlyAmina nonReentrant {
        _requireRef(settlementRef);
        Deal storage deal = _requireDeal(dealId);
        _requireState(dealId, deal, DealState.RepaymentRequested);

        uint256 repayQuote = deal.repayQuote;
        deal.state = DealState.ReleasePending;
        IERC20(address(deal.principalToken)).safeTransfer(deal.lender, deal.principalAmount);

        emit RepaymentConfirmed(dealId, settlementRef, repayQuote);
        emit CollateralReleaseInstruction(dealId, deal.collateralRef, deal.borrowerReleaseRef, deal.collateralAmount);
    }

    function confirmCollateralReleased(bytes32 dealId, bytes32 releaseRef) external onlyAmina nonReentrant {
        _requireRef(releaseRef);
        Deal storage deal = _requireDeal(dealId);
        _requireState(dealId, deal, DealState.ReleasePending);

        deal.state = DealState.Closed;
        deal.collateralToken.burnLocked(deal.collateralAmount, releaseRef);

        emit CollateralReleased(dealId, releaseRef);
    }

    function requestLiquidation(bytes32 dealId, LiquidationOracleReport calldata report, bytes calldata signature)
        external
        onlyAmina
    {
        Deal storage deal = _requireDeal(dealId);
        if (deal.state != DealState.Active && deal.state != DealState.RepaymentRequested) {
            revert BadState(dealId, deal.state);
        }
        _verifyLiquidationReport(dealId, deal, report, signature);

        DealState previousState = deal.state;
        uint64 requestedAt = _now64();
        uint64 cureDeadline = requestedAt + LIQUIDATION_DELAY;
        deal.state = DealState.LiquidationPending;
        _pendingLiquidations[dealId] = PendingLiquidation({
            previousState: previousState,
            requestedAt: requestedAt,
            initialReportRef: report.reportRef,
            initialDebtValue: report.debtValue,
            initialCollateralValue: report.collateralValue,
            liquidationThresholdBps: report.liquidationThresholdBps
        });

        emit LiquidationInstruction(
            dealId, deal.collateralRef, deal.aminaLiquidationRef, deal.collateralAmount, report.reportRef, cureDeadline
        );
    }

    function finalizeLiquidation(
        bytes32 dealId,
        LiquidationOracleReport calldata report,
        bytes calldata signature,
        bytes32 settlementRef
    ) external onlyAmina nonReentrant {
        _requireRef(settlementRef);
        Deal storage deal = _requireDeal(dealId);
        _requireState(dealId, deal, DealState.LiquidationPending);
        PendingLiquidation memory pending = _pendingLiquidations[dealId];
        uint64 cureDeadline = pending.requestedAt + LIQUIDATION_DELAY;
        if (block.timestamp < cureDeadline) revert LiquidationDelayLive(dealId, cureDeadline);
        if (report.observedAt < cureDeadline) revert InvalidOracleReport(report.reportRef, bytes32("EARLY_FINAL"));
        if (report.reportRef == pending.initialReportRef) {
            revert InvalidOracleReport(report.reportRef, bytes32("REUSED"));
        }
        _verifyLiquidationReport(dealId, deal, report, signature);

        deal.state = DealState.Liquidated;
        delete _pendingLiquidations[dealId];
        deal.collateralToken.burnLocked(deal.collateralAmount, settlementRef);
        IERC20(address(deal.principalToken)).safeTransfer(deal.lender, deal.principalAmount);

        emit LiquidationFinalized(dealId, settlementRef, report.reportRef);
    }

    function cancelPendingLiquidation(bytes32 dealId, bytes32 reasonRef) external {
        _requireRef(reasonRef);
        Deal storage deal = _requireDeal(dealId);
        _requireState(dealId, deal, DealState.LiquidationPending);
        PendingLiquidation memory pending = _pendingLiquidations[dealId];
        uint64 cureDeadline = pending.requestedAt + LIQUIDATION_DELAY;
        if (block.timestamp < cureDeadline) revert LiquidationDelayLive(dealId, cureDeadline);

        deal.state = pending.previousState;
        delete _pendingLiquidations[dealId];

        emit LiquidationCancelled(dealId, msg.sender, reasonRef);
    }

    function getDeal(bytes32 dealId) external view returns (Deal memory) {
        return _requireDeal(dealId);
    }

    function getPendingLiquidation(bytes32 dealId) external view returns (PendingLiquidation memory) {
        return _pendingLiquidations[dealId];
    }

    function stateOf(bytes32 dealId) external view returns (DealState) {
        return _deals[dealId].state;
    }

    function hashLiquidationReport(LiquidationOracleReport calldata report) external view returns (bytes32) {
        return _hashLiquidationReport(report);
    }

    function _validateOpenDeal(OpenDealParams calldata p) private view {
        if (p.lender == address(0) || p.borrower == address(0)) revert ZeroAddress();
        if (address(p.collateralToken) == address(0) || address(p.principalToken) == address(0)) {
            revert ZeroAddress();
        }
        if (p.lender == p.borrower) revert BadParams(bytes32("SAME_PARTY"));
        if (address(p.collateralToken) == address(p.principalToken)) revert BadParams(bytes32("SAME_TOKEN"));
        if (!approved[p.lender]) revert NotApproved(p.lender);
        if (!approved[p.borrower]) revert NotApproved(p.borrower);
        if (p.principalAmount == 0 || p.collateralAmount == 0) revert ZeroAmount();
        if (p.rateBps == 0 || p.rateBps > 10000) revert BadParams(bytes32("RATE"));
        if (p.maturityTs <= block.timestamp) revert BadParams(bytes32("MATURITY"));
        if (
            p.legalTermsHash == bytes32(0) || p.collateralRef == bytes32(0) || p.reserveRef == bytes32(0)
                || p.borrowerReleaseRef == bytes32(0) || p.lenderSettlementRef == bytes32(0)
                || p.aminaLiquidationRef == bytes32(0)
        ) {
            revert BadParams(bytes32("REF"));
        }
    }

    function _requireDeal(bytes32 dealId) private view returns (Deal storage deal) {
        deal = _deals[dealId];
        if (deal.state == DealState.None) revert DealMissing(dealId);
    }

    function _requireState(bytes32 dealId, Deal storage deal, DealState expected) private view {
        if (deal.state != expected) revert BadState(dealId, deal.state);
    }

    function _requireRef(bytes32 ref) private pure {
        if (ref == bytes32(0)) revert BadParams(bytes32("REF"));
    }

    function _verifyLiquidationReport(
        bytes32 dealId,
        Deal storage deal,
        LiquidationOracleReport calldata report,
        bytes calldata signature
    ) private view {
        _validateLiquidationReport(dealId, deal, report);

        address recovered = ECDSA.recover(_hashLiquidationReport(report), signature);
        if (recovered != chainlinkOracle) revert InvalidOracleSigner(recovered);
    }

    function _validateLiquidationReport(bytes32 dealId, Deal storage deal, LiquidationOracleReport calldata report)
        private
        view
    {
        if (report.reportRef == bytes32(0)) revert InvalidOracleReport(report.reportRef, bytes32("REF"));
        if (
            report.dealId != dealId || report.legalTermsHash != deal.legalTermsHash
                || report.collateralToken != address(deal.collateralToken)
                || report.principalToken != address(deal.principalToken)
        ) {
            revert InvalidOracleReport(report.reportRef, bytes32("MATCH"));
        }
        if (report.observedAt == 0 || report.observedAt > block.timestamp) {
            revert InvalidOracleReport(report.reportRef, bytes32("OBSERVED_AT"));
        }
        if (report.expiresAt < block.timestamp || report.expiresAt <= report.observedAt) {
            revert InvalidOracleReport(report.reportRef, bytes32("EXPIRED"));
        }
        if (
            report.debtValue == 0 || report.collateralValue == 0 || report.liquidationThresholdBps == 0
                || report.liquidationThresholdBps > 10000
        ) {
            revert InvalidOracleReport(report.reportRef, bytes32("VALUES"));
        }
        if (Math.mulDiv(report.debtValue, 10000, report.collateralValue) < report.liquidationThresholdBps) {
            revert InvalidOracleReport(report.reportRef, bytes32("HEALTHY"));
        }
    }

    function _hashLiquidationReport(LiquidationOracleReport calldata report) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LIQUIDATION_ORACLE_REPORT_TYPEHASH,
                    report.dealId,
                    report.legalTermsHash,
                    report.collateralToken,
                    report.principalToken,
                    report.debtValue,
                    report.collateralValue,
                    report.liquidationThresholdBps,
                    report.observedAt,
                    report.expiresAt,
                    report.reportRef
                )
            )
        );
    }

    function _computedOutstanding(Deal storage deal) private view returns (uint256) {
        uint256 endTs = block.timestamp < deal.maturityTs ? block.timestamp : deal.maturityTs;
        if (endTs <= deal.fundedAt) return deal.principalAmount;

        uint256 elapsed = endTs - deal.fundedAt;
        uint256 interest = Math.mulDiv(deal.principalAmount, uint256(deal.rateBps) * elapsed, 10000 * YEAR);
        return deal.principalAmount + interest;
    }

    function _now64() private view returns (uint64) {
        return uint64(block.timestamp);
    }
}
