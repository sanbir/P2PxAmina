// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ICustodyAdapter, ICustodyAdapterRegistry} from "../interfaces/ICustodyAdapter.sol";
import {IPledgeRegistry} from "../interfaces/IPledgeRegistry.sol";
import {TypesV2} from "../libraries/TypesV2.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title PledgeRegistry -- source of truth for BitGo-controlled collateral pledges.
contract PledgeRegistry is AccessManaged, IPledgeRegistry {
    ICustodyAdapterRegistry public immutable custodyRegistry;

    address public engine;
    address public releaseAuthorizer;
    address public settlementAcker;

    mapping(bytes32 pledgeId => TypesV2.Pledge) private _pledges;
    mapping(address token => uint256) public totalPledged;

    event EngineSet(address indexed engine);
    event ReleaseAuthorizerSet(address indexed releaseAuthorizer);
    event SettlementAckerSet(address indexed settlementAcker);
    event PledgeRequested(bytes32 indexed pledgeId, bytes32 indexed custodianId, bytes32 custodyAccountRef);
    event PledgeActivated(bytes32 indexed pledgeId, uint256 pledgedAmount, bytes32 evidenceHash);
    event PledgeMintRecorded(bytes32 indexed pledgeId, uint256 amount, uint256 mintedAmount);
    event PledgeBurnRecorded(bytes32 indexed pledgeId, uint256 amount, uint256 mintedAmount);
    event PledgeLocked(bytes32 indexed pledgeId, bytes32 indexed dealId, uint256 amount);
    event PledgeUnlocked(bytes32 indexed pledgeId, bytes32 indexed dealId, uint256 amount);
    event PledgeReleasePending(bytes32 indexed pledgeId, bytes32 indexed voucherId, bool liquidation);
    event PledgeReleased(bytes32 indexed pledgeId, bytes32 indexed ackId);
    event PledgeLiquidated(bytes32 indexed pledgeId, bytes32 indexed ackId);

    error PledgeExists(bytes32 pledgeId);
    error PledgeMissing(bytes32 pledgeId);
    error PledgeNotActive(bytes32 pledgeId);
    error PledgeAmountExceeded(bytes32 pledgeId);
    error BadPledgeAttestation(bytes32 pledgeId, bytes32 reason);
    error IneligibleCustodyAccount(bytes32 custodyAccountRef);
    error UnauthorizedRegistryCaller(address caller);

    constructor(address authority_, address custodyRegistry_) AccessManaged(authority_) {
        if (custodyRegistry_ == address(0)) revert Errors.ZeroAddress();
        custodyRegistry = ICustodyAdapterRegistry(custodyRegistry_);
    }

    function setEngine(address engine_) external restricted {
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
        emit EngineSet(engine_);
    }

    function setReleaseAuthorizer(address releaseAuthorizer_) external restricted {
        if (releaseAuthorizer_ == address(0)) revert Errors.ZeroAddress();
        releaseAuthorizer = releaseAuthorizer_;
        emit ReleaseAuthorizerSet(releaseAuthorizer_);
    }

    function setSettlementAcker(address settlementAcker_) external restricted {
        if (settlementAcker_ == address(0)) revert Errors.ZeroAddress();
        settlementAcker = settlementAcker_;
        emit SettlementAckerSet(settlementAcker_);
    }

    function requestPledge(TypesV2.PledgeRequest calldata req) external restricted {
        if (req.pledgeId == bytes32(0) || req.collateralToken == address(0) || req.pledgedAmount == 0) {
            revert Errors.ZeroAmount();
        }
        if (_pledges[req.pledgeId].status != TypesV2.PledgeStatus.None) revert PledgeExists(req.pledgeId);
        if (!custodyRegistry.isCustodyAccountEligible(req.custodianId, req.custodyAccountRef)) {
            revert IneligibleCustodyAccount(req.custodyAccountRef);
        }

        _pledges[req.pledgeId] = TypesV2.Pledge({
            entityId: req.entityId,
            custodyAccountRef: req.custodyAccountRef,
            custodianId: req.custodianId,
            collateralToken: req.collateralToken,
            assetId: req.assetId,
            pledgedAmount: req.pledgedAmount,
            mintedAmount: 0,
            freeAmount: 0,
            encumberedAmount: 0,
            status: TypesV2.PledgeStatus.Requested,
            latestEvidenceHash: bytes32(0),
            controlAgreementHash: req.controlAgreementHash,
            activeDealId: bytes32(0)
        });
        totalPledged[req.collateralToken] += req.pledgedAmount;
        emit PledgeRequested(req.pledgeId, req.custodianId, req.custodyAccountRef);
    }

    function activatePledge(bytes32 pledgeId, bytes calldata attestation) external restricted {
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        if (pledge.status != TypesV2.PledgeStatus.Requested && pledge.status != TypesV2.PledgeStatus.Frozen) {
            revert PledgeNotActive(pledgeId);
        }
        address adapter = custodyRegistry.adapterOf(pledge.custodianId);
        (bool ok, bytes32 subjectId, uint256 amount,, bytes32 reason) =
            ICustodyAdapter(adapter).verifyCustodyAttestation(attestation);
        if (!ok || subjectId != pledgeId || amount < pledge.pledgedAmount) {
            revert BadPledgeAttestation(pledgeId, reason);
        }
        if (!ICustodyAdapter(adapter).isControlActive(pledge.custodyAccountRef)) {
            revert BadPledgeAttestation(pledgeId, bytes32("NO_CONTROL"));
        }
        (TypesV2.CustodyProof memory proof,,,) = _decodeProof(attestation);
        pledge.latestEvidenceHash = proof.evidenceHash;
        pledge.status = TypesV2.PledgeStatus.Active;
        emit PledgeActivated(pledgeId, pledge.pledgedAmount, proof.evidenceHash);
    }

    function canMint(bytes32 pledgeId, uint256 amount) external view returns (bool) {
        TypesV2.Pledge storage pledge = _pledges[pledgeId];
        if (pledge.status != TypesV2.PledgeStatus.Active && pledge.status != TypesV2.PledgeStatus.PartiallyEncumbered) {
            return false;
        }
        return pledge.mintedAmount + amount <= pledge.pledgedAmount;
    }

    function recordMint(bytes32 pledgeId, uint256 amount) external {
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        if (msg.sender != pledge.collateralToken) revert UnauthorizedRegistryCaller(msg.sender);
        if (pledge.mintedAmount + amount > pledge.pledgedAmount) revert PledgeAmountExceeded(pledgeId);
        pledge.mintedAmount += amount;
        pledge.freeAmount += amount;
        emit PledgeMintRecorded(pledgeId, amount, pledge.mintedAmount);
    }

    function recordBurn(bytes32 pledgeId, uint256 amount) external {
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        if (msg.sender != pledge.collateralToken) revert UnauthorizedRegistryCaller(msg.sender);
        if (amount > pledge.mintedAmount) revert PledgeAmountExceeded(pledgeId);
        if (amount <= pledge.freeAmount) {
            pledge.freeAmount -= amount;
        } else {
            uint256 encumberedBurn = amount - pledge.freeAmount;
            if (encumberedBurn > pledge.encumberedAmount) revert PledgeAmountExceeded(pledgeId);
            pledge.freeAmount = 0;
            pledge.encumberedAmount -= encumberedBurn;
        }
        pledge.mintedAmount -= amount;
        emit PledgeBurnRecorded(pledgeId, amount, pledge.mintedAmount);
    }

    function lockForDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external {
        if (msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        if (pledge.status != TypesV2.PledgeStatus.Active && pledge.status != TypesV2.PledgeStatus.PartiallyEncumbered) {
            revert PledgeNotActive(pledgeId);
        }
        if (amount == 0 || amount > pledge.freeAmount) revert PledgeAmountExceeded(pledgeId);
        pledge.freeAmount -= amount;
        pledge.encumberedAmount += amount;
        pledge.activeDealId = dealId;
        pledge.status = pledge.freeAmount == 0 ? TypesV2.PledgeStatus.FullyEncumbered : TypesV2.PledgeStatus.PartiallyEncumbered;
        emit PledgeLocked(pledgeId, dealId, amount);
    }

    function unlockFromDeal(bytes32 pledgeId, bytes32 dealId, uint256 amount) external {
        if (msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        if (pledge.activeDealId != dealId) revert BadPledgeAttestation(pledgeId, bytes32("DEAL"));
        if (amount == 0 || amount > pledge.encumberedAmount) revert PledgeAmountExceeded(pledgeId);
        pledge.encumberedAmount -= amount;
        pledge.freeAmount += amount;
        if (pledge.encumberedAmount == 0) {
            pledge.activeDealId = bytes32(0);
            pledge.status = TypesV2.PledgeStatus.Active;
        } else {
            pledge.status = TypesV2.PledgeStatus.PartiallyEncumbered;
        }
        emit PledgeUnlocked(pledgeId, dealId, amount);
    }

    function markReleasePending(bytes32 pledgeId, bytes32 voucherId) external {
        if (msg.sender != releaseAuthorizer) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        if (pledge.encumberedAmount != 0) revert PledgeAmountExceeded(pledgeId);
        pledge.status = TypesV2.PledgeStatus.ReleasePending;
        emit PledgeReleasePending(pledgeId, voucherId, false);
    }

    function markLiquidationPending(bytes32 pledgeId, bytes32 voucherId) external {
        if (msg.sender != releaseAuthorizer) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        pledge.status = TypesV2.PledgeStatus.ReleasePending;
        emit PledgeReleasePending(pledgeId, voucherId, true);
    }

    function markReleased(bytes32 pledgeId, bytes32 ackId) external {
        if (msg.sender != settlementAcker && msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        pledge.status = TypesV2.PledgeStatus.Released;
        totalPledged[pledge.collateralToken] =
            pledge.pledgedAmount >= totalPledged[pledge.collateralToken] ? 0 : totalPledged[pledge.collateralToken] - pledge.pledgedAmount;
        emit PledgeReleased(pledgeId, ackId);
    }

    function markLiquidated(bytes32 pledgeId, bytes32 ackId) external {
        if (msg.sender != settlementAcker && msg.sender != engine) revert UnauthorizedRegistryCaller(msg.sender);
        TypesV2.Pledge storage pledge = _requirePledge(pledgeId);
        pledge.status = TypesV2.PledgeStatus.Liquidated;
        totalPledged[pledge.collateralToken] =
            pledge.pledgedAmount >= totalPledged[pledge.collateralToken] ? 0 : totalPledged[pledge.collateralToken] - pledge.pledgedAmount;
        emit PledgeLiquidated(pledgeId, ackId);
    }

    function getPledge(bytes32 pledgeId) external view returns (TypesV2.Pledge memory) {
        return _pledges[pledgeId];
    }

    function _requirePledge(bytes32 pledgeId) internal view returns (TypesV2.Pledge storage pledge) {
        pledge = _pledges[pledgeId];
        if (pledge.status == TypesV2.PledgeStatus.None) revert PledgeMissing(pledgeId);
    }

    function _decodeProof(bytes calldata attestation)
        internal
        pure
        returns (TypesV2.CustodyProof memory proof, bytes memory bitgoSig, bytes memory aminaSig, bytes memory raw)
    {
        raw = attestation;
        (proof, bitgoSig, aminaSig) = abi.decode(attestation, (TypesV2.CustodyProof, bytes, bytes));
    }
}
