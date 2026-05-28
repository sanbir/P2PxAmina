// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Stateless event emitter; custodian listeners depend on
///         stable schema forever within a router version.
interface ISettlementRouter {
    function version() external view returns (uint16);
    function nextSequence() external returns (uint64);

    function emitAdvanceIntent(
        bytes32 dealId,
        address supplyToken,
        uint256 amount,
        address beneficiary,
        bytes32 settlementRef,
        uint64 expectedSettlementDeadline
    ) external;

    function emitDealActivated(bytes32 dealId, address lender, address borrower, uint128 principal) external;
    function emitRepaid(bytes32 dealId, uint128 amount, bool collateralReleased) external;
    function emitCollateralReleased(bytes32 dealId, address to, uint256 amount, bool success, bytes32 reasonCode)
        external;
    function emitLiquidationWarn(bytes32 dealId, uint256 hf) external;
    function emitLiquidationPartial(bytes32 dealId, uint256 collateralSeized, uint256 debtCovered) external;
    function emitLiquidationFull(bytes32 dealId, uint256 collateralSeized, uint256 debtCovered, uint256 surplus)
        external;
    function emitOracleOverridden(
        bytes32 dealId,
        address newCollOracle,
        address newSuppOracle,
        bytes32 reason,
        uint64 effectiveAt
    ) external;
}
