// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";

interface IPledgeRegistry {
    function canMint(bytes32 pledgeId, uint256 amount) external view returns (bool);
    function recordMint(bytes32 pledgeId, uint256 amount) external;
    function recordBurn(bytes32 pledgeId, uint256 amount) external;
    function lockForDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external;
    function unlockFromDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external;
    function markReleasePending(bytes32 pledgeId, bytes32 voucherId) external;
    function markLiquidationPending(bytes32 pledgeId, bytes32 voucherId) external;
    function markReleased(bytes32 pledgeId, bytes32 ackId) external;
    function markLiquidated(bytes32 pledgeId, bytes32 ackId) external;
    function getPledge(bytes32 pledgeId) external view returns (TypesV2.Pledge memory);
}
