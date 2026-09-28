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

    /// @notice Pool configuration struct containing pool manager, pool ID, and tick spacing
    struct V4PoolInfo {
        IPoolManager poolMgr;
        PoolId poolIdentifier;
        int24 tickSpacing;
    }

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
    /// @dev Starts from the constant-liquidity plan above and, when the planned swap would cross
    ///      initialized ticks of the route pool, refines it against an exact-input quote that walks
    ///      those ticks (SwapMath step by step, liquidity updated at every crossing), so the plan is
    ///      sized against the route's real depth wherever its liquidity thickens or thins beyond the
    ///      current tick range. The route's fee is read from its slot0 for the planned direction.
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

    /// @dev Bound on the initialized ticks one route quote crosses; past it the quote stops and
    ///      the plan is sized to what was quoted (a conservative bound for a very long walk).
    uint256 internal constant MAX_ROUTE_QUOTE_CROSSINGS = 32;

    /// @dev Effective-price refinement rounds after the constant-liquidity start: each one quotes
    ///      the planned input through the route's ticks and re-solves with the quoted price.
    uint256 internal constant ROUTE_REFINEMENT_ROUNDS = 2;

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

        // Start from the constant-liquidity plan, exact until the first crossed tick.
        (inputAmount,,) = _planConstantLiquidity(
            RouteQuote({
                sqrtPrice: route.sqrtPrice,
                liquidity: route.liquidity,
                inputMultiplier: MAX_FEE_PIPS - uint256(route.feeRate),
                outputMultiplier: route.outputMultiplier
            }),
            positionSqrtPrice,
            lowerTick,
            upperTick,
            amount0,
            amount1
        );
        if (inputAmount == 0) return (0, 0, swapDir0to1);
        outputAmount = _quoteThroughTicks(route, swapDir0to1, inputAmount);
        if (outputAmount == 0) return (0, 0, swapDir0to1);

        // One-sided plans swap everything; an in-range plan is refined against the quoted
        // effective price, which already includes every tick the swap crosses.
        if (positionSqrtPrice > sqrtLower && positionSqrtPrice < sqrtUpper) {
            uint256 requiredRatio = _calculateRequiredRatio(positionSqrtPrice, sqrtLower, sqrtUpper);
            for (uint256 round; round < ROUTE_REFINEMENT_ROUNDS; ++round) {
                uint256 refined = _solveWithEffectivePrice(
                    requiredRatio,
                    amount0,
                    amount1,
                    swapDir0to1,
                    FullMath.mulDiv(outputAmount, FixedPoint96.Q96, inputAmount)
                );
                if (refined == 0 || refined == inputAmount) break;
                inputAmount = refined;
                outputAmount = _quoteThroughTicks(route, swapDir0to1, inputAmount);
                if (outputAmount == 0) return (0, 0, swapDir0to1);
            }
        }
    }

    /// @notice Route pool state for a tick-walking quote
    struct RouteState {
        V4PoolInfo pool;
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        uint24 feeRate;
        uint256 outputMultiplier;
    }

    /// @notice Net output of an exact-input swap through the route pool, crossing its ticks
    /// @dev The same step the pool takes (SwapMath.computeSwapStep against the next initialized
    ///      tick, liquidity net applied at every crossing) with the caller's output fee netted out.
    ///      Bounded by MAX_ROUTE_QUOTE_CROSSINGS steps; a quote that stops early under-reports the
    ///      output, which only makes the plan swap more conservatively.
    function _quoteThroughTicks(RouteState memory route, bool zeroForOne, uint256 amountIn)
        private
        view
        returns (uint256 amountOut)
    {
        (amountOut,,) = _quoteThroughTicksState(route, zeroForOne, amountIn);
    }

    function _quoteThroughTicksState(RouteState memory route, bool zeroForOne, uint256 amountIn)
        private
        view
        returns (uint256 amountOut, uint160 sqrtPrice, uint256 remaining)
    {
        sqrtPrice = route.sqrtPrice;
        uint128 liquidity = route.liquidity;
        int24 tick = route.tick;
        int16 wordPosition = type(int16).min;
        uint256 tickBitmap;
        remaining = amountIn;
        for (uint256 crossings; remaining > 0 && crossings < MAX_ROUTE_QUOTE_CROSSINGS; ++crossings) {
            NextInitializedTickResult memory next = _locateNextTick(
                NextInitializedTickParams({
                    pool: route.pool,
                    tickValue: tick,
                    tickSpacing: route.pool.tickSpacing,
                    swapDir0to1: zeroForOne,
                    wordPosition: wordPosition,
                    tickBitmap: tickBitmap
                })
            );
            wordPosition = next.wordPosition;
            tickBitmap = next.tickBitmap;
            int24 nextTick = next.nextTick;
            if (nextTick < TickMath.MIN_TICK) nextTick = TickMath.MIN_TICK;
            if (nextTick > TickMath.MAX_TICK) nextTick = TickMath.MAX_TICK;
            uint160 sqrtPriceNext = TickMath.getSqrtPriceAtTick(nextTick);

            (uint160 sqrtPriceAfter, uint256 stepIn, uint256 stepOut, uint256 stepFee) =
                SwapMath.computeSwapStep(sqrtPrice, sqrtPriceNext, liquidity, -int256(remaining), route.feeRate);
            amountOut += stepOut;
            remaining -= stepIn + stepFee;
            sqrtPrice = sqrtPriceAfter;
            // the input ran out inside this tick range, or the pool's price bound was reached
            if (sqrtPriceAfter != sqrtPriceNext || nextTick == TickMath.MIN_TICK || nextTick == TickMath.MAX_TICK) {
                break;
            }
            (, int128 liquidityNet) = route.pool.poolMgr.getTickLiquidity(route.pool.poolIdentifier, nextTick);
            if (zeroForOne) liquidityNet = -liquidityNet;
            liquidity = liquidityNet < 0 ? liquidity - uint128(-liquidityNet) : liquidity + uint128(liquidityNet);
            tick = zeroForOne ? nextTick - 1 : nextTick;
        }
        amountOut = FullMath.mulDiv(amountOut, route.outputMultiplier, MAX_FEE_PIPS);
    }

    /// @notice Linear re-solve of the balance condition at a quoted effective price
    /// @param effectivePriceX96 Net output per unit of input from the last quote (Q96)
    function _solveWithEffectivePrice(
        uint256 requiredRatio,
        uint256 amount0,
        uint256 amount1,
        bool swapDir0to1,
        uint256 effectivePriceX96
    ) private pure returns (uint256 inputAmount) {
        uint256 requiredAmount0 = FullMath.mulDiv(requiredRatio, amount1, FixedPoint96.Q96);
        if (swapDir0to1) {
            if (amount0 <= requiredAmount0) return 0;
            // amount0 - in == ratio * (amount1 + p * in)
            uint256 denominator = FixedPoint96.Q96 + FullMath.mulDiv(requiredRatio, effectivePriceX96, FixedPoint96.Q96);
            inputAmount = FullMath.mulDiv(amount0 - requiredAmount0, FixedPoint96.Q96, denominator);
            if (inputAmount > amount0) inputAmount = amount0;
        } else {
            if (requiredAmount0 <= amount0) return 0;
            // amount0 + p * in == ratio * (amount1 - in)
            inputAmount =
                FullMath.mulDiv(requiredAmount0 - amount0, FixedPoint96.Q96, effectivePriceX96 + requiredRatio);
            if (inputAmount > amount1) inputAmount = amount1;
        }
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
            inputAmount = _solveRouteInputInRange(
                route, _calculateRequiredRatio(positionSqrtPrice, sqrtLower, sqrtUpper), amount0, amount1, swapDir0to1
            );
            if (inputAmount == 0) return (0, 0, swapDir0to1);
        }
        outputAmount = _routeOutput(route, swapDir0to1, inputAmount);
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

    /// @notice Largest input that still leaves at least the required ratio on the input side
    /// @dev The route curve is monotone, so the balance condition is solved by bisection: the
    ///      input token stays in surplus below the root and in deficit above it. Returns the
    ///      surplus-side bound, so the leftover after minting is at most the bracket width (dust).
    function _solveRouteInputInRange(
        RouteQuote memory route,
        uint256 requiredRatio,
        uint256 amount0,
        uint256 amount1,
        bool swapDir0to1
    ) private pure returns (uint256 inputAmount) {
        uint256 requiredAmount0 = FullMath.mulDiv(requiredRatio, amount1, FixedPoint96.Q96);
        if (swapDir0to1 ? amount0 <= requiredAmount0 : requiredAmount0 <= amount0) return 0;

        uint256 lo;
        uint256 hi = swapDir0to1 ? amount0 : amount1;
        while (hi - lo > 1 && hi - lo > (hi >> ROUTE_SOLVE_PRECISION_SHIFT)) {
            uint256 mid = (lo + hi) / 2;
            uint256 out = _routeOutput(route, swapDir0to1, mid);
            bool inputStillInSurplus = swapDir0to1
                ? amount0 - mid > FullMath.mulDiv(requiredRatio, amount1 + out, FixedPoint96.Q96)
                : FullMath.mulDiv(requiredRatio, amount1 - mid, FixedPoint96.Q96) > amount0 + out;
            if (inputStillInSurplus) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        inputAmount = lo;
    }

    /// @notice Calculate required ratio for perfect liquidity in range
    /// @dev For price P in range [Pa, Pb]: ratio = (sqrt(Pb) - sqrt(P)) / (sqrt(Pb) * sqrt(P) * (sqrt(P) - sqrt(Pa)))
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @return requiredRatio Required ratio scaled by Q96
    function _calculateRequiredRatio(uint160 sqrtPrice, uint160 sqrtLower, uint160 sqrtUpper)
        private
        pure
        returns (uint256 requiredRatio)
    {
        uint256 numerator = sqrtUpper - sqrtPrice;
        uint256 denominator = FullMath.mulDiv(
            FullMath.mulDiv(sqrtUpper, sqrtPrice, FixedPoint96.Q96), sqrtPrice - sqrtLower, FixedPoint96.Q96
        );
        requiredRatio = FullMath.mulDiv(numerator, FixedPoint96.Q96, denominator);
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
        uint256 low;
        uint256 high = zeroForOne ? amount0 : amount1;
        uint256 tolerance = (high >> ROUTE_SOLVE_PRECISION_SHIFT) + 1;
        // The balance condition is monotone: more input both buys the deficient token and moves
        // the pool price and the range ratio. Every candidate uses
        // the exact tick-walking output and ending price, including initialized tick crossings.
        while (high - low > tolerance) {
            uint256 mid = low + (high - low) / 2;
            (uint256 out, uint160 price, uint256 unspent) = _quoteThroughTicksState(route, zeroForOne, mid);
            if (unspent != 0) {
                high = mid;
                continue;
            }
            bool stillExcess0 = _shouldSwap0to1(
                zeroForOne ? amount0 - mid : amount0 + out,
                zeroForOne ? amount1 + out : amount1 - mid,
                price,
                lower,
                upper
            );
            if (stillExcess0 == zeroForOne) low = mid;
            else high = mid;
        }
        inputAmount = low;
        (outputAmount, sqrtPrice,) = _quoteThroughTicksState(route, zeroForOne, inputAmount);
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
            if (initialized || wordsExamined == MAX_BITMAP_WORDS_PER_SEARCH) {
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
    /// @return nextTick The next initialized tick, or the far edge of the word if none is set
    function _findTickInWord(uint256 word, int24 compressedTick, uint8 bitPosition, int24 tickSpacing, bool searchLeft)
        private
        pure
        returns (bool initialized, int24 nextTick)
    {
        unchecked {
            if (searchLeft) {
                // Mask all bits at or to the right of current position
                uint256 bitMask = type(uint256).max >> (uint256(type(uint8).max) - bitPosition);
                uint256 maskedWord = word & bitMask;
                initialized = maskedWord != 0;
                if (initialized) {
                    // Found initialized tick - find the most significant set bit
                    uint8 mostSigBit = BitMath.mostSignificantBit(maskedWord);
                    nextTick = (compressedTick - int24(uint24(bitPosition - mostSigBit))) * tickSpacing;
                } else {
                    // No initialized tick in this word
                    nextTick = (compressedTick - int24(uint24(bitPosition))) * tickSpacing;
                }
            } else {
                // Mask all bits at or to the left of current position
                uint256 bitMask = type(uint256).max << bitPosition;
                uint256 maskedWord = word & bitMask;
                initialized = maskedWord != 0;
                if (initialized) {
                    // Found initialized tick - find the least significant set bit
                    uint8 leastSigBit = BitMath.leastSignificantBit(maskedWord);
                    nextTick = (compressedTick + int24(uint24(leastSigBit - bitPosition))) * tickSpacing;
                } else {
                    // No initialized tick in this word
                    nextTick = (compressedTick + int24(uint24(type(uint8).max - bitPosition))) * tickSpacing;
                }
            }
        }
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
        // Solve quadratic: sqrtPriceFinal = (sqrt(b^2 + 4ac) + b) / 2a
        (bool realRoot, uint256 root) = _sqrtDiscriminant(a, b, c);
        if (!realRoot) {
            return uint160(sqrtPrice);
        }
        unchecked {
            uint256 num = root + b;
            assembly {
                sqrtPriceFinal := div(shl(96, num), a)
            }
        }
        // Ensure final price doesn't exceed current price
        assembly {
            sqrtPriceFinal := xor(sqrtPrice, mul(xor(sqrtPrice, sqrtPriceFinal), lt(sqrtPriceFinal, sqrtPrice)))
        }
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
        // Solve quadratic: sqrtPriceFinal = (sqrt(b^2 + 4ac) + b) / 2a
        (bool realRoot, uint256 root) = _sqrtDiscriminant(a, b, c);
        if (!realRoot) {
            return uint160(sqrtPrice);
        }
        unchecked {
            uint256 num = root + b;
            assembly {
                // Use signed division as result may be negative
                sqrtPriceFinal := sdiv(shl(96, num), a)
            }
        }
        // Ensure final price is at least current price
        assembly {
            sqrtPriceFinal := xor(sqrtPrice, mul(xor(sqrtPrice, sqrtPriceFinal), gt(sqrtPriceFinal, sqrtPrice)))
        }
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
    /// @dev Compares liquidity requirements for token0 vs token1 at current price
    /// @param amount0Target Desired amount of token0
    /// @param amount1Target Desired amount of token1
    /// @param sqrtPrice Current sqrt price
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
            // Compare liquidity needed for token0 vs token1
            // If more token0 needed relative to price movement, swap token0->token1
            return FullMath.mulDiv(
                FullMath.mulDiv(amount0Target, sqrtPrice, FixedPoint96.Q96), sqrtPrice - sqrtLower, FixedPoint96.Q96
            ) > amount1Target.mulDiv(sqrtUpper - sqrtPrice, sqrtUpper);
        }
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
