// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "../libraries/TypesV2.sol";

interface IReleaseAuthorizer {
    function issueRepaymentRelease(bytes32 dealId) external returns (bytes32 voucherId);
    function issueLiquidationRelease(bytes32 dealId) external returns (bytes32 voucherId);
    function consumeVoucher(bytes32 voucherId, bytes32 ackNonce) external;
    function isVoucherValid(bytes32 voucherId) external view returns (bool);
    function getVoucher(bytes32 voucherId) external view returns (TypesV2.ReleaseVoucher memory);
}
