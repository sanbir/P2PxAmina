// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISettlementRouterV2} from "../interfaces/ISettlementRouterV2.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title SettlementRouterV2 -- append-only BitGo settlement instruction stream.
contract SettlementRouterV2 is ISettlementRouterV2 {
    uint16 public constant VERSION = 2;

    address public immutable binder;
    address public engine;
    address public acker;
    address public releaseAuthorizer;
    address public liquidationHandler;

    uint64 private _seq;

    event Bound(address indexed engine, address indexed acker, address indexed releaseAuthorizer, address liquidationHandler);
    event FundingInstruction(
        bytes32 indexed dealId,
        bytes32 indexed pledgeId,
        bytes32 indexed reserveId,
        address asset,
        uint256 amount,
        bytes32 routeHash,
        bytes32 settlementRef,
        uint64 deadline,
        uint64 sequenceNumber
    );
    event FundingConfirmed(bytes32 indexed dealId, bytes32 settlementRef, uint256 amount, uint64 sequenceNumber);
    event FundingCancelled(bytes32 indexed dealId, bytes32 reasonCode, uint64 sequenceNumber);
    event RepaymentInstruction(
        bytes32 indexed dealId,
        uint256 amount,
        bytes32 routeHash,
        uint64 deadline,
        uint64 sequenceNumber
    );
    event RepaymentConfirmed(bytes32 indexed dealId, uint256 amount, uint256 outstanding, uint64 sequenceNumber);
    event ReleaseInstruction(
        bytes32 indexed dealId,
        bytes32 indexed voucherId,
        bytes32 indexed pledgeId,
        uint8 destinationType,
        bytes32 destinationRef,
        uint256 amount,
        uint64 expiresAt,
        uint64 sequenceNumber
    );
    event ReleaseConfirmed(bytes32 indexed dealId, bytes32 indexed voucherId, bytes32 ackNonce, uint64 sequenceNumber);
    event LiquidationInstruction(bytes32 indexed dealId, bytes32 indexed voucherId, uint256 amount, uint64 sequenceNumber);
    event SettlementFailed(bytes32 indexed dealId, bytes32 reasonCode, uint64 sequenceNumber);

    error AlreadyBound();
    error NotBinder();
    error UnauthorizedEmitter(address caller);

    constructor(address binder_) {
        if (binder_ == address(0)) revert Errors.ZeroAddress();
        binder = binder_;
    }

    function bind(address engine_, address acker_, address releaseAuthorizer_, address liquidationHandler_) external {
        if (msg.sender != binder) revert NotBinder();
        if (engine != address(0)) revert AlreadyBound();
        if (engine_ == address(0) || acker_ == address(0) || releaseAuthorizer_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        engine = engine_;
        acker = acker_;
        releaseAuthorizer = releaseAuthorizer_;
        liquidationHandler = liquidationHandler_;
        emit Bound(engine_, acker_, releaseAuthorizer_, liquidationHandler_);
    }

    modifier onlyEmitter() {
        if (
            msg.sender != engine && msg.sender != acker && msg.sender != releaseAuthorizer
                && msg.sender != liquidationHandler
        ) {
            revert UnauthorizedEmitter(msg.sender);
        }
        _;
    }

    function nextSequence() external onlyEmitter returns (uint64) {
        return _next();
    }

    function currentSequence() external view returns (uint64) {
        return _seq;
    }

    function emitFundingInstruction(
        bytes32 dealId,
        bytes32 pledgeId,
        bytes32 reserveId,
        address asset,
        uint256 amount,
        bytes32 routeHash,
        bytes32 settlementRef,
        uint64 deadline
    ) external onlyEmitter {
        emit FundingInstruction(dealId, pledgeId, reserveId, asset, amount, routeHash, settlementRef, deadline, _next());
    }

    function emitFundingConfirmed(bytes32 dealId, bytes32 settlementRef, uint256 amount) external onlyEmitter {
        emit FundingConfirmed(dealId, settlementRef, amount, _next());
    }

    function emitFundingCancelled(bytes32 dealId, bytes32 reasonCode) external onlyEmitter {
        emit FundingCancelled(dealId, reasonCode, _next());
    }

    function emitRepaymentInstruction(bytes32 dealId, uint256 amount, bytes32 routeHash, uint64 deadline)
        external
        onlyEmitter
    {
        emit RepaymentInstruction(dealId, amount, routeHash, deadline, _next());
    }

    function emitRepaymentConfirmed(bytes32 dealId, uint256 amount, uint256 outstanding) external onlyEmitter {
        emit RepaymentConfirmed(dealId, amount, outstanding, _next());
    }

    function emitReleaseInstruction(TypesV2.ReleaseVoucher calldata voucher) external onlyEmitter {
        emit ReleaseInstruction(
            voucher.dealId,
            voucher.voucherId,
            voucher.pledgeId,
            uint8(voucher.destinationType),
            voucher.destinationRef,
            voucher.amount,
            voucher.expiresAt,
            _next()
        );
    }

    function emitReleaseConfirmed(bytes32 dealId, bytes32 voucherId, bytes32 ackNonce) external onlyEmitter {
        emit ReleaseConfirmed(dealId, voucherId, ackNonce, _next());
    }

    function emitLiquidationInstruction(bytes32 dealId, bytes32 voucherId, uint256 amount) external onlyEmitter {
        emit LiquidationInstruction(dealId, voucherId, amount, _next());
    }

    function emitSettlementFailed(bytes32 dealId, bytes32 reasonCode) external onlyEmitter {
        emit SettlementFailed(dealId, reasonCode, _next());
    }

    function _next() internal returns (uint64) {
        unchecked {
            return ++_seq;
        }
    }
}
