// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import {TrioraMath} from "../libraries/TrioraMath.sol";
import {LendingEngine} from "../engine/LendingEngine.sol";
import {RiskConfig} from "../config/RiskConfig.sol";

/// @title LiquidationModule
/// @notice AMINA *operates* liquidation, but **eligibility is objective** (Tech Spec S8): a signed
///         oracle report proving the LTV breach, a fixed cure window, and a required SECOND fresh
///         report after the deadline to finalize. Anyone may cancel a stale pending liquidation.
contract LiquidationModule is TrioraAccess, EIP712 {
    bytes32 private constant LIQ_REPORT_TYPEHASH = keccak256(
        "LiquidationReport(bytes32 positionId,uint256 collateralValue,uint256 debtValue,uint32 thresholdBps,uint64 observedAt,uint64 expiresAt,bytes32 reportRef)"
    );
    uint64 public constant MAX_REPORT_SKEW = 5 minutes;

    LendingEngine public immutable bridge;
    RiskConfig public immutable riskConfig;
    bytes32 public immutable marketId;
    address public oracleSigner;

    mapping(bytes32 => bool) public usedReport; // reportRef => used
    mapping(bytes32 => bytes32) public firstReportRef; // positionId => first report ref

    struct LiquidationReport {
        bytes32 positionId;
        uint256 collateralValue;
        uint256 debtValue;
        uint32 thresholdBps;
        uint64 observedAt;
        uint64 expiresAt;
        bytes32 reportRef;
    }

    event OracleSignerSet(address signer);
    event LiquidationRequested(bytes32 indexed positionId, bytes32 reportRef, uint64 cureDeadline);
    event LiquidationFinalized(bytes32 indexed positionId, bytes32 reportRef);

    constructor(address roleManager_, address bridge_, address riskConfig_, bytes32 marketId_, address oracleSigner_)
        TrioraAccess(roleManager_)
        EIP712("TrioraLiquidationModule", "1")
    {
        if (bridge_ == address(0) || riskConfig_ == address(0) || oracleSigner_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        bridge = LendingEngine(bridge_);
        riskConfig = RiskConfig(riskConfig_);
        marketId = marketId_;
        oracleSigner = oracleSigner_;
    }

    function setOracleSigner(address signer) external restricted(Roles.ORACLE_ADMIN) {
        if (signer == address(0)) revert Errors.ZeroAddress();
        oracleSigner = signer;
        emit OracleSignerSet(signer);
    }

    /// @notice Soft warning from the live oracle (starts the cure clock). LIQUIDATOR-only.
    function warn(bytes32 positionId) external restricted(Roles.LIQUIDATOR) {
        Types.MarketParams memory mp = riskConfig.getParams(marketId);
        if (bridge.healthLtvBps(positionId) < mp.aminaWarningBps) revert Errors.StillHealthy();
        bridge.setWarned(positionId, uint64(block.timestamp) + mp.cureWindowSecs);
    }

    /// @notice Request liquidation with an objective signed oracle report (LTV breach OR maturity).
    function requestLiquidation(LiquidationReport calldata r, bytes calldata oracleSig)
        external
        restricted(Roles.LIQUIDATOR)
    {
        _verifyReport(r, oracleSig);
        Types.MarketParams memory mp = riskConfig.getParams(marketId);
        Types.Position memory p = bridge.getPosition(r.positionId);

        bool matured = block.timestamp >= p.maturityTs;
        bool breach = r.thresholdBps == mp.aminaLiquidationBps && r.collateralValue > 0
            && r.debtValue * TrioraMath.BPS >= uint256(r.thresholdBps) * r.collateralValue;
        if (!matured && !breach) revert Errors.StillHealthy();

        usedReport[r.reportRef] = true;
        firstReportRef[r.positionId] = r.reportRef;
        uint64 cureDeadline = uint64(block.timestamp) + mp.cureWindowSecs;
        bridge.setLiquidationPending(r.positionId, cureDeadline);
        emit LiquidationRequested(r.positionId, r.reportRef, cureDeadline);
    }

    /// @notice Finalize after the cure window with a SECOND distinct fresh report.
    function finalizeLiquidation(LiquidationReport calldata r, bytes calldata oracleSig)
        external
        restricted(Roles.LIQUIDATOR)
    {
        _verifyReport(r, oracleSig);
        if (r.reportRef == firstReportRef[r.positionId]) revert Errors.ReportReused(r.reportRef);
        Types.Position memory p = bridge.getPosition(r.positionId);
        if (block.timestamp < p.cureDeadline) revert Errors.CureWindowNotElapsed(p.cureDeadline);

        usedReport[r.reportRef] = true;
        bridge.executeLiquidation(r.positionId);
        emit LiquidationFinalized(r.positionId, r.reportRef);
    }

    /// @notice Escape hatch: anyone can cancel a pending (not-yet-executed) liquidation after the window.
    function cancelPendingLiquidation(bytes32 positionId) external {
        Types.Position memory p = bridge.getPosition(positionId);
        if (block.timestamp <= p.cureDeadline) revert Errors.CureWindowActive(p.cureDeadline);
        bridge.cancelLiquidation(positionId);
    }

    function _verifyReport(LiquidationReport calldata r, bytes calldata sig) internal view {
        if (r.observedAt > block.timestamp + MAX_REPORT_SKEW) revert Errors.AttestationFromFuture();
        if (r.expiresAt <= block.timestamp) revert Errors.AttestationExpired();
        if (usedReport[r.reportRef]) revert Errors.ReportReused(r.reportRef);
        bytes32 structHash = keccak256(
            abi.encode(
                LIQ_REPORT_TYPEHASH,
                r.positionId,
                r.collateralValue,
                r.debtValue,
                r.thresholdBps,
                r.observedAt,
                r.expiresAt,
                r.reportRef
            )
        );
        if (!SignatureChecker.isValidSignatureNow(oracleSigner, _hashTypedDataV4(structHash), sig)) {
            revert Errors.BadSignature();
        }
    }
}
