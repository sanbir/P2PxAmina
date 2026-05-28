// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

interface IKYBGateway {
    function isApproved(address who) external view returns (bool);
    function getRecord(address who) external view returns (Types.KybRecord memory);
}
