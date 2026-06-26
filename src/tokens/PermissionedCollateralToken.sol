// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPledgeRegistry} from "../interfaces/IPledgeRegistry.sol";
import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {IReleaseAuthorizer} from "../interfaces/IReleaseAuthorizer.sol";
import {PermissionedTokenBase} from "./PermissionedTokenBase.sol";

/// @title PermissionedCollateralToken -- BitGo-cBTC style pledge-bound ERC-20.
contract PermissionedCollateralToken is PermissionedTokenBase {
    IPledgeRegistry public immutable pledgeRegistry;
    IReserveGuard public immutable reserveGuard;
    IReleaseAuthorizer public releaseAuthorizer;

    event ReleaseAuthorizerSet(address indexed releaseAuthorizer);
    event MintedForPledge(address indexed to, bytes32 indexed pledgeId, uint256 amount);
    event BurnedForRelease(address indexed from, bytes32 indexed pledgeId, uint256 amount, bytes32 voucherId);

    error MintExceedsPledge(bytes32 pledgeId);
    error InvalidVoucher(bytes32 voucherId);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address authority_,
        address pledgeRegistry_,
        address reserveGuard_
    ) PermissionedTokenBase(name_, symbol_, decimals_, authority_) {
        pledgeRegistry = IPledgeRegistry(pledgeRegistry_);
        reserveGuard = IReserveGuard(reserveGuard_);
    }

    function setReleaseAuthorizer(address releaseAuthorizer_) external restricted {
        releaseAuthorizer = IReleaseAuthorizer(releaseAuthorizer_);
        emit ReleaseAuthorizerSet(releaseAuthorizer_);
    }

    function mintForPledge(address to, bytes32 pledgeId, uint256 amount) external restricted {
        if (!pledgeRegistry.canMint(pledgeId, amount)) revert MintExceedsPledge(pledgeId);
        reserveGuard.validateMint(address(this), totalSupply() + amount);
        _mint(to, amount);
        pledgeRegistry.recordMint(pledgeId, amount);
        emit MintedForPledge(to, pledgeId, amount);
    }

    function burnForRelease(address from, bytes32 pledgeId, uint256 amount, bytes32 voucherId) external restricted {
        if (address(releaseAuthorizer) != address(0) && !releaseAuthorizer.isVoucherValid(voucherId)) {
            revert InvalidVoucher(voucherId);
        }
        _burn(from, amount);
        pledgeRegistry.recordBurn(pledgeId, amount);
        emit BurnedForRelease(from, pledgeId, amount, voucherId);
    }
}
