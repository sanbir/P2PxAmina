// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {PermissionedTokenBase} from "./PermissionedTokenBase.sol";

/// @title ReserveToken -- restricted cUSDC ERC-20 balance for reserved BitGo liquidity.
contract ReserveToken is PermissionedTokenBase {
    address public reserveRegistry;
    IReserveGuard public immutable reserveGuard;

    event ReserveRegistrySet(address indexed reserveRegistry);
    event MintedForReserve(address indexed to, bytes32 indexed reserveId, uint256 amount);
    event BurnedFromProtocol(address indexed from, uint256 amount);

    error OnlyReserveRegistry();

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address authority_,
        address reserveGuard_
    ) PermissionedTokenBase(name_, symbol_, decimals_, authority_) {
        reserveGuard = IReserveGuard(reserveGuard_);
    }

    function setReserveRegistry(address reserveRegistry_) external restricted {
        reserveRegistry = reserveRegistry_;
        emit ReserveRegistrySet(reserveRegistry_);
    }

    function mintForReserve(address to, bytes32 reserveId, uint256 amount) external {
        if (msg.sender != reserveRegistry) revert OnlyReserveRegistry();
        reserveGuard.validateMint(address(this), totalSupply() + amount);
        _mint(to, amount);
        emit MintedForReserve(to, reserveId, amount);
    }

    function burnFromProtocol(address from, uint256 amount) external restricted {
        _burn(from, amount);
        emit BurnedFromProtocol(from, amount);
    }
}
