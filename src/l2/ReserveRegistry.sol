// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ICustodyAdapter, ICustodyAdapterRegistry} from "../interfaces/ICustodyAdapter.sol";
import {IReserveRegistry} from "../interfaces/IReserveRegistry.sol";
import {IReserveToken} from "../interfaces/IRestrictedToken.sol";
import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title ReserveRegistry -- source of truth for BitGo Go Account cUSDC reserves.
contract ReserveRegistry is AccessManaged, IReserveRegistry {
    ICustodyAdapterRegistry public immutable custodyRegistry;
    IReserveGuard public reserveGuard;
    address public engine;

    mapping(bytes32 reserveId => TypesV2.Reserve) private _reserves;

    event EngineSet(address indexed engine);
    event ReserveGuardSet(address indexed reserveGuard);
    event ReserveRequested(bytes32 indexed reserveId, address indexed owner, bytes32 indexed custodyAccountRef);
    event ReserveActivated(bytes32 indexed reserveId, uint256 amount, bytes32 evidenceHash);
    event ReserveLocked(bytes32 indexed reserveId, bytes32 indexed dealId, uint256 amount);
    event ReserveFunded(bytes32 indexed reserveId, bytes32 indexed dealId, uint256 amount);
    event ReserveReleased(bytes32 indexed reserveId, bytes32 indexed dealId, uint256 amount);
    event ReserveReturned(bytes32 indexed reserveId, bytes32 indexed dealId, uint256 amount);

    error ReserveExists(bytes32 reserveId);
    error ReserveMissing(bytes32 reserveId);
    error ReserveNotAvailable(bytes32 reserveId);
    error ReserveAmountExceeded(bytes32 reserveId);
    error BadReserveAttestation(bytes32 reserveId, bytes32 reason);
    error IneligibleCustodyAccount(bytes32 custodyAccountRef);
    error UnauthorizedRegistryCaller(address caller);

    constructor(address authority_, address custodyRegistry_, address reserveGuard_) AccessManaged(authority_) {
        if (custodyRegistry_ == address(0) || reserveGuard_ == address(0)) revert Errors.ZeroAddress();
        custodyRegistry = ICustodyAdapterRegistry(custodyRegistry_);
        reserveGuard = IReserveGuard(reserveGuard_);
    }

    function setEngine(address engine_) external restricted {
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
        emit EngineSet(engine_);
    }

    function setReserveGuard(address reserveGuard_) external restricted {
        if (reserveGuard_ == address(0)) revert Errors.ZeroAddress();
        reserveGuard = IReserveGuard(reserveGuard_);
        emit ReserveGuardSet(reserveGuard_);
    }

    function requestReserve(TypesV2.ReserveRequest calldata req) external restricted {
        if (req.reserveId == bytes32(0) || req.owner == address(0) || req.reserveToken == address(0) || req.amount == 0) {
            revert Errors.ZeroAmount();
        }
        if (_reserves[req.reserveId].status != TypesV2.ReserveStatus.None) revert ReserveExists(req.reserveId);
        if (!custodyRegistry.isCustodyAccountEligible(req.custodianId, req.custodyAccountRef)) {
            revert IneligibleCustodyAccount(req.custodyAccountRef);
        }
        _reserves[req.reserveId] = TypesV2.Reserve({
            owner: req.owner,
            entityId: req.entityId,
            custodyAccountRef: req.custodyAccountRef,
            custodianId: req.custodianId,
            reserveToken: req.reserveToken,
            asset: req.asset,
            verifiedAmount: req.amount,
            available: 0,
            settlementPending: 0,
            funded: 0,
            status: TypesV2.ReserveStatus.Requested,
            latestEvidenceHash: bytes32(0),
            activeDealId: bytes32(0)
        });
        emit ReserveRequested(req.reserveId, req.owner, req.custodyAccountRef);
    }

    function activateReserve(bytes32 reserveId, bytes calldata attestation) external restricted {
        TypesV2.Reserve storage reserve = _requireReserve(reserveId);
        if (reserve.status != TypesV2.ReserveStatus.Requested && reserve.status != TypesV2.ReserveStatus.Frozen) {
            revert ReserveNotAvailable(reserveId);
        }
        address adapter = custodyRegistry.adapterOf(reserve.custodianId);
        (bool ok, bytes32 subjectId, uint256 amount,, bytes32 reason) =
            ICustodyAdapter(adapter).verifyCustodyAttestation(attestation);
        if (!ok || subjectId != reserveId || amount < reserve.verifiedAmount) {
            revert BadReserveAttestation(reserveId, reason);
        }
        (TypesV2.CustodyProof memory proof,,,) = _decodeProof(attestation);
        reserve.verifiedAmount = amount;
        reserve.available = amount;
        reserve.latestEvidenceHash = proof.evidenceHash;
        reserve.status = TypesV2.ReserveStatus.Available;
        IReserveToken(reserve.reserveToken).mintForReserve(reserve.owner, reserveId, amount);
        emit ReserveActivated(reserveId, amount, proof.evidenceHash);
    }

    function lockForDeal(bytes32 reserveId, bytes32 dealId, uint256 amount) external {
        if (msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Reserve storage reserve = _requireReserve(reserveId);
        if (reserve.status != TypesV2.ReserveStatus.Available && reserve.status != TypesV2.ReserveStatus.Returned) {
            revert ReserveNotAvailable(reserveId);
        }
        if (amount == 0 || amount > reserve.available) revert ReserveAmountExceeded(reserveId);
        reserve.available -= amount;
        reserve.settlementPending += amount;
        reserve.activeDealId = dealId;
        reserve.status = TypesV2.ReserveStatus.SettlementPending;
        emit ReserveLocked(reserveId, dealId, amount);
    }

    function markFunded(bytes32 reserveId, bytes32 dealId, uint256 amount) external {
        if (msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Reserve storage reserve = _requireReserve(reserveId);
        if (reserve.activeDealId != dealId || amount == 0 || amount > reserve.settlementPending) {
            revert ReserveAmountExceeded(reserveId);
        }
        reserve.settlementPending -= amount;
        reserve.funded += amount;
        reserve.status = TypesV2.ReserveStatus.Funded;
        emit ReserveFunded(reserveId, dealId, amount);
    }

    function releaseLocked(bytes32 reserveId, bytes32 dealId, uint256 amount) external {
        if (msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Reserve storage reserve = _requireReserve(reserveId);
        if (reserve.activeDealId != dealId || amount == 0 || amount > reserve.settlementPending) {
            revert ReserveAmountExceeded(reserveId);
        }
        reserve.settlementPending -= amount;
        reserve.available += amount;
        reserve.activeDealId = bytes32(0);
        reserve.status = TypesV2.ReserveStatus.Available;
        emit ReserveReleased(reserveId, dealId, amount);
    }

    function markReturned(bytes32 reserveId, bytes32 dealId, uint256 amount) external {
        if (msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Reserve storage reserve = _requireReserve(reserveId);
        if (amount == 0 || amount > reserve.funded) revert ReserveAmountExceeded(reserveId);
        reserve.funded -= amount;
        reserve.available += amount;
        reserve.status = TypesV2.ReserveStatus.Returned;
        IReserveToken(reserve.reserveToken).mintForReserve(reserve.owner, reserveId, amount);
        emit ReserveReturned(reserveId, dealId, amount);
    }

    function getReserve(bytes32 reserveId) external view returns (TypesV2.Reserve memory) {
        return _reserves[reserveId];
    }

    function _requireReserve(bytes32 reserveId) internal view returns (TypesV2.Reserve storage reserve) {
        reserve = _reserves[reserveId];
        if (reserve.status == TypesV2.ReserveStatus.None) revert ReserveMissing(reserveId);
    }

    function _decodeProof(bytes calldata attestation)
        internal
        pure
        returns (TypesV2.CustodyProof memory proof, bytes memory bitgoSig, bytes memory aminaSig, bytes memory raw)
    {
        raw = attestation;
        (proof, bitgoSig, aminaSig) = abi.decode(attestation, (TypesV2.CustodyProof, bytes, bytes));
    }
}
