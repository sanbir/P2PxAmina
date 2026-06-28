// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title RoleManager
/// @notice Single source of truth for every permission in Triora (Tech Spec S1).
/// @dev Thin wrapper over OZ AccessControl. GOVERNOR (P2P) holds DEFAULT_ADMIN_ROLE and
///      can grant/revoke all roles. In production GOVERNOR is a 3-of-5 Safe behind a timelock;
///      here it is wired in the constructor. The privilege-separation invariant (S0.9 #8) —
///      no role both moves collateral AND sets risk params — is enforced by how roles are
///      assigned to contracts/actors, not by this registry.
contract RoleManager is AccessControl {
    constructor(address governor) {
        require(governor != address(0), "governor=0");
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(Roles.GOVERNOR, governor);
        // GOVERNOR administers every functional role.
        _setRoleAdmin(Roles.CURATOR, Roles.GOVERNOR);
        _setRoleAdmin(Roles.ALLOCATOR, Roles.GOVERNOR);
        _setRoleAdmin(Roles.LIQUIDATOR, Roles.GOVERNOR);
        _setRoleAdmin(Roles.ISSUER_MINTER, Roles.GOVERNOR);
        _setRoleAdmin(Roles.GUARDIAN, Roles.GOVERNOR);
        _setRoleAdmin(Roles.EMERGENCY, Roles.GOVERNOR);
        _setRoleAdmin(Roles.ORACLE_ADMIN, Roles.GOVERNOR);
        _setRoleAdmin(Roles.SETTLEMENT, Roles.GOVERNOR);
        _setRoleAdmin(Roles.ENGINE, Roles.GOVERNOR);
        _setRoleAdmin(Roles.LIQUIDATION_MODULE, Roles.GOVERNOR);
        _setRoleAdmin(Roles.TOKEN, Roles.GOVERNOR);
        _setRoleAdmin(Roles.RELEASE_AUTHORIZER, Roles.GOVERNOR);
    }
}
