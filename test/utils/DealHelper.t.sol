// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolFixture} from "./ProtocolFixture.t.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";
import {LiquidationHandler} from "../../src/l4/LiquidationHandler.sol";

/// @notice Small mixin: pair setup + deal-opening helpers reused by
///         every fork-flow test.
abstract contract DealHelper is ProtocolFixture {
    bytes32 internal pairKey;
    uint32 internal paramVersion;

    function _registerCustodianAndPair(
        address supply,
        address collateral,
        address suppFeed,
        address collFeed,
        uint16 ltvBps,
        uint16 warningBps,
        uint16 partialBps,
        uint16 fullBps
    ) internal {
        vm.prank(CURATOR_ADDR);
        issuers.addIssuer(CUSTODIAN, CUSTODIAN, keccak256("legal"), 1_000_000_000e18);
        _admitAndAddToken(supply, Types.TokenKind.Supply, CUSTODIAN, 1_000_000_000e18);
        _admitAndAddToken(collateral, Types.TokenKind.Collateral, CUSTODIAN, 1_000_000_000e18);

        Types.ParamsV1 memory p = Types.ParamsV1({
            ltvBps: ltvBps,
            warningBps: warningBps,
            partialLiqBps: partialBps,
            fullLiqBps: fullBps,
            maxMaturity: 365 days,
            maxRateBps: 2_000,
            liquidationBonusBps: 500,
            aminaFeeBps: 100,
            pairCapUsd: 1_000_000_000e18,
            priceSourceCollateral: collFeed,
            priceSourceSupply: suppFeed,
            heartbeatCollateral: 24 hours,
            heartbeatSupply: 24 hours,
            oracleDecimalsCollateral: 8,
            oracleDecimalsSupply: 8,
            active: true
        });
        vm.prank(CURATOR_ADDR);
        collateralRegistry.addPair(collateral, supply, p);
        pairKey = collateralRegistry.pairKey(collateral, supply);
        paramVersion = collateralRegistry.latestVersion(pairKey);

        vm.startPrank(GOVERNOR);
        engine.setGlobalCapUsd(1_000_000_000e18);
        engine.setBorrowerCapUsd(BORROWER, 1_000_000_000e18);
        engine.setLenderCapUsd(LENDER, 1_000_000_000e18);
        vm.stopPrank();
    }

    function _buildIntent(
        address supply,
        address collateral,
        uint128 principal,
        uint128 collAmount,
        uint64 maturityDelta,
        uint32 rateBps
    ) internal view returns (Types.DealIntent memory) {
        return Types.DealIntent({
            lender: LENDER,
            borrower: BORROWER,
            supplyToken: supply,
            collateralToken: collateral,
            principal: principal,
            collateralAmount: collAmount,
            rateBps: rateBps,
            startTs: uint64(block.timestamp),
            maturityTs: uint64(block.timestamp + maturityDelta),
            pairKey: pairKey,
            paramVersion: paramVersion,
            nonceLender: keccak256(abi.encode("L", block.timestamp, principal)),
            nonceBorrower: keccak256(abi.encode("B", block.timestamp, principal)),
            nonceAmina: keccak256(abi.encode("A", block.timestamp, principal)),
            legalTermsHash: keccak256("legalTerms-v1")
        });
    }

    function _signIntent(Types.DealIntent memory intent, uint256 pk) internal view returns (bytes memory) {
        bytes32 typedHash = engine.hashDealIntent(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, typedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signAttestation(Types.DualPriceAttestation memory att, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typedHash = handler.hashAttestation(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, typedHash);
        return abi.encodePacked(r, s, v);
    }
}
