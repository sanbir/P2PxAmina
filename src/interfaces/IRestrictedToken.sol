// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRestrictedToken {
    function setProtocol(address account, bool allowed) external;
    function isTransferAllowed(address from, address to) external view returns (bool);
    function protocolBurn(address from, uint256 amount) external;
}

interface IPermissionedCollateralToken is IRestrictedToken {
    function mintForPledge(address to, bytes32 pledgeId, uint256 amount) external;
    function burnForRelease(address from, bytes32 pledgeId, uint256 amount, bytes32 voucherId) external;
}

interface IReserveToken is IRestrictedToken {
    function mintForReserve(address to, bytes32 reserveId, uint256 amount) external;
    function burnFromProtocol(address from, uint256 amount) external;
}
