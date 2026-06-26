// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Errors} from "../libraries/Errors.sol";

/// @title PermissionedTokenBase -- restricted ERC-20 base for Triora accounting tokens.
abstract contract PermissionedTokenBase is ERC20, AccessManaged {
    uint8 private immutable _decimals;

    bool public paused;
    mapping(address account => bool) public protocol;
    mapping(address account => bool) public frozen;

    event ProtocolSet(address indexed account, bool allowed);
    event FrozenSet(address indexed account, bool frozen);
    event PausedSet(bool paused);

    error TransferRestricted(address from, address to);
    error AccountFrozen(address account);
    error TokenPaused();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address authority_)
        ERC20(name_, symbol_)
        AccessManaged(authority_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setProtocol(address account, bool allowed) external restricted {
        if (account == address(0)) revert Errors.ZeroAddress();
        protocol[account] = allowed;
        emit ProtocolSet(account, allowed);
    }

    function setFrozen(address account, bool frozen_) external restricted {
        frozen[account] = frozen_;
        emit FrozenSet(account, frozen_);
    }

    function setPaused(bool paused_) external restricted {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function isTransferAllowed(address from, address to) public view returns (bool) {
        if (from == address(0) || to == address(0)) return true;
        return protocol[from] || protocol[to];
    }

    function protocolBurn(address from, uint256 amount) external restricted {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (paused) revert TokenPaused();
        if (from != address(0) && frozen[from]) revert AccountFrozen(from);
        if (to != address(0) && frozen[to]) revert AccountFrozen(to);
        if (!isTransferAllowed(from, to)) revert TransferRestricted(from, to);
        super._update(from, to, amount);
    }
}
