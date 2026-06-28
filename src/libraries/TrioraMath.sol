// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TrioraMath
/// @notice Fixed-point + decimal-scaling helpers used across valuation, interest, and reserve math.
/// @dev BPS = basis points (1e4). Conventions: cBTC has 8 decimals, USDC 6, Chainlink USD feeds 8.
library TrioraMath {
    uint256 internal constant BPS = 10000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice mulDiv with rounding down (conservative for limits/valuation).
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(a, b, d);
    }

    /// @notice Scale `amount` from `fromDecimals` to `toDecimals` (rounds down).
    function scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        }
        return amount * (10 ** (toDecimals - fromDecimals));
    }

    /// @notice Linear (non-compounding) interest: principal * rateBps * elapsed / (BPS * year).
    function linearInterest(uint256 principal, uint32 rateBps, uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(principal * rateBps, elapsed, BPS * SECONDS_PER_YEAR);
    }

    /// @notice USD value (1e8) of a token amount given a Chainlink USD price (1e8) and token decimals.
    /// @return value scaled to 1e8 (i.e. USD with 8 decimals).
    function usdValue(uint256 amount, uint8 tokenDecimals, uint256 price1e8) internal pure returns (uint256) {
        // value = amount/10^dec * price1e8  →  keep 1e8 scale
        return Math.mulDiv(amount, price1e8, 10 ** tokenDecimals);
    }
}
