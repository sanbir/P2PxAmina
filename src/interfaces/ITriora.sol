// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";

/// @notice Source of attested reserve quantity (custodian attestation / Chainlink PoR / CRE report).
/// @dev The audit boundary of the secure-mint guard: swapping the source needs no mint-path re-audit.
interface IReserveSource {
    /// @return amount attested reserve quantity, asOf timestamp, decimals of `amount`.
    function attestedReserves(address token) external view returns (uint256 amount, uint64 asOf, uint8 decimals);
}

interface ICustodyAdapter is IReserveSource {
    function isLockActive(bytes32 pledgeId) external view returns (bool);
    function verifyPledge(bytes32 pledgeId, address token, uint256 amount) external view returns (bool);
}

interface IReserveGuard {
    /// @notice Reverts (fail-closed) unless `totalSupply(token) + amount` stays within attested reserves − margin.
    function checkMint(address token, uint256 amount) external view;
    function previewMintLimit(address token) external view returns (uint256);
}

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

interface IOracleAdapter {
    /// @return price1e8 latest USD price (8 dec), and whether it is fresh.
    function getPrice() external view returns (uint256 price1e8, bool fresh);
    /// @notice USD value (1e8) of `cbtcAmount`, capped at the attested-reserve value (peg guard).
    function collateralValueUsd(uint256 cbtcAmount) external view returns (uint256);
}

interface IReleaseAuthorizer {
    function issueRepaymentRelease(bytes32 positionId, bytes32 pledgeId, address borrower, uint256 amount)
        external
        returns (bytes32 voucherId); // ENGINE
    function issueLiquidationRelease(bytes32 positionId, bytes32 pledgeId, address aminaDesk, uint256 amount)
        external
        returns (bytes32 voucherId); // ENGINE
    function issueSurplusRelease(bytes32 positionId, bytes32 pledgeId, address borrower, uint256 amount)
        external
        returns (bytes32 voucherId); // ENGINE
    /// @notice One-use consume; reverts if already consumed or mismatched. Returns the voucher destination.
    function consume(bytes32 voucherId, bytes32 pledgeId, uint256 amount) external returns (address destination); // TOKEN/ENGINE
    function getVoucher(bytes32 voucherId) external view returns (Types.ReleaseVoucher memory);
}

interface ISettlementRouter {
    function emitInstruction(bytes32 kind, bytes32 positionId, bytes32 voucherId, bytes calldata data) external; // ENGINE/MODULE
}

interface IProtocolAdapter {
    function supplyCollateral(uint256 cbtcAmount) external;
    function withdrawCollateral(uint256 cbtcAmount, address receiver) external;
    function borrow(uint256 usdcAmount, address receiver) external;
    function repay(uint256 usdcAmount) external;
    function borrowBalance() external view returns (uint256);
    function collateralBalance() external view returns (uint256);
    function accrue() external;
}
