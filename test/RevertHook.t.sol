// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

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
import {RevertHookConfig} from "../src/RevertHookConfig.sol";
import {MockV4Oracle} from "./utils/MockV4Oracle.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC4626Vault} from "./utils/MockERC4626Vault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    MockERC4626Vault vault0;
    MockERC4626Vault vault1;

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

    address protocolFeeRecipient;

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | 
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );


        // Deploy V4Oracle
        MockV4Oracle v4Oracle = new MockV4Oracle(
            positionManager
        );

        protocolFeeRecipient = makeAddr("protocolFeeRecipient");

        bytes memory constructorArgs = abi.encode(protocolFeeRecipient, permit2, v4Oracle); // Add all the necessary constructor arguments from the hook
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(flags);

        // Deploy MockERC4626Vault for both currencies
        vault0 = new MockERC4626Vault(
            IERC20(Currency.unwrap(currency0)),
            "Vault Token0",
            "vT0"
        );
        vault1 = new MockERC4626Vault(
            IERC20(Currency.unwrap(currency1)),
            "Vault Token1",
            "vT1"
        );

        // Set vaults in hook using the setter function
        hook.setAutoLendVault(Currency.unwrap(currency0), vault0);
        hook.setAutoLendVault(Currency.unwrap(currency1), vault1);
        
        // Verify vaults are set correctly
        assertEq(address(hook.autoLendVaults(Currency.unwrap(currency0))), address(vault0), "Vault0 should be set");
        assertEq(address(hook.autoLendVaults(Currency.unwrap(currency1))), address(vault1), "Vault1 should be set");

        // Create the pool
        nonHookedPoolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(nonHookedPoolKey, Constants.SQRT_PRICE_1_1);

        // Set pool key for mock v4Oracle
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), poolKey);

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
        hook.setPositionConfig(token3Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_RANGE,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,

            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0
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

    /// @notice Helper function to set up auto compound test: configures position, generates fees
    /// @param autoCompoundMode The auto compound mode to test
    /// @return token2Liquidity The initial liquidity of the position
    function _setupAutoCompoundTest(RevertHook.AutoCompoundMode autoCompoundMode) internal returns (uint128 token2Liquidity) {
        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_COMPOUND_ONLY,
            autoCompoundMode: autoCompoundMode,
            isRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity
        token2Liquidity = positionManager.getPositionLiquidity(token2Id);
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

        vm.warp(block.timestamp + 600);
    }

    /// @notice Helper struct to hold balance snapshots before autoCompound
    struct BalanceSnapshot {
        uint256 executorBalance0;
        uint256 executorBalance1;
        uint256 ownerBalance0;
        uint256 ownerBalance1;
        uint256 protocolFeeRecipientBalance0;
        uint256 protocolFeeRecipientBalance1;
    }

    /// @notice Helper function to record balances before autoCompound
    /// @return snapshot The balance snapshot
    function _recordBalancesBeforeAutoCompound() internal view returns (BalanceSnapshot memory snapshot) {
        address executor = address(this);
        address feeRecipient = hook.protocolFeeRecipient();
        address owner = address(this);
        
        snapshot.executorBalance0 = currency0.balanceOf(executor);
        snapshot.executorBalance1 = currency1.balanceOf(executor);
        snapshot.ownerBalance0 = currency0.balanceOf(owner);
        snapshot.ownerBalance1 = currency1.balanceOf(owner);
        snapshot.protocolFeeRecipientBalance0 = currency0.balanceOf(feeRecipient);
        snapshot.protocolFeeRecipientBalance1 = currency1.balanceOf(feeRecipient);
    }

    /// @notice Helper function to verify hook has no leftover balances
    function _verifyNoLeftoverBalances(string memory context) internal view {
        assertEq(currency0.balanceOf(address(hook)), 0, string.concat("Hook should have 0 balance of currency0 after ", context));
        assertEq(currency1.balanceOf(address(hook)), 0, string.concat("Hook should have 0 balance of currency1 after ", context));
    }

    function testBasicAutoCompound() public {
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookConfig.AutoCompoundMode.AUTO_COMPOUND);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCompound();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCompound(params);
   
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2LiquidityAfter, token2Liquidity, "token2Id should have more liquidity");

        _verifyNoLeftoverBalances("auto-compound");

        // Verify executor received fees
        uint256 executorBalance0After = currency0.balanceOf(address(this));
        uint256 executorBalance1After = currency1.balanceOf(address(this));
        uint256 executorFee0 = executorBalance0After - before.executorBalance0;
        uint256 executorFee1 = executorBalance1After - before.executorBalance1;
        assertGt(executorFee0 + executorFee1, 0, "Executor should have received fees");

        // Verify protocolFeeRecipient received fees
        address feeRecipient = hook.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0 + protocolFee1, 0, "ProtocolFeeRecipient should have received fees");
    }

    function testBasicAutoHarvestToken0() public {
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookConfig.AutoCompoundMode.HARVEST_TOKEN_0);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCompound();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCompound(params);
   
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        // Position liquidity should NOT increase (unlike auto-compound)
        assertEq(token2LiquidityAfter, token2Liquidity, "token2Id liquidity should remain the same after harvest");

        _verifyNoLeftoverBalances("harvest");

        // Verify executor received fees in token0 (reward for harvesting)
        uint256 executorBalance0After = currency0.balanceOf(address(this));
        uint256 executorBalance1After = currency1.balanceOf(address(this));
        uint256 executorFee0 = executorBalance0After - before.executorBalance0;
        uint256 executorFee1 = executorBalance1After - before.executorBalance1;
        assertGt(executorFee0, 0, "Executor should have received fees in token0");
        assertEq(executorFee1, 0, "Executor should not have received fees in token1 (harvested to token0)");

        // Verify owner received harvested token0 (after fees)
        uint256 ownerBalance0After = currency0.balanceOf(address(this));
        uint256 ownerBalance1After = currency1.balanceOf(address(this));
        uint256 ownerReceived0 = ownerBalance0After - before.ownerBalance0;
        uint256 ownerReceived1 = ownerBalance1After - before.ownerBalance1;
        assertGt(ownerReceived0, 0, "Owner should have received harvested token0");
        assertEq(ownerReceived1, 0, "Owner should not have received token1 (all swapped to token0)");

        // Verify protocolFeeRecipient received fees in token0
        address feeRecipient = hook.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0, 0, "ProtocolFeeRecipient should have received fees in token0");
        assertGt(protocolFee1, 0, "ProtocolFeeRecipient should have received fees in token1");
    }

    function testBasicAutoHarvestToken1() public {
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookConfig.AutoCompoundMode.HARVEST_TOKEN_1);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCompound();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCompound(params);
   
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        // Position liquidity should NOT increase (unlike auto-compound)
        assertEq(token2LiquidityAfter, token2Liquidity, "token2Id liquidity should remain the same after harvest");

        _verifyNoLeftoverBalances("harvest");

        // Verify executor received fees in token1 (reward for harvesting)
        uint256 executorBalance0After = currency0.balanceOf(address(this));
        uint256 executorBalance1After = currency1.balanceOf(address(this));
        uint256 executorFee0 = executorBalance0After - before.executorBalance0;
        uint256 executorFee1 = executorBalance1After - before.executorBalance1;
        assertGt(executorFee1, 0, "Executor should have received fees in token1");
        assertEq(executorFee0, 0, "Executor should not have received fees in token0 (harvested to token1)");

        // Verify owner received harvested token1 (after fees)
        uint256 ownerBalance0After = currency0.balanceOf(address(this));
        uint256 ownerBalance1After = currency1.balanceOf(address(this));
        uint256 ownerReceived0 = ownerBalance0After - before.ownerBalance0;
        uint256 ownerReceived1 = ownerBalance1After - before.ownerBalance1;
        assertGt(ownerReceived1, 0, "Owner should have received harvested token1");
        assertEq(ownerReceived0, 0, "Owner should not have received token0 (all swapped to token1)");

        // Verify protocolFeeRecipient received fees in token1
        address feeRecipient = hook.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0, 0, "ProtocolFeeRecipient should have received fees in token0");
        assertGt(protocolFee1, 0, "ProtocolFeeRecipient should have received fees in token1");
    }

    function testBasicAutoExit() public {

        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
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

    function testAutoExitAndAutoRange() public {

        // Configure AUTO_EXIT_AND_AUTO_RANGE mode
        hook.setPositionConfig(token3Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT_AND_AUTO_RANGE,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false, // Use absolute ticks
            autoExitTickLower: type(int24).min, // Set to min so it never triggers on lower side
            autoExitTickUpper: tickUpper3 + poolKey.tickSpacing * 3,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0
        }));

        // approve all positions to the hook
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        // Verify initial state
        uint128 initialLiquidity = positionManager.getPositionLiquidity(token3Id);
        assertGt(initialLiquidity, 0, "Position should have liquidity initially");

        // Get initial position info
        (, PositionInfo posInfoBefore) = positionManager.getPoolAndPositionInfo(token3Id);
        int24 initialTickLower = posInfoBefore.tickLower();
        int24 initialTickUpper = posInfoBefore.tickUpper();
        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        // ===== Test 1: Trigger Auto Range (should NOT trigger auto exit) =====
        console.log("=== Test 1: Trigger Auto Range ===");
        
        // Swap down to trigger auto range on lower side (but not hit exit tick)
        uint256 amountIn = 2e17;
        BalanceDelta swapDelta1 = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true, // Swap token0 -> token1 (price goes down)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        assertEq(int256(swapDelta1.amount0()), -int256(amountIn), "Swap should consume amountIn token0");

        // Get current tick after swap
        (, int24 currentTickAfterRange,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after range swap", currentTickAfterRange);

        // Verify auto range happened: old position has 0 liquidity, new position was created
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Old position should have 0 liquidity after auto-range");
        
        uint256 nextTokenIdAfter = positionManager.nextTokenId();
        assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "A new position should be minted after auto-range");

        // Get the new position info
        uint256 newTokenId = nextTokenIdBefore;
        (, PositionInfo posInfoNew) = positionManager.getPoolAndPositionInfo(newTokenId);
        int24 newTickLower = posInfoNew.tickLower();
        int24 newTickUpper = posInfoNew.tickUpper();

        // Verify new position has different range
        assertTrue(newTickLower != initialTickLower || newTickUpper != initialTickUpper, 
            "New position should have a different range than the old position");
        
        // Verify new position has liquidity
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "New position should have liquidity > 0");

        // Verify current tick is within the new position's range
        assertTrue(currentTickAfterRange >= newTickLower && currentTickAfterRange <= newTickUpper, 
            "Current tick should be within the new position's range");

        // Verify hook has no leftover balances
        _verifyNoLeftoverBalances("auto-range");

        // ===== Test 2: Trigger Auto Exit (should hit the absolute exit tick) =====
        console.log("=== Test 2: Trigger Auto Exit ===");
        
        // Swap up to hit the absolute exit tick on the upper side
        // We need to swap enough to reach the exit tick
        uint256 exitAmountIn = 10e17;
        BalanceDelta swapDelta2 = swapRouter.swapExactTokensForTokens({
            amountIn: exitAmountIn,
            amountOutMin: 0,
            zeroForOne: false, // Swap token1 -> token0 (price goes up)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // Get current tick after swap
        (, int24 currentTickAfterExit,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after exit swap", currentTickAfterExit);
        //console.log("autoExitTickUpper", autoExitTickUpper);
        console.log("newTickUpper", newTickUpper);

        // Verify auto exit happened: position should have 0 liquidity
        // The exit triggers when the price crosses the exit tick during the swap
        uint128 finalLiquidity = positionManager.getPositionLiquidity(newTokenId);
        assertEq(finalLiquidity, 0, "Position should have 0 liquidity after auto-exit");
        
        // Verify we crossed the exit tick (current tick should be at or above it)
        //assertTrue(currentTickAfterExit >= autoExitTickUpper, "Current tick should be at or above the exit tick after swap");

        // Verify hook has no leftover balances
        _verifyNoLeftoverBalances("auto-exit");
    }

    function testBasicAutoExit_NonHookedPool() public {

        hook.setGeneralConfig(token2Id, RevertHookConfig.GeneralConfig({
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(address(0)),
            maxPriceImpact0: 0,
            maxPriceImpact1: 0
        }));

        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
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

    function testAutoExit_NotApproved() public {
        // Set up autoExit config for token2Id
        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }));

        // DO NOT approve the position to the hook - this is the key difference
        // IERC721(address(positionManager)).approve(address(hook), token2Id); // COMMENTED OUT

        // Assert that token2Id position has > 0 liquidity before swap
        uint128 token2LiquidityBefore = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2LiquidityBefore, 0, "token2Id should have > 0 liquidity before swap");

        // Record logs to check for HookModifyLiquiditiesFailed event
        vm.recordLogs();

        // Perform a swap to trigger auto exit attempt
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

        assertEq(int256(swapDelta.amount0()), -int256(amountIn));

        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertTrue(currentTick < tickLower2, "token2Id position should be out of range (currentTick < tickLower2)");

        // Verify that the position still has liquidity (autoExit failed due to lack of approval)
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2LiquidityAfter, 0, "token2Id should still have liquidity because autoExit failed without approval");
        assertEq(token2LiquidityAfter, token2LiquidityBefore, "Liquidity should remain unchanged since autoExit failed");

        // Verify hook contract has no leftover token balances (since autoExit didn't execute)
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");

        // Check that HookModifyLiquiditiesFailed event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;
        bytes32 eventSignature = keccak256("HookModifyLiquiditiesFailed(bytes,bytes[],bytes)");
        
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSignature && logs[i].emitter == address(hook)) {
                eventFound = true;
                break;
            }
        }
        
        assertTrue(eventFound, "HookModifyLiquiditiesFailed event should have been emitted");
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

    function testBasicAutoLend() public {

        // set higher max ticks (10%) for mock oracle to avoid testing oracle price validation issues
        hook.setMaxTicksFromOracle(1000);

        // Create a new position for autolend testing
        int24 testTickLower = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        int24 testTickUpper = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;
        
        uint128 liquidityAmount = 50e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(testTickLower),
            TickMath.getSqrtPriceAtTick(testTickUpper),
            liquidityAmount
        );

        // Mint a new position
        (uint256 autolendTokenId,) = positionManager.mint(
            poolKey,
            testTickLower,
            testTickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Configure autolend for this position
        hook.setPositionConfig(autolendTokenId, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_LEND,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 60
        }));

        // for auto lend where new positions may be created we need to approve all positions to the hook
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        // Verify initial state
        uint128 initialLiquidity = positionManager.getPositionLiquidity(autolendTokenId);
        assertGt(initialLiquidity, 0, "Position should have liquidity initially");

        (,,, address autoLendToken, uint256 autoLendShares,,) = hook.positionStates(autolendTokenId);

        assertEq(autoLendShares, 0, "Should have no autolend shares initially");
        assertEq(autoLendToken, address(0), "Should have no autolend token initially");

        // Get initial vault balances
        uint256 vault0BalanceBefore = vault0.totalAssets();
        uint256 vault1BalanceBefore = vault1.totalAssets();

        // ===== Test 1: Currency0 Deposit (swap down) =====
        console.log("=== Test 1: Currency0 Deposit ===");
        uint256 swapAmount = 20e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // Swap token0 -> token1 (price goes down)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // Verify currency0 deposit was triggered
        (,,,autoLendToken, autoLendShares,,) = hook.positionStates(autolendTokenId);
        assertGt(autoLendShares, 0, "Should have autolend shares after currency0 deposit");
        assertEq(autoLendToken, Currency.unwrap(currency0), "Should have currency0 as autolend token");
        assertGt(vault0.totalAssets(), vault0BalanceBefore, "Vault0 should have received assets");
        
        uint128 liquidityAfterCurrency0Deposit = positionManager.getPositionLiquidity(autolendTokenId);
        assertEq(liquidityAfterCurrency0Deposit, 0, "Position liquidity should be 0 after currency0 deposit");

        // ===== Test 2: Currency0 Withdraw (swap back up) =====
        console.log("=== Test 2: Currency0 Withdraw ===");
        vault0BalanceBefore = vault0.totalAssets();
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // Swap token1 -> token0 (price goes up)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // get the token id of the new position
        autolendTokenId = positionManager.nextTokenId() - 1;

        // Verify currency0 withdraw was triggered
        (,,,autoLendToken, autoLendShares,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendShares, 0, "Should have no autolend shares after currency0 withdraw");
        assertEq(autoLendToken, address(0), "Should have no autolend token after withdraw");
        assertLt(vault0.totalAssets(), vault0BalanceBefore, "Vault0 should have less assets after withdraw");
        
        uint128 liquidityAfterCurrency0Withdraw = positionManager.getPositionLiquidity(autolendTokenId);
        assertGt(liquidityAfterCurrency0Withdraw, liquidityAfterCurrency0Deposit, 
            "Position liquidity should increase after currency0 withdraw");

        // ===== Test 3: Currency1 Deposit (swap up more) =====
        console.log("=== Test 3: Currency1 Deposit ===");
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // Swap token1 -> token0 (price goes up)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // log current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        // Verify currency1 deposit was triggered
        (,,,autoLendToken, autoLendShares,,) = hook.positionStates(autolendTokenId);
        assertGt(autoLendShares, 0, "Should have autolend shares after currency1 deposit");
        assertEq(autoLendToken, Currency.unwrap(currency1), "Should have currency1 as autolend token");
        assertGt(vault1.totalAssets(), vault1BalanceBefore, "Vault1 should have received assets");
        
        uint128 liquidityAfterCurrency1Deposit = positionManager.getPositionLiquidity(autolendTokenId);
        assertEq(liquidityAfterCurrency1Deposit, 0, 
            "Position liquidity be 0 after currency1 deposit");

        vault1.simulateYield(1000); // 10% yield

        // ===== Test 4: Currency1 Withdraw (swap back down) =====
        console.log("=== Test 4: Currency1 Withdraw ===");
        vault1BalanceBefore = vault1.totalAssets();
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // Swap token0 -> token1 (price goes down)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // get the token id of the new position
        autolendTokenId = positionManager.nextTokenId() - 1;

        // Verify currency1 withdraw was triggered
        (,,,autoLendToken, autoLendShares,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendShares, 0, "Should have no autolend shares after currency1 withdraw");
        assertEq(autoLendToken, address(0), "Should have no autolend token after withdraw");
        assertLt(vault1.totalAssets(), vault1BalanceBefore, "Vault1 should have less assets after withdraw");

        assertGt(positionManager.getPositionLiquidity(autolendTokenId), liquidityAfterCurrency1Deposit, 
            "Position liquidity should increase after currency1 withdraw");

        // ===== Test 5: Currency0 Deposit Second Time (swap down again) =====
        console.log("=== Test 5: Currency0 Deposit Second Time ===");
        vault0BalanceBefore = vault0.totalAssets();
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount * 15000 / 100,
            amountOutMin: 0,
            zeroForOne: true, // Swap token0 -> token1 (price goes down)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        (,,,autoLendToken, autoLendShares,,) = hook.positionStates(autolendTokenId);

        // Verify currency0 deposit was triggered again
        assertGt(autoLendShares, 0, "Should have autolend shares after second currency0 deposit");
        assertEq(autoLendToken, Currency.unwrap(currency0), "Should have currency0 as autolend token again");
        assertGt(vault0.totalAssets(), vault0BalanceBefore, "Vault0 should have received assets in second deposit");
        
        assertEq(positionManager.getPositionLiquidity(autolendTokenId), 0, 
            "Position liquidity be 0 after second currency0 deposit");

        // Final verification: hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testPriceImpactLimitPartialSwap() public {
        // Set up a position with strict price impact limits (0.5% = 50 bps)
        // This limits how much the price can move during the internal swap
        hook.setGeneralConfig(token2Id, RevertHookConfig.GeneralConfig({
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(hook),
            maxPriceImpact0: 50, // 0.5% max price impact for token0 -> token1
            maxPriceImpact1: 50  // 0.5% max price impact for token1 -> token0
        }));

        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Perform a large swap to activate auto exit
        // The internal hook swap will be limited by price impact, resulting in a partial swap
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // The position's liquidity should be removed (auto-exit triggered)
        // The internal swap executed partially within price impact limits
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2LiquidityAfter, 0, "Position liquidity should be 0 after auto-exit");

        // Verify hook contract has no leftover token balances
        _verifyNoLeftoverBalances("price impact limit partial swap");
    }

    function testPriceImpactLimitAllowsSmallSlippage() public {
        // Set up a position with generous price impact limits (50% = 5000 bps)
        hook.setGeneralConfig(token2Id, RevertHookConfig.GeneralConfig({
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(hook),
            maxPriceImpact0: 5000, // 50% max price impact for token0 -> token1
            maxPriceImpact1: 5000  // 50% max price impact for token1 -> token0
        }));

        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Perform a swap to activate auto exit
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // With generous price impact limits, the auto-exit should succeed
        token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2Liquidity, 0, "token2Id should have 0 liquidity after successful auto-exit");

        // Verify hook contract has no leftover token balances
        _verifyNoLeftoverBalances("generous price impact");
    }

    function testPriceImpactLimitDisabled() public {
        // Test with maxPriceImpact set to 0 (disabled - should allow any slippage)
        hook.setGeneralConfig(token2Id, RevertHookConfig.GeneralConfig({
            swapPoolFee: 3000,
            swapPoolTickSpacing: 60,
            swapPoolHooks: IHooks(hook),
            maxPriceImpact0: 0, // Disabled
            maxPriceImpact1: 0  // Disabled
        }));

        hook.setPositionConfig(token2Id, RevertHookConfig.PositionConfig({
            mode: RevertHookConfig.PositionMode.AUTO_EXIT,
            autoCompoundMode: RevertHookConfig.AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Perform a large swap - with price impact check disabled, should succeed
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // With disabled price impact check, auto-exit should succeed regardless of slippage
        token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2Liquidity, 0, "token2Id should have 0 liquidity after auto-exit with disabled price impact");

        // Verify hook contract has no leftover token balances
        _verifyNoLeftoverBalances("disabled price impact");
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
}