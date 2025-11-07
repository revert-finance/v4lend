// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {OptimalSwap} from "../src/OptimalSwap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

/// @title Test suite for OptimalSwap library (V4)
contract OptimalSwapTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager poolManager;
    OptimalSwap.V4PoolCallee poolCallee;
    
    // Standard test parameters
    uint160 constant SQRT_PRICE_1_0 = 79228162514264337593543950336; // sqrt(1.0) * 2^96
    uint24 constant DEFAULT_FEE = 3000; // 0.3% fee in hundredths of a bip
    int24 constant DEFAULT_TICK_SPACING = 60;
    
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // Deploy PoolManager
        poolManager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(0x4444))));
        
        // Create a pool key
        Currency currency0 = Currency.wrap(address(0x1000));
        Currency currency1 = Currency.wrap(address(0x2000));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        
        // Initialize the pool in PoolManager
        poolManager.initialize(poolKey, SQRT_PRICE_1_0);
        
        // Create pool callee struct
        poolCallee = OptimalSwap.V4PoolCallee({
            poolManager: poolManager,
            poolId: poolId,
            tickSpacing: DEFAULT_TICK_SPACING
        });
    }

    // ============ Edge Cases ============

    function test_getOptimalSwap_ZeroAmounts() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                0,
                0
            );
        
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(zeroForOne, false);
        assertEq(sqrtPriceX96, 0);
    }

    function test_getOptimalSwap_OnlyAmount0() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                1e18,
                0
            );
        
        assertTrue(amountIn >= 0);
        assertTrue(sqrtPriceX96 > 0);
    }

    function test_getOptimalSwap_OnlyAmount1() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                0,
                1e18
            );
        
        assertTrue(amountIn >= 0);
        assertTrue(sqrtPriceX96 > 0);
    }

    function test_getOptimalSwap_InvalidTickRange_LowerGreaterThanUpper() public {
        int24 tickLower = 60;
        int24 tickUpper = -60;
        
        vm.expectRevert(OptimalSwap.Invalid_Tick_Range.selector);
        OptimalSwap.getOptimalSwap(
            poolCallee,
            tickLower,
            tickUpper,
            1e18,
            1e18
        );
    }

    function test_getOptimalSwap_InvalidTickRange_LowerTooSmall() public {
        int24 tickLower = TickMath.MIN_TICK - 1;
        int24 tickUpper = 60;
        
        vm.expectRevert(OptimalSwap.Invalid_Tick_Range.selector);
        OptimalSwap.getOptimalSwap(
            poolCallee,
            tickLower,
            tickUpper,
            1e18,
            1e18
        );
    }

    function test_getOptimalSwap_InvalidTickRange_UpperTooLarge() public {
        int24 tickLower = -60;
        int24 tickUpper = TickMath.MAX_TICK + 1;
        
        vm.expectRevert(OptimalSwap.Invalid_Tick_Range.selector);
        OptimalSwap.getOptimalSwap(
            poolCallee,
            tickLower,
            tickUpper,
            1e18,
            1e18
        );
    }

    // ============ Swap Direction Tests ============

    function test_getOptimalSwap_PriceBelowRange_ShouldSwapOneForZero() public {
        // Create a new pool with price below the range
        Currency currency0 = Currency.wrap(address(0x3000));
        Currency currency1 = Currency.wrap(address(0x4000));
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        uint160 sqrtPriceBelow = TickMath.getSqrtPriceAtTick(-120);
        poolManager.initialize(newPoolKey, sqrtPriceBelow);
        
        OptimalSwap.V4PoolCallee memory newPoolCallee = OptimalSwap.V4PoolCallee({
            poolManager: poolManager,
            poolId: newPoolKey.toId(),
            tickSpacing: DEFAULT_TICK_SPACING
        });
        
        int24 tickLower = -60;
        int24 tickUpper = 60;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                newPoolCallee,
                tickLower,
                tickUpper,
                1e18,
                1e18
            );
        
        // When price is below range, we should swap token1 for token0 (zeroForOne = false)
        assertFalse(zeroForOne, "Should swap oneForZero when price is below range");
        assertTrue(sqrtPriceX96 > 0);
    }

    function test_getOptimalSwap_PriceAboveRange_ShouldSwapZeroForOne() public {
        // Create a new pool with price above the range
        Currency currency0 = Currency.wrap(address(0x5000));
        Currency currency1 = Currency.wrap(address(0x6000));
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        uint160 sqrtPriceAbove = TickMath.getSqrtPriceAtTick(120);
        poolManager.initialize(newPoolKey, sqrtPriceAbove);
        
        OptimalSwap.V4PoolCallee memory newPoolCallee = OptimalSwap.V4PoolCallee({
            poolManager: poolManager,
            poolId: newPoolKey.toId(),
            tickSpacing: DEFAULT_TICK_SPACING
        });
        
        int24 tickLower = -60;
        int24 tickUpper = 60;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                newPoolCallee,
                tickLower,
                tickUpper,
                1e18,
                1e18
            );
        
        // When price is above range, we should swap token0 for token1 (zeroForOne = true)
        assertTrue(zeroForOne, "Should swap zeroForOne when price is above range");
        assertTrue(sqrtPriceX96 > 0);
    }

    function test_getOptimalSwap_PriceInRange() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                1e18,
                1e18
            );
        
        assertTrue(sqrtPriceX96 > 0);
        // Direction depends on the ratio of amounts
    }

    // ============ isZeroForOne Tests ============

    function test_isZeroForOne_PriceBelowRange() public pure {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-120);
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(60);
        
        bool result = OptimalSwap.isZeroForOne(
            1e18,
            1e18,
            sqrtPriceX96,
            sqrtRatioLowerX96,
            sqrtRatioUpperX96
        );
        
        assertFalse(result, "Should return false when price is below range");
    }

    function test_isZeroForOne_PriceAboveRange() public pure {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(120);
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(60);
        
        bool result = OptimalSwap.isZeroForOne(
            1e18,
            1e18,
            sqrtPriceX96,
            sqrtRatioLowerX96,
            sqrtRatioUpperX96
        );
        
        assertTrue(result, "Should return true when price is above range");
    }

    // ============ Optimal Swap Calculation Tests ============

    function test_getOptimalSwap_BalancedAmounts() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                amount0,
                amount1
            );
        
        assertTrue(amountIn >= 0);
        assertTrue(amountOut >= 0);
        assertTrue(sqrtPriceX96 > 0);
        
        // Verify final price is within the range
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        assertGe(sqrtPriceX96, sqrtRatioLowerX96);
        assertLe(sqrtPriceX96, sqrtRatioUpperX96);
    }

    function test_getOptimalSwap_WideRange() public view {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                1e18,
                1e18
            );
        
        assertTrue(amountIn >= 0);
        assertTrue(amountOut >= 0);
        assertTrue(sqrtPriceX96 > 0);
        
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        assertGe(sqrtPriceX96, sqrtRatioLowerX96);
        assertLe(sqrtPriceX96, sqrtRatioUpperX96);
    }

    function test_getOptimalSwap_NarrowRange() public view {
        int24 tickLower = -10;
        int24 tickUpper = 10;
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            OptimalSwap.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                1e18,
                1e18
            );
        
        assertTrue(amountIn >= 0);
        assertTrue(amountOut >= 0);
        assertTrue(sqrtPriceX96 > 0);
        
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        assertGe(sqrtPriceX96, sqrtRatioLowerX96);
        assertLe(sqrtPriceX96, sqrtRatioUpperX96);
    }
}
