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
import {BaseTest} from "./utils/BaseTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract RevertHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

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
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(positionManager, poolManager, address(this), permit2); // Add all the necessary constructor arguments from the hook
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(flags);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

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

        // full range mint
        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        tickLower2 = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        tickUpper2 = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;

        // 2 tick range mint
        (token2Id,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
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
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testBasicAutoRange() public {
        hook.setPositionConfig(token3Id, RevertHook.PositionConfig({
            doAutoCompound: false,
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


    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
}