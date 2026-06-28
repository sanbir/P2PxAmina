// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {TrioraMath} from "../libraries/TrioraMath.sol";
import {IReserveSource, IOracleAdapter} from "../interfaces/ITriora.sol";

/// @title OracleAdapter
/// @notice Chainlink BTC/USD price read with staleness/decimal guards + a PEG CAP so cBTC can never
///         be valued above its attested backing (Tech Spec S5). Drives valuation + the liquidation trigger.
/// @dev Price is a USD price (1e8). Reserve source is a QUANTITY feed (cBTC units) — kept separate from price.
contract OracleAdapter is IOracleAdapter, TrioraAccess {
    AggregatorV3Interface public priceFeed;
    uint64 public heartbeat;
    address public collateralToken;
    IReserveSource public reserveSource;

    event FeedSet(address feed, uint64 heartbeat);

    constructor(address roleManager_, address collateralToken_, address reserveSource_) TrioraAccess(roleManager_) {
        if (collateralToken_ == address(0) || reserveSource_ == address(0)) revert Errors.ZeroAddress();
        collateralToken = collateralToken_;
        reserveSource = IReserveSource(reserveSource_);
    }

    function setFeed(address feed, uint64 heartbeat_) external restricted(Roles.ORACLE_ADMIN) {
        if (feed == address(0) || heartbeat_ == 0) revert Errors.BadConfig();
        priceFeed = AggregatorV3Interface(feed);
        heartbeat = heartbeat_;
        emit FeedSet(feed, heartbeat_);
    }

    /// @inheritdoc IOracleAdapter
    function getPrice() public view returns (uint256 price1e8, bool fresh) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId || updatedAt == 0) revert Errors.BadPrice();
        uint8 d = priceFeed.decimals();
        price1e8 = d == 8 ? uint256(answer) : TrioraMath.scaleDecimals(uint256(answer), d, 8);
        fresh = block.timestamp <= updatedAt + heartbeat;
    }

    /// @notice Fresh price or revert (callers that compute health/origination require freshness).
    function requireFreshPrice() public view returns (uint256 price1e8) {
        bool fresh;
        (price1e8, fresh) = getPrice();
        if (!fresh) revert Errors.PriceStale();
    }

    /// @inheritdoc IOracleAdapter
    /// @dev value = amount * price, then capped by the global backing ratio (reserves/supply) so that
    ///      total collateral value can never exceed reserves*price even if reserves dip below supply.
    function collateralValueUsd(uint256 cbtcAmount) external view returns (uint256) {
        uint256 price = requireFreshPrice();
        uint256 value = TrioraMath.usdValue(cbtcAmount, 8, price); // 1e8 USD
        (uint256 reserves,, uint8 dec) = reserveSource.attestedReserves(collateralToken);
        uint256 reserves8 = TrioraMath.scaleDecimals(reserves, dec, 8);
        uint256 supply = IERC20(collateralToken).totalSupply();
        if (supply > 0 && reserves8 < supply) {
            value = TrioraMath.mulDiv(value, reserves8, supply); // backing-ratio peg cap
        }
        return value;
    }
}
