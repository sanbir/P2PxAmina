// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

/// @notice Source of attested reserve quantity (custodian attestation / Chainlink PoR / CRE report).
interface IReserveSource {
    function attestedReserves(address token) external view returns (uint256 amount, uint64 asOf, uint8 decimals);
}

interface ICustodyAdapter is IReserveSource {
    function isLockActive(bytes32 pledgeId) external view returns (bool);
    function verifyPledge(bytes32 pledgeId, address token, uint256 amount) external view returns (bool);
}

interface IReserveGuard {
    function checkMint(address token, uint256 amount) external view;
    function previewMintLimit(address token) external view returns (uint256);
}

// ── cBTC collateral pledges ───────────────────────────────────────────────────
interface IPledgeRegistry {
    function getPledge(bytes32 pledgeId) external view returns (Types.Pledge memory);
    function freeAmount(bytes32 pledgeId) external view returns (uint256);
    function canMint(bytes32 pledgeId, uint256 amount) external view returns (bool);
    function recordMint(bytes32 pledgeId, uint256 amount) external; // TOKEN
    function lockForDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external; // ENGINE
    function unlockFromDeal(bytes32 pledgeId, uint256 amount) external; // ENGINE
    function markReleasePending(bytes32 pledgeId) external; // ENGINE
    function markReleased(bytes32 pledgeId, uint256 amount) external; // ENGINE
    function markLiquidated(bytes32 pledgeId, uint256 amount) external; // ENGINE
}

interface IPermissionedCollateralToken {
    function mintForPledge(address to, bytes32 pledgeId, uint256 amount) external; // ISSUER_MINTER
    function burnForRelease(address from, bytes32 pledgeId, uint256 amount, bytes32 voucherId) external; // ENGINE
}

// ── cUSDC lender liquidity reservations ───────────────────────────────────────
interface IReserveRegistry {
    function getReserve(bytes32 reserveId) external view returns (Types.Reserve memory);
    function availableAmount(bytes32 reserveId) external view returns (uint256);
    function canMint(bytes32 reserveId, uint256 amount) external view returns (bool);
    function recordMint(bytes32 reserveId, uint256 amount) external; // TOKEN
    function lockForDeal(bytes32 reserveId, bytes32 dealId, uint256 amount) external; // ENGINE
    function unlockFromDeal(bytes32 reserveId, uint256 amount) external; // ENGINE
    function markFunded(bytes32 reserveId, uint256 amount) external; // ENGINE
    function markReturned(bytes32 reserveId) external; // ENGINE
}

interface IReserveToken {
    function mintForReserve(address to, bytes32 reserveId, uint256 amount) external; // ISSUER_MINTER
    function burnLocked(address from, uint256 amount) external; // ENGINE (burn on funding)
}

interface IOracleAdapter {
    function getPrice() external view returns (uint256 price1e8, bool fresh);
    function collateralValueUsd(uint256 cbtcAmount) external view returns (uint256);
}

interface IReleaseAuthorizer {
    function issueRepaymentRelease(bytes32 positionId, bytes32 pledgeId, address borrower, uint256 amount)
        external
        returns (bytes32 voucherId);
    function issueLiquidationRelease(bytes32 positionId, bytes32 pledgeId, address aminaDesk, uint256 amount)
        external
        returns (bytes32 voucherId);
    function issueSurplusRelease(bytes32 positionId, bytes32 pledgeId, address borrower, uint256 amount)
        external
        returns (bytes32 voucherId);
    function consume(bytes32 voucherId, bytes32 pledgeId, uint256 amount) external returns (address destination);
    function getVoucher(bytes32 voucherId) external view returns (Types.ReleaseVoucher memory);
}

interface ISettlementRouter {
    function emitInstruction(bytes32 kind, bytes32 positionId, bytes32 voucherId, bytes calldata data) external;
}
