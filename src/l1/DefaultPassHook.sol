// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplianceHook} from "../interfaces/IComplianceRegistry.sol";

/// @title DefaultPassHook — terminal compliance hook (always passes).
/// @notice Used as the catch-all hook when a token / action has no
///         explicit per-pair hook. Immutable, view-only, no state.
contract DefaultPassHook is IComplianceHook {
    function preCheck(
        address, /*token*/
        bytes32, /*action*/
        address, /*from*/
        address, /*to*/
        uint256, /*amount*/
        bytes32 /*dealId*/
    ) external pure returns (bool ok, bytes32 reason) {
        return (true, bytes32(0));
    }

    function postNotify(
        address, /*token*/
        bytes32, /*action*/
        address, /*from*/
        address, /*to*/
        uint256, /*amount*/
        bytes32 /*dealId*/
    ) external pure {
        // no-op
    }
}
