// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

interface IDealRegistry {
    function record(bytes32 dealId, Types.DealTerms calldata terms) external;

    function getTerms(bytes32 dealId) external view returns (Types.DealTerms memory);

    function exists(bytes32 dealId) external view returns (bool);

    function nonceUsed(address who, bytes32 nonce) external view returns (bool);

    function markNonceUsed(address who, bytes32 nonce) external;
}
