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

/// @title LiquidityCalculator
/// @notice Library for calculating optimal swap amounts for double-sided liquidity deposits for Uniswap V4
/// @dev Uses analytic solutions to efficiently compute optimal swap parameters
library LiquidityCalculator {
    using FullMath for uint256;
    using UnsafeMath for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Maximum fee in hundredths of a bip (1e6 = 100%)
    uint256 internal constant MAX_FEE_PIPS = 1e6;

    error Invalid_Pool();
    error Invalid_Tick_Range();
    error Math_Overflow();

    /// @notice Pool configuration struct containing pool manager, pool ID, and tick spacing
    struct V4PoolInfo {
        IPoolManager poolMgr;
        PoolId poolIdentifier;
        int24 tickSpacing;
    }

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

    /// @notice Calculate optimal swap amount for double-sided liquidity deposit
    /// @dev Simplified version that assumes swap happens in another pool (no tick crossing simulation)
    /// @param sqrtPrice Current sqrt price of the pool
    /// @param lowerTick Lower bound of the position
    /// @param upperTick Upper bound of the position
    /// @param amount0 Desired amount of token0
    /// @param amount1 Desired amount of token1
    /// @param feeRate Fee rate in hundredths of a bip (e.g., 3000 = 0.3%)
    /// @return inputAmount Optimal swap input amount
    /// @return outputAmount Expected swap output amount (before fees)
    /// @return swapDir0to1 Direction: true for token0->token1, false for token1->token0
    function calculateSimple(
        uint160 sqrtPrice,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint24 feeRate
    ) internal pure returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) {
        if (amount0 == 0 && amount1 == 0) return (0, 0, false);
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }
        
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upperTick);
        
        // Determine swap direction
        swapDir0to1 = shouldSwap0to1(amount0, amount1, sqrtPrice, sqrtLower, sqrtUpper);
        
        unchecked {
            if (sqrtPrice <= sqrtLower) {
                (inputAmount, outputAmount) = _calculateSwapBelowRange(amount0, amount1, sqrtPrice, sqrtLower, feeRate);
            } else if (sqrtPrice >= sqrtUpper) {
                (inputAmount, outputAmount) = _calculateSwapAboveRange(amount0, amount1, sqrtPrice, sqrtUpper, feeRate);
            } else {
                (inputAmount, outputAmount) = _calculateSwapInRange(
                    amount0,
                    amount1,
                    sqrtPrice,
                    sqrtLower,
                    sqrtUpper,
                    feeRate,
                    swapDir0to1
                );
            }
        }
    }

    /// @notice Calculate swap when price is below range (need all token0)
    /// @param amount1 Current amount of token1
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param feeRate Fee rate
    /// @return inputAmount Swap input amount
    /// @return outputAmount Swap output amount
    function _calculateSwapBelowRange(
        uint256 /* amount0 */,
        uint256 amount1,
        uint160 sqrtPrice,
        uint160 sqrtLower,
        uint24 feeRate
    ) private pure returns (uint256 inputAmount, uint256 outputAmount) {
        if (amount1 == 0) return (0, 0);
        
        // Swap all token1 -> token0
        inputAmount = amount1;
        uint256 feeMultiplier = MAX_FEE_PIPS - uint256(feeRate);
        outputAmount = FullMath.mulDiv(
            FullMath.mulDiv(amount1, sqrtPrice, sqrtLower),
            feeMultiplier,
            MAX_FEE_PIPS
        );
    }

    /// @notice Calculate swap when price is above range (need all token1)
    /// @param amount0 Current amount of token0
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @param feeRate Fee rate
    /// @return inputAmount Swap input amount
    /// @return outputAmount Swap output amount
    function _calculateSwapAboveRange(
        uint256 amount0,
        uint256 /* amount1 */,
        uint160 sqrtPrice,
        uint160 sqrtUpper,
        uint24 feeRate
    ) private pure returns (uint256 inputAmount, uint256 outputAmount) {
        if (amount0 == 0) return (0, 0);
        
        // Swap all token0 -> token1
        inputAmount = amount0;
        uint256 feeMultiplier = MAX_FEE_PIPS - uint256(feeRate);
        outputAmount = FullMath.mulDiv(
            FullMath.mulDiv(amount0, sqrtUpper, sqrtPrice),
            feeMultiplier,
            MAX_FEE_PIPS
        );
    }

    /// @notice Calculate swap when price is in range (need optimal ratio)
    /// @param amount0 Current amount of token0
    /// @param amount1 Current amount of token1
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @param feeRate Fee rate
    /// @param swapDir0to1 Swap direction
    /// @return inputAmount Swap input amount
    /// @return outputAmount Swap output amount
    function _calculateSwapInRange(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPrice,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint24 feeRate,
        bool swapDir0to1
    ) private pure returns (uint256 inputAmount, uint256 outputAmount) {
        uint256 requiredRatio = _calculateRequiredRatio(sqrtPrice, sqrtLower, sqrtUpper);
        uint256 feeMultiplier = MAX_FEE_PIPS - uint256(feeRate);
        
        if (swapDir0to1) {
            (inputAmount, outputAmount) = _calculateSwap0to1InRange(
                amount0,
                amount1,
                sqrtPrice,
                sqrtUpper,
                requiredRatio,
                feeMultiplier
            );
        } else {
            (inputAmount, outputAmount) = _calculateSwap1to0InRange(
                amount0,
                amount1,
                sqrtPrice,
                sqrtLower,
                requiredRatio,
                feeMultiplier
            );
        }
    }

    /// @notice Calculate required ratio for perfect liquidity in range
    /// @dev For price P in range [Pa, Pb]: ratio = (sqrt(Pb) - sqrt(P)) / (sqrt(Pb) * sqrt(P) * (sqrt(P) - sqrt(Pa)))
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @return requiredRatio Required ratio scaled by Q96
    function _calculateRequiredRatio(
        uint160 sqrtPrice,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) private pure returns (uint256 requiredRatio) {
        uint256 numerator = sqrtUpper - sqrtPrice;
        uint256 denominator = FullMath.mulDiv(
            FullMath.mulDiv(sqrtUpper, sqrtPrice, FixedPoint96.Q96),
            sqrtPrice - sqrtLower,
            FixedPoint96.Q96
        );
        requiredRatio = FullMath.mulDiv(numerator, FixedPoint96.Q96, denominator);
    }

    /// @notice Calculate swap when swapping token0 -> token1 in range
    /// @param amount0 Current amount of token0
    /// @param amount1 Current amount of token1
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @param requiredRatio Required ratio scaled by Q96
    /// @param feeMultiplier Fee multiplier (MAX_FEE_PIPS - feeRate)
    /// @return inputAmount Swap input amount
    /// @return outputAmount Swap output amount
    function _calculateSwap0to1InRange(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPrice,
        uint160 sqrtUpper,
        uint256 requiredRatio,
        uint256 feeMultiplier
    ) private pure returns (uint256 inputAmount, uint256 outputAmount) {
        uint256 requiredAmount0 = FullMath.mulDiv(requiredRatio, amount1, FixedPoint96.Q96);
        if (amount0 <= requiredAmount0) return (0, 0);
        
        uint256 excess0 = amount0 - requiredAmount0;
        uint256 swapRate = FullMath.mulDiv(
            FullMath.mulDiv(requiredRatio, feeMultiplier, FixedPoint96.Q96),
            sqrtPrice,
            sqrtUpper
        );
        uint256 denominator = FixedPoint96.Q96 + swapRate;
        inputAmount = FullMath.mulDiv(excess0, FixedPoint96.Q96, denominator);
        
        // Cap at available amount
        if (inputAmount > amount0) inputAmount = amount0;
        
        // Calculate output
        outputAmount = FullMath.mulDiv(
            FullMath.mulDiv(inputAmount, sqrtPrice, sqrtUpper),
            feeMultiplier,
            MAX_FEE_PIPS
        );
    }

    /// @notice Calculate swap when swapping token1 -> token0 in range
    /// @param amount0 Current amount of token0
    /// @param amount1 Current amount of token1
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param requiredRatio Required ratio scaled by Q96
    /// @param feeMultiplier Fee multiplier (MAX_FEE_PIPS - feeRate)
    /// @return inputAmount Swap input amount
    /// @return outputAmount Swap output amount
    function _calculateSwap1to0InRange(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPrice,
        uint160 sqrtLower,
        uint256 requiredRatio,
        uint256 feeMultiplier
    ) private pure returns (uint256 inputAmount, uint256 outputAmount) {
        uint256 requiredAmount0 = FullMath.mulDiv(requiredRatio, amount1, FixedPoint96.Q96);
        if (requiredAmount0 <= amount0) return (0, 0);
        
        uint256 deficit0 = requiredAmount0 - amount0;
        uint256 swapRate = FullMath.mulDiv(
            FullMath.mulDiv(requiredRatio, feeMultiplier, FixedPoint96.Q96),
            sqrtLower,
            sqrtPrice
        );
        uint256 denominator = FullMath.mulDiv(feeMultiplier, sqrtLower, sqrtPrice) + swapRate;
        inputAmount = FullMath.mulDiv(
            FullMath.mulDiv(deficit0, sqrtPrice, sqrtLower),
            MAX_FEE_PIPS,
            denominator
        );
        
        // Cap at available amount
        if (inputAmount > amount1) inputAmount = amount1;
        
        // Calculate output
        outputAmount = FullMath.mulDiv(
            FullMath.mulDiv(inputAmount, sqrtLower, sqrtPrice),
            feeMultiplier,
            MAX_FEE_PIPS
        );
    }

    /// @notice Calculate optimal swap amount for double-sided liquidity deposit
    /// @dev Simulates crossing ticks to find optimal swap point, then uses analytic solution
    /// @param pool Pool configuration
    /// @param lowerTick Lower bound of the position
    /// @param upperTick Upper bound of the position
    /// @param amount0Target Desired amount of token0
    /// @param amount1Target Desired amount of token1
    /// @return inputAmount Optimal swap input amount
    /// @return outputAmount Expected swap output amount
    /// @return swapDir0to1 Direction: true for token0->token1, false for token1->token0
    /// @return sqrtPrice Final sqrt price after optimal swap
    function calculateSamePool(
        V4PoolInfo memory pool,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0Target,
        uint256 amount1Target
    ) internal view returns (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1, uint160 sqrtPrice) {
        if (amount0Target == 0 && amount1Target == 0) return (0, 0, false, 0);
        if (lowerTick >= upperTick || lowerTick < TickMath.MIN_TICK || upperTick > TickMath.MAX_TICK) {
            revert Invalid_Tick_Range();
        }
        SwapState memory state;
        // Populate state with liquidity, price, amounts, and fee
        {
            int24 tickValue;
            uint24 protoFee;
            uint24 lpFeeRate;
            (sqrtPrice, tickValue, protoFee, lpFeeRate) = pool.poolMgr.getSlot0(pool.poolIdentifier);
            if (sqrtPrice == 0) {
                revert Invalid_Pool();
            }
            uint128 liquidity = pool.poolMgr.getLiquidity(pool.poolIdentifier);
            int24 tickSpacing = pool.tickSpacing;
            uint256 feeRate = uint256(lpFeeRate + protoFee);
            assembly ("memory-safe") {
                mstore(state, liquidity) // offset 0x00
                mstore(add(state, 0x20), sqrtPrice) // offset 0x20
                mstore(add(state, 0x40), tickValue) // offset 0x40
                mstore(add(state, 0x60), amount0Target) // offset 0x60
                mstore(add(state, 0x80), amount1Target) // offset 0x80
                mstore(add(state, 0xe0), feeRate) // offset 0xe0
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
        swapDir0to1 = shouldSwap0to1(amount0Target, amount1Target, sqrtPrice, sqrtLower, sqrtUpper);
        // Simulate optimal swap by crossing ticks until direction reverses
        traverseTicks(TraverseTicksParams({pool: pool, state: state, sqrtPrice: sqrtPrice, swapDir0to1: swapDir0to1}));
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
                    sqrtPrice = calculateSwap1to0(state);
                    inputAmount = amount1Target - lastAmount1
                        + SqrtPriceMath.getAmount1Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, true).mulDiv(
                            MAX_FEE_PIPS, MAX_FEE_PIPS - state.feeRate
                        );
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
                    sqrtPrice = calculateSwap0to1(state);
                    inputAmount = amount0Target - lastAmount0
                        + SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, true).mulDiv(
                            MAX_FEE_PIPS, MAX_FEE_PIPS - state.feeRate
                        );
                }
                outputAmount = lastAmount1 - amount1Target
                    + SqrtPriceMath.getAmount1Delta(sqrtPrice, sqrtPriceLast, lastLiquidity, false);
            }
        }
    }

    /// @notice Find the next initialized tick in the given direction
    /// @dev Searches through tick bitmap words to find the next initialized tick
    /// @param params Search parameters including current tick, direction, and cached bitmap word
    /// @return result Next initialized tick and updated search state
    function _locateNextTick(NextInitializedTickParams memory params)
        private
        view
        returns (NextInitializedTickResult memory result)
    {
        bool searchLeft = params.swapDir0to1;
        int24 compressedTick = TickBitmap.compress(params.tickValue, params.tickSpacing);
        (int16 currentWordPosition, uint8 bitPosition) = TickBitmap.position(compressedTick);
        // Check cached word first if it's the current word
        if (params.wordPosition == currentWordPosition && params.tickBitmap != 0) {
            result.nextTick =
                _findTickInWord(params.tickBitmap, compressedTick, bitPosition, params.tickSpacing, searchLeft);
            if (result.nextTick != params.tickValue) {
                result.wordPosition = currentWordPosition;
                result.tickBitmap = params.tickBitmap;
                return result;
            }
        }
        // Start searching from cached position or current position
        int16 searchWordPosition = params.wordPosition == type(int16).min ? currentWordPosition : params.wordPosition;
        uint256 tickBitmap = params.tickBitmap;
        bool firstIteration = true;
        while (true) {
            if (searchLeft) {
                // Search left (decreasing ticks)
                // Limit search to 100 words to prevent excessive gas usage
                if (searchWordPosition < currentWordPosition - 100) {
                    result.nextTick = (compressedTick - int24(uint24(type(uint8).max))) * params.tickSpacing;
                    result.wordPosition = searchWordPosition;
                    result.tickBitmap = 0;
                    return result;
                }
                // Load bitmap word if needed
                if (searchWordPosition == currentWordPosition && firstIteration && tickBitmap == 0) {
                    tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, searchWordPosition);
                    firstIteration = false;
                } else if (searchWordPosition < currentWordPosition) {
                    searchWordPosition--;
                    tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, searchWordPosition);
                } else {
                    searchWordPosition--;
                    if (searchWordPosition >= currentWordPosition - 100) {
                        tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, searchWordPosition);
                    } else {
                        result.nextTick = (compressedTick - int24(uint24(type(uint8).max))) * params.tickSpacing;
                        result.wordPosition = searchWordPosition;
                        result.tickBitmap = 0;
                        return result;
                    }
                }
            } else {
                // Search right (increasing ticks)
                // Limit search to 100 words to prevent excessive gas usage
                if (searchWordPosition > currentWordPosition + 100) {
                    result.nextTick = (compressedTick + int24(uint24(type(uint8).max))) * params.tickSpacing;
                    result.wordPosition = searchWordPosition;
                    result.tickBitmap = 0;
                    return result;
                }
                // Load bitmap word if needed
                if (searchWordPosition == currentWordPosition && tickBitmap == 0) {
                    tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, searchWordPosition + 1);
                    searchWordPosition++;
                } else if (searchWordPosition <= currentWordPosition) {
                    searchWordPosition = currentWordPosition + 1;
                    tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, searchWordPosition);
                } else {
                    searchWordPosition++;
                    if (searchWordPosition <= currentWordPosition + 100) {
                        tickBitmap = params.pool.poolMgr.getTickBitmap(params.pool.poolIdentifier, searchWordPosition);
                    } else {
                        result.nextTick = (compressedTick + int24(uint24(type(uint8).max))) * params.tickSpacing;
                        result.wordPosition = searchWordPosition;
                        result.tickBitmap = 0;
                        return result;
                    }
                }
            }
            // If we found a word with initialized ticks, search within it
            if (tickBitmap != 0) {
                int24 searchCompressedTick = searchLeft ? compressedTick : compressedTick + 1;
                if (searchWordPosition != currentWordPosition) {
                    searchCompressedTick = int24(searchWordPosition) * 256;
                    if (!searchLeft) searchCompressedTick++;
                }
                uint8 searchBitPosition = uint8(uint24(searchCompressedTick) & 0xff);
                result.nextTick = _findTickInWord(
                    tickBitmap, searchCompressedTick, searchBitPosition, params.tickSpacing, searchLeft
                );
                result.wordPosition = searchWordPosition;
                result.tickBitmap = tickBitmap;
                return result;
            }
        }
    }

    /// @notice Find the next initialized tick within a single bitmap word
    /// @dev Uses bit manipulation to efficiently find the next set bit
    /// @param word The 256-bit tick bitmap word
    /// @param compressedTick The compressed tick value
    /// @param bitPosition Current bit position in the word
    /// @param tickSpacing The tick spacing
    /// @param searchLeft Whether to search left (true) or right (false)
    /// @return nextTick The next initialized tick
    function _findTickInWord(
        uint256 word,
        int24 compressedTick,
        uint8 bitPosition,
        int24 tickSpacing,
        bool searchLeft
    ) private pure returns (int24 nextTick) {
        unchecked {
            if (searchLeft) {
                // Mask all bits at or to the right of current position
                uint256 bitMask = type(uint256).max >> (uint256(type(uint8).max) - bitPosition);
                uint256 maskedWord = word & bitMask;
                if (maskedWord != 0) {
                    // Found initialized tick - find the most significant set bit
                    uint8 mostSigBit = BitMath.mostSignificantBit(maskedWord);
                    nextTick = (compressedTick - int24(uint24(bitPosition - mostSigBit))) * tickSpacing;
                } else {
                    // No initialized tick in this word
                    nextTick = (compressedTick - int24(uint24(bitPosition))) * tickSpacing;
                }
            } else {
                // Search right: start from next compressed tick
                compressedTick++;
                bitPosition = uint8(uint24(compressedTick) & 0xff);
                // Mask all bits at or to the left of current position
                uint256 bitMask = ~((1 << bitPosition) - 1);
                uint256 maskedWord = word & bitMask;
                if (maskedWord != 0) {
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
    function traverseTicks(TraverseTicksParams memory params) private view {
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
                shouldSwap0to1(
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
    function calculateSwap0to1(SwapState memory state) private pure returns (uint160 sqrtPriceFinal) {
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
                    // Ensure a > amount0Target to prevent overflow
                    if iszero(gt(a, amount0Target)) {
                        mstore(0, 0x20236808) // Math_Overflow error selector
                        revert(0x1c, 0x04)
                    }
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
                b -= cBase.mulDiv(FixedPoint96.Q96, sqrtUpper);
            }
            // Multiply a and c by 2 for quadratic formula
            assembly {
                a := shl(1, a)
                c := shl(1, c)
            }
        }
        // Solve quadratic: sqrtPriceFinal = (sqrt(b^2 + 4ac) + b) / 2a
        unchecked {
            uint256 num = Math.sqrt(b * b + a * c) + b;
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
    function calculateSwap1to0(SwapState memory state) private pure returns (uint160 sqrtPriceFinal) {
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
                // Ensure c > amount1Target to prevent overflow
                assembly ("memory-safe") {
                    if iszero(gt(c, amount1Target)) {
                        mstore(0, 0x20236808) // Math_Overflow error selector
                        revert(0x1c, 0x04)
                    }
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
        unchecked {
            uint256 num = Math.sqrt(b * b + a * c) + b;
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

    /// @notice Determine swap direction when price is within range
    /// @dev Compares liquidity requirements for token0 vs token1 at current price
    /// @param amount0Target Desired amount of token0
    /// @param amount1Target Desired amount of token1
    /// @param sqrtPrice Current sqrt price
    /// @param sqrtLower Lower bound sqrt price
    /// @param sqrtUpper Upper bound sqrt price
    /// @return true if should swap token0->token1, false otherwise
    function checkSwapDirectionInRange(
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
    function shouldSwap0to1(
        uint256 amount0Target,
        uint256 amount1Target,
        uint256 sqrtPrice,
        uint256 sqrtLower,
        uint256 sqrtUpper
    ) internal pure returns (bool) {
        // If price is below range, only need token0 (swap token1->token0)
        if (sqrtPrice <= sqrtLower) return false;
        // If price is above range, only need token1 (swap token0->token1)
        else if (sqrtPrice >= sqrtUpper) return true;
        // If price is in range, compare liquidity requirements
        else return checkSwapDirectionInRange(amount0Target, amount1Target, sqrtPrice, sqrtLower, sqrtUpper);
    }
}
