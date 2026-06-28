// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Roles
/// @notice Canonical role identifiers for Triora Core (S0.6 of the Tech Spec).
/// @dev Used with {RoleManager} (an AccessControl instance). External/governance
///      roles are held by AMINA/P2P multisigs; internal roles wire contracts together.
library Roles {
    // ── Governance / external actors ──────────────────────────────────────────
    bytes32 internal constant GOVERNOR = keccak256("triora.role.GOVERNOR"); // P2P: upgrades, wiring
    bytes32 internal constant CURATOR = keccak256("triora.role.CURATOR"); // AMINA: risk params, admission
    bytes32 internal constant ALLOCATOR = keccak256("triora.role.ALLOCATOR"); // AMINA: open positions
    bytes32 internal constant LIQUIDATOR = keccak256("triora.role.LIQUIDATOR"); // AMINA: liquidation ops
    bytes32 internal constant ISSUER_MINTER = keccak256("triora.role.ISSUER_MINTER"); // custodian/CRE mint key
    bytes32 internal constant GUARDIAN = keccak256("triora.role.GUARDIAN"); // AMINA OPS: pause / reduce risk
    bytes32 internal constant EMERGENCY = keccak256("triora.role.EMERGENCY"); // joint: global halt / override
    bytes32 internal constant ORACLE_ADMIN = keccak256("triora.role.ORACLE_ADMIN"); // oracle/param versions
    bytes32 internal constant SETTLEMENT = keccak256("triora.role.SETTLEMENT"); // custody listener acks

    // ── Internal component-to-component roles ─────────────────────────────────
    bytes32 internal constant ENGINE = keccak256("triora.role.ENGINE"); // CollateralBridge
    bytes32 internal constant LIQUIDATION_MODULE = keccak256("triora.role.LIQUIDATION_MODULE");
    bytes32 internal constant TOKEN = keccak256("triora.role.TOKEN"); // cBTC token
    bytes32 internal constant RELEASE_AUTHORIZER = keccak256("triora.role.RELEASE_AUTHORIZER");
}
