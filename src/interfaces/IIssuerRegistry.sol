// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

interface IIssuerRegistry {
    function getTokenInfo(address token) external view returns (Types.TokenInfo memory);
    function getIssuerInfo(address issuer) external view returns (Types.IssuerInfo memory);
    function isTokenActive(address token) external view returns (bool);
    function isTokenKind(address token, Types.TokenKind kind) external view returns (bool);
    function chargeCap(address token, uint256 usdValue) external;
    function releaseCap(address token, uint256 usdValue) external;
}
