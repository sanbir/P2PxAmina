// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import {ICustodyAdapter, IReserveRegistry} from "../interfaces/ITriora.sol";

/// @title ReserveRegistry
/// @notice Source of truth for lender cUSDC reservations (Model A). Mirrors {PledgeRegistry} for the
///         cash leg: binds reservation → cUSDC → deal; enforces `minted <= reserved`, one active deal
///         per reservation. The cUSDC is burned at funding (markFunded) once real USDC moves in custody.
contract ReserveRegistry is IReserveRegistry, TrioraAccess {
    ICustodyAdapter public adapter;
    address public reserveToken; // cUSDC
    bool private _bound;

    mapping(bytes32 => Types.Reserve) private _reserves;

    event Bound(address adapter, address token);
    event ReserveRegistered(bytes32 indexed reserveId, address indexed owner, uint256 amount);
    event MintRecorded(bytes32 indexed reserveId, uint256 amount, uint256 mintedTotal);
    event LockedForDeal(bytes32 indexed reserveId, bytes32 indexed dealId, uint256 amount);
    event StatusChanged(bytes32 indexed reserveId, Types.ReserveStatus status);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    function bind(address adapter_, address token_) external restricted(Roles.GOVERNOR) {
        if (_bound) revert Errors.AlreadySet();
        if (adapter_ == address(0) || token_ == address(0)) revert Errors.ZeroAddress();
        adapter = ICustodyAdapter(adapter_);
        reserveToken = token_;
        _bound = true;
        emit Bound(adapter_, token_);
    }

    /// @notice Register a lender reservation after custody (USDC) evidence exists on-chain.
    function registerReserve(
        bytes32 reserveId,
        address owner,
        bytes32 custodyAccountRef,
        uint256 amount,
        bytes32 controlAgreementHash
    ) external restricted(Roles.ALLOCATOR) whenNotPaused {
        if (owner == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (_reserves[reserveId].status != Types.ReserveStatus.None) revert Errors.AlreadySet();
        if (!adapter.verifyPledge(reserveId, reserveToken, amount)) revert Errors.LockNotActive(reserveId);

        _reserves[reserveId] = Types.Reserve({
            owner: owner,
            custodyAccountRef: custodyAccountRef,
            reservedAmount: amount,
            mintedAmount: 0,
            encumberedAmount: 0,
            status: Types.ReserveStatus.Available,
            dealId: bytes32(0),
            controlAgreementHash: controlAgreementHash,
            registeredAt: uint64(block.timestamp)
        });
        emit ReserveRegistered(reserveId, owner, amount);
    }

    function canMint(bytes32 reserveId, uint256 amount) public view returns (bool) {
        Types.Reserve storage r = _reserves[reserveId];
        if (r.status != Types.ReserveStatus.Available) return false;
        if (r.mintedAmount + amount > r.reservedAmount) return false;
        if (!adapter.isLockActive(reserveId)) return false;
        return true;
    }

    function recordMint(bytes32 reserveId, uint256 amount) external restricted(Roles.TOKEN) {
        Types.Reserve storage r = _reserves[reserveId];
        if (!canMint(reserveId, amount)) revert Errors.MintExceedsPledge(r.mintedAmount + amount, r.reservedAmount);
        r.mintedAmount += amount;
        emit MintRecorded(reserveId, amount, r.mintedAmount);
    }

    function availableAmount(bytes32 reserveId) public view returns (uint256) {
        Types.Reserve storage r = _reserves[reserveId];
        return r.mintedAmount - r.encumberedAmount;
    }

    function lockForDeal(bytes32 reserveId, bytes32 dealId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Reserve storage r = _reserves[reserveId];
        if (r.dealId != bytes32(0)) revert Errors.PledgeBound(reserveId);
        if (amount == 0 || amount > availableAmount(reserveId)) revert Errors.PledgeNotFree(reserveId);
        r.encumberedAmount += amount;
        r.dealId = dealId;
        r.status = Types.ReserveStatus.Bound;
        emit LockedForDeal(reserveId, dealId, amount);
    }

    function unlockFromDeal(bytes32 reserveId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Reserve storage r = _reserves[reserveId];
        r.encumberedAmount = amount >= r.encumberedAmount ? 0 : r.encumberedAmount - amount;
        if (r.encumberedAmount == 0) {
            r.dealId = bytes32(0);
            r.status = Types.ReserveStatus.Available;
        }
        emit StatusChanged(reserveId, r.status);
    }

    function markFunded(bytes32 reserveId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Reserve storage r = _reserves[reserveId];
        // the reservation's cUSDC is burned at funding; reduce minted + encumbered
        r.mintedAmount = amount >= r.mintedAmount ? 0 : r.mintedAmount - amount;
        r.encumberedAmount = amount >= r.encumberedAmount ? 0 : r.encumberedAmount - amount;
        r.dealId = bytes32(0);
        r.status = Types.ReserveStatus.Funded;
        emit StatusChanged(reserveId, Types.ReserveStatus.Funded);
    }

    function markReturned(bytes32 reserveId) external restricted(Roles.ENGINE) {
        _reserves[reserveId].status = Types.ReserveStatus.Returned;
        emit StatusChanged(reserveId, Types.ReserveStatus.Returned);
    }

    function freezeReserve(bytes32 reserveId) external restricted(Roles.GUARDIAN) {
        _reserves[reserveId].status = Types.ReserveStatus.Frozen;
        emit StatusChanged(reserveId, Types.ReserveStatus.Frozen);
    }

    function getReserve(bytes32 reserveId) external view returns (Types.Reserve memory) {
        return _reserves[reserveId];
    }
}
