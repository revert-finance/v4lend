// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IV4Oracle} from "../../src/interfaces/IV4Oracle.sol";

/// @title MockV4Oracle
/// @notice Mock implementation of V4Oracle that returns current pool price for getPoolSqrtPriceX96
/// @dev Other IV4Oracle methods are stubbed and return zero/default values
contract MockV4Oracle is IV4Oracle {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    // Mapping from (token0, token1) to PoolKey for price lookup
    mapping(address => mapping(address => PoolKey)) public poolKeys;

    /// @notice Constructor
    /// @param _positionManager The PositionManager instance
    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
    }

    /// @notice Sets the pool key for a token pair
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param poolKey The pool key to use for price lookup
    function setPoolKey(address token0, address token1, PoolKey memory poolKey) external {
        poolKeys[token0][token1] = poolKey;
    }

    /// @notice Gets the current pool price in X96 format
    /// @dev Returns the current sqrtPriceX96^2 / Q96 from the pool
    ///      Price is always returned as token0/token1 (price of token0 in terms of token1)
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @return sqrtPriceX96 Current pool sqrt price in X96 format (token0/token1)
    function getPoolSqrtPriceX96(address token0, address token1) external view returns (uint160 sqrtPriceX96) {
        if (token0 == token1) {
            return uint160(FixedPoint96.Q96); // Price of 1:1
        }
        PoolKey memory poolKey = poolKeys[token0][token1];
        PoolId poolId = poolKey.toId();
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    /// @notice Stub implementation - returns zero values
    function getValue(uint256, address) external pure returns (uint256 value, uint256 feeValue, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    /// @notice Stub implementation - returns zero/default values
    function getPositionBreakdown(uint256)
        external
        pure
        returns (Currency currency0, Currency currency1, uint24 fee, uint128 liquidity, uint256 amount0, uint256 amount1, uint128 fees0, uint128 fees1)
    {
        return (Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, 0, 0, 0, 0);
    }

    /// @notice Stub implementation - returns zero values
    function getLiquidityAndFees(uint256) external pure returns (uint128 liquidity, uint128 fees0, uint128 fees1) {
        return (0, 0, 0);
    }
}
