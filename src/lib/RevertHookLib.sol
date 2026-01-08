// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {RevertHookState} from "../RevertHookState.sol";

/// @title RevertHookLib
/// @notice Library containing helper functions for RevertHook operations
library RevertHookLib {
    using PoolIdLibrary for PoolKey;

    uint128 internal constant Q64 = 2 ** 64;

    function getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function getTick(IPoolManager poolManager, PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    function applyBalanceDelta(BalanceDelta balanceDelta, uint256 amount0, uint256 amount1) internal pure returns (uint256, uint256) {
        int128 delta0 = balanceDelta.amount0();
        int128 delta1 = balanceDelta.amount1();
        return (
            delta0 < 0 ? amount0 - uint256(int256(-delta0)) : amount0 + uint256(int256(delta0)),
            delta1 < 0 ? amount1 - uint256(int256(-delta1)) : amount1 + uint256(int256(delta1))
        );
    }

    function calculateLiquidityForAmounts(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function calculateSqrtPriceLimitX96(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 multiplier
    ) internal view returns (uint160) {
        if (multiplier == 0) {
            return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        uint160 sqrtPriceLimitX96 = uint160(FullMath.mulDiv(currentSqrtPriceX96, multiplier, Q64));

        if (zeroForOne && sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
            return TickMath.MIN_SQRT_PRICE + 1;
        }
        if (!zeroForOne && sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            return TickMath.MAX_SQRT_PRICE - 1;
        }
        return sqrtPriceLimitX96;
    }

    function buildIncreaseLiquidityParams(
        uint256 tokenId,
        uint128 liquidity,
        Currency currency0,
        Currency currency1,
        address caller
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(currency0, currency1, caller);
    }

    function buildDecreaseLiquidityParams(
        uint256 tokenId,
        uint128 liquidity,
        Currency currency0,
        Currency currency1,
        bool onlyFees,
        address caller
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(
            onlyFees ? uint8(Actions.INCREASE_LIQUIDITY) : uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            liquidity,
            onlyFees ? type(uint128).max : 0,
            onlyFees ? type(uint128).max : 0,
            bytes("")
        );
        params[1] = abi.encode(currency0, currency1, caller);
    }

    function buildMintPositionParams(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 available0,
        uint128 available1,
        address recipient,
        address caller
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, available0, available1, recipient, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, caller);
    }
}
