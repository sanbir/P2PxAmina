// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IReleaseAuthorizer} from "../interfaces/IReleaseAuthorizer.sol";
import {LendingEngineV2} from "../l3/LendingEngineV2.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {EIP712HashesV2} from "../libraries/EIP712HashesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title LiquidationHandlerV2 -- AMINA-only warning and liquidation voucher trigger.
contract LiquidationHandlerV2 is AccessManaged, EIP712, ReentrancyGuard {
    LendingEngineV2 public immutable engine;
    IReleaseAuthorizer public immutable releaseAuthorizer;

    address public priceAttestor;
    uint64 public maxAttestationAge;
    uint256 public warningHealthBps = 12_500;
    uint256 public fullLiquidationHealthBps = 10_500;

    event PriceAttestorSet(address indexed priceAttestor);
    event MaxAttestationAgeSet(uint64 maxAttestationAge);
    event ThresholdsSet(uint256 warningHealthBps, uint256 fullLiquidationHealthBps);
    event Warned(bytes32 indexed dealId, uint256 healthBps);
    event FullLiquidationRequested(bytes32 indexed dealId, uint256 healthBps, bytes32 indexed voucherId);

    error LiquidationNotAllowed(uint256 healthBps);
    error BadPriceAttestor(address expected);
    error PriceAttestationStale();

    constructor(address authority_, address engine_, address releaseAuthorizer_, address priceAttestor_)
        AccessManaged(authority_)
        EIP712("TrioraLiquidationHandlerV2", "1")
    {
        if (engine_ == address(0) || releaseAuthorizer_ == address(0) || priceAttestor_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        engine = LendingEngineV2(engine_);
        releaseAuthorizer = IReleaseAuthorizer(releaseAuthorizer_);
        priceAttestor = priceAttestor_;
        maxAttestationAge = 10 minutes;
        emit PriceAttestorSet(priceAttestor_);
        emit MaxAttestationAgeSet(maxAttestationAge);
    }

    function setPriceAttestor(address priceAttestor_) external restricted {
        if (priceAttestor_ == address(0)) revert Errors.ZeroAddress();
        priceAttestor = priceAttestor_;
        emit PriceAttestorSet(priceAttestor_);
    }

    function setMaxAttestationAge(uint64 maxAttestationAge_) external restricted {
        maxAttestationAge = maxAttestationAge_;
        emit MaxAttestationAgeSet(maxAttestationAge_);
    }

    function setThresholds(uint256 warningHealthBps_, uint256 fullLiquidationHealthBps_) external restricted {
        if (fullLiquidationHealthBps_ == 0 || fullLiquidationHealthBps_ > warningHealthBps_) {
            revert Errors.InvalidParams(bytes32("THRESHOLDS"));
        }
        warningHealthBps = warningHealthBps_;
        fullLiquidationHealthBps = fullLiquidationHealthBps_;
        emit ThresholdsSet(warningHealthBps_, fullLiquidationHealthBps_);
    }

    function warn(TypesV2.PriceAttestationV2 calldata att, bytes calldata sig) external restricted nonReentrant {
        _checkAttestation(att, sig);
        uint256 health = _health(att);
        if (health >= warningHealthBps) revert LiquidationNotAllowed(health);
        engine.setWarned(att.dealId);
        emit Warned(att.dealId, health);
    }

    function requestFullLiquidation(TypesV2.PriceAttestationV2 calldata att, bytes calldata sig)
        external
        restricted
        nonReentrant
        returns (bytes32 voucherId)
    {
        _checkAttestation(att, sig);
        uint256 health = _health(att);
        TypesV2.DealTermsV2 memory terms = engine.getTerms(att.dealId);
        bool matured = block.timestamp >= terms.maturityTs;
        if (health >= fullLiquidationHealthBps && !matured) revert LiquidationNotAllowed(health);
        engine.markLiquidationPending(att.dealId, bytes32(0));
        voucherId = releaseAuthorizer.issueLiquidationRelease(att.dealId);
        engine.markLiquidationPending(att.dealId, voucherId);
        emit FullLiquidationRequested(att.dealId, health, voucherId);
    }

    function hashPriceAttestation(TypesV2.PriceAttestationV2 calldata att) external view returns (bytes32) {
        return _hashTypedDataV4(EIP712HashesV2.hashPriceAttestation(att));
    }

    function _checkAttestation(TypesV2.PriceAttestationV2 calldata att, bytes calldata sig) internal view {
        if (block.timestamp - uint256(att.observationTs) > uint256(maxAttestationAge)) revert PriceAttestationStale();
        bytes32 digest = _hashTypedDataV4(EIP712HashesV2.hashPriceAttestation(att));
        if (!SignatureChecker.isValidSignatureNow(priceAttestor, digest, sig)) revert BadPriceAttestor(priceAttestor);
    }

    function _health(TypesV2.PriceAttestationV2 calldata att) internal view returns (uint256) {
        return engine.healthFactorBpsFromPrices(
            att.dealId,
            att.collateralPrice,
            att.reservePrice,
            att.collateralPriceDecimals,
            att.reservePriceDecimals
        );
    }
}
