// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";

interface IReserveRegistry {
    function lockForDeal(bytes32 reserveId, bytes32 dealId, uint256 amount) external;
    function markFunded(bytes32 reserveId, bytes32 dealId, uint256 amount) external;
    function releaseLocked(bytes32 reserveId, bytes32 dealId, uint256 amount) external;
    function markReturned(bytes32 reserveId, bytes32 dealId, uint256 amount) external;
    function getReserve(bytes32 reserveId) external view returns (TypesV2.Reserve memory);
}
