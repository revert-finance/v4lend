// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

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
///      upgradeable token whose implementation changes its metadata. The oracle reads `decimals()` and, at
///      configuration, `totalSupply()` (the v4 settlement bound, V4LE-156): no supply is minted here.
contract MutableDecimalsToken {
    uint8 public decimals;
    uint256 public constant totalSupply = 0;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }
}

/// @dev Pool hook stand-in that is also its own `IPositionFeeQuoter`: it reports a configurable carried
///      obligation for every position and does nothing in its pool callback. Deploy it with `deployCodeTo`
///      at an address carrying `Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG`, the only callback it implements.
contract ObligationQuoterHook {
    uint256 public owed0;
    uint256 public owed1;

    function setObligation(uint256 _owed0, uint256 _owed1) external {
        owed0 = _owed0;
        owed1 = _owed1;
    }

    function hook() external view returns (address) {
        return address(this);
    }

    function quoteProtocolFees(uint256, uint128, uint128) external view returns (uint256, uint256) {
        return (owed0, owed1);
    }

    function validateVaultPosition(uint256, address) external pure {}

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }
}
