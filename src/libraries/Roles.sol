// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Roles — canonical role IDs registered with `RoleManager`.
/// @notice Eight roles per architecture v3 §7. Numerical IDs are
///         chosen as deterministic constants so deployments are
///         reproducible.
library Roles {
    // OZ AccessManager reserves 0 for ADMIN. Application roles start at 1.
    uint64 internal constant GOVERNOR = 1; // P2P + AMINA 3-of-4
    uint64 internal constant EMERGENCY = 2; // P2P + AMINA 2-of-2
    uint64 internal constant CURATOR = 3; // AMINA risk
    uint64 internal constant ALLOCATOR = 4; // matching engine
    uint64 internal constant LIQUIDATOR = 5; // AMINA liquidator
    uint64 internal constant GUARDIAN = 6; // pause / reduce risk only
    uint64 internal constant OPS = 7; // hot keys, decrease caps
    uint64 internal constant ORACLE_ADMIN = 8; // rotate oracle versions
}
