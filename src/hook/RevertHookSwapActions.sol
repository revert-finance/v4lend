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

import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {RevertHookState} from "./RevertHookState.sol";

/// @title RevertHookSwapActions
/// @notice Delegatecall helper for hook-managed swaps and swap-fee settlement
contract RevertHookSwapActions is RevertHookState {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable poolManager;
    IHookFeeController internal immutable hookFeeController;

    constructor(IPoolManager _poolManager, IHookFeeController _hookFeeController) {
        poolManager = _poolManager;
        hookFeeController = _hookFeeController;
    }

    /// @dev Hook-managed swaps may execute in the position pool or through a configured external route.
    /// RevertHookActionBase validates an external execution pool against the oracle immediately before
    /// delegatecalling this helper. Same-pool triggered actions inherit the traversal oracle window.
    /// Within those bounds there is no amountOutMin floor by default (unlike the standalone automators'
    /// _routerSwapWithSlippageCheck), though owners can configure a tighter per-swap price bound.
    /// The assumptions and worst case behind that decision are stated at the accepted-risk marker below.
    function executeSwap(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn, uint256 tokenId, Mode mode)
        external
        returns (BalanceDelta delta)
    {
        SwapProtectionConfig storage config = _swapProtectionConfigs[tokenId];
        uint128 priceMultiplier = zeroForOne ? config.sqrtPriceMultiplier0 : config.sqrtPriceMultiplier1;

        uint160 sqrtPriceLimitX96;
        if (priceMultiplier == 0) {
            // @custom:accepted-risk AUDIT-ACCEPTED-HOOK-SWAP-NO-SLIPPAGE-FLOOR
            // No configured multiplier means no additional price limit. External pools are oracle-
            // checked immediately before this call, while same-pool triggered actions inherit the
            // traversal oracle window; a tighter position-specific floor is optional.
            //
            // Accepted with the following assumptions (deployed values, see script/Deploy*.s.sol):
            //   - _maxTicksFromOracle = 100 ticks, so a trigger is only processed while the pool
            //     price is within ~1.0% of the oracle price (1.0001^100), and a configured external
            //     route is re-checked against the same bound immediately before its swap;
            //   - V4Oracle.maxPoolPriceDifference = 200 bps, so a manipulation that leaves the pool
            //     more than 2% from the oracle makes position valuation revert and the action aborts
            //     instead of swapping;
            //   - action swap sizes are small next to pool depth: collected fees (AUTO_COLLECT), one
            //     position's rebalance delta (AUTO_RANGE), or one leverage/exit step.
            // Worst case per action: an attacker moves the pool to the far edge of the oracle window
            // to force the trigger, so the swap starts up to ~1% away from the oracle price and
            // additionally pays its own impact against the remaining liquidity, which nothing here
            // bounds. Extractable value is therefore on the order of (1% + own impact) x swap size,
            // and is only profitable when that exceeds the attacker's round trip - the pool fee twice
            // on the size needed to reach the window edge, plus their own impact and the risk of an
            // unrelated swap landing between the two legs. It does not compound across actions: the
            // window is re-established for every one, and the 2% oracle guard caps how far the pool
            // can be pushed before automation stops entirely.
            //
            // Where the window comes from differs by entry point, and both are covered:
            //   - trigger-driven actions (AUTO_RANGE / AUTO_EXIT / AUTO_LEVERAGE / AUTO_LEND) only
            //     run inside _afterSwap, whose traversal is already clamped to the oracle window;
            //   - AUTO_COLLECT arms no trigger and is invoked through the permissionless
            //     `autoCollect`, so traversal never bounds it; `_executeSwapResolved` price-checks
            //     its swaps explicitly instead (same bound, applied immediately before the swap).
            // Levers that tighten this without a code change: per-position setSwapProtectionConfig
            // (a real price limit for that position), a lower owner-set setMaxTicksFromOracle, and
            // HookRouteController routes pointing actions at deeper pools.
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
            // @custom:accepted-risk AUDIT-ACCEPTED-HOOK-SWAP-FAIL-OPEN
            // Hook-managed swaps fail open and return zero delta; later balance checks
            // and events are the intended recovery surface.
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
            emit SendProtocolFee(
                tokenId, poolKey.currency0, poolKey.currency1, protocolFee0, protocolFee1, protocolFeeRecipient
            );
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
