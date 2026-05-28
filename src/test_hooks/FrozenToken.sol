// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only ERC-20 that lets us flip its `transfer` to revert
///         (simulating an issuer-side freeze, F12). Standard otherwise —
///         passes the admission transfer-exactness tests.
contract FrozenToken is ERC20 {
    bool public frozen;
    address public immutable freezer;

    constructor(string memory n, string memory s) ERC20(n, s) {
        freezer = msg.sender;
    }

    function setFrozen(bool f) external {
        require(msg.sender == freezer, "only freezer");
        frozen = f;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (frozen && from != address(0)) {
            revert("FROZEN");
        }
        super._update(from, to, amount);
    }
}
