// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";

interface ISettlementRouterV2 {
    function nextSequence() external returns (uint64);
    function emitFundingInstruction(
        bytes32 dealId,
        bytes32 pledgeId,
        bytes32 reserveId,
        address asset,
        uint256 amount,
        bytes32 routeHash,
        bytes32 settlementRef,
        uint64 deadline
    ) external;
    function emitFundingConfirmed(bytes32 dealId, bytes32 settlementRef, uint256 amount) external;
    function emitFundingCancelled(bytes32 dealId, bytes32 reasonCode) external;
    function emitRepaymentInstruction(bytes32 dealId, uint256 amount, bytes32 routeHash, uint64 deadline) external;
    function emitRepaymentConfirmed(bytes32 dealId, uint256 amount, uint256 outstanding) external;
    function emitReleaseInstruction(TypesV2.ReleaseVoucher calldata voucher) external;
    function emitReleaseConfirmed(bytes32 dealId, bytes32 voucherId, bytes32 ackNonce) external;
    function emitLiquidationInstruction(bytes32 dealId, bytes32 voucherId, uint256 amount) external;
    function emitSettlementFailed(bytes32 dealId, bytes32 reasonCode) external;
}
