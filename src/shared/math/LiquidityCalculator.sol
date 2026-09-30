// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.8;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ILiquidityCalculator
/// @notice Interface for LiquidityCalculator contract
interface ILiquidityCalculator {
    error Invalid_Pool();
    error Invalid_Tick_Range();
    error Invalid_Fee();
    error Math_Overflow();
    /// @notice The balancing swap crosses more initialized ticks of the pool than one quote walks
    ///         (LiquidityCalculator.MAX_ROUTE_QUOTE_CROSSINGS), so no exact plan can be sized
    error Quote_Truncated();

    /// @notice Pool configuration struct containing pool manager, pool ID, and tick spacing
    struct V4PoolInfo {
        IPoolManager poolMgr;
        PoolId poolIdentifier;
        int24 tickSpacing;
    }

    /// @notice Which side of a range position is in surplus at a price: true when token0 must be swapped
    ///         into token1, false the other way. The comparison the planners use, exposed so integrators
    ///         (the hook's route selection) do not carry a copy of it (Scan #2 V4LE-145 / V4LE-146).
    function swapDirection(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        pure
        returns (bool zeroForOne);

    /// @notice Calculate optimal swap amount for double-sided liquidity deposit (external route version)
    /// @dev The swap executes in another v4 pool than the position pool: the position pool's price
    ///      fixes the ratio the range needs, the route pool's price and active liquidity price the
    ///      swap. The route is modelled as constant-liquidity AMM from its current sqrt price (no
    ///      tick crossing), so the quote includes the swap's own price impact against the route's
    ///      depth instead of assuming an infinitely deep pool at spot (V4LE-53). Liquidity that
    ///      changes at the first crossed tick is not modelled: exact until then, then a bound
    ///      that is conservative if depth thins out and optimistic if it thickens.
    /// @param positionSqrtPrice Current sqrt price of the position pool, used
    ///        to determine the ratio required by its tick range
    /// @param swapSqrtPrice Current sqrt price of the external route pool
    /// @param swapLiquidity Active liquidity of the external route pool at that price; zero
    ///        means nothing can be bought and no swap is planned
    /// @param lowerTick Lower bound of the position
    /// @param upperTick Upper bound of the position
    /// @param amount0 Desired amount of token0
    /// @param amount1 Desired amount of token1
    /// @param feeRate Route pool fee taken from the input, in hundredths of a bip (3000 = 0.3%)
    /// @param outputFeePips Fee the caller takes from the swap output before minting (the hook's
    ///        per-mode swap fee), in hundredths of a bip; planned so the net output funds the mint
    /// @return inputAmount Optimal swap input amount
    /// @return outputAmount Expected net swap output amount (after both fees)
    /// @return swapDir0to1 Direction: true for token0->token1, false for token1->token0
    function calculateSimple(
        uint160 positionSqrtPrice,
        uint160 swapSqrtPrice,
        uint128 swapLiquidity,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 feeRate,
        uint24 outputFeePips
    ) external pure returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1);

    /// @notice External-route planner that reads the route pool and walks its ticks
    /// @dev Every candidate input is priced with an exact-input quote that walks the route's
    ///      initialized ticks (SwapMath step by step, liquidity updated at every crossing), so the
    ///      plan is sized against the route's real depth wherever its liquidity thickens or thins.
    ///      In range, the input is found by bisection on that quote (the balance condition is
    ///      monotone in the input); out of range the whole surplus side is swapped. A plan never
    ///      exceeds what the quote actually consumed: a route whose ticks or price bound stop the
    ///      swap early gets the consumed input, and an in-range balancing swap that would cross
    ///      more ticks than one quote walks (MAX_ROUTE_QUOTE_CROSSINGS) reverts Quote_Truncated
    ///      instead of returning an under-sized plan as if it balanced. A route with no active
    ///      liquidity at its price is walked to the first initialized tick ahead, as Pool.swap does.
    ///      The route's fee is read from its slot0 for the planned direction.
    /// @param positionSqrtPrice Current sqrt price of the position pool
    /// @param swapPool The external route pool
    /// @param lowerTick Lower bound of the position
    /// @param upperTick Upper bound of the position
    /// @param amount0 Desired amount of token0
    /// @param amount1 Desired amount of token1
    /// @param outputFeePips Fee the caller takes from the swap output before minting, in
    ///        hundredths of a bip
    /// @return inputAmount Optimal swap input amount
    /// @return outputAmount Expected net swap output amount (after both fees)
    /// @return swapDir0to1 Direction: true for token0->token1, false for token1->token0
    function calculateSimple(
        uint160 positionSqrtPrice,
        V4PoolInfo memory swapPool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 outputFeePips
    ) external view returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1);

    /// @notice Same-pool planner accounting for the caller's output fee and final pool price.
    function calculateSamePool(
        V4PoolInfo memory pool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 outputFeePips
    ) external view returns (uint256 inputAmount, uint256 outputAmount, bool zeroForOne, uint160 sqrtPrice);

    /// @notice Calculate optimal swap amount for double-sided liquidity deposit (same pool version)
    function calculateSamePool(
        V4PoolInfo memory pool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0Target,
        uint256 amount1Target
    ) external view returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1, uint160 sqrtPrice);
}

/// @title LiquidityCalculator
/// @notice Contract for calculating optimal swap amounts for double-sided liquidity deposits for Uniswap V4
/// @dev Uses analytic solutions to efficiently compute optimal swap parameters
contract LiquidityCalculator is ILiquidityCalculator {
    using FullMath for uint256;
    using UnsafeMath for uint256;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @notice Maximum fee in hundredths of a bip (1e6 = 100%)
    uint256 internal constant MAX_FEE_PIPS = 1e6;
    /// @dev Gas bound for a single next-tick search across the tick bitmap (one word = 256 tick spacings)
    uint256 internal constant MAX_BITMAP_WORDS_PER_SEARCH = 100;

    /// @notice Parameters for finding the next initialized tick in the tick bitmap
    struct NextInitializedTickParams {
        V4PoolInfo pool;
        int24 tickValue;
        int24 tickSpacing;
        bool swapDir0to1;
        int16 wordPosition;
        uint256 tickBitmap;
    }

    /// @notice Result of finding the next initialized tick
    struct NextInitializedTickResult {
        int24 nextTick;
        int16 wordPosition;
        uint256 tickBitmap;
    }

    /// @notice Parameters for crossing ticks during optimal swap calculation
    struct TraverseTicksParams {
        V4PoolInfo pool;
        SwapState state;
        uint160 sqrtPrice;
        bool swapDir0to1;
    }

    /// @notice State struct for tracking swap calculations
    /// @dev Uses fixed memory offsets for efficient assembly access
    struct SwapState {
        uint128 liquidity; // offset 0x00
        uint256 sqrtPrice; // offset 0x20
        int24 tickValue; // offset 0x40
        uint256 amount0Target; // offset 0x60
        uint256 amount1Target; // offset 0x80
        uint256 sqrtLower; // offset 0xa0
        uint256 sqrtUpper; // offset 0xc0
        uint256 feeRate; // offset 0xe0
        int24 tickSpacing; // offset 0x100
    }

    /// @notice Route pool state the external-route planner quotes against
    struct RouteQuote {
        uint160 sqrtPrice;
        uint128 liquidity;
        uint256 inputMultiplier; // MAX_FEE_PIPS - route fee
        uint256 outputMultiplier; // MAX_FEE_PIPS - caller's output fee
    }

    /// @dev Relative precision of the in-range bisection: stop once the bracket is below
    ///      2^-40 of the swappable amount (about 1e-12), which bounds the search at ~41 steps.
    uint256 internal constant ROUTE_SOLVE_PRECISION_SHIFT = 40;

    /// @dev Bound on the swap steps (initialized ticks crossed, plus the final partial step) one
    ///      tick-walking quote takes. A quote that stops here with input left is truncated: the
    ///      one-sided planners then size the plan to the consumed input, the in-range bisections
    ///      revert Quote_Truncated when the balance root lies beyond it (external audit V4LE-95,
    ///      V4LE-114). Gas (measured, see the V4LE-95/114/128 tests): the ticks are read from the
    ///      pool once per plan and cached (RouteState.ladder); each of the bisection's ~41 quotes
    ///      then costs ~2k per step in memory. A full-range or one-crossing route plans for
    ///      150k-520k, a plan crossing ~15 ticks for ~1M, and the worst case - every quote taking
    ///      all 64 steps before reverting Quote_Truncated - for ~6.1M.
    uint256 internal constant MAX_ROUTE_QUOTE_CROSSINGS = 64;

    /// @inheritdoc ILiquidityCalculator
    function calculateSimple(
        uint160 positionSqrtPrice,
        uint160 swapSqrtPrice,
        uint128 swapLiquidity,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 feeRate,
        uint24 outputFeePips
    ) external pure returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) {
        if (positionSqrtPrice == 0 || swapSqrtPrice == 0) revert Invalid_Pool();
        if (feeRate >= MAX_FEE_PIPS || outputFeePips >= MAX_FEE_PIPS) revert Invalid_Fee();
        RouteQuote memory route = RouteQuote({
            sqrtPrice: swapSqrtPrice,
            liquidity: swapLiquidity,
            inputMultiplier: MAX_FEE_PIPS - uint256(feeRate),
            outputMultiplier: MAX_FEE_PIPS - uint256(outputFeePips)
        });
        (inputAmount, outputAmount, swapDir0to1) =
            _planConstantLiquidity(route, positionSqrtPrice, lowerTick, upperTick, amount0, amount1);
    }

    /// @inheritdoc ILiquidityCalculator
    function calculateSimple(
        uint160 positionSqrtPrice,
        V4PoolInfo memory swapPool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 outputFeePips
    ) external view returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) {
        if (amount0 == 0 && amount1 == 0) return (0, 0, false);
        if (outputFeePips >= MAX_FEE_PIPS) revert Invalid_Fee();
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }
        RouteState memory route;
        route.pool = swapPool;
        uint24 packedProtocolFee;
        uint24 lpFee;
        (route.sqrtPrice, route.tick, packedProtocolFee, lpFee) = swapPool.poolMgr.getSlot0(swapPool.poolIdentifier);
        if (positionSqrtPrice == 0 || route.sqrtPrice == 0) revert Invalid_Pool();
        route.liquidity = swapPool.poolMgr.getLiquidity(swapPool.poolIdentifier);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upperTick);
        swapDir0to1 = _shouldSwap0to1(amount0, amount1, positionSqrtPrice, sqrtLower, sqrtUpper);
        uint16 protocolFee = swapDir0to1 ? packedProtocolFee.getZeroForOneFee() : packedProtocolFee.getOneForZeroFee();
        route.feeRate = protocolFee == 0 ? lpFee : protocolFee.calculateSwapFee(lpFee);
        if (route.feeRate >= MAX_FEE_PIPS) revert Invalid_Fee();
        route.outputMultiplier = MAX_FEE_PIPS - uint256(outputFeePips);
        _prepareRoute(route, swapDir0to1);

        if (positionSqrtPrice <= sqrtLower) {
            // Below range: only token0 is needed, swap all token1
            inputAmount = amount1;
        } else if (positionSqrtPrice >= sqrtUpper) {
            // Above range: only token1 is needed, swap all token0
            inputAmount = amount0;
        } else {
            // In range: the position pool's price fixes the ratio, the route's tick walk prices
            // every candidate. Replaces the constant-liquidity start with two effective-price
            // re-solves, which linearized the route and could leave a material deficit whenever
            // its liquidity changed inside the swap (external audit V4LE-128), and could
            // over-swap when the quote behind the effective price was truncated (V4LE-95).
            inputAmount = _solveInputOnQuote(route, amount0, amount1, positionSqrtPrice, sqrtLower, sqrtUpper);
        }
        if (inputAmount == 0) return (0, 0, swapDir0to1);
        uint256 unspent;
        (outputAmount,, unspent,) = _quoteThroughTicksState(route, inputAmount);
        // The plan is what the quote priced: input the route could not take (its ticks ran out
        // within the quote's bound, or its price bound was reached) is left out (V4LE-95).
        inputAmount -= unspent;
        if (outputAmount == 0) return (0, 0, swapDir0to1);
    }

    /// @notice One tick ahead of the pool price in the swap direction, as the tick walk found it
    struct TickStep {
        uint160 sqrtPrice; // price at the tick
        int24 tick; // the tick; MIN_TICK / MAX_TICK when nothing further is initialized
        int128 liquidityNet; // liquidity change on crossing it in the swap direction
    }

    /// @notice Pool state for tick-walking quotes in one swap direction
    /// @dev The ticks ahead are discovered once per plan and cached in `ladder` (the walker's
    ///      resume state in the `walk*` fields), so the bisection's ~41 quotes read the bitmap
    ///      and tick liquidity from the pool exactly once per tick instead of once per quote: a
    ///      far next tick (a full-range route: ~57 bitmap words away) costs ~150k gas to locate,
    ///      which per quote would dominate the plan.
    struct RouteState {
        V4PoolInfo pool;
        bool zeroForOne;
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        uint24 feeRate;
        uint256 outputMultiplier;
        TickStep[] ladder;
        uint256 ladderLength;
        int24 walkTick;
        int16 walkWordPosition;
        uint256 walkTickBitmap;
    }

    /// @dev Fixes the quote direction and resets the tick ladder to start at the route's tick.
    function _prepareRoute(RouteState memory route, bool zeroForOne) private pure {
        route.zeroForOne = zeroForOne;
        if (route.ladder.length == 0) route.ladder = new TickStep[](MAX_ROUTE_QUOTE_CROSSINGS);
        route.ladderLength = 0;
        route.walkTick = route.tick;
        route.walkWordPosition = type(int16).min;
        route.walkTickBitmap = 0;
    }

    /// @dev Appends the next tick ahead of the walker to the ladder (an uninitialized far-edge
    ///      tick when the bitmap search hit its word bound, with zero liquidity change).
    function _discoverNextTick(RouteState memory route) private view {
        NextInitializedTickResult memory next = _locateNextTick(
            NextInitializedTickParams({
                pool: route.pool,
                tickValue: route.walkTick,
                tickSpacing: route.pool.tickSpacing,
                swapDir0to1: route.zeroForOne,
                wordPosition: route.walkWordPosition,
                tickBitmap: route.walkTickBitmap
            })
        );
        route.walkWordPosition = next.wordPosition;
        route.walkTickBitmap = next.tickBitmap;
        int24 nextTick = next.nextTick;
        (, int128 liquidityNet) = route.pool.poolMgr.getTickLiquidity(route.pool.poolIdentifier, nextTick);
        if (route.zeroForOne) liquidityNet = -liquidityNet;
        route.ladder[route.ladderLength++] =
            TickStep({sqrtPrice: TickMath.getSqrtPriceAtTick(nextTick), tick: nextTick, liquidityNet: liquidityNet});
        route.walkTick = route.zeroForOne ? nextTick - 1 : nextTick;
    }

    /// @notice Net output of an exact-input swap through the pool, crossing its ticks
    /// @dev The same step the pool takes (SwapMath.computeSwapStep against the next initialized
    ///      tick, liquidity net applied at every crossing) with the caller's output fee netted out.
    ///      Bounded by MAX_ROUTE_QUOTE_CROSSINGS steps.
    /// @return amountOut Net output for the consumed input
    /// @return sqrtPrice Pool price after the consumed input
    /// @return remaining Input not consumed: the step bound was reached (`truncated`) or the
    ///         pool's price bound was, where the real swap stops as well
    /// @return truncated The quote stopped at the step bound with input left
    function _quoteThroughTicksState(RouteState memory route, uint256 amountIn)
        private
        view
        returns (uint256 amountOut, uint160 sqrtPrice, uint256 remaining, bool truncated)
    {
        sqrtPrice = route.sqrtPrice;
        uint128 liquidity = route.liquidity;
        remaining = amountIn;
        for (uint256 steps; remaining > 0; ++steps) {
            if (steps == MAX_ROUTE_QUOTE_CROSSINGS) {
                truncated = true;
                break;
            }
            if (steps == route.ladderLength) _discoverNextTick(route);
            TickStep memory next = route.ladder[steps];

            (uint160 sqrtPriceAfter, uint256 stepIn, uint256 stepOut, uint256 stepFee) =
                SwapMath.computeSwapStep(sqrtPrice, next.sqrtPrice, liquidity, -int256(remaining), route.feeRate);
            amountOut += stepOut;
            remaining -= stepIn + stepFee;
            sqrtPrice = sqrtPriceAfter;
            // the input ran out inside this tick range, or the pool's price bound was reached
            if (sqrtPriceAfter != next.sqrtPrice || next.tick == TickMath.MIN_TICK || next.tick == TickMath.MAX_TICK) {
                break;
            }
            liquidity = next.liquidityNet < 0
                ? liquidity - uint128(-next.liquidityNet)
                : liquidity + uint128(next.liquidityNet);
        }
        amountOut = FullMath.mulDiv(amountOut, route.outputMultiplier, MAX_FEE_PIPS);
    }

    /// @notice Largest input that still leaves the input token in surplus, priced by the exact
    ///         tick-walking quote
    /// @dev The balance condition is monotone in the input: more input both buys the deficient
    ///      token and (in the same pool) moves the price and with it the ratio the range needs, so
    ///      the input token stays in surplus below the root and is in deficit above it, and
    ///      bisection finds the root to ROUTE_SOLVE_PRECISION_SHIFT. Every candidate is quoted
    ///      with _quoteThroughTicksState, including initialized tick crossings. A candidate the
    ///      pool cannot take in full is treated as beyond the root, so the result is always fully
    ///      quotable: when that is because the pool's price bound was reached, the result is the
    ///      most the pool can absorb, the same partial swap the pool would execute; when it is
    ///      because the quote's step bound was reached and the bracket closes on that bound with
    ///      the input still in surplus, the root lies beyond what can be quoted and the planner
    ///      reverts Quote_Truncated rather than return a plan that leaves the range unbalanced
    ///      while reporting success (external audit V4LE-114, V4LE-95).
    /// @param positionSqrtPrice Price fixing the range's ratio; zero to use the quote's ending
    ///        price (same-pool swap), nonzero for a route into another pool (position price fixed)
    function _solveInputOnQuote(
        RouteState memory route,
        uint256 amount0,
        uint256 amount1,
        uint160 positionSqrtPrice,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) private view returns (uint256 inputAmount) {
        bool zeroForOne = route.zeroForOne;
        uint256 low;
        uint256 high = zeroForOne ? amount0 : amount1;
        uint256 tolerance = (high >> ROUTE_SOLVE_PRECISION_SHIFT) + 1;
        // whether `high` was last lowered by a step-bound truncation rather than by the balance
        // flipping (or the pool's price bound)
        bool highTruncated;
        while (high - low > tolerance) {
            uint256 mid = low + (high - low) / 2;
            (uint256 out, uint160 price, uint256 unspent, bool truncated) = _quoteThroughTicksState(route, mid);
            if (unspent != 0) {
                high = mid;
                highTruncated = truncated;
                continue;
            }
            bool stillExcess0 = _shouldSwap0to1(
                zeroForOne ? amount0 - mid : amount0 + out,
                zeroForOne ? amount1 + out : amount1 - mid,
                positionSqrtPrice == 0 ? price : positionSqrtPrice,
                sqrtLower,
                sqrtUpper
            );
            if (stillExcess0 == zeroForOne) {
                low = mid;
            } else {
                high = mid;
                highTruncated = false;
            }
        }
        if (highTruncated) revert Quote_Truncated();
        inputAmount = low;
    }

    /// @dev The constant-liquidity plan shared by both calculateSimple variants (validation of the
    ///      route price and fees is the caller's).
    function _planConstantLiquidity(
        RouteQuote memory route,
        uint160 positionSqrtPrice,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1
    ) private pure returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) {
        if (amount0 == 0 && amount1 == 0) return (0, 0, false);
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upperTick);

        // Determine swap direction from the position pool
        swapDir0to1 = _shouldSwap0to1(amount0, amount1, positionSqrtPrice, sqrtLower, sqrtUpper);

        // A route without active liquidity cannot deliver anything; plan no swap rather than
        // pricing against an empty book (the action then proceeds with what it holds).
        if (route.liquidity == 0) return (0, 0, swapDir0to1);

        if (positionSqrtPrice <= sqrtLower) {
            // Below range: only token0 is needed, swap all token1
            if (amount1 == 0) return (0, 0, swapDir0to1);
            inputAmount = amount1;
        } else if (positionSqrtPrice >= sqrtUpper) {
            // Above range: only token1 is needed, swap all token0
            if (amount0 == 0) return (0, 0, swapDir0to1);
            inputAmount = amount0;
        } else {
            inputAmount =
                _solveRouteInputInRange(route, positionSqrtPrice, sqrtLower, sqrtUpper, amount0, amount1, swapDir0to1);
            if (inputAmount == 0) return (0, 0, swapDir0to1);
        }
        outputAmount = _routeOutput(route, swapDir0to1, inputAmount);
        // an input that buys nothing (a price at which the whole holding is worth less than one
        // unit of the other token) is not worth swapping
        if (outputAmount == 0) return (0, 0, swapDir0to1);
    }

    /// @notice Net output of an exact-input swap against the route modelled as constant liquidity
    /// @dev Mirrors one SwapMath step: the fee comes off the input, the price moves along the
    ///      curve from the route's current sqrt price, and the price is capped at the pool's
    ///      sqrt price bounds the way the real swap would stop there. Output is rounded down.
    function _routeOutput(RouteQuote memory route, bool zeroForOne, uint256 amountIn)
        private
        pure
        returns (uint256 outputAmount)
    {
        uint256 amountInNet = FullMath.mulDiv(amountIn, route.inputMultiplier, MAX_FEE_PIPS);
        if (amountInNet == 0) return 0;

        uint160 nextSqrtPrice;
        if (zeroForOne) {
            nextSqrtPrice = SqrtPriceMath.getNextSqrtPriceFromInput(route.sqrtPrice, route.liquidity, amountInNet, true);
            if (nextSqrtPrice <= TickMath.MIN_SQRT_PRICE) nextSqrtPrice = TickMath.MIN_SQRT_PRICE + 1;
            outputAmount = SqrtPriceMath.getAmount1Delta(nextSqrtPrice, route.sqrtPrice, route.liquidity, false);
        } else {
            // getNextSqrtPriceFromInput's uint160 cast reverts past the price ceiling; the real
            // swap stops there instead, so cap the price the same way.
            uint256 nextRaw = uint256(route.sqrtPrice) + FullMath.mulDiv(amountInNet, FixedPoint96.Q96, route.liquidity);
            nextSqrtPrice = nextRaw >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : uint160(nextRaw);
            outputAmount = SqrtPriceMath.getAmount0Delta(route.sqrtPrice, nextSqrtPrice, route.liquidity, false);
        }
        outputAmount = FullMath.mulDiv(outputAmount, route.outputMultiplier, MAX_FEE_PIPS);
    }

    /// @notice Largest input that still leaves the input token in surplus for the range
    /// @dev The route curve is monotone, so the balance condition is solved by bisection: the
    ///      input token stays in surplus below the root and in deficit above it. Returns the
    ///      surplus-side bound, so the leftover after minting is at most the bracket width (dust).
    ///      The balance is judged by _shouldSwap0to1, i.e. by which token funds less liquidity,
    ///      instead of a required amount0/amount1 ratio in Q96: that ratio's denominator
    ///      sqrtUpper * sqrtPrice / Q96 * (sqrtPrice - sqrtLower) / Q96 floored to zero at valid
    ///      prices near MIN_TICK (sqrt prices ~2^32) and the planner reverted on the division
    ///      (external audit V4LE-145).
    function _solveRouteInputInRange(
        RouteQuote memory route,
        uint160 positionSqrtPrice,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount0,
        uint256 amount1,
        bool swapDir0to1
    ) private pure returns (uint256 inputAmount) {
        uint256 lo;
        uint256 hi = swapDir0to1 ? amount0 : amount1;
        while (hi - lo > 1 && hi - lo > (hi >> ROUTE_SOLVE_PRECISION_SHIFT)) {
            uint256 mid = (lo + hi) / 2;
            uint256 out = _routeOutput(route, swapDir0to1, mid);
            bool stillExcess0 = _shouldSwap0to1(
                swapDir0to1 ? amount0 - mid : amount0 + out,
                swapDir0to1 ? amount1 + out : amount1 - mid,
                positionSqrtPrice,
                sqrtLower,
                sqrtUpper
            );
            if (stillExcess0 == swapDir0to1) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        inputAmount = lo;
    }

    /// @notice Calculate optimal swap amount for double-sided liquidity deposit
    /// @dev Simulates crossing ticks to find optimal swap point, then uses analytic solution
    /// @param pool Pool configuration
    /// @param lowerTick Lower bound of the position
    /// @param upperTick Upper bound of the position
    /// @param amount0 Desired amount of token0
    /// @param amount1 Desired amount of token1
    /// @return inputAmount Optimal swap input amount
    /// @return outputAmount Expected swap output amount
    /// @return zeroForOne Direction: true for token0->token1, false for token1->token0
    /// @return sqrtPrice Final sqrt price after optimal swap
    function calculateSamePool(
        V4PoolInfo memory pool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 outputFeePips
    ) external view returns (uint256 inputAmount, uint256 outputAmount, bool zeroForOne, uint160 sqrtPrice) {
        if (outputFeePips >= MAX_FEE_PIPS) revert Invalid_Fee();
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }
        RouteState memory route;
        route.pool = pool;
        uint24 packedProtocolFee;
        uint24 lpFee;
        (route.sqrtPrice, route.tick, packedProtocolFee, lpFee) = pool.poolMgr.getSlot0(pool.poolIdentifier);
        if (route.sqrtPrice == 0) revert Invalid_Pool();
        route.liquidity = pool.poolMgr.getLiquidity(pool.poolIdentifier);
        uint160 lower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 upper = TickMath.getSqrtPriceAtTick(upperTick);
        zeroForOne = _shouldSwap0to1(amount0, amount1, route.sqrtPrice, lower, upper);
        uint16 protocolFee = zeroForOne ? packedProtocolFee.getZeroForOneFee() : packedProtocolFee.getOneForZeroFee();
        route.feeRate = protocolFee == 0 ? lpFee : protocolFee.calculateSwapFee(lpFee);
        if (route.feeRate >= MAX_FEE_PIPS) revert Invalid_Fee();
        route.outputMultiplier = MAX_FEE_PIPS - uint256(outputFeePips);
        _prepareRoute(route, zeroForOne);
        // The ending price of every candidate's quote fixes the ratio the range needs there.
        inputAmount = _solveInputOnQuote(route, amount0, amount1, 0, lower, upper);
        (outputAmount, sqrtPrice,,) = _quoteThroughTicksState(route, inputAmount);
        if (outputAmount == 0) inputAmount = 0;
    }

    function calculateSamePool(
        V4PoolInfo memory pool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0Target,
        uint256 amount1Target
    ) external view returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1, uint160 sqrtPrice) {
        if (amount0Target == 0 && amount1Target == 0) return (0, 0, false, 0);
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }
        SwapState memory state;
        uint24 packedProtocolFee;
        uint24 lpFeeRate;
        // Populate state with liquidity, price, amounts, and fee
        {
            int24 tickValue;
            (sqrtPrice, tickValue, packedProtocolFee, lpFeeRate) = pool.poolMgr.getSlot0(pool.poolIdentifier);
            if (sqrtPrice == 0) {
                revert Invalid_Pool();
            }
            uint128 liquidity = pool.poolMgr.getLiquidity(pool.poolIdentifier);
            int24 tickSpacing = pool.tickSpacing;
            assembly ("memory-safe") {
                mstore(state, liquidity) // offset 0x00
                mstore(add(state, 0x20), sqrtPrice) // offset 0x20
                mstore(add(state, 0x40), tickValue) // offset 0x40
                mstore(add(state, 0x60), amount0Target) // offset 0x60
                mstore(add(state, 0x80), amount1Target) // offset 0x80
                mstore(add(state, 0x100), tickSpacing) // offset 0x100
            }
        }
        // Calculate sqrt prices at tick bounds
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upperTick);
        assembly ("memory-safe") {
            mstore(add(state, 0xa0), sqrtLower) // offset 0xa0
            mstore(add(state, 0xc0), sqrtUpper) // offset 0xc0
        }
        // Determine swap direction
        swapDir0to1 = _shouldSwap0to1(amount0Target, amount1Target, sqrtPrice, sqrtLower, sqrtUpper);
        uint16 protocolFee = swapDir0to1 ? packedProtocolFee.getZeroForOneFee() : packedProtocolFee.getOneForZeroFee();
        state.feeRate = protocolFee == 0 ? lpFeeRate : protocolFee.calculateSwapFee(lpFeeRate);
        // A 100% total fee is a valid pool state (LPFeeLibrary allows it) but leaves nothing to
        // swap: both analytic branches divide by (1 - fee). Reject it like calculateSimple does
        // instead of dividing by zero.
        if (state.feeRate >= MAX_FEE_PIPS) {
            revert Invalid_Fee();
        }
        // Simulate optimal swap by crossing ticks until direction reverses
        _traverseTicks(TraverseTicksParams({pool: pool, state: state, sqrtPrice: sqrtPrice, swapDir0to1: swapDir0to1}));
        // Load final state after crossing ticks
        uint128 lastLiquidity;
        uint160 sqrtPriceLast;
        uint256 lastAmount0;
        uint256 lastAmount1;
        assembly ("memory-safe") {
            lastLiquidity := mload(state)
            sqrtPriceLast := mload(add(state, 0x20))
            lastAmount0 := mload(add(state, 0x60))
            lastAmount1 := mload(add(state, 0x80))
        }
        // Zero active liquidity where the traversal stopped (external audit V4LE-89). A valid pool
        // state: e.g. an exact-limit swap just crossed the sole in-range position's boundary tick and
        // nothing initialized lies ahead in the swap direction, so every simulated step moved the
        // price for free without consuming anything. There is nothing left to swap against toward
        // the target, and both analytic solvers assume liquidity > 0 (they would revert
        // Math_Overflow, and the hook's caught action consumes the trigger). Return what the
        // traversal could already commit against real liquidity - in the usual case no swap at all,
        // with the pool's current price - so the caller gets a deterministic plan.
        if (lastLiquidity == 0) {
            unchecked {
                if (swapDir0to1) {
                    return (amount0Target - lastAmount0, lastAmount1 - amount1Target, true, sqrtPriceLast);
                }
                return (amount1Target - lastAmount1, lastAmount0 - amount0Target, false, sqrtPriceLast);
            }
        }
        // Calculate final swap amounts based on direction
        unchecked {
            if (!swapDir0to1) {
                // Swapping token1 -> token0
                // If price is below range, try to swap to lower bound
                if (sqrtPriceLast < sqrtLower) {
                    sqrtPrice = SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(
                        sqrtPriceLast,
                        lastLiquidity,
                        lastAmount1.mulDiv(MAX_FEE_PIPS - state.feeRate, MAX_FEE_PIPS),
                        true
                    );
                    // If still below range, consume all token1
                    if (sqrtPrice < sqrtLower) {
                        inputAmount = amount1Target;
                    } else {
                        // Swap to lower bound and update state
                        lastAmount1 -= SqrtPriceMath.getAmount1Delta(sqrtPriceLast, sqrtLower, lastLiquidity, true)
                            .mulDiv(MAX_FEE_PIPS, MAX_FEE_PIPS - state.feeRate);
                        lastAmount0 += SqrtPriceMath.getAmount0Delta(sqrtPriceLast, sqrtLower, lastLiquidity, false);
                        sqrtPriceLast = sqrtLower;
                        state.sqrtPrice = sqrtPriceLast;
                        state.amount0Target = lastAmount0;
                        state.amount1Target = lastAmount1;
                    }
                }
                // If price is in range, use analytic solution
                if (sqrtPriceLast >= sqrtLower) {
                    sqrtPrice = _calculateSwap1to0(state);
                    inputAmount = amount1Target - lastAmount1
                        + SqrtPriceMath.getAmount1Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, true)
                            .mulDiv(MAX_FEE_PIPS, MAX_FEE_PIPS - state.feeRate);
                }
                outputAmount = lastAmount0 - amount0Target
                    + SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, false);
            } else {
                // Swapping token0 -> token1
                // If price is above range, try to swap to upper bound
                if (sqrtPriceLast > sqrtUpper) {
                    sqrtPrice = SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(
                        sqrtPriceLast,
                        lastLiquidity,
                        lastAmount0.mulDiv(MAX_FEE_PIPS - state.feeRate, MAX_FEE_PIPS),
                        true
                    );
                    // If still above range, consume all token0
                    if (sqrtPrice >= sqrtUpper) {
                        inputAmount = amount0Target;
                    } else {
                        // Swap to upper bound and update state
                        lastAmount0 -= SqrtPriceMath.getAmount0Delta(sqrtUpper, sqrtPriceLast, lastLiquidity, true)
                            .mulDiv(MAX_FEE_PIPS, MAX_FEE_PIPS - state.feeRate);
                        lastAmount1 += SqrtPriceMath.getAmount1Delta(sqrtUpper, sqrtPriceLast, lastLiquidity, false);
                        sqrtPriceLast = sqrtUpper;
                        state.sqrtPrice = sqrtPriceLast;
                        state.amount0Target = lastAmount0;
                        state.amount1Target = lastAmount1;
                    }
                }
                // If price is in range, use analytic solution
                if (sqrtPriceLast <= sqrtUpper) {
                    sqrtPrice = _calculateSwap0to1(state);
                    inputAmount = amount0Target - lastAmount0
                        + SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, true)
                            .mulDiv(MAX_FEE_PIPS, MAX_FEE_PIPS - state.feeRate);
                }
                outputAmount = lastAmount1 - amount1Target
                    + SqrtPriceMath.getAmount1Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, false);
            }
        }
    }

    /// @notice Find the next initialized tick in the given direction
    /// @dev Mirrors TickBitmap.nextInitializedTickWithinOneWord across word boundaries: the left search
    ///      starts at the current compressed tick, the right search at the one after it. Words further out
    ///      are entered at bit 255 (left) or bit 0 (right) so no bit is skipped. When the cached word
    ///      matches the word the search starts in, it is reused instead of reloaded. At most
    ///      MAX_BITMAP_WORDS_PER_SEARCH words are examined per call; if none holds an initialized tick,
    ///      the uninitialized tick at the far edge of the last examined word is returned so the caller
    ///      keeps making progress (crossing it changes no liquidity) and the next call resumes from there.
    ///      The search ends at the tick domain: once an empty word's far edge lies at or beyond
    ///      MIN_TICK / MAX_TICK that bound is returned (nothing further can be initialized), so the
    ///      walk never leaves the domain and never wraps back into it (external audit V4LE-140).
    /// @param params Search parameters including current tick, direction, and cached bitmap word
    /// @return result Next initialized tick and the word it was found in
    function _locateNextTick(NextInitializedTickParams memory params)
        private
        view
        returns (NextInitializedTickResult memory result)
    {
        bool searchLeft = params.swapDir0to1;
        int24 compressedTick = TickBitmap.compress(params.tickValue, params.tickSpacing);
        if (!searchLeft) compressedTick++;
        (int16 wordPosition, uint8 bitPosition) = TickBitmap.position(compressedTick);
        uint256 tickBitmap = params.wordPosition == wordPosition
            ? params.tickBitmap
            : params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, wordPosition);
        for (uint256 wordsExamined = 1;; wordsExamined++) {
            (bool initialized, int24 nextTick) =
                _findTickInWord(tickBitmap, compressedTick, bitPosition, params.tickSpacing, searchLeft);
            if (
                initialized || wordsExamined == MAX_BITMAP_WORDS_PER_SEARCH
                    || nextTick == (searchLeft ? TickMath.MIN_TICK : TickMath.MAX_TICK)
            ) {
                result.nextTick = nextTick;
                result.wordPosition = wordPosition;
                result.tickBitmap = tickBitmap;
                return result;
            }
            unchecked {
                if (searchLeft) {
                    // Continue from the highest bit of the previous word
                    compressedTick -= int24(uint24(bitPosition)) + 1;
                    wordPosition--;
                    bitPosition = type(uint8).max;
                } else {
                    // Continue from the lowest bit of the next word
                    compressedTick += int24(uint24(type(uint8).max - bitPosition)) + 1;
                    wordPosition++;
                    bitPosition = 0;
                }
            }
            tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, wordPosition);
        }
    }

    /// @notice Find the next initialized tick within a single bitmap word
    /// @dev Uses bit manipulation to efficiently find the next set bit. `compressedTick` and
    ///      `bitPosition` describe the first candidate: the current compressed tick when searching left,
    ///      the one after it when searching right.
    /// @param word The 256-bit tick bitmap word
    /// @param compressedTick The compressed tick the search starts at (inclusive)
    /// @param bitPosition Bit position of `compressedTick` in the word
    /// @param tickSpacing The tick spacing
    /// @param searchLeft Whether to search left (true) or right (false)
    /// @return initialized Whether an initialized tick was found in the word
    /// @return nextTick The next initialized tick, or the far edge of the word if none is set, clamped
    ///         to the tick domain
    function _findTickInWord(uint256 word, int24 compressedTick, uint8 bitPosition, int24 tickSpacing, bool searchLeft)
        private
        pure
        returns (bool initialized, int24 nextTick)
    {
        int256 compressedNext;
        unchecked {
            if (searchLeft) {
                // Mask all bits at or to the right of current position
                uint256 bitMask = type(uint256).max >> (uint256(type(uint8).max) - bitPosition);
                uint256 maskedWord = word & bitMask;
                initialized = maskedWord != 0;
                // the most significant set bit, or the far (low) edge of the word when none is set
                uint8 stepBack = initialized ? bitPosition - BitMath.mostSignificantBit(maskedWord) : bitPosition;
                compressedNext = int256(compressedTick) - int256(uint256(stepBack));
            } else {
                // Mask all bits at or to the left of current position
                uint256 bitMask = type(uint256).max << bitPosition;
                uint256 maskedWord = word & bitMask;
                initialized = maskedWord != 0;
                // the least significant set bit, or the far (high) edge of the word when none is set
                uint8 stepForward =
                    initialized ? BitMath.leastSignificantBit(maskedWord) - bitPosition : type(uint8).max - bitPosition;
                compressedNext = int256(compressedTick) + int256(uint256(stepForward));
            }
        }
        // An initialized tick is always inside the domain. An empty word's far edge is not: with
        // wide spacings the product overflows int24 (25599 * 32767 wrapped to -58367, a tick
        // inside the domain that made the walk re-enter and re-quote liquidity it had already
        // passed - external audit V4LE-140), so it is formed in int256 and clamped to the bound
        // the search is heading for; the callers stop at that bound.
        int256 tick = compressedNext * int256(tickSpacing);
        if (tick < TickMath.MIN_TICK) tick = TickMath.MIN_TICK;
        else if (tick > TickMath.MAX_TICK) tick = TickMath.MAX_TICK;
        nextTick = int24(tick);
    }

    /// @notice Cross ticks during optimal swap calculation
    /// @dev Simulates crossing initialized ticks until swap direction reverses or price target reached
    /// @param params Parameters including pool, state, current price, and swap direction
    function _traverseTicks(TraverseTicksParams memory params) private view {
        int24 nextTick;
        int16 wordPosition = type(int16).min;
        uint256 tickBitmap;
        do {
            // Find next initialized tick
            NextInitializedTickResult memory result = _locateNextTick(
                NextInitializedTickParams({
                    pool: params.pool,
                    tickValue: params.state.tickValue,
                    tickSpacing: params.state.tickSpacing,
                    swapDir0to1: params.swapDir0to1,
                    wordPosition: wordPosition,
                    tickBitmap: tickBitmap
                })
            );
            nextTick = result.nextTick;
            wordPosition = result.wordPosition;
            tickBitmap = result.tickBitmap;

            if (nextTick < TickMath.MIN_TICK) {
                nextTick = TickMath.MIN_TICK;
            } else if (nextTick > TickMath.MAX_TICK) {
                nextTick = TickMath.MAX_TICK;
            }

            uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(nextTick);
            uint256 amount0Target;
            uint256 amount1Target;
            unchecked {
                if (!params.swapDir0to1) {
                    // Swapping token1 -> token0
                    uint256 inputAmount;
                    uint256 feeAmt;
                    (params.sqrtPrice, inputAmount, amount0Target, feeAmt) = SwapMath.computeSwapStep(
                        uint160(params.state.sqrtPrice),
                        sqrtPriceNext,
                        params.state.liquidity,
                        -int256(params.state.amount1Target),
                        uint24(params.state.feeRate)
                    );
                    amount1Target = inputAmount + feeAmt; // Total amount consumed
                    amount0Target = params.state.amount0Target + amount0Target;
                    amount1Target = params.state.amount1Target - amount1Target;
                } else {
                    // Swapping token0 -> token1
                    uint256 inputAmount;
                    uint256 feeAmt;
                    (params.sqrtPrice, inputAmount, amount1Target, feeAmt) = SwapMath.computeSwapStep(
                        uint160(params.state.sqrtPrice),
                        sqrtPriceNext,
                        params.state.liquidity,
                        -int256(params.state.amount0Target),
                        uint24(params.state.feeRate)
                    );
                    amount0Target = inputAmount + feeAmt; // Total amount consumed
                    amount0Target = params.state.amount0Target - amount0Target;
                    amount1Target = params.state.amount1Target + amount1Target;
                }
            }
            // Stop if we didn't reach the next tick or if direction reversed
            if (params.sqrtPrice != sqrtPriceNext) break;
            if (
                _shouldSwap0to1(
                        amount0Target, amount1Target, params.sqrtPrice, params.state.sqrtLower, params.state.sqrtUpper
                    ) != params.swapDir0to1
            ) {
                break;
            } else {
                // Cross the tick and update liquidity
                (, int128 netLiquidity) = params.pool.poolMgr.getTickLiquidity(params.pool.poolIdentifier, nextTick);
                bool swapDir0to1 = params.swapDir0to1;
                SwapState memory state = params.state;
                uint160 sqrtPrice = params.sqrtPrice;
                assembly ("memory-safe") {
                    // Adjust liquidity net based on swap direction
                    // If swapping left (zeroForOne), flip the sign of liquidityNet
                    netLiquidity := add(swapDir0to1, xor(sub(0, swapDir0to1), netLiquidity))
                    // Update state in memory
                    mstore(state, add(mload(state), netLiquidity)) // liquidity
                    mstore(add(state, 0x20), sqrtPrice) // sqrtPrice
                    mstore(add(state, 0x40), sub(nextTick, swapDir0to1)) // tick
                    mstore(add(state, 0x60), amount0Target) // amount0Target
                    mstore(add(state, 0x80), amount1Target) // amount1Target
                }
                params.state = state;
                params.sqrtPrice = sqrtPrice;
            }
        } while (true);
    }

    /// @notice Analytic solution for optimal swap (token0 -> token1)
    /// @dev Solves quadratic equation: root = (sqrt(b^2 + 4ac) + b) / 2a
    /// @param state Pool state at the last tick of optimal swap
    /// @return sqrtPriceFinal Final sqrt price after optimal swap
    function _calculateSwap0to1(SwapState memory state) private pure returns (uint160 sqrtPriceFinal) {
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 sqrtPrice;
        unchecked {
            uint256 liquidity;
            uint256 sqrtUpper;
            uint256 feeRate;
            uint256 FEE_DIFF;
            assembly ("memory-safe") {
                liquidity := mload(state)
                sqrtPrice := mload(add(state, 0x20))
                sqrtUpper := mload(add(state, 0xc0))
                feeRate := mload(add(state, 0xe0))
                FEE_DIFF := sub(MAX_FEE_PIPS, feeRate)
            }
            {
                // Calculate coefficient 'a'
                uint256 aBase;
                assembly ("memory-safe") {
                    let amount0Target := mload(add(state, 0x60))
                    let liqX96 := shl(96, liquidity)
                    // a = amount0Target + liquidity / ((1 - f) * sqrtPrice) - liquidity / sqrtUpper
                    aBase := add(amount0Target, div(mul(MAX_FEE_PIPS, liqX96), mul(FEE_DIFF, sqrtPrice)))
                    a := sub(aBase, div(liqX96, sqrtUpper))
                    // a < amount0Target means sqrtUpper < (1 - f) * sqrtPrice: not an in-range
                    // state, the solver's premise is broken
                    if lt(a, amount0Target) {
                        mstore(0, 0x20236808) // Math_Overflow error selector
                        revert(0x1c, 0x04)
                    }
                }
                // a == amount0Target is the exact upper bound of a zero-fee pool (external audit
                // V4LE-85), a valid state the old strict guard rejected. With token0 to place the
                // quadratic is well-defined there (leading coefficient amount0Target) and finds the
                // interior root; with none it degenerates to the linear solution p == sqrtPrice, i.e.
                // no swap - return it directly, the division by a below would yield 0.
                if (a == 0) {
                    return uint160(sqrtPrice);
                }
                // Calculate coefficient 'b'
                b = FullMath.mulDiv(aBase, state.sqrtLower, FixedPoint96.Q96);
                assembly {
                    b := add(div(mul(feeRate, liquidity), FEE_DIFF), b)
                }
            }
            {
                // Calculate coefficient 'c'
                uint256 cBase = FullMath.mulDiv(liquidity, sqrtPrice, FixedPoint96.Q96);
                assembly ("memory-safe") {
                    cBase := add(mload(add(state, 0x80)), cBase)
                }
                c = cBase - FullMath.mulDiv(liquidity, (MAX_FEE_PIPS * state.sqrtLower) / FEE_DIFF, FixedPoint96.Q96);
                // NOTE (M-5): 'c' is intentionally not guarded with `c > amount1Target`. Unlike the 'a'
                // guard above - whose invariant (sqrtUpper > (1-f)*sqrtPrice) always holds for a valid
                // in-range state and so only catches corruption - `c > amount1Target` does NOT always hold:
                // when sqrtPrice is within the fee band of sqrtLower, c is legitimately a small value below
                // amount1Target. Guarding it reverts valid tight-range swaps (breaks
                // test_LiquidityCalculator_NarrowRange). On the rare extreme where the subtraction wraps, the
                // result degrades to the clamped boundary price (a minimal/no-op swap), and downstream
                // amountOutMin / oracle slippage checks bound any mispricing - so a hard revert is worse.
                b -= cBase.mulDiv(FixedPoint96.Q96, sqrtUpper);
            }
            // Multiply a and c by 2 for quadratic formula
            assembly {
                a := shl(1, a)
                c := shl(1, c)
            }
        }
        // The root lies in [sqrtLower, sqrtPrice]: the direction check that selected this solver
        // holds token0 in surplus at sqrtPrice and the range wants only token0 at sqrtLower.
        uint256 root = _positiveQuadraticRoot(a, b, c, sqrtPrice);
        if (root > sqrtPrice) root = sqrtPrice;
        if (root < state.sqrtLower) root = state.sqrtLower;
        sqrtPriceFinal = uint160(root);
    }

    /// @notice Analytic solution for optimal swap (token1 -> token0)
    /// @dev Solves quadratic equation: root = (sqrt(b^2 + 4ac) + b) / 2a
    /// @param state Pool state at the last tick of optimal swap
    /// @return sqrtPriceFinal Final sqrt price after optimal swap
    function _calculateSwap1to0(SwapState memory state) private pure returns (uint160 sqrtPriceFinal) {
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 sqrtPrice;
        unchecked {
            uint256 liquidity;
            uint256 sqrtUpper;
            uint256 feeRate;
            uint256 FEE_DIFF;
            assembly ("memory-safe") {
                liquidity := mload(state)
                sqrtPrice := mload(add(state, 0x20))
                sqrtUpper := mload(add(state, 0xc0))
                feeRate := mload(add(state, 0xe0))
                FEE_DIFF := sub(MAX_FEE_PIPS, feeRate)
            }
            {
                // Calculate coefficient 'a'
                uint256 aBase;
                // NOTE (M-5): 'a' is intentionally not guarded with `a > amount0Target`. Unlike the 'c'
                // guard below - whose invariant (sqrtPrice > (1-f)*sqrtLower) always holds for a valid
                // in-range state and so only catches corruption - `a > amount0Target` does NOT always hold:
                // when sqrtPrice is within the fee band of sqrtUpper, a is legitimately a small value below
                // amount0Target. Guarding it reverts valid tight-range swaps (breaks
                // test_LiquidityCalculator_NarrowRange). On the rare extreme where the subtraction wraps, the
                // result degrades to the clamped boundary price (a minimal/no-op swap), and downstream
                // amountOutMin / oracle slippage checks bound any mispricing - so a hard revert is worse.
                assembly ("memory-safe") {
                    let liqX96 := shl(96, liquidity)
                    // a = amount0Target + liquidity / sqrtPrice - liquidity / ((1 - f) * sqrtUpper)
                    aBase := add(mload(add(state, 0x60)), div(liqX96, sqrtPrice))
                    a := sub(aBase, div(mul(MAX_FEE_PIPS, liqX96), mul(FEE_DIFF, sqrtUpper)))
                }
                // Calculate coefficient 'b'
                b = FullMath.mulDiv(aBase, state.sqrtLower, FixedPoint96.Q96);
                assembly {
                    b := sub(b, div(mul(feeRate, liquidity), FEE_DIFF))
                }
            }
            {
                // Calculate coefficient 'c'
                uint256 cBase = FullMath.mulDiv(liquidity, (MAX_FEE_PIPS * sqrtPrice) / FEE_DIFF, FixedPoint96.Q96);
                uint256 amount1Target;
                assembly ("memory-safe") {
                    amount1Target := mload(add(state, 0x80))
                    cBase := add(amount1Target, cBase)
                }
                c = cBase - FullMath.mulDiv(liquidity, state.sqrtLower, FixedPoint96.Q96);
                // c < amount1Target means sqrtPrice < (1 - f) * sqrtLower: not an in-range state,
                // the solver's premise is broken
                assembly ("memory-safe") {
                    if lt(c, amount1Target) {
                        mstore(0, 0x20236808) // Math_Overflow error selector
                        revert(0x1c, 0x04)
                    }
                }
                // c == amount1Target is the exact lower bound of a zero-fee pool (external audit
                // V4LE-85), a valid state the old strict guard rejected. With token1 to place the
                // quadratic finds the interior root; with none the root is p == sqrtPrice, i.e. no
                // swap - return it directly rather than rely on the rounding of the general path.
                if (c == 0) {
                    return uint160(sqrtPrice);
                }
                b -= cBase.mulDiv(FixedPoint96.Q96, sqrtUpper);
            }
            // Multiply a and c by 2 for quadratic formula
            assembly {
                a := shl(1, a)
                c := shl(1, c)
            }
        }
        // The root lies in [sqrtPrice, sqrtUpper]: the direction check that selected this solver
        // holds token1 in surplus at sqrtPrice and the range wants only token1 at sqrtUpper.
        uint256 root = _positiveQuadraticRoot(a, b, c, sqrtPrice);
        if (root < sqrtPrice) root = sqrtPrice;
        if (root > state.sqrtUpper) root = state.sqrtUpper;
        sqrtPriceFinal = uint160(root);
    }

    /// @notice The analytic solvers' root of a*p^2 - b*p - c == 0: p = (b + sqrt(b^2 + 4ac)) / (2a)
    /// @dev The coefficients are two's-complement words (see _sqrtDiscriminant), `a2` and `c2`
    ///      already doubled. Formed the numerically stable way: with b >= 0 the sum b + sqrt(D)
    ///      is exact, with b < 0 the same root is 2c / (sqrt(D) - b), whose denominator is again a
    ///      sum of magnitudes. The textbook form b + sqrt(D) cancels there (sqrt(D) is floored, so
    ///      for a*c << b^2 the numerator is off by whole units and the division by a small `a`
    ///      turns that into an arbitrary price), and at a == 0 - a valid fee-bearing state of the
    ///      1->0 solver, where the balance equation is linear with root c / |b| - it divided by
    ///      zero and returned the current price, i.e. no swap although token1 was in surplus
    ///      (external audit V4LE-150). Every case where no positive root exists (no real root,
    ///      or the sign of a / c puts the root at or below zero) returns `noRoot`, the current
    ///      price, which the callers treat as no swap; the callers clamp the result to their side
    ///      of the current price and to the requested range.
    /// @param noRoot Returned when the equation has no positive root
    /// @return root The positive root in Q96, or `noRoot`
    function _positiveQuadraticRoot(uint256 a2, uint256 b, uint256 c2, uint256 noRoot)
        private
        pure
        returns (uint256 root)
    {
        (bool realRoot, uint256 sqrtDiscriminant) = _sqrtDiscriminant(a2, b, c2);
        if (!realRoot) return noRoot;
        if (int256(b) >= 0) {
            // (b + sqrt(D)) / (2a): positive only for a > 0 (a == 0 leaves -b*p - c == 0, whose
            // root is -c/b: at or below zero for c >= 0, and the callers exclude c < 0 with b >= 0
            // from a swap by the range clamp anyway)
            if (int256(a2) <= 0) return noRoot;
            // b <= 2^128 - 1 and sqrt(D) < 2^128 (checked in _sqrtDiscriminant): no overflow
            root = FullMath.mulDiv(sqrtDiscriminant + b, FixedPoint96.Q96, a2);
        } else {
            // 2c / (sqrt(D) + |b|): positive only for c > 0; covers a == 0 (root c / |b|) and
            // the 1->0 solver's negative `a` (the smaller positive root, as before)
            if (int256(c2) <= 0) return noRoot;
            root = FullMath.mulDiv(c2, FixedPoint96.Q96, sqrtDiscriminant + _abs(b));
        }
        if (root == 0) return noRoot;
    }

    /// @notice Square root of the analytic solvers' quadratic discriminant b*b + a*c
    /// @dev The coefficients are two's-complement words: `b` may be negative in both solvers, `a`
    ///      in the 1->0 solver (whose root is taken with sdiv) and `c` in the 0->1 solver (the
    ///      unguarded fee-band case documented at M-5), so the products are formed on magnitudes
    ///      and recombined by sign. Everything used to be computed unchecked (external audit
    ///      V4LE-33): for large valid coefficients b*b wrapped modulo 2^256 and the solver returned
    ///      a plausible-looking but wrong plan (a final price outside the requested range). A
    ///      magnitude that does not fit 256 bits now reverts Math_Overflow. A negative discriminant
    ///      has no real root; the solvers then keep the current price (no swap), the degradation the
    ///      M-5 note documents for that extreme.
    /// @return realRoot False when the discriminant is negative
    /// @return root sqrt(b*b + a*c) when realRoot
    function _sqrtDiscriminant(uint256 a, uint256 b, uint256 c) private pure returns (bool realRoot, uint256 root) {
        unchecked {
            uint256 absB = _abs(b);
            // (2^128 - 1)^2 < 2^256 <= (2^128)^2
            if (absB > type(uint128).max) revert Math_Overflow();
            uint256 bb = absB * absB;
            uint256 absA = _abs(a);
            uint256 absC = _abs(c);
            uint256 ac = absA * absC;
            if (absA != 0 && ac / absA != absC) revert Math_Overflow();
            if (ac != 0 && (int256(a) < 0) != (int256(c) < 0)) {
                if (ac > bb) return (false, 0);
                return (true, Math.sqrt(bb - ac));
            }
            uint256 disc = bb + ac;
            if (disc < bb) revert Math_Overflow();
            return (true, Math.sqrt(disc));
        }
    }

    /// @dev Magnitude of a two's-complement word
    function _abs(uint256 x) private pure returns (uint256) {
        unchecked {
            return int256(x) < 0 ? 0 - x : x;
        }
    }

    /// @notice Determine swap direction when price is within range
    /// @dev Token0 is in surplus when it funds more liquidity for the range than token1 does:
    ///        L0 = amount0 * sqrtPrice * sqrtUpper / (Q96 * (sqrtUpper - sqrtPrice))
    ///        L1 = amount1 * Q96 / (sqrtPrice - sqrtLower)
    ///      Both are formed so that no intermediate floors to zero: the price-only factor
    ///      sqrtPrice * sqrtUpper / (sqrtUpper - sqrtPrice) is at least sqrtPrice (>= 2^32), so
    ///      it keeps 32 bits of precision, and the amounts are multiplied in before the single
    ///      division by Q96. The previous form floored amount0 * sqrtPrice / Q96 first, which is
    ///      zero for any amount0 below Q96 / sqrtPrice (~1.8e19 wei at the sqrt prices near
    ///      MIN_TICK), so a pure token0 holding compared as an empty one and the planner chose
    ///      1->0 with nothing to swap (external audit V4LE-146). A product that does not fit
    ///      256 bits saturates: liquidity that large cannot be minted anyway, and the comparison
    ///      only needs the ordering.
    /// @param amount0Target Desired amount of token0
    /// @param amount1Target Desired amount of token1
    /// @param sqrtPrice Current sqrt price, strictly inside (sqrtLower, sqrtUpper)
    /// @param sqrtLower Lower bound sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @return true if should swap token0->token1, false otherwise
    function _checkSwapDirectionInRange(
        uint256 amount0Target,
        uint256 amount1Target,
        uint256 sqrtPrice,
        uint256 sqrtLower,
        uint256 sqrtUpper
    ) private pure returns (bool) {
        unchecked {
            uint256 liquidity0 = _mulDivSaturating(
                amount0Target, _mulDivSaturating(sqrtPrice, sqrtUpper, sqrtUpper - sqrtPrice), FixedPoint96.Q96
            );
            uint256 liquidity1 = _mulDivSaturating(amount1Target, FixedPoint96.Q96, sqrtPrice - sqrtLower);
            return liquidity0 > liquidity1;
        }
    }

    /// @dev floor(a * b / denominator), or type(uint256).max when the result does not fit
    function _mulDivSaturating(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256) {
        uint256 prod1;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            let prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 >= denominator) return type(uint256).max;
        return FullMath.mulDiv(a, b, denominator);
    }

    /// @inheritdoc ILiquidityCalculator
    function swapDirection(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        pure
        returns (bool zeroForOne)
    {
        if (tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }
        return _shouldSwap0to1(
            amount0, amount1, sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper)
        );
    }

    /// @notice Determine optimal swap direction for double-sided deposit
    /// @dev Returns true if should swap token0->token1, false for token1->token0
    /// @param amount0Target Desired amount of token0
    /// @param amount1Target Desired amount of token1
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @return true if should swap token0->token1, false otherwise
    function _shouldSwap0to1(
        uint256 amount0Target,
        uint256 amount1Target,
        uint256 sqrtPrice,
        uint256 sqrtLower,
        uint256 sqrtUpper
    ) private pure returns (bool) {
        // If price is below range, only need token0 (swap token1->token0)
        if (sqrtPrice <= sqrtLower) return false;
        // If price is above range, only need token1 (swap token0->token1)
        else if (sqrtPrice >= sqrtUpper) return true;
        // If price is in range, compare liquidity requirements
        else return _checkSwapDirectionInRange(amount0Target, amount1Target, sqrtPrice, sqrtLower, sqrtUpper);
    }
}
