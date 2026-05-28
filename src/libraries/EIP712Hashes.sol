// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "./Types.sol";

/// @title EIP712Hashes — canonical typehashes used in P2PxAmina.
library EIP712Hashes {
    bytes32 internal constant DEAL_INTENT_TYPEHASH = keccak256(
        "DealIntent(address lender,address borrower,address supplyToken,address collateralToken,uint128 principal,uint128 collateralAmount,uint32 rateBps,uint64 startTs,uint64 maturityTs,bytes32 pairKey,uint32 paramVersion,bytes32 nonceLender,bytes32 nonceBorrower,bytes32 nonceAmina,bytes32 legalTermsHash)"
    );

    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "DualPriceAttestation(bytes32 dealId,bytes32 sourceId,uint256 observedCollateralPrice,uint256 observedSupplyPrice,uint64 observationTs,bytes32 reasonCode)"
    );

    function hashDealIntent(Types.DealIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DEAL_INTENT_TYPEHASH,
                intent.lender,
                intent.borrower,
                intent.supplyToken,
                intent.collateralToken,
                intent.principal,
                intent.collateralAmount,
                intent.rateBps,
                intent.startTs,
                intent.maturityTs,
                intent.pairKey,
                intent.paramVersion,
                intent.nonceLender,
                intent.nonceBorrower,
                intent.nonceAmina,
                intent.legalTermsHash
            )
        );
    }

    function hashAttestation(Types.DualPriceAttestation memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                a.dealId,
                a.sourceId,
                a.observedCollateralPrice,
                a.observedSupplyPrice,
                a.observationTs,
                a.reasonCode
            )
        );
    }
}
