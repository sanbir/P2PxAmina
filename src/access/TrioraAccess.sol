// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RoleManager} from "./RoleManager.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title TrioraAccess
/// @notice Shared base: role checks against the central {RoleManager} + a guardian pause.
/// @dev Hot keys (GUARDIAN) may only *reduce* risk (pause). EMERGENCY may pause/unpause.
abstract contract TrioraAccess {
    RoleManager public immutable roleManager;
    bool public paused;

    event PausedSet(bool paused, address indexed by);

    constructor(address roleManager_) {
        if (roleManager_ == address(0)) revert Errors.ZeroAddress();
        roleManager = RoleManager(roleManager_);
    }

    modifier restricted(bytes32 role) {
        if (!roleManager.hasRole(role, msg.sender)) revert Errors.NotAuthorized(role, msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Errors.Paused();
        _;
    }

    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        return roleManager.hasRole(role, account);
    }

    /// @notice GUARDIAN (hot key, risk-reducing) or EMERGENCY can pause.
    function pause() external {
        if (!_hasRole(Roles.GUARDIAN, msg.sender) && !_hasRole(Roles.EMERGENCY, msg.sender)) {
            revert Errors.NotAuthorized(Roles.GUARDIAN, msg.sender);
        }
        paused = true;
        emit PausedSet(true, msg.sender);
    }

    /// @notice Only EMERGENCY can unpause (risk-increasing → higher bar).
    function unpause() external restricted(Roles.EMERGENCY) {
        paused = false;
        emit PausedSet(false, msg.sender);
    }
}
