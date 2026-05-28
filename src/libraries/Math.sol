// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MathLib — basis-point and decimal-normalising helpers.
/// @notice All token amounts in the protocol are wei. USD valuations
///         are 1e18-scaled. Chainlink prices ship in 1e8 (or whatever
///         `decimals()` reports). The helpers below stick to mulDiv
///         rounding-down for accounting (favours the protocol), and
///         rounding-up for liquidation-bound checks (errs against the
///         protocol — i.e., conservative).
library MathLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant USD_SCALE = 1e18;

    error PrecisionOverflow();
    error DivideByZero();

    function bps(uint256 amount, uint256 rateBps) internal pure returns (uint256) {
        return (amount * rateBps) / BPS;
    }

    /// @dev floor((a * b) / c). Reverts on c == 0.
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if (c == 0) revert DivideByZero();
        return (a * b) / c;
    }

    /// @dev ceil((a * b) / c).
    function mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if (c == 0) revert DivideByZero();
        return (a * b + c - 1) / c;
    }

    /// @dev Convert a token amount (in its own decimals) to a USD value
    ///      scaled to 1e18. `priceScale` = 10**(price decimals).
    function tokenToUsd(uint256 amount, uint256 price, uint8 tokenDecimals, uint8 priceDecimals)
        internal
        pure
        returns (uint256)
    {
        // value = amount * price / 10**tokenDecimals (in price-decimal units)
        // → re-scale to 1e18
        uint256 priceScale = 10 ** priceDecimals;
        uint256 tokenScale = 10 ** tokenDecimals;
        // value_in_priceDecimals = amount * price / tokenScale
        // value_in_1e18 = value_in_priceDecimals * 1e18 / priceScale
        return (amount * price * USD_SCALE) / (tokenScale * priceScale);
    }

    /// @dev Convert a USD value (1e18 scale) to a token amount in its own decimals.
    function usdToToken(uint256 usd, uint256 price, uint8 tokenDecimals, uint8 priceDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 priceScale = 10 ** priceDecimals;
        uint256 tokenScale = 10 ** tokenDecimals;
        // amount = usd * tokenScale * priceScale / (1e18 * price)
        return (usd * tokenScale * priceScale) / (USD_SCALE * price);
    }
}
