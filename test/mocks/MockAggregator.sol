// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal Chainlink price feed mock for tests.
contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable _decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;

    constructor(uint8 d, int256 initial, uint256 updatedAt_) {
        _decimals = d;
        answer = initial;
        updatedAt = updatedAt_;
    }

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
        roundId++;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MOCK/USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, answer, updatedAt, updatedAt, _roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
