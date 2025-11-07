// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.8;

import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import "@uniswap/v4-core/src/libraries/SwapMath.sol";
import "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/libraries/BitMath.sol";
import "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library OptimalSwap {
    using FullMath for uint256;
    using UnsafeMath for uint256;
    using StateLibrary for IPoolManager;

    uint256 internal constant MAX_FEE_PIPS = 1e6;

    error Invalid_Pool();
    error Invalid_Tick_Range();
    error Math_Overflow();

    /// @notice V4 Pool Callee struct that wraps IPoolManager, PoolId, and tickSpacing
    struct V4PoolCallee {
        IPoolManager poolManager;
        PoolId poolId;
        int24 tickSpacing;
    }

    /// @notice Parameters for finding the next initialized tick
    struct NextInitializedTickParams {
        V4PoolCallee pool;
        int24 tick;
        int24 tickSpacing;
        bool zeroForOne;
        int16 wordPos;
        uint256 tickWord;
    }

    /// @notice Result of finding the next initialized tick
    struct NextInitializedTickResult {
        int24 tickNext;
        int16 wordPos;
        uint256 tickWord;
    }

    /// @notice Parameters for crossing ticks during optimal swap calculation
    struct CrossTicksParams {
        V4PoolCallee pool;
        SwapState state;
        uint160 sqrtPriceX96;
        bool zeroForOne;
    }

    struct SwapState {
        // liquidity in range after swap, accessible by `mload(state)`
        uint128 liquidity;
        // sqrt(price) after swap, accessible by `mload(add(state, 0x20))`
        uint256 sqrtPriceX96;
        // tick after swap, accessible by `mload(add(state, 0x40))`
        int24 tick;
        // The desired amount of token0 to add liquidity, `mload(add(state, 0x60))`
        uint256 amount0Desired;
        // The desired amount of token1 to add liquidity, `mload(add(state, 0x80))`
        uint256 amount1Desired;
        // sqrt(price) at the lower tick, `mload(add(state, 0xa0))`
        uint256 sqrtRatioLowerX96;
        // sqrt(price) at the upper tick, `mload(add(state, 0xc0))`
        uint256 sqrtRatioUpperX96;
        // the fee taken from the input amount, expressed in hundredths of a bip
        // accessible by `mload(add(state, 0xe0))`
        uint256 feePips;
        // the tick spacing of the pool, accessible by `mload(add(state, 0x100))`
        int24 tickSpacing;
    }

    /// @notice Get swap amount, output amount, swap direction for double-sided optimal deposit
    /// @dev Given the elegant analytic solution and custom optimizations to Uniswap libraries,
    /// the amount of gas is at the order of 10k depending on the swap amount and the number of ticks crossed,
    /// an order of magnitude less than that achieved by binary search, which can be calculated on-chain.
    /// @param pool Uniswap v4 pool callee
    /// @param tickLower The lower tick of the position in which to add liquidity
    /// @param tickUpper The upper tick of the position in which to add liquidity
    /// @param amount0Desired The desired amount of token0 to be spent
    /// @param amount1Desired The desired amount of token1 to be spent
    /// @return amountIn The optimal swap amount
    /// @return amountOut Expected output amount
    /// @return zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
    /// @return sqrtPriceX96 The sqrt(price) after the swap
    function getOptimalSwap(
        V4PoolCallee memory pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal view returns (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) {
        if (amount0Desired == 0 && amount1Desired == 0) return (0, 0, false, 0);
        if (tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK)
            revert Invalid_Tick_Range();
        // Ensure the pool manager exists.
        assembly ("memory-safe") {
            let poolManager := mload(pool)
            let poolCodeSize := extcodesize(poolManager)
            if iszero(poolCodeSize) {
                // revert Invalid_Pool()
                mstore(0, 0x01ac05a5)
                revert(0x1c, 0x04)
            }
        }
        // intermediate state cache
        SwapState memory state;
        // Populate `SwapState` with hardcoded offsets.
        {
            int24 tick;
            uint24 protocolFee;
            uint24 lpFee;
            (sqrtPriceX96, tick, protocolFee, lpFee) = pool.poolManager.getSlot0(pool.poolId);
            assembly ("memory-safe") {
                // state.tick = tick
                mstore(add(state, 0x40), tick)
            }
        }
        {
            uint128 liquidity = pool.poolManager.getLiquidity(pool.poolId);
            (, , , uint24 lpFee) = pool.poolManager.getSlot0(pool.poolId);
            int24 tickSpacing = pool.tickSpacing;
            uint256 feePips = uint256(lpFee);
            assembly ("memory-safe") {
                // state.liquidity = liquidity
                mstore(state, liquidity)
                // state.sqrtPriceX96 = sqrtPriceX96
                mstore(add(state, 0x20), sqrtPriceX96)
                // state.amount0Desired = amount0Desired
                mstore(add(state, 0x60), amount0Desired)
                // state.amount1Desired = amount1Desired
                mstore(add(state, 0x80), amount1Desired)
                // state.feePips = feePips
                mstore(add(state, 0xe0), feePips)
                // state.tickSpacing = tickSpacing
                mstore(add(state, 0x100), tickSpacing)
            }
        }
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        assembly ("memory-safe") {
            // state.sqrtRatioLowerX96 = sqrtRatioLowerX96
            mstore(add(state, 0xa0), sqrtRatioLowerX96)
            // state.sqrtRatioUpperX96 = sqrtRatioUpperX96
            mstore(add(state, 0xc0), sqrtRatioUpperX96)
        }
        zeroForOne = isZeroForOne(amount0Desired, amount1Desired, sqrtPriceX96, sqrtRatioLowerX96, sqrtRatioUpperX96);
        // Simulate optimal swap by crossing ticks until the direction reverses.
        crossTicks(
            CrossTicksParams({
                pool: pool,
                state: state,
                sqrtPriceX96: sqrtPriceX96,
                zeroForOne: zeroForOne
            })
        );
        // Active liquidity at the last tick of optimal swap
        uint128 liquidityLast;
        // sqrt(price) at the last tick of optimal swap
        uint160 sqrtPriceLastTickX96;
        // Remaining amount of token0 to add liquidity at the last tick
        uint256 amount0LastTick;
        // Remaining amount of token1 to add liquidity at the last tick
        uint256 amount1LastTick;
        assembly ("memory-safe") {
            // liquidityLast = state.liquidity
            liquidityLast := mload(state)
            // sqrtPriceLastTickX96 = state.sqrtPriceX96
            sqrtPriceLastTickX96 := mload(add(state, 0x20))
            // amount0LastTick = state.amount0Desired
            amount0LastTick := mload(add(state, 0x60))
            // amount1LastTick = state.amount1Desired
            amount1LastTick := mload(add(state, 0x80))
        }
        unchecked {
            if (!zeroForOne) {
                // The last tick is out of range. There are two cases:
                // 1. There is not enough token1 to swap to reach the lower tick.
                // 2. There is no initialized tick between the last tick and the lower tick.
                if (sqrtPriceLastTickX96 < sqrtRatioLowerX96) {
                    sqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(
                        sqrtPriceLastTickX96,
                        liquidityLast,
                        amount1LastTick.mulDiv(MAX_FEE_PIPS - state.feePips, MAX_FEE_PIPS),
                        true
                    );
                    // The final price is out of range. Simply consume all token1.
                    if (sqrtPriceX96 < sqrtRatioLowerX96) {
                        amountIn = amount1Desired;
                    }
                    // Swap to the lower tick and update the state.
                    else {
                        amount1LastTick -= SqrtPriceMath
                            .getAmount1Delta(sqrtPriceLastTickX96, sqrtRatioLowerX96, liquidityLast, true)
                            .mulDiv(MAX_FEE_PIPS, MAX_FEE_PIPS - state.feePips);
                        amount0LastTick += SqrtPriceMath.getAmount0Delta(
                            sqrtPriceLastTickX96,
                            sqrtRatioLowerX96,
                            liquidityLast,
                            false
                        );
                        sqrtPriceLastTickX96 = sqrtRatioLowerX96;
                        state.sqrtPriceX96 = sqrtPriceLastTickX96;
                        state.amount0Desired = amount0LastTick;
                        state.amount1Desired = amount1LastTick;
                    }
                }
                // The final price is in range. Use the closed form solution.
                if (sqrtPriceLastTickX96 >= sqrtRatioLowerX96) {
                    sqrtPriceX96 = solveOptimalOneForZero(state);
                    amountIn =
                        amount1Desired -
                        amount1LastTick +
                        SqrtPriceMath.getAmount1Delta(sqrtPriceX96, sqrtPriceLastTickX96, liquidityLast, true).mulDiv(
                            MAX_FEE_PIPS,
                            MAX_FEE_PIPS - state.feePips
                        );
                }
                amountOut =
                    amount0LastTick -
                    amount0Desired +
                    SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceLastTickX96, liquidityLast, false);
            } else {
                // The last tick is out of range. There are two cases:
                // 1. There is not enough token0 to swap to reach the upper tick.
                // 2. There is no initialized tick between the last tick and the upper tick.
                if (sqrtPriceLastTickX96 > sqrtRatioUpperX96) {
                    sqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(
                        sqrtPriceLastTickX96,
                        liquidityLast,
                        amount0LastTick.mulDiv(MAX_FEE_PIPS - state.feePips, MAX_FEE_PIPS),
                        true
                    );
                    // The final price is out of range. Simply consume all token0.
                    if (sqrtPriceX96 >= sqrtRatioUpperX96) {
                        amountIn = amount0Desired;
                    }
                    // Swap to the upper tick and update the state.
                    else {
                        amount0LastTick -= SqrtPriceMath
                            .getAmount0Delta(sqrtRatioUpperX96, sqrtPriceLastTickX96, liquidityLast, true)
                            .mulDiv(MAX_FEE_PIPS, MAX_FEE_PIPS - state.feePips);
                        amount1LastTick += SqrtPriceMath.getAmount1Delta(
                            sqrtRatioUpperX96,
                            sqrtPriceLastTickX96,
                            liquidityLast,
                            false
                        );
                        sqrtPriceLastTickX96 = sqrtRatioUpperX96;
                        state.sqrtPriceX96 = sqrtPriceLastTickX96;
                        state.amount0Desired = amount0LastTick;
                        state.amount1Desired = amount1LastTick;
                    }
                }
                // The final price is in range. Use the closed form solution.
                if (sqrtPriceLastTickX96 <= sqrtRatioUpperX96) {
                    sqrtPriceX96 = solveOptimalZeroForOne(state);
                    amountIn =
                        amount0Desired -
                        amount0LastTick +
                        SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceLastTickX96, liquidityLast, true).mulDiv(
                            MAX_FEE_PIPS,
                            MAX_FEE_PIPS - state.feePips
                        );
                }
                amountOut =
                    amount1LastTick -
                    amount1Desired +
                    SqrtPriceMath.getAmount1Delta(sqrtPriceX96, sqrtPriceLastTickX96, liquidityLast, false);
            }
        }
    }

    /// @dev Find the next initialized tick in the given direction, using V4 StateLibrary
    /// @param params The parameters for finding the next initialized tick
    /// @return result The result containing the next initialized tick and updated state
    function _nextInitializedTick(NextInitializedTickParams memory params)
        private
        view
        returns (NextInitializedTickResult memory result)
    {
        bool lte = params.zeroForOne; // lte = less than or equal (search left)
        int24 compressed = TickBitmap.compress(params.tick, params.tickSpacing);
        (int16 currentWordPos, uint8 bitPos) = TickBitmap.position(compressed);
        
        // If we have a cached word and it's the current word, check it first
        if (params.wordPos == currentWordPos && params.tickWord != 0) {
            result.tickNext = _nextInitializedTickInWord(
                params.tickWord,
                compressed,
                bitPos,
                params.tickSpacing,
                lte
            );
            if (result.tickNext != params.tick) {
                result.wordPos = currentWordPos;
                result.tickWord = params.tickWord;
                return result;
            }
        }
        
        // Search through words until we find an initialized tick
        int16 searchWordPos = params.wordPos == type(int16).min ? currentWordPos : params.wordPos;
        uint256 tickWord = params.tickWord;
        
        while (true) {
            if (lte) {
                // Search left (decreasing ticks)
                if (searchWordPos < currentWordPos - 100) {
                    // Went too far, return the boundary tick
                    result.tickNext = (compressed - int24(uint24(type(uint8).max))) * params.tickSpacing;
                    result.wordPos = searchWordPos;
                    result.tickWord = 0;
                    return result;
                }
                if (searchWordPos == currentWordPos && tickWord == 0) {
                    tickWord = params.pool.poolManager.getTickBitmap(params.pool.poolId, searchWordPos);
                } else if (searchWordPos < currentWordPos) {
                    searchWordPos--;
                    tickWord = params.pool.poolManager.getTickBitmap(params.pool.poolId, searchWordPos);
                } else {
                    searchWordPos--;
                    if (searchWordPos >= currentWordPos - 100) {
                        tickWord = params.pool.poolManager.getTickBitmap(params.pool.poolId, searchWordPos);
                    } else {
                        result.tickNext = (compressed - int24(uint24(type(uint8).max))) * params.tickSpacing;
                        result.wordPos = searchWordPos;
                        result.tickWord = 0;
                        return result;
                    }
                }
            } else {
                // Search right (increasing ticks)
                if (searchWordPos > currentWordPos + 100) {
                    // Went too far, return the boundary tick
                    result.tickNext = (compressed + int24(uint24(type(uint8).max))) * params.tickSpacing;
                    result.wordPos = searchWordPos;
                    result.tickWord = 0;
                    return result;
                }
                if (searchWordPos == currentWordPos && tickWord == 0) {
                    tickWord = params.pool.poolManager.getTickBitmap(params.pool.poolId, searchWordPos + 1);
                    searchWordPos++;
                } else if (searchWordPos <= currentWordPos) {
                    searchWordPos = currentWordPos + 1;
                    tickWord = params.pool.poolManager.getTickBitmap(params.pool.poolId, searchWordPos);
                } else {
                    searchWordPos++;
                    if (searchWordPos <= currentWordPos + 100) {
                        tickWord = params.pool.poolManager.getTickBitmap(params.pool.poolId, searchWordPos);
                    } else {
                        result.tickNext = (compressed + int24(uint24(type(uint8).max))) * params.tickSpacing;
                        result.wordPos = searchWordPos;
                        result.tickWord = 0;
                        return result;
                    }
                }
            }
            
            if (tickWord != 0) {
                // Found a word with initialized ticks
                int24 searchCompressed = lte ? compressed : compressed + 1;
                if (searchWordPos != currentWordPos) {
                    searchCompressed = int24(searchWordPos) * 256;
                    if (!lte) searchCompressed++;
                }
                uint8 searchBitPos = uint8(uint24(searchCompressed) & 0xff);
                result.tickNext = _nextInitializedTickInWord(
                    tickWord,
                    searchCompressed,
                    searchBitPos,
                    params.tickSpacing,
                    lte
                );
                result.wordPos = searchWordPos;
                result.tickWord = tickWord;
                return result;
            }
        }
    }
    
    /// @dev Find the next initialized tick within a single word
    /// @param word The tick bitmap word
    /// @param compressed The compressed tick
    /// @param bitPos The bit position in the word
    /// @param tickSpacing The tick spacing
    /// @param lte Whether to search left (true) or right (false)
    /// @return tickNext The next initialized tick
    function _nextInitializedTickInWord(
        uint256 word,
        int24 compressed,
        uint8 bitPos,
        int24 tickSpacing,
        bool lte
    ) private pure returns (int24 tickNext) {
        unchecked {
            if (lte) {
                // Search left: mask all bits at or to the right of current bitPos
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = word & mask;
                
                if (masked != 0) {
                    // Found initialized tick
                    uint8 msb = BitMath.mostSignificantBit(masked);
                    tickNext = (compressed - int24(uint24(bitPos - msb))) * tickSpacing;
                } else {
                    // No initialized tick in this word, return rightmost tick
                    tickNext = (compressed - int24(uint24(bitPos))) * tickSpacing;
                }
            } else {
                // Search right: start from next compressed tick
                compressed++;
                bitPos = uint8(uint24(compressed) & 0xff);
                // Mask all bits at or to the left of bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = word & mask;
                
                if (masked != 0) {
                    // Found initialized tick
                    uint8 lsb = BitMath.leastSignificantBit(masked);
                    tickNext = (compressed + int24(uint24(lsb - bitPos))) * tickSpacing;
                } else {
                    // No initialized tick in this word, return leftmost tick
                    tickNext = (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
                }
            }
        }
    }

    /// @dev Check if the remaining amount is enough to cross the next initialized tick.
    // If so, check whether the swap direction changes for optimal deposit. If so, we swap too much and the final sqrt
    // price must be between the current tick and the next tick. Otherwise the next tick must be crossed.
    /// @param params The parameters for crossing ticks, including pool, state, current sqrtPrice, and swap direction
    /// @notice Modifies params.state and params.sqrtPriceX96 in place
    function crossTicks(CrossTicksParams memory params) private view {
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // Ensure the initial `wordPos` doesn't coincide with the starting tick's.
        int16 wordPos = type(int16).min;
        // a word in `pool.tickBitmap`
        uint256 tickWord;

        do {
            NextInitializedTickResult memory result = _nextInitializedTick(
                NextInitializedTickParams({
                    pool: params.pool,
                    tick: params.state.tick,
                    tickSpacing: params.state.tickSpacing,
                    zeroForOne: params.zeroForOne,
                    wordPos: wordPos,
                    tickWord: tickWord
                })
            );
            tickNext = result.tickNext;
            wordPos = result.wordPos;
            tickWord = result.tickWord;
            // sqrt(price) for the next tick (1/0)
            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);
            // The desired amount of token0 to add liquidity after swap
            uint256 amount0Desired;
            // The desired amount of token1 to add liquidity after swap
            uint256 amount1Desired;

            unchecked {
                if (!params.zeroForOne) {
                    // Abuse `amount1Desired` to store `amountIn` to avoid stack too deep errors.
                    uint256 amountIn;
                    uint256 feeAmount;
                    (params.sqrtPriceX96, amountIn, amount0Desired, feeAmount) = SwapMath.computeSwapStep(
                        uint160(params.state.sqrtPriceX96),
                        sqrtPriceNextX96,
                        params.state.liquidity,
                        -int256(params.state.amount1Desired),
                        uint24(params.state.feePips)
                    );
                    amount1Desired = amountIn + feeAmount; // total amount consumed
                    amount0Desired = params.state.amount0Desired + amount0Desired;
                    amount1Desired = params.state.amount1Desired - amount1Desired;
                } else {
                    // Abuse `amount0Desired` to store `amountIn` to avoid stack too deep errors.
                    uint256 amountIn;
                    uint256 feeAmount;
                    (params.sqrtPriceX96, amountIn, amount1Desired, feeAmount) = SwapMath.computeSwapStep(
                        uint160(params.state.sqrtPriceX96),
                        sqrtPriceNextX96,
                        params.state.liquidity,
                        -int256(params.state.amount0Desired),
                        uint24(params.state.feePips)
                    );
                    amount0Desired = amountIn + feeAmount; // total amount consumed
                    amount0Desired = params.state.amount0Desired - amount0Desired;
                    amount1Desired = params.state.amount1Desired + amount1Desired;
                }
            }

            // If the remaining amount is large enough to consume the current tick and the optimal swap direction
            // doesn't change, continue crossing ticks.
            if (params.sqrtPriceX96 != sqrtPriceNextX96) break;
            if (
                isZeroForOne(
                    amount0Desired,
                    amount1Desired,
                    params.sqrtPriceX96,
                    params.state.sqrtRatioLowerX96,
                    params.state.sqrtRatioUpperX96
                ) != params.zeroForOne
            ) {
                break;
            } else {
                (, int128 liquidityNet) = params.pool.poolManager.getTickLiquidity(params.pool.poolId, tickNext);
                // Load values into local variables for assembly access
                bool zeroForOne = params.zeroForOne;
                SwapState memory state = params.state;
                uint160 sqrtPriceX96 = params.sqrtPriceX96;
                
                assembly ("memory-safe") {
                    // If we're moving leftward, we interpret `liquidityNet` as the opposite sign.
                    // If zeroForOne, liquidityNet = -liquidityNet = ~liquidityNet + 1 = -1 ^ liquidityNet + 1.
                    // Therefore, liquidityNet = -zeroForOne ^ liquidityNet + zeroForOne.
                    liquidityNet := add(zeroForOne, xor(sub(0, zeroForOne), liquidityNet))
                    // `liquidity` is the first in `SwapState`
                    mstore(state, add(mload(state), liquidityNet))
                    // state.sqrtPriceX96 = sqrtPriceX96
                    mstore(add(state, 0x20), sqrtPriceX96)
                    // state.tick = zeroForOne ? tickNext - 1 : tickNext
                    mstore(add(state, 0x40), sub(tickNext, zeroForOne))
                    // state.amount0Desired = amount0Desired
                    mstore(add(state, 0x60), amount0Desired)
                    // state.amount1Desired = amount1Desired
                    mstore(add(state, 0x80), amount1Desired)
                }
                
                // Update params with modified values
                params.state = state;
                params.sqrtPriceX96 = sqrtPriceX96;
            }
        } while (true);
    }

    /// @dev Analytic solution for optimal swap between two nearest initialized ticks swapping token0 to token1
    /// @param state Pool state at the last tick of optimal swap
    /// @return sqrtPriceFinalX96 sqrt(price) after optimal swap
    function solveOptimalZeroForOne(SwapState memory state) private pure returns (uint160 sqrtPriceFinalX96) {
        /**
         * root = (sqrt(b^2 + 4ac) + b) / 2a
         * `a` is in the order of `amount0Desired`. `b` is in the order of `liquidity`.
         * `c` is in the order of `amount1Desired`.
         * `a`, `b`, `c` are signed integers in two's complement but typed as unsigned to avoid unnecessary casting.
         */
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 sqrtPriceX96;
        unchecked {
            uint256 liquidity;
            uint256 sqrtRatioUpperX96;
            uint256 feePips;
            uint256 FEE_COMPLEMENT;
            assembly ("memory-safe") {
                // liquidity = state.liquidity
                liquidity := mload(state)
                // sqrtPriceX96 = state.sqrtPriceX96
                sqrtPriceX96 := mload(add(state, 0x20))
                // sqrtRatioUpperX96 = state.sqrtRatioUpperX96
                sqrtRatioUpperX96 := mload(add(state, 0xc0))
                // feePips = state.feePips
                feePips := mload(add(state, 0xe0))
                // FEE_COMPLEMENT = MAX_FEE_PIPS - feePips
                FEE_COMPLEMENT := sub(MAX_FEE_PIPS, feePips)
            }
            {
                uint256 a0;
                assembly ("memory-safe") {
                    // amount0Desired = state.amount0Desired
                    let amount0Desired := mload(add(state, 0x60))
                    let liquidityX96 := shl(96, liquidity)
                    // a = amount0Desired + liquidity / ((1 - f) * sqrtPrice) - liquidity / sqrtRatioUpper
                    a0 := add(amount0Desired, div(mul(MAX_FEE_PIPS, liquidityX96), mul(FEE_COMPLEMENT, sqrtPriceX96)))
                    a := sub(a0, div(liquidityX96, sqrtRatioUpperX96))
                    // `a` is always positive and greater than `amount0Desired`.
                    if iszero(gt(a, amount0Desired)) {
                        // revert Math_Overflow()
                        mstore(0, 0x20236808)
                        revert(0x1c, 0x04)
                    }
                }
                b = FullMath.mulDiv(a0, state.sqrtRatioLowerX96, FixedPoint96.Q96);
                assembly {
                    b := add(div(mul(feePips, liquidity), FEE_COMPLEMENT), b)
                }
            }
            {
                // c = amount1Desired + liquidity * sqrtPrice - liquidity * sqrtRatioLower / (1 - f)
                uint256 c0 = FullMath.mulDiv(liquidity, sqrtPriceX96, FixedPoint96.Q96);
                assembly ("memory-safe") {
                    // c0 = amount1Desired + liquidity * sqrtPrice
                    c0 := add(mload(add(state, 0x80)), c0)
                }
                c = c0 - FullMath.mulDiv(liquidity, (MAX_FEE_PIPS * state.sqrtRatioLowerX96) / FEE_COMPLEMENT, FixedPoint96.Q96);
                b -= c0.mulDiv(FixedPoint96.Q96, sqrtRatioUpperX96);
            }
            assembly {
                a := shl(1, a)
                c := shl(1, c)
            }
        }
        // Given a root exists, the following calculations cannot realistically overflow/underflow.
        unchecked {
            uint256 numerator = Math.sqrt(b * b + a * c) + b;
            assembly {
                // `numerator` and `a` must be positive so use `div`.
                sqrtPriceFinalX96 := div(shl(96, numerator), a)
            }
        }
        // The final price must be less than or equal to the price at the last tick.
        // However the calculated price may increase if the ratio is close to optimal.
        assembly {
            // sqrtPriceFinalX96 = min(sqrtPriceFinalX96, sqrtPriceX96)
            sqrtPriceFinalX96 := xor(
                sqrtPriceX96,
                mul(xor(sqrtPriceX96, sqrtPriceFinalX96), lt(sqrtPriceFinalX96, sqrtPriceX96))
            )
        }
    }

    /// @dev Analytic solution for optimal swap between two nearest initialized ticks swapping token1 to token0
    /// @param state Pool state at the last tick of optimal swap
    /// @return sqrtPriceFinalX96 sqrt(price) after optimal swap
    function solveOptimalOneForZero(SwapState memory state) private pure returns (uint160 sqrtPriceFinalX96) {
        /**
         * root = (sqrt(b^2 + 4ac) + b) / 2a
         * `a` is in the order of `amount0Desired`. `b` is in the order of `liquidity`.
         * `c` is in the order of `amount1Desired`.
         * `a`, `b`, `c` are signed integers in two's complement but typed as unsigned to avoid unnecessary casting.
         */
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 sqrtPriceX96;
        unchecked {
            uint256 liquidity;
            uint256 sqrtRatioUpperX96;
            uint256 feePips;
            uint256 FEE_COMPLEMENT;
            assembly ("memory-safe") {
                // liquidity = state.liquidity
                liquidity := mload(state)
                // sqrtPriceX96 = state.sqrtPriceX96
                sqrtPriceX96 := mload(add(state, 0x20))
                // sqrtRatioUpperX96 = state.sqrtRatioUpperX96
                sqrtRatioUpperX96 := mload(add(state, 0xc0))
                // feePips = state.feePips
                feePips := mload(add(state, 0xe0))
                // FEE_COMPLEMENT = MAX_FEE_PIPS - feePips
                FEE_COMPLEMENT := sub(MAX_FEE_PIPS, feePips)
            }
            {
                // a = state.amount0Desired + liquidity / sqrtPrice - liquidity / ((1 - f) * sqrtRatioUpper)
                uint256 a0;
                assembly ("memory-safe") {
                    let liquidityX96 := shl(96, liquidity)
                    // a0 = state.amount0Desired + liquidity / sqrtPrice
                    a0 := add(mload(add(state, 0x60)), div(liquidityX96, sqrtPriceX96))
                    a := sub(a0, div(mul(MAX_FEE_PIPS, liquidityX96), mul(FEE_COMPLEMENT, sqrtRatioUpperX96)))
                }
                b = FullMath.mulDiv(a0, state.sqrtRatioLowerX96, FixedPoint96.Q96);
                assembly {
                    b := sub(b, div(mul(feePips, liquidity), FEE_COMPLEMENT))
                }
            }
            {
                // c = amount1Desired + liquidity * sqrtPrice / (1 - f) - liquidity * sqrtRatioLower
                uint256 c0 = FullMath.mulDiv(liquidity, (MAX_FEE_PIPS * sqrtPriceX96) / FEE_COMPLEMENT, FixedPoint96.Q96);
                uint256 amount1Desired;
                assembly ("memory-safe") {
                    // amount1Desired = state.amount1Desired
                    amount1Desired := mload(add(state, 0x80))
                    // c0 = amount1Desired + liquidity * sqrtPrice / (1 - f)
                    c0 := add(amount1Desired, c0)
                }
                c = c0 - FullMath.mulDiv(liquidity, state.sqrtRatioLowerX96, FixedPoint96.Q96);
                assembly ("memory-safe") {
                    // `c` is always positive and greater than `amount1Desired`.
                    if iszero(gt(c, amount1Desired)) {
                        // revert Math_Overflow()
                        mstore(0, 0x20236808)
                        revert(0x1c, 0x04)
                    }
                }
                b -= c0.mulDiv(FixedPoint96.Q96, sqrtRatioUpperX96);
            }
            assembly {
                a := shl(1, a)
                c := shl(1, c)
            }
        }
        // Given a root exists, the following calculations cannot realistically overflow/underflow.
        unchecked {
            uint256 numerator = Math.sqrt(b * b + a * c) + b;
            assembly {
                // `numerator` and `a` may be negative so use `sdiv`.
                sqrtPriceFinalX96 := sdiv(shl(96, numerator), a)
            }
        }
        // The final price must be greater than or equal to the price at the last tick.
        // However the calculated price may decrease if the ratio is close to optimal.
        assembly {
            // sqrtPriceFinalX96 = max(sqrtPriceFinalX96, sqrtPriceX96)
            sqrtPriceFinalX96 := xor(
                sqrtPriceX96,
                mul(xor(sqrtPriceX96, sqrtPriceFinalX96), gt(sqrtPriceFinalX96, sqrtPriceX96))
            )
        }
    }

    /// @dev Swap direction to achieve optimal deposit when the current price is in range
    /// @param amount0Desired The desired amount of token0 to be spent
    /// @param amount1Desired The desired amount of token1 to be spent
    /// @param sqrtPriceX96 sqrt(price) at the last tick of optimal swap
    /// @param sqrtRatioLowerX96 The lower sqrt(price) of the position in which to add liquidity
    /// @param sqrtRatioUpperX96 The upper sqrt(price) of the position in which to add liquidity
    /// @return The direction of the swap, true for token0 to token1, false for token1 to token0
    function isZeroForOneInRange(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 sqrtPriceX96,
        uint256 sqrtRatioLowerX96,
        uint256 sqrtRatioUpperX96
    ) private pure returns (bool) {
        // amount0 = liquidity * (sqrt(upper) - sqrt(current)) / (sqrt(upper) * sqrt(current))
        // amount1 = liquidity * (sqrt(current) - sqrt(lower))
        // amount0 * amount1 = liquidity * (sqrt(upper) - sqrt(current)) / (sqrt(upper) * sqrt(current)) * amount1
        //     = liquidity * (sqrt(current) - sqrt(lower)) * amount0
        unchecked {
            return
                FullMath.mulDiv(
                    FullMath.mulDiv(amount0Desired, sqrtPriceX96, FixedPoint96.Q96),
                    sqrtPriceX96 - sqrtRatioLowerX96,
                    FixedPoint96.Q96
                ) >
                amount1Desired.mulDiv(sqrtRatioUpperX96 - sqrtPriceX96, sqrtRatioUpperX96);
        }
    }

    /// @dev Swap direction to achieve optimal deposit
    /// @param amount0Desired The desired amount of token0 to be spent
    /// @param amount1Desired The desired amount of token1 to be spent
    /// @param sqrtPriceX96 sqrt(price) at the last tick of optimal swap
    /// @param sqrtRatioLowerX96 The lower sqrt(price) of the position in which to add liquidity
    /// @param sqrtRatioUpperX96 The upper sqrt(price) of the position in which to add liquidity
    /// @return The direction of the swap, true for token0 to token1, false for token1 to token0
    function isZeroForOne(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 sqrtPriceX96,
        uint256 sqrtRatioLowerX96,
        uint256 sqrtRatioUpperX96
    ) internal pure returns (bool) {
        // If the current price is below `sqrtRatioLowerX96`, only token0 is required.
        if (sqrtPriceX96 <= sqrtRatioLowerX96) return false;
        // If the current tick is above `sqrtRatioUpperX96`, only token1 is required.
        else if (sqrtPriceX96 >= sqrtRatioUpperX96) return true;
        else
            return
                isZeroForOneInRange(amount0Desired, amount1Desired, sqrtPriceX96, sqrtRatioLowerX96, sqrtRatioUpperX96);
    }
}