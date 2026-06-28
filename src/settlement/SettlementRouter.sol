// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {ISettlementRouter} from "../interfaces/ITriora.sol";

/// @title SettlementRouter
/// @notice Append-only, monotonic-sequenced instruction/voucher event stream for the off-chain
///         custody listener (Tech Spec S8). Stateless except the sequence counter; the event field
///         shape is an integration contract — new schemas ship as a new versioned router.
contract SettlementRouter is ISettlementRouter, TrioraAccess {
    uint256 public seq;

    event Instruction(
        uint256 indexed sequence, bytes32 indexed kind, bytes32 indexed positionId, bytes32 voucherId, bytes data
    );

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    /// @notice Only the engine or the liquidation module may emit instructions.
    function emitInstruction(bytes32 kind, bytes32 positionId, bytes32 voucherId, bytes calldata data) external {
        if (!_hasRole(Roles.ENGINE, msg.sender) && !_hasRole(Roles.LIQUIDATION_MODULE, msg.sender)) {
            revert Errors.NotAuthorized(Roles.ENGINE, msg.sender);
        }
        emit Instruction(++seq, kind, positionId, voucherId, data);
    }
}
