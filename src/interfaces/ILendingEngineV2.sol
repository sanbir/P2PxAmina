// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";

interface ILendingEngineV2 {
    function confirmFunding(TypesV2.FundingAck calldata ack) external;
    function confirmRepayment(TypesV2.RepaymentAck calldata ack) external;
    function confirmRelease(TypesV2.ReleaseAck calldata ack) external;
    function markSettlementFailed(TypesV2.FailureAck calldata ack) external;
    function setWarned(bytes32 dealId) external;
    function markLiquidationPending(bytes32 dealId, bytes32 voucherId) external;
    function stateOf(bytes32 dealId) external view returns (TypesV2.DealStateV2);
    function getTerms(bytes32 dealId) external view returns (TypesV2.DealTermsV2 memory);
    function getRuntime(bytes32 dealId) external view returns (TypesV2.DealRuntimeV2 memory);
    function computeOutstanding(bytes32 dealId) external view returns (uint128);
}
