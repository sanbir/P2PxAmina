// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplianceHook} from "../interfaces/IComplianceRegistry.sol";

/// @notice Test-only hook: pre passes, post reverts. Used to verify
///         post-hook revert isolation per architecture v3 §17 / §21
///         (post-hooks try/catch, no rollback of protocol state).
contract RevertingPostHook is IComplianceHook {
    function preCheck(address, bytes32, address, address, uint256, bytes32)
        external
        pure
        returns (bool ok, bytes32 reason)
    {
        return (true, bytes32(0));
    }

    function postNotify(address, bytes32, address, address, uint256, bytes32) external pure {
        revert("HOOK_POST_REVERT");
    }
}
