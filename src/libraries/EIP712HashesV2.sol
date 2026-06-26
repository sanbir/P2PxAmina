// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TypesV2} from "./TypesV2.sol";

/// @title EIP712HashesV2 -- canonical Triora v2 typed-data hashes.
library EIP712HashesV2 {
    bytes32 internal constant CUSTODY_PROOF_TYPEHASH = keccak256(
        "CustodyProof(bytes32 subjectId,bytes32 custodyAccountRef,address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt,bytes32 evidenceHash)"
    );

    bytes32 internal constant DEAL_INTENT_V2_TYPEHASH = keccak256(
        "DealIntentV2(address lender,address borrower,address reserveToken,address collateralToken,uint128 principal,uint128 collateralAmount,uint32 rateBps,uint64 maturityTs,bytes32 pledgeId,bytes32 reserveId,bytes32 nonceLender,bytes32 nonceBorrower,bytes32 nonceAmina,bytes32 legalTermsHash,bytes32 borrowerReleaseRef,bytes32 lenderSettlementRef,bytes32 aminaLiquidationRef)"
    );

    bytes32 internal constant FUNDING_ACK_TYPEHASH = keccak256(
        "FundingAck(bytes32 dealId,bytes32 reserveId,uint256 amount,bytes32 routeHash,bytes32 settlementRef,bytes32 ackNonce,uint64 observedAt)"
    );

    bytes32 internal constant REPAYMENT_ACK_TYPEHASH = keccak256(
        "RepaymentAck(bytes32 dealId,uint256 amount,bytes32 routeHash,bytes32 settlementRef,bytes32 ackNonce,uint64 observedAt)"
    );

    bytes32 internal constant RELEASE_ACK_TYPEHASH = keccak256(
        "ReleaseAck(bytes32 voucherId,bytes32 dealId,bytes32 pledgeId,uint256 amount,bytes32 destinationRef,bytes32 ackNonce,uint64 observedAt)"
    );

    bytes32 internal constant FAILURE_ACK_TYPEHASH = keccak256(
        "FailureAck(bytes32 dealId,bytes32 routeHash,bytes32 reasonCode,bytes32 ackNonce,uint64 observedAt)"
    );

    bytes32 internal constant PRICE_ATTESTATION_V2_TYPEHASH = keccak256(
        "PriceAttestationV2(bytes32 dealId,uint256 collateralPrice,uint256 reservePrice,uint8 collateralPriceDecimals,uint8 reservePriceDecimals,uint64 observationTs,bytes32 reasonCode)"
    );

    function hashCustodyProof(TypesV2.CustodyProof memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CUSTODY_PROOF_TYPEHASH,
                p.subjectId,
                p.custodyAccountRef,
                p.token,
                p.amount,
                p.decimals,
                p.observedAt,
                p.expiresAt,
                p.evidenceHash
            )
        );
    }

    function hashDealIntent(TypesV2.DealIntentV2 memory i) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DEAL_INTENT_V2_TYPEHASH,
                i.lender,
                i.borrower,
                i.reserveToken,
                i.collateralToken,
                i.principal,
                i.collateralAmount,
                i.rateBps,
                i.maturityTs,
                i.pledgeId,
                i.reserveId,
                i.nonceLender,
                i.nonceBorrower,
                i.nonceAmina,
                i.legalTermsHash,
                i.borrowerReleaseRef,
                i.lenderSettlementRef,
                i.aminaLiquidationRef
            )
        );
    }

    function hashFundingAck(TypesV2.FundingAck memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FUNDING_ACK_TYPEHASH,
                a.dealId,
                a.reserveId,
                a.amount,
                a.routeHash,
                a.settlementRef,
                a.ackNonce,
                a.observedAt
            )
        );
    }

    function hashRepaymentAck(TypesV2.RepaymentAck memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(REPAYMENT_ACK_TYPEHASH, a.dealId, a.amount, a.routeHash, a.settlementRef, a.ackNonce, a.observedAt)
        );
    }

    function hashReleaseAck(TypesV2.ReleaseAck memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RELEASE_ACK_TYPEHASH,
                a.voucherId,
                a.dealId,
                a.pledgeId,
                a.amount,
                a.destinationRef,
                a.ackNonce,
                a.observedAt
            )
        );
    }

    function hashFailureAck(TypesV2.FailureAck memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(FAILURE_ACK_TYPEHASH, a.dealId, a.routeHash, a.reasonCode, a.ackNonce, a.observedAt)
        );
    }

    function hashPriceAttestation(TypesV2.PriceAttestationV2 memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PRICE_ATTESTATION_V2_TYPEHASH,
                a.dealId,
                a.collateralPrice,
                a.reservePrice,
                a.collateralPriceDecimals,
                a.reservePriceDecimals,
                a.observationTs,
                a.reasonCode
            )
        );
    }
}
