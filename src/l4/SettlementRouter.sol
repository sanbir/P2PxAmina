// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISettlementRouter} from "../interfaces/ISettlementRouter.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title SettlementRouter — immutable, versioned, stateless event emitter (D19).
/// @notice Within a single router version, fields can never be removed
///         and field meanings never change. New events ship as
///         `SettlementRouterV2`. Engine/handler are bound ONCE after
///         deployment because per the deployment order the engine
///         proxy doesn't exist at router-construction time.
contract SettlementRouter is ISettlementRouter {
    uint16 public constant VERSION = 1;

    address public immutable binder; // one-shot binder for engine + handler
    address public engine;
    address public handler;

    uint64 private _seq;

    event Bound(address indexed engine, address indexed handler);
    event AdvanceIntent(
        bytes32 indexed dealId,
        address indexed supplyToken,
        uint256 amount,
        address indexed beneficiary,
        bytes32 settlementRef,
        uint64 sequenceNumber,
        uint64 expectedSettlementDeadline
    );
    event DealActivated(
        bytes32 indexed dealId,
        address indexed lender,
        address indexed borrower,
        uint128 principal,
        uint64 sequenceNumber
    );
    event Repaid(bytes32 indexed dealId, uint128 amount, bool collateralReleased, uint64 sequenceNumber);
    event CollateralReleased(
        bytes32 indexed dealId,
        address to,
        uint256 amount,
        bool success,
        bytes32 reasonCode,
        uint64 sequenceNumber
    );
    event LiquidationWarn(bytes32 indexed dealId, uint256 hf, uint64 sequenceNumber);
    event LiquidationPartial(
        bytes32 indexed dealId, uint256 collateralSeized, uint256 debtCovered, uint64 sequenceNumber
    );
    event LiquidationFull(
        bytes32 indexed dealId,
        uint256 collateralSeized,
        uint256 debtCovered,
        uint256 surplus,
        uint64 sequenceNumber
    );
    event OracleOverridden(
        bytes32 indexed dealId,
        address newCollOracle,
        address newSuppOracle,
        bytes32 reason,
        uint64 effectiveAt,
        uint64 sequenceNumber
    );

    error UnauthorisedEmitter();
    error AlreadyBound();
    error NotBinder();

    constructor(address binder_) {
        if (binder_ == address(0)) revert Errors.ZeroAddress();
        binder = binder_;
    }

    function bind(address engine_, address handler_) external {
        if (msg.sender != binder) revert NotBinder();
        if (engine != address(0) || handler != address(0)) revert AlreadyBound();
        if (engine_ == address(0) || handler_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
        handler = handler_;
        emit Bound(engine_, handler_);
    }

    modifier onlyEmitter() {
        if (msg.sender != engine && msg.sender != handler) revert UnauthorisedEmitter();
        _;
    }

    function version() external pure returns (uint16) {
        return VERSION;
    }

    function nextSequence() external onlyEmitter returns (uint64) {
        return _next();
    }

    function currentSequence() external view returns (uint64) {
        return _seq;
    }

    function emitAdvanceIntent(
        bytes32 dealId,
        address supplyToken,
        uint256 amount,
        address beneficiary,
        bytes32 settlementRef,
        uint64 expectedSettlementDeadline
    ) external onlyEmitter {
        emit AdvanceIntent(
            dealId, supplyToken, amount, beneficiary, settlementRef, _next(), expectedSettlementDeadline
        );
    }

    function emitDealActivated(bytes32 dealId, address lender, address borrower, uint128 principal)
        external
        onlyEmitter
    {
        emit DealActivated(dealId, lender, borrower, principal, _next());
    }

    function emitRepaid(bytes32 dealId, uint128 amount, bool collateralReleased) external onlyEmitter {
        emit Repaid(dealId, amount, collateralReleased, _next());
    }

    function emitCollateralReleased(bytes32 dealId, address to, uint256 amount, bool success, bytes32 reasonCode)
        external
        onlyEmitter
    {
        emit CollateralReleased(dealId, to, amount, success, reasonCode, _next());
    }

    function emitLiquidationWarn(bytes32 dealId, uint256 hf) external onlyEmitter {
        emit LiquidationWarn(dealId, hf, _next());
    }

    function emitLiquidationPartial(bytes32 dealId, uint256 collateralSeized, uint256 debtCovered)
        external
        onlyEmitter
    {
        emit LiquidationPartial(dealId, collateralSeized, debtCovered, _next());
    }

    function emitLiquidationFull(bytes32 dealId, uint256 collateralSeized, uint256 debtCovered, uint256 surplus)
        external
        onlyEmitter
    {
        emit LiquidationFull(dealId, collateralSeized, debtCovered, surplus, _next());
    }

    function emitOracleOverridden(
        bytes32 dealId,
        address newCollOracle,
        address newSuppOracle,
        bytes32 reason,
        uint64 effectiveAt
    ) external onlyEmitter {
        emit OracleOverridden(dealId, newCollOracle, newSuppOracle, reason, effectiveAt, _next());
    }

    function _next() internal returns (uint64) {
        unchecked {
            return ++_seq;
        }
    }
}
