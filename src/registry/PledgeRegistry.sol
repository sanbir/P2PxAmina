// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import {ICustodyAdapter, IPledgeRegistry} from "../interfaces/ITriora.sol";

/// @title PledgeRegistry
/// @notice Source of truth binding a custody pledge → cBTC → an active position (Tech Spec S4).
///         Enforces `mintedAmount <= pledgedAmount`, `encumbered <= minted`, and one active
///         position per pledge. Implements "tokenize once, borrow once-at-a-time".
contract PledgeRegistry is IPledgeRegistry, TrioraAccess {
    ICustodyAdapter public adapter;
    address public collateralToken;
    bool private _bound;

    mapping(bytes32 => Types.Pledge) private _pledges;

    event Bound(address adapter, address token);
    event PledgeRegistered(bytes32 indexed pledgeId, address indexed owner, uint256 amount);
    event MintRecorded(bytes32 indexed pledgeId, uint256 amount, uint256 mintedTotal);
    event LockedForDeal(bytes32 indexed pledgeId, bytes32 indexed dealId, uint256 amount);
    event UnlockedFromDeal(bytes32 indexed pledgeId, uint256 amount);
    event StatusChanged(bytes32 indexed pledgeId, Types.PledgeStatus status);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    /// @notice One-shot wiring by GOVERNOR.
    function bind(address adapter_, address token_) external restricted(Roles.GOVERNOR) {
        if (_bound) revert Errors.AlreadySet();
        if (adapter_ == address(0) || token_ == address(0)) revert Errors.ZeroAddress();
        adapter = ICustodyAdapter(adapter_);
        collateralToken = token_;
        _bound = true;
        emit Bound(adapter_, token_);
    }

    /// @notice Register a pledge after custody evidence exists on-chain (AMINA ops). Verifies the
    ///         custody attestation (amount + active lock) before accepting it.
    function registerPledge(
        bytes32 pledgeId,
        address owner,
        bytes32 custodyAccountRef,
        uint256 amount,
        bytes32 controlAgreementHash
    ) external restricted(Roles.ALLOCATOR) whenNotPaused {
        if (owner == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (_pledges[pledgeId].status != Types.PledgeStatus.None) revert Errors.AlreadySet();
        if (!adapter.verifyPledge(pledgeId, collateralToken, amount)) revert Errors.LockNotActive(pledgeId);

        _pledges[pledgeId] = Types.Pledge({
            owner: owner,
            custodyAccountRef: custodyAccountRef,
            pledgedAmount: amount,
            mintedAmount: 0,
            encumberedAmount: 0,
            status: Types.PledgeStatus.Pledged,
            dealId: bytes32(0),
            controlAgreementHash: controlAgreementHash,
            registeredAt: uint64(block.timestamp)
        });
        emit PledgeRegistered(pledgeId, owner, amount);
    }

    function canMint(bytes32 pledgeId, uint256 amount) public view returns (bool) {
        Types.Pledge storage p = _pledges[pledgeId];
        if (p.status != Types.PledgeStatus.Pledged && p.status != Types.PledgeStatus.Minted) return false;
        if (p.mintedAmount + amount > p.pledgedAmount) return false;
        if (!adapter.isLockActive(pledgeId)) return false;
        return true;
    }

    function recordMint(bytes32 pledgeId, uint256 amount) external restricted(Roles.TOKEN) {
        Types.Pledge storage p = _pledges[pledgeId];
        if (!canMint(pledgeId, amount)) revert Errors.MintExceedsPledge(p.mintedAmount + amount, p.pledgedAmount);
        p.mintedAmount += amount;
        p.status = Types.PledgeStatus.Minted;
        emit MintRecorded(pledgeId, amount, p.mintedAmount);
    }

    function freeAmount(bytes32 pledgeId) public view returns (uint256) {
        Types.Pledge storage p = _pledges[pledgeId];
        return p.mintedAmount - p.encumberedAmount;
    }

    function lockForDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Pledge storage p = _pledges[pledgeId];
        if (p.dealId != bytes32(0)) revert Errors.PledgeBound(pledgeId);
        if (amount == 0 || amount > freeAmount(pledgeId)) revert Errors.PledgeNotFree(pledgeId);
        p.encumberedAmount += amount;
        p.dealId = dealId;
        p.status = Types.PledgeStatus.Bound;
        emit LockedForDeal(pledgeId, dealId, amount);
    }

    function unlockFromDeal(bytes32 pledgeId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Pledge storage p = _pledges[pledgeId];
        p.encumberedAmount = amount >= p.encumberedAmount ? 0 : p.encumberedAmount - amount;
        if (p.encumberedAmount == 0) {
            p.dealId = bytes32(0);
            p.status = Types.PledgeStatus.Minted;
        }
        emit UnlockedFromDeal(pledgeId, amount);
    }

    function markReleasePending(bytes32 pledgeId) external restricted(Roles.ENGINE) {
        _pledges[pledgeId].status = Types.PledgeStatus.ReleasePending;
        emit StatusChanged(pledgeId, Types.PledgeStatus.ReleasePending);
    }

    function markReleased(bytes32 pledgeId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Pledge storage p = _pledges[pledgeId];
        p.mintedAmount = amount >= p.mintedAmount ? 0 : p.mintedAmount - amount;
        p.encumberedAmount = 0;
        p.dealId = bytes32(0);
        p.status = Types.PledgeStatus.Released;
        emit StatusChanged(pledgeId, Types.PledgeStatus.Released);
    }

    function markLiquidated(bytes32 pledgeId, uint256 amount) external restricted(Roles.ENGINE) {
        Types.Pledge storage p = _pledges[pledgeId];
        p.mintedAmount = amount >= p.mintedAmount ? 0 : p.mintedAmount - amount;
        p.encumberedAmount = 0;
        p.dealId = bytes32(0);
        p.status = Types.PledgeStatus.Liquidated;
        emit StatusChanged(pledgeId, Types.PledgeStatus.Liquidated);
    }

    function freezePledge(bytes32 pledgeId) external restricted(Roles.GUARDIAN) {
        _pledges[pledgeId].status = Types.PledgeStatus.Frozen;
        emit StatusChanged(pledgeId, Types.PledgeStatus.Frozen);
    }

    function getPledge(bytes32 pledgeId) external view returns (Types.Pledge memory) {
        return _pledges[pledgeId];
    }
}
