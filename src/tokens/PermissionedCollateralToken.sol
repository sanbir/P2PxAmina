// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {
    IReserveGuard,
    IPledgeRegistry,
    IReleaseAuthorizer,
    IPermissionedCollateralToken
} from "../interfaces/ITriora.sol";

/// @title PermissionedCollateralToken (cBTC)
/// @notice 1:1 restricted accounting claim on custodied BTC (Tech Spec S4). 8 decimals.
///         Mints are pledge-bound AND reserve-guarded; burns are voucher-gated; transfers are
///         restricted to protocol paths and check BOTH `from` and `to` (the recurring allowlist bug).
contract PermissionedCollateralToken is ERC20, TrioraAccess, IPermissionedCollateralToken {
    IReserveGuard public reserveGuard;
    IPledgeRegistry public pledgeRegistry;
    IReleaseAuthorizer public releaseAuthorizer;
    bool private _bound;

    mapping(address => bool) public isProtocol; // bridge, protocol adapter, etc.
    mapping(address => bool) public frozen;

    event Bound(address reserveGuard, address pledgeRegistry, address releaseAuthorizer);
    event ProtocolSet(address indexed account, bool allowed);
    event FrozenSet(address indexed account, bool frozen);
    event MintedForPledge(address indexed to, bytes32 indexed pledgeId, uint256 amount);
    event BurnedForRelease(address indexed from, bytes32 indexed pledgeId, uint256 amount, bytes32 voucherId);

    constructor(address roleManager_) ERC20("Triora Custody BTC", "cBTC") TrioraAccess(roleManager_) {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function bind(address reserveGuard_, address pledgeRegistry_, address releaseAuthorizer_)
        external
        restricted(Roles.GOVERNOR)
    {
        if (_bound) revert Errors.AlreadySet();
        if (reserveGuard_ == address(0) || pledgeRegistry_ == address(0) || releaseAuthorizer_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        reserveGuard = IReserveGuard(reserveGuard_);
        pledgeRegistry = IPledgeRegistry(pledgeRegistry_);
        releaseAuthorizer = IReleaseAuthorizer(releaseAuthorizer_);
        _bound = true;
        emit Bound(reserveGuard_, pledgeRegistry_, releaseAuthorizer_);
    }

    function setProtocol(address account, bool allowed) external restricted(Roles.GOVERNOR) {
        isProtocol[account] = allowed;
        emit ProtocolSet(account, allowed);
    }

    function setFrozen(address account, bool f) external restricted(Roles.GUARDIAN) {
        frozen[account] = f;
        emit FrozenSet(account, f);
    }

    /// @inheritdoc IPermissionedCollateralToken
    function mintForPledge(address to, bytes32 pledgeId, uint256 amount) external restricted(Roles.ISSUER_MINTER) {
        if (amount == 0) revert Errors.ZeroAmount();
        if (!isProtocol[to]) revert Errors.TransferRestricted(address(0), to); // cBTC only ever minted to protocol
        reserveGuard.checkMint(address(this), amount); // SECURE-MINT (fail-closed)
        pledgeRegistry.recordMint(pledgeId, amount); // pledge-bound (reverts if minted>pledged)
        _mint(to, amount);
        emit MintedForPledge(to, pledgeId, amount);
    }

    /// @inheritdoc IPermissionedCollateralToken
    function burnForRelease(address from, bytes32 pledgeId, uint256 amount, bytes32 voucherId)
        external
        restricted(Roles.ENGINE)
    {
        releaseAuthorizer.consume(voucherId, pledgeId, amount); // one-use, state-derived voucher
        _burn(from, amount);
        emit BurnedForRelease(from, pledgeId, amount, voucherId);
    }

    /// @dev Transfer restriction (Tech Spec S4): cBTC circulates ONLY among allowlisted protocol
    ///      addresses (bridge, protocol adapter, the isolated market). A normal transfer requires BOTH
    ///      `from` and `to` to be protocol — checking both sides is the point (one-sided checks are the bug).
    ///      Mint: `to` must be protocol. Burn: `from` must be protocol. Honors pause/freeze.
    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Errors.Paused();
        bool isMint = from == address(0);
        bool isBurn = to == address(0);
        if (!isMint && frozen[from]) revert Errors.TransferRestricted(from, to);
        if (!isBurn && frozen[to]) revert Errors.TransferRestricted(from, to);

        if (isMint) {
            if (!isProtocol[to]) revert Errors.TransferRestricted(from, to);
        } else if (isBurn) {
            if (!isProtocol[from]) revert Errors.TransferRestricted(from, to);
        } else {
            if (!isProtocol[from] || !isProtocol[to]) revert Errors.TransferRestricted(from, to);
        }
        super._update(from, to, value);
    }
}
