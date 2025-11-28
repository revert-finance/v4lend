// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionInfoLibrary, PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {RevertHook} from "../src/RevertHook.sol";
import {V4Oracle} from "../src/V4Oracle.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract RevertHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey nonHookedPoolKey;
    PoolKey poolKey;

    RevertHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    uint256 token2Id;
    int24 tickLower2;
    int24 tickUpper2;

    uint256 token3Id;
    int24 tickLower3;
    int24 tickUpper3;

    int24 tickStart;

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | 
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );


        // Deploy V4Oracle
        V4Oracle v4Oracle = new V4Oracle(
            positionManager,
            Currency.unwrap(currency0),
            0x000000000000000000000000000000000000dEaD
        );

        bytes memory constructorArgs = abi.encode(address(this), permit2, v4Oracle); // Add all the necessary constructor arguments from the hook
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(flags);

        // Create the pool
        nonHookedPoolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(nonHookedPoolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        tickStart = TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_1);

        console.log("tickStart", tickStart);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );
    
        // full range mint (non-hooked pool)
        (tokenId,) = positionManager.mint(
            nonHookedPoolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    
        // full range mint
        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        console.log("tokenId liquidity", positionManager.getPositionLiquidity(tokenId));

        tickLower2 = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        tickUpper2 = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;

        // 2 tick range mint
        (token2Id,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            liquidityAmount,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        tickLower3 = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        tickUpper3 = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;

        // 2 tick range mint - smaller liquidity
        (token3Id,) = positionManager.mint(
            poolKey,
            tickLower3,
            tickUpper3,
            liquidityAmount / 10,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testBasicAutoRange() public {
        hook.setPositionConfig(token3Id, RevertHook.PositionConfig({
            doAutoCompound: false,
            doAutoLend: false,
            doAutoRange: true,
            doAutoExit: false,
            autoExitTickLower: 0,
            autoExitTickUpper: 0,
            autoExitSwapLower: false,
            autoExitSwapUpper: false,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(hook)
        }));
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        // Assert that token3Id position has > 0 liquidity after swap (out of range)
        uint128 token3Liquidity = positionManager.getPositionLiquidity(token3Id);
        assertGt(token3Liquidity, 0, "token2Id should have > 0 liquidity");

        // Store initial state
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        
        // Get initial position info
        (, PositionInfo posInfoBefore) = positionManager.getPoolAndPositionInfo(token3Id);
        int24 initialTickLower = posInfoBefore.tickLower();
        int24 initialTickUpper = posInfoBefore.tickUpper();
        
        // Perform swap to activate auto range
        uint256 amountIn = 7e17;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
                
        // Assert swap was successful
        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "Swap should consume amountIn token0");
        
        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        // After auto-range execution, verify the old position has 0 liquidity
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "token3Id should have 0 liquidity after auto-range");

        // Verify a new position was minted
        {
            uint256 nextTokenIdAfter = positionManager.nextTokenId();
            assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "A new position should be minted");
        }

        // Get the new position info and verify properties
        {
            uint256 newTokenId = nextTokenIdBefore;
            (, PositionInfo posInfoNew) = positionManager.getPoolAndPositionInfo(newTokenId);
            int24 newTickLower = posInfoNew.tickLower();
            int24 newTickUpper = posInfoNew.tickUpper();

            // Verify new position has the expected tick range
            assertEq(newTickUpper - newTickLower, 120, "New position tick range should be 120");

            // Verify new position has liquidity > 0
            assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "New position should have liquidity > 0");

            // Verify new position is owned by the same owner
            assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(this), 
                "New position should be owned by the same address");

            // Verify current tick is within the new position's range
            assertTrue(currentTick >= newTickLower && currentTick <= newTickUpper, 
                "Current tick should be within the new position's range");

            // Verify the old position's range is different from the new position's range
            assertTrue(newTickLower != initialTickLower || newTickUpper != initialTickUpper, 
                "New position should have a different range than the old position");
        }

        // Verify hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0 after auto-range");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1 after auto-range");
    }

    function testBasicAutoCompound() public {

        hook.setPositionConfig(token2Id, RevertHook.PositionConfig({
            doAutoCompound: true,
            doAutoLend: false,
            doAutoRange: false,
            doAutoExit: false,
            autoExitTickLower: 0,
            autoExitTickUpper: 0,
            autoExitSwapLower: false,
            autoExitSwapUpper: false,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(hook)
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity after swap (out of range)
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Perform swaps (in both directions) to generate some fees
        uint256 amountIn = 1e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        // ------------------- //

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;

        hook.autoCompound(params);
   
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2LiquidityAfter, token2Liquidity, "token2Id should have more liquidity");

        // Verify hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0 after auto-compound");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1 after auto-compound");
    }

    function testBasicAutoExit() public {

        hook.setPositionConfig(token2Id, RevertHook.PositionConfig({
            doAutoCompound: false,
            doAutoLend: false,
            doAutoRange: false,
            doAutoExit: true,
            autoExitTickLower: tickLower2,
            autoExitTickUpper: tickUpper2,
            autoExitSwapLower: false,
            autoExitSwapUpper: false,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(hook)
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity after swap (out of range)
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Perform a swap to activate auto exit
        uint256 amountIn = 7e17;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), -int256(amountIn));

        console.log("swapDelta.amount0()", swapDelta.amount0());
        console.log("swapDelta.amount1()", swapDelta.amount1());

        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        assertTrue(currentTick < tickLower2, "token2Id position should be out of range (currentTick < tickLower2)");

        token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2Liquidity, 0, "token2Id should have 0 liquidity");

        // Verify hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0 after auto-exit");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1 after auto-exit");
    }

    function testBasicAutoExit_NonHookedPool() public {

        hook.setPositionConfig(token2Id, RevertHook.PositionConfig({
            doAutoCompound: false,
            doAutoLend: false,
            doAutoRange: false,
            doAutoExit: true,
            autoExitTickLower: tickLower2,
            autoExitTickUpper: tickUpper2,
            autoExitSwapLower: true, // Enable swap when exiting at lower bound
            autoExitSwapUpper: false,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(address(0)) // Use nonHookedPool for swapping
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity after swap (out of range)
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Record initial state of nonHookedPool before swap
        PoolId nonHookedPoolId = nonHookedPoolKey.toId();
        (uint160 sqrtPriceX96NonHookedBefore, int24 tickNonHookedBefore,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolId);
        console.log("NonHookedPool sqrtPrice BEFORE swap:", sqrtPriceX96NonHookedBefore);
        console.log("NonHookedPool tick BEFORE swap:", tickNonHookedBefore);

        // Perform a swap to activate auto exit
        uint256 amountIn = 7e17;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), -int256(amountIn));

        console.log("swapDelta.amount0()", swapDelta.amount0());
        console.log("swapDelta.amount1()", swapDelta.amount1());

        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        assertTrue(currentTick < tickLower2, "token2Id position should be out of range (currentTick < tickLower2)");

        token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2Liquidity, 0, "token2Id should have 0 liquidity");

        // Verify hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0 after auto-exit");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1 after auto-exit");
        
        // Verify that the swap happened in the nonHookedPool by checking its state
        // The nonHookedPool should be initialized and have a price
        (uint160 sqrtPriceX96NonHookedAfter, int24 tickNonHookedAfter,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolId);
        assertGt(sqrtPriceX96NonHookedAfter, 0, "NonHookedPool should be initialized and have a price");
        
        console.log("NonHookedPool sqrtPrice AFTER swap:", sqrtPriceX96NonHookedAfter);
        console.log("NonHookedPool tick AFTER swap:", tickNonHookedAfter);
        
        // Verify the price changed in the nonHookedPool (proving swap happened there)
        assertTrue(
            sqrtPriceX96NonHookedAfter != sqrtPriceX96NonHookedBefore,
            "NonHookedPool price should have changed after swap"
        );
        assertTrue(
            tickNonHookedAfter != tickNonHookedBefore,
            "NonHookedPool tick should have changed after swap"
        );
        
        console.log("Price change:", 
            sqrtPriceX96NonHookedAfter > sqrtPriceX96NonHookedBefore ? "increased" : "decreased");
        console.log("Tick change:", int256(tickNonHookedAfter) - int256(tickNonHookedBefore));
        
        // Verify the nonHookedPool has liquidity (from the initial mint in setUp)
        uint128 nonHookedLiquidity = poolManager.getLiquidity(nonHookedPoolId);
        assertGt(nonHookedLiquidity, 0, "NonHookedPool should have liquidity");
        console.log("NonHookedPool liquidity:", nonHookedLiquidity);
    }


    function testSwapAllLiquidityNarrowRange() public {
        // Create a new pool with a different fee to ensure it's separate
        PoolKey memory newPoolKey = PoolKey(currency0, currency1, 0, 10, IHooks(address(0)));
        PoolId newPoolId = newPoolKey.toId();
        
        // Initialize the new pool
        poolManager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Get initial tick
        int24 initialTick = TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_1);
        console.log("Initial tick:", initialTick);
        
        // Calculate liquidity amounts for the narrow range
        uint128 liquidityAmount = 50e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(-10),
            TickMath.getSqrtPriceAtTick(10),
            liquidityAmount
        );
        
        console.log("Amount0 for liquidity:", amount0Expected);
        console.log("Amount1 for liquidity:", amount1Expected);
        
        // Mint the narrow range position
        (uint256 newTokenId,) = positionManager.mint(
            newPoolKey,
            -10,
            10,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        
        console.log("Minted position tokenId:", newTokenId);
        
        // Get initial pool state
        (uint160 sqrtPriceBefore, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, newPoolId);
        console.log("Pool sqrtPrice before swaps:", sqrtPriceBefore);
        console.log("Pool tick before swaps:", tickBefore);
        
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
                amountIn: amount0Expected * 101 / 100,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: newPoolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        
        console.log("swapDelta.amount0()", swapDelta.amount0());
        console.log("swapDelta.amount1()", swapDelta.amount1());
        
        // Get final pool state
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, newPoolId);
        console.log("Final sqrtPrice:", sqrtPriceAfter);
        console.log("Final tick:", tickAfter);
        
        // Verify the tick changed
        assertTrue(tickAfter != tickBefore, "Tick should have changed after swapping");
        
        // Verify we moved in the expected direction (swapping token0 -> token1 decreases price/tick)
        assertTrue(tickAfter < tickBefore, "Tick should have decreased after swapping token0 -> token1");
        
        // Verify we're at or below the lower bound of the range
        assertTrue(tickAfter <= tickLower, "Final tick should be at or below the lower bound of the range");
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
}