// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ILendingEngineV2} from "../interfaces/ILendingEngineV2.sol";
import {IReleaseAuthorizer} from "../interfaces/IReleaseAuthorizer.sol";
import {IPledgeRegistry} from "../interfaces/IPledgeRegistry.sol";
import {ISettlementRouterV2} from "../interfaces/ISettlementRouterV2.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title ReleaseAuthorizer -- canonical custody release voucher issuer.
contract ReleaseAuthorizer is AccessManaged, IReleaseAuthorizer {
    ILendingEngineV2 public immutable engine;
    IPledgeRegistry public immutable pledgeRegistry;
    ISettlementRouterV2 public immutable router;
    address public settlementAcker;
    uint64 public voucherTtl;

    uint64 private _nonce;
    mapping(bytes32 voucherId => TypesV2.ReleaseVoucher) private _vouchers;
    mapping(bytes32 dealId => bytes32 voucherId) public latestVoucherForDeal;

    event SettlementAckerSet(address indexed settlementAcker);
    event VoucherTtlSet(uint64 ttl);
    event VoucherIssued(
        bytes32 indexed voucherId,
        bytes32 indexed dealId,
        bytes32 indexed pledgeId,
        uint8 destinationType,
        bytes32 destinationRef,
        uint256 amount,
        bytes32 reason
    );
    event VoucherConsumed(bytes32 indexed voucherId, bytes32 indexed ackNonce);

    error VoucherNotAllowed(bytes32 dealId);
    error VoucherMissing(bytes32 voucherId);
    error VoucherConsumedAlready(bytes32 voucherId);
    error VoucherExpired(bytes32 voucherId);
    error UnauthorizedVoucherCaller(address caller);

    constructor(address authority_, address engine_, address pledgeRegistry_, address router_) AccessManaged(authority_) {
        if (engine_ == address(0) || pledgeRegistry_ == address(0) || router_ == address(0)) revert Errors.ZeroAddress();
        engine = ILendingEngineV2(engine_);
        pledgeRegistry = IPledgeRegistry(pledgeRegistry_);
        router = ISettlementRouterV2(router_);
        voucherTtl = 7 days;
        emit VoucherTtlSet(voucherTtl);
    }

    function setSettlementAcker(address settlementAcker_) external restricted {
        if (settlementAcker_ == address(0)) revert Errors.ZeroAddress();
        settlementAcker = settlementAcker_;
        emit SettlementAckerSet(settlementAcker_);
    }

    function setVoucherTtl(uint64 voucherTtl_) external restricted {
        voucherTtl = voucherTtl_;
        emit VoucherTtlSet(voucherTtl_);
    }

    function issueRepaymentRelease(bytes32 dealId) external returns (bytes32 voucherId) {
        if (msg.sender != address(engine)) revert UnauthorizedVoucherCaller(msg.sender);
        if (engine.stateOf(dealId) != TypesV2.DealStateV2.Repaid) revert VoucherNotAllowed(dealId);
        TypesV2.DealTermsV2 memory terms = engine.getTerms(dealId);
        voucherId = _issue(
            dealId,
            terms.pledgeId,
            TypesV2.DestinationType.Borrower,
            terms.borrowerReleaseRef,
            terms.collateralAmount,
            bytes32("REPAID")
        );
        pledgeRegistry.markReleasePending(terms.pledgeId, voucherId);
    }

    function issueLiquidationRelease(bytes32 dealId) external returns (bytes32 voucherId) {
        if (engine.stateOf(dealId) != TypesV2.DealStateV2.LiquidationPending) revert VoucherNotAllowed(dealId);
        TypesV2.DealTermsV2 memory terms = engine.getTerms(dealId);
        TypesV2.DealRuntimeV2 memory runtime = engine.getRuntime(dealId);
        voucherId = _issue(
            dealId,
            terms.pledgeId,
            TypesV2.DestinationType.AminaDesk,
            terms.aminaLiquidationRef,
            runtime.collateralLocked,
            bytes32("LIQUIDATED")
        );
        pledgeRegistry.markLiquidationPending(terms.pledgeId, voucherId);
        router.emitLiquidationInstruction(dealId, voucherId, runtime.collateralLocked);
    }

    function consumeVoucher(bytes32 voucherId, bytes32 ackNonce) external {
        if (msg.sender != settlementAcker && msg.sender != address(engine)) revert UnauthorizedVoucherCaller(msg.sender);
        TypesV2.ReleaseVoucher storage voucher = _requireVoucher(voucherId);
        if (voucher.consumed) revert VoucherConsumedAlready(voucherId);
        if (voucher.expiresAt < block.timestamp) revert VoucherExpired(voucherId);
        voucher.consumed = true;
        emit VoucherConsumed(voucherId, ackNonce);
    }

    function isVoucherValid(bytes32 voucherId) external view returns (bool) {
        TypesV2.ReleaseVoucher storage voucher = _vouchers[voucherId];
        return voucher.voucherId != bytes32(0) && !voucher.consumed && voucher.expiresAt >= block.timestamp;
    }

    function getVoucher(bytes32 voucherId) external view returns (TypesV2.ReleaseVoucher memory) {
        return _requireVoucher(voucherId);
    }

    function _issue(
        bytes32 dealId,
        bytes32 pledgeId,
        TypesV2.DestinationType destinationType,
        bytes32 destinationRef,
        uint256 amount,
        bytes32 reason
    ) internal returns (bytes32 voucherId) {
        uint64 seq = _nextVoucherSequence();
        voucherId = keccak256(abi.encode(block.chainid, address(this), dealId, pledgeId, seq, destinationType, destinationRef));
        TypesV2.Pledge memory pledge = pledgeRegistry.getPledge(pledgeId);
        TypesV2.ReleaseVoucher memory voucher = TypesV2.ReleaseVoucher({
            voucherId: voucherId,
            dealId: dealId,
            pledgeId: pledgeId,
            assetId: pledge.assetId,
            amount: amount,
            destinationType: destinationType,
            destinationRef: destinationRef,
            reason: reason,
            sequenceNumber: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + voucherTtl),
            consumed: false
        });
        _vouchers[voucherId] = voucher;
        latestVoucherForDeal[dealId] = voucherId;
        router.emitReleaseInstruction(voucher);
        emit VoucherIssued(voucherId, dealId, pledgeId, uint8(destinationType), destinationRef, amount, reason);
    }

    function _nextVoucherSequence() internal returns (uint64) {
        unchecked {
            return ++_nonce;
        }
    }

    function _requireVoucher(bytes32 voucherId) internal view returns (TypesV2.ReleaseVoucher storage voucher) {
        voucher = _vouchers[voucherId];
        if (voucher.voucherId == bytes32(0)) revert VoucherMissing(voucherId);
    }
}
