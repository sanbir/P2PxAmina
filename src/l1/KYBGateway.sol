// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessManagedUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IKYBGateway} from "../interfaces/IKYBGateway.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title KYBGateway — per-counterparty KYB approvals.
/// @notice UUPS contract behind a proxy. The authority is `RoleManager`;
///         setStatus is gated to the CURATOR role.
contract KYBGateway is Initializable, UUPSUpgradeable, AccessManagedUpgradeable, IKYBGateway {
    /// @custom:storage-location erc7201:p2pxamina.kybgateway.v1
    struct Storage {
        mapping(address => Types.KybRecord) records;
    }

    // keccak256(abi.encode(uint256(keccak256("p2pxamina.kybgateway.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x6f70a47cb2da3ed7b5e5b89db4e2b6e07ff5b27c3e6bd8d3c0fb0e8e6f9c0e00;

    event KybSet(
        address indexed who,
        Types.KybStatus status,
        uint64 expiryTs,
        bytes32 documentsHash,
        address by,
        bytes32 jurisdictionCode
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address authority_) external initializer {
        __AccessManaged_init(authority_);
        __UUPSUpgradeable_init();
    }

    // --------------- mutators ---------------

    function setStatus(
        address who,
        Types.KybStatus status,
        uint64 expiryTs,
        bytes32 documentsHash,
        bytes32 jurisdictionCode
    ) external restricted {
        Storage storage $ = _store();
        Types.KybRecord storage rec = $.records[who];
        rec.status = status;
        rec.approvedAt = status == Types.KybStatus.Approved ? uint64(block.timestamp) : rec.approvedAt;
        rec.expiryTs = expiryTs;
        rec.documentsHash = documentsHash;
        rec.approvedBy = msg.sender;
        rec.jurisdictionCode = jurisdictionCode;
        emit KybSet(who, status, expiryTs, documentsHash, msg.sender, jurisdictionCode);
    }

    // --------------- views ---------------

    function isApproved(address who) external view returns (bool) {
        Types.KybRecord storage rec = _store().records[who];
        if (rec.status != Types.KybStatus.Approved) return false;
        if (rec.expiryTs != 0 && rec.expiryTs <= block.timestamp) return false;
        return true;
    }

    function getRecord(address who) external view returns (Types.KybRecord memory) {
        return _store().records[who];
    }

    // --------------- internals ---------------

    function _authorizeUpgrade(address) internal override restricted {}

    function _store() private pure returns (Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
