// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Minimal Chainlink AggregatorV3 mock returning a fixed wstETH/stETH price.
/// @dev Deploy on OP Sepolia where a real Chainlink feed may not exist.
contract MockAggregator {
    int256 public immutable PRICE;
    uint8 public constant decimals = 18;

    constructor(int256 price) {
        PRICE = price;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, PRICE, block.timestamp, block.timestamp, 1);
    }

    function description() external pure returns (string memory) {
        return "MockAggregator wstETH/stETH";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, PRICE, block.timestamp, block.timestamp, 1);
    }
}
