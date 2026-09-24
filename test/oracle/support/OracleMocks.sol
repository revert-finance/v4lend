// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @dev Chainlink-compatible feed whose every round field and its `decimals()` can be changed by the test.
///      Fresh by default: `latestRoundData` reports the current block time unless an explicit
///      `updatedAt` was set.
contract MutableChainlinkFeed {
    int256 public answer;
    uint8 public decimals;
    uint80 public roundId = 1;
    uint256 public startedAtOverride;
    uint256 public updatedAtOverride;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }

    /// @dev Pins the round timestamps; 0 restores "always fresh".
    function setRoundTimes(uint256 _startedAt, uint256 _updatedAt) external {
        startedAtOverride = _startedAt;
        updatedAtOverride = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 startedAt = startedAtOverride == 0 ? block.timestamp : startedAtOverride;
        uint256 updatedAt = updatedAtOverride == 0 ? block.timestamp : updatedAtOverride;
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @dev Token metadata stub whose `decimals()` can be changed after deployment, standing in for an
///      upgradeable token whose implementation changes its metadata. The oracle only reads `decimals()`.
contract MutableDecimalsToken {
    uint8 public decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }
}
