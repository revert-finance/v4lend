// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "src/oracle/V4Oracle.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private immutable feedDecimals;
    int256 private answer;
    uint80 private roundId;
    uint256 private updatedAt;

    constructor(uint8 decimals_, int256 initialAnswer) {
        feedDecimals = decimals_;
        setAnswer(initialAnswer);
    }

    function setAnswer(int256 newAnswer) public {
        answer = newAnswer;
        unchecked {
            ++roundId;
        }
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
