// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplianceHook} from "../interfaces/IComplianceRegistry.sol";

/// @notice Test-only hook: pre returns (false, reason) for one
///         specified counterparty address. Used to verify pre-hook
///         enforcement.
contract BlockingPreHook is IComplianceHook {
    address public immutable blocked;
    bytes32 public immutable reason;

    constructor(address blocked_, bytes32 reason_) {
        blocked = blocked_;
        reason = reason_;
    }

    function preCheck(address, bytes32, address from, address to, uint256, bytes32)
        external
        view
        returns (bool ok, bytes32 r)
    {
        if (from == blocked || to == blocked) return (false, reason);
        return (true, bytes32(0));
    }

    function postNotify(address, bytes32, address, address, uint256, bytes32) external pure {}
}
