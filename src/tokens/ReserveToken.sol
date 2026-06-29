// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {IReserveGuard, IReserveRegistry, IReserveToken} from "../interfaces/ITriora.sol";

/// @title ReserveToken (cUSDC)
/// @notice The lender's 1:1 **reservation** of their own custodied USDC (Model A, ADR-0001). 6 decimals.
///         NOT real USDC and never accepted as settlement. Reserve-bound + secure-minted; held by the
///         lender; posted to a deal; **burned at funding** (the real USDC has moved in custody).
///         Restricted transfers: at least one side must be a protocol address (lender↔engine), user↔user blocked.
contract ReserveToken is ERC20, TrioraAccess, IReserveToken {
    IReserveGuard public reserveGuard;
    IReserveRegistry public reserveRegistry;
    bool private _bound;

    mapping(address => bool) public isProtocol;
    mapping(address => bool) public frozen;

    event Bound(address reserveGuard, address reserveRegistry);
    event ProtocolSet(address indexed account, bool allowed);
    event FrozenSet(address indexed account, bool frozen);
    event MintedForReserve(address indexed to, bytes32 indexed reserveId, uint256 amount);
    event BurnedLocked(address indexed from, uint256 amount);

    constructor(address roleManager_) ERC20("Triora Reserve USDC", "cUSDC") TrioraAccess(roleManager_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function bind(address reserveGuard_, address reserveRegistry_) external restricted(Roles.GOVERNOR) {
        if (_bound) revert Errors.AlreadySet();
        if (reserveGuard_ == address(0) || reserveRegistry_ == address(0)) revert Errors.ZeroAddress();
        reserveGuard = IReserveGuard(reserveGuard_);
        reserveRegistry = IReserveRegistry(reserveRegistry_);
        _bound = true;
        emit Bound(reserveGuard_, reserveRegistry_);
    }

    function setProtocol(address account, bool allowed) external restricted(Roles.GOVERNOR) {
        isProtocol[account] = allowed;
        emit ProtocolSet(account, allowed);
    }

    function setFrozen(address account, bool f) external restricted(Roles.GUARDIAN) {
        frozen[account] = f;
        emit FrozenSet(account, f);
    }

    /// @inheritdoc IReserveToken
    function mintForReserve(address to, bytes32 reserveId, uint256 amount) external restricted(Roles.ISSUER_MINTER) {
        if (amount == 0) revert Errors.ZeroAmount();
        reserveGuard.checkMint(address(this), amount); // SECURE-MINT (supply <= attested USDC reserves - margin)
        reserveRegistry.recordMint(reserveId, amount); // reserve-bound
        _mint(to, amount);
        emit MintedForReserve(to, reserveId, amount);
    }

    /// @inheritdoc IReserveToken
    /// @notice Engine burns the locked cUSDC at funding (the reservation is consumed once real USDC moves).
    function burnLocked(address from, uint256 amount) external restricted(Roles.ENGINE) {
        _burn(from, amount);
        emit BurnedLocked(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Errors.Paused();
        bool isMint = from == address(0);
        bool isBurn = to == address(0);
        if (!isMint && frozen[from]) revert Errors.TransferRestricted(from, to);
        if (!isBurn && frozen[to]) revert Errors.TransferRestricted(from, to);
        if (!isMint && !isBurn) {
            if (!isProtocol[from] && !isProtocol[to]) revert Errors.TransferRestricted(from, to);
        }
        super._update(from, to, value);
    }
}
