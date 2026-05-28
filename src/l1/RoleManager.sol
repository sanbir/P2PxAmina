// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @title RoleManager — immutable authority for every UUPS contract.
/// @notice Wraps OZ AccessManager. v3 §5.1 specifies this is deployed
///         directly (not behind a proxy). Migration is an explicit
///         timelocked authority-migration ceremony, not a UUPS upgrade.
contract RoleManager is AccessManager {
    /// @param initialAdmin the bootstrap admin. Production deployments
    ///        immediately transfer this to a multisig and revoke EOA.
    constructor(address initialAdmin) AccessManager(initialAdmin) {}
}
