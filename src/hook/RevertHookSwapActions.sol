// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {RevertHookState} from "./RevertHookState.sol";

/// @title RevertHookSwapActions
/// @notice Delegatecall helper for hook-managed swaps and swap-fee settlement
contract RevertHookSwapActions is RevertHookState {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable poolManager;
    IHookFeeController internal immutable hookFeeController;
    /// @dev This contract's own address: the state-mutating entries below run under delegatecall
    ///      from the hook (address(this) is then the hook) and refuse a direct call, like the other
    ///      sidecars. A direct call would run against this contract's own storage and balance with a
    ///      caller-chosen PositionManager and emit spoofable events from this address.
    address private immutable _selfAddress;

    constructor(IPoolManager _poolManager, IHookFeeController _hookFeeController) {
        poolManager = _poolManager;
        hookFeeController = _hookFeeController;
        _selfAddress = address(this);
    }

    /// @dev Shared delegatecall encoder, including fee-first removals and native sweeps.
    ///      Delegatecall-only: a direct call is rejected.
    function modifyLiquiditiesWithPair(
        IPositionManager positionManager, bytes memory actions, bytes memory primaryParams,
        Currency currency0, Currency currency1, uint256 nativeValue
    ) external payable returns (bool success) {
        if (address(this) == _selfAddress) {
            revert Unauthorized();
        }
        bool removing = uint8(actions[0]) == uint8(Actions.DECREASE_LIQUIDITY);
        uint256 offset = removing ? 1 : 0;
        bytes memory actionsWithSweep = removing ? abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), actions) : actions;
        bytes[] memory params = new bytes[](offset + (nativeValue == 0 ? 2 : 3));
        if (removing) {
            uint256 tokenId = abi.decode(primaryParams, (uint256));
            params[0] = abi.encode(tokenId, 0, type(uint128).max, type(uint128).max, bytes(""));
        }
        params[offset] = primaryParams;
        params[offset + 1] = abi.encode(currency0, currency1, address(this));
        if (nativeValue > 0) {
            actionsWithSweep = abi.encodePacked(actionsWithSweep, uint8(Actions.SWEEP));
            params[offset + 2] = abi.encode(address(0), address(this));
        }

        try positionManager.modifyLiquiditiesWithoutUnlock{value: nativeValue}(actionsWithSweep, params) {
            return true;
        } catch (bytes memory reason) {
            emit HookModifyLiquiditiesFailed(actionsWithSweep, params, reason);
            return false;
        }
    }
    /// @notice Plans an exact-input swap through a configured external route for a liquidity action
    /// @dev Plain view (staticcalled by the action sidecars, which have no bytecode room for it):
    ///      hands the planner the route pool (price, liquidity and fee are read there and its
    ///      ticks walked) and the hook's own per-mode output fee (`swapFeeBps`, taken from the
    ///      swap output in _settleSwapDeltas), so the swap is sized against the route's real
    ///      depth and the net output that will actually fund the mint (V4LE-53, V4LE-21).
    /// @param calculator The planner
    /// @param positionSqrtPriceX96 Position pool price, fixing the ratio the range needs
    /// @param swapPool The route pool
    /// @param mode Action mode, selecting the hook swap fee
    function planExternalRoute(
        ILiquidityCalculator calculator,
        uint160 positionSqrtPriceX96,
        PoolKey memory swapPool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        Mode mode,
        bool samePool
    ) external view returns (uint256 amountIn, bool zeroForOne) {
        PoolId swapPoolId = swapPool.toId();
        if (samePool) {
            ILiquidityCalculator.V4PoolInfo memory pool =
                ILiquidityCalculator.V4PoolInfo(poolManager, swapPoolId, swapPool.tickSpacing);
            uint24 outputFeePips = uint24(hookFeeController.swapFeeBps(swapPoolId, uint8(mode))) * 100;
            if (outputFeePips == 0) {
                (amountIn,, zeroForOne,) = calculator.calculateSamePool(pool, tickLower, tickUpper, amount0, amount1);
            } else {
                (amountIn,, zeroForOne,) =
                    calculator.calculateSamePool(pool, tickLower, tickUpper, amount0, amount1, outputFeePips);
            }
            return (amountIn, zeroForOne);
        }
        (amountIn,, zeroForOne) = calculator.calculateSimple(
            positionSqrtPriceX96,
            ILiquidityCalculator.V4PoolInfo({
                poolMgr: poolManager, poolIdentifier: swapPoolId, tickSpacing: swapPool.tickSpacing
            }),
            tickLower,
            tickUpper,
            amount0,
            amount1,
            uint24(hookFeeController.swapFeeBps(swapPoolId, uint8(mode))) * 100
        );
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
        if (address(this) == _selfAddress) {
            revert Unauthorized();
        }
        SwapProtectionConfig storage config = _swapProtectionConfigs[tokenId];
        uint128 priceMultiplier = zeroForOne ? config.sqrtPriceMultiplier0 : config.sqrtPriceMultiplier1;

        uint160 sqrtPriceLimitX96;
        if (priceMultiplier == 0) {
            // @custom:accepted-risk AUDIT-ACCEPTED-HOOK-SWAP-NO-SLIPPAGE-FLOOR
            // No configured multiplier means no additional price limit: the swap runs to whatever
            // price the pool gives. What bounds it instead is the requirement that the pool price
            // is inside the oracle window at the moment the action starts, enforced for every
            // entry point:
            //   - trigger-driven actions (AUTO_RANGE / AUTO_EXIT / AUTO_LEVERAGE / AUTO_LEND) run
            //     only from _afterSwap, which dispatches nothing while the live tick is outside
            //     [oracleTick - _maxTicksFromOracle, oracleTick + _maxTicksFromOracle], re-checks
            //     after every executed action and requeues the rest of a tick when an action's own
            //     swap leaves the window; a swap that overshoots leaves the triggers armed for a
            //     later swap that ends inside it, and registration is refused while the cursor lags
            //     so no trigger can land where the resumed walk would miss it (M-03);
            //   - the hook's own action entry points are reachable from a vault only during a
            //     transform the hook itself started (RevertHookActionBase._requireAuthorization), so
            //     a borrower cannot fire them at an arbitrary price (C-01);
            //   - AUTO_COLLECT arms no trigger and is invoked through the permissionless
            //     `autoCollect`, so `_executeSwapResolved` price-checks its swaps explicitly;
            //   - a configured external route is price-checked immediately before its swap.
            //
            // Accepted with the following assumptions (deployed values, see script/Deploy*.s.sol):
            //   - _maxTicksFromOracle = 100 ticks, so an action starts while the pool price is
            //     within ~1.0% of the oracle price (1.0001^100);
            //   - V4Oracle.maxPoolPriceDifference = 200 bps, so a manipulation that leaves the pool
            //     more than 2% from the oracle makes position valuation revert and value-gated
            //     actions abort instead of swapping;
            //   - action swap sizes are small next to pool depth: collected fees (AUTO_COLLECT), one
            //     position's rebalance delta (AUTO_RANGE), or one leverage/exit step.
            // Worst case per action: an attacker moves the pool to the far edge of the oracle window
            // to force the trigger, so the swap starts up to ~1% away from the oracle price and
            // additionally pays its own impact against the remaining liquidity, which nothing here
            // bounds. Extractable value is therefore on the order of (1% + own impact) x swap size,
            // and is only profitable when that exceeds the attacker's round trip - the pool fee twice
            // on the size needed to reach the window edge, plus their own impact and the risk of an
            // unrelated swap landing between the two legs. It does not compound across actions: the
            // window is re-established for every one.
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
