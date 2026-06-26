// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TrioraAccountToken
/// @notice Minimal custody-backed accounting token for Triora v1.
contract TrioraAccountToken is ERC20, Ownable {
    uint8 private immutable _decimalsValue;

    address public immutable issuer;
    address public engine;

    event EngineSet(address indexed engine);
    event Minted(address indexed to, uint256 amount, bytes32 indexed evidenceRef);
    event BurnedLocked(uint256 amount, bytes32 indexed reasonRef);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroReference();
    error OnlyIssuer(address caller);
    error OnlyEngine(address caller);
    error EngineAlreadySet(address engine);
    error TransferRestricted(address from, address to);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address issuer_, address owner_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        if (issuer_ == address(0)) revert ZeroAddress();
        issuer = issuer_;
        _decimalsValue = decimals_;
    }

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert OnlyIssuer(msg.sender);
        _;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine(msg.sender);
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function setEngine(address engine_) external onlyOwner {
        if (engine_ == address(0)) revert ZeroAddress();
        if (engine != address(0)) revert EngineAlreadySet(engine);
        engine = engine_;
        emit EngineSet(engine_);
    }

    function mint(address to, uint256 amount, bytes32 evidenceRef) external onlyIssuer {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (evidenceRef == bytes32(0)) revert ZeroReference();
        _mint(to, amount);
        emit Minted(to, amount, evidenceRef);
    }

    function burnLocked(uint256 amount, bytes32 reasonRef) external onlyEngine {
        if (amount == 0) revert ZeroAmount();
        if (reasonRef == bytes32(0)) revert ZeroReference();
        _burn(msg.sender, amount);
        emit BurnedLocked(amount, reasonRef);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != engine && to != engine) {
            revert TransferRestricted(from, to);
        }
        super._update(from, to, value);
    }
}
