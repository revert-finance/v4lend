// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {RevertHookLookupBase} from "./RevertHookLookupBase.sol";

/// @title RevertHookSwapActions
/// @notice Delegatecall helper for hook-managed swaps and swap-fee settlement
contract RevertHookSwapActions is RevertHookLookupBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPositionManager internal immutable positionManager;
    IPoolManager internal immutable poolManager;
    IHookFeeController internal immutable hookFeeController;

    constructor(IV4Oracle _v4Oracle, IHookFeeController _hookFeeController) {
        positionManager = _v4Oracle.positionManager();
        poolManager = _v4Oracle.poolManager();
        hookFeeController = _hookFeeController;
    }

    function _positionManagerRef() internal view override returns (IPositionManager) {
        return positionManager;
    }

    function _poolManagerRef() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function executeSwap(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn, uint256 tokenId, Mode mode)
        external
        returns (BalanceDelta delta)
    {
        GeneralConfig storage config = _generalConfigs[tokenId];
        uint128 priceMultiplier = zeroForOne ? config.sqrtPriceMultiplier0 : config.sqrtPriceMultiplier1;

        uint160 sqrtPriceLimitX96;
        if (priceMultiplier == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
            sqrtPriceLimitX96 = uint160(FullMath.mulDiv(currentSqrtPriceX96, priceMultiplier, Q64));
            if (zeroForOne && sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
            }
            if (!zeroForOne && sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
            }
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        try poolManager.swap(poolKey, params, "") returns (BalanceDelta result) {
            delta = _settleSwapDeltas(poolKey, result, tokenId, mode);
            uint256 actualSwapped = uint256(int256(-(zeroForOne ? result.amount0() : result.amount1())));
            if (actualSwapped < amountIn) {
                emit HookSwapPartial(tokenId, zeroForOne, amountIn, actualSwapped);
            }
        } catch (bytes memory reason) {
            emit HookSwapFailed(poolKey, params, reason);
        }
    }

    function _settleSwapDeltas(PoolKey memory poolKey, BalanceDelta delta, uint256 tokenId, Mode mode)
        internal
        returns (BalanceDelta adjustedDelta)
    {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        uint16 feeBps = hookFeeController.swapFeeBps(poolKey.toId(), uint8(mode));
        address protocolFeeRecipient = hookFeeController.protocolFeeRecipient();

        uint256 protocolFee0;
        uint256 protocolFee1;

        if (delta0 < 0) {
            _settleCurrencyDelta(poolKey.currency0, delta0);
        } else if (delta0 > 0) {
            uint256 amount0 = uint256(int256(delta0));
            protocolFee0 = amount0 * feeBps / 10000;
            uint256 netAmount0 = amount0 - protocolFee0;
            if (netAmount0 > 0) {
                poolManager.take(poolKey.currency0, address(this), netAmount0);
            }
            if (protocolFee0 > 0) {
                poolManager.take(poolKey.currency0, protocolFeeRecipient, protocolFee0);
                // forge-lint: disable-next-line(unsafe-typecast)
                delta0 = int128(int256(netAmount0));
            }
        }

        if (delta1 < 0) {
            _settleCurrencyDelta(poolKey.currency1, delta1);
        } else if (delta1 > 0) {
            uint256 amount1 = uint256(int256(delta1));
            protocolFee1 = amount1 * feeBps / 10000;
            uint256 netAmount1 = amount1 - protocolFee1;
            if (netAmount1 > 0) {
                poolManager.take(poolKey.currency1, address(this), netAmount1);
            }
            if (protocolFee1 > 0) {
                poolManager.take(poolKey.currency1, protocolFeeRecipient, protocolFee1);
                // forge-lint: disable-next-line(unsafe-typecast)
                delta1 = int128(int256(netAmount1));
            }
        }

        if (protocolFee0 > 0 || protocolFee1 > 0) {
            emit SendProtocolFee(tokenId, poolKey.currency0, poolKey.currency1, protocolFee0, protocolFee1, protocolFeeRecipient);
        }

        adjustedDelta = toBalanceDelta(delta0, delta1);
    }

    function _settleCurrencyDelta(Currency currency, int256 delta) internal {
        if (delta < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-delta);
            poolManager.sync(currency);
            if (currency.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                currency.transfer(address(poolManager), amount);
                poolManager.settle();
            }
        } else if (delta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(currency, address(this), uint256(delta));
        }
    }
}
