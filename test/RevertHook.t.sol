// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
import {RevertHookState} from "../src/RevertHookState.sol";
import {PositionModeFlags} from "../src/lib/PositionModeFlags.sol";
import {RevertHookPositionActions} from "../src/RevertHookPositionActions.sol";
import {RevertHookLendingActions} from "../src/RevertHookLendingActions.sol";
import {LiquidityCalculator, ILiquidityCalculator} from "../src/LiquidityCalculator.sol";
import {IV4Oracle} from "../src/interfaces/IV4Oracle.sol";
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
    LiquidityCalculator liquidityCalculator;
    PoolId poolId;

    MockERC4626Vault vault0;
    MockERC4626Vault vault1;
    MockV4Oracle v4Oracle;

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
        v4Oracle = new MockV4Oracle(
            positionManager
        );

        protocolFeeRecipient = makeAddr("protocolFeeRecipient");

        // Deploy LiquidityCalculator
        liquidityCalculator = new LiquidityCalculator();

        // Deploy RevertHookPositionActions and RevertHookLendingActions
        RevertHookPositionActions hookFunctionsPositionActions = new RevertHookPositionActions(permit2, v4Oracle, liquidityCalculator);
        RevertHookLendingActions hookFunctionsLendingActions = new RevertHookLendingActions(permit2, v4Oracle, liquidityCalculator);

        bytes memory constructorArgs = abi.encode(address(this), protocolFeeRecipient, permit2, v4Oracle, liquidityCalculator, hookFunctionsPositionActions, hookFunctionsLendingActions);
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
        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,

            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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

    function testAutoRangeCopiesGeneralConfigOnRemint() public {
        hook.setMaxTicksFromOracle(1000);

        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));
        hook.setGeneralConfig(token3Id, 3000, 60, IHooks(hook), 123, 456);
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        (
            uint24 feeBefore,
            int24 tickSpacingBefore,
            IHooks hooksBefore,
            uint128 multiplier0Before,
            uint128 multiplier1Before
        ) = hook.generalConfigs(token3Id);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        uint256 newTokenId = nextTokenIdBefore;
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "AUTO_RANGE should mint replacement token");

        (
            uint24 feeAfter,
            int24 tickSpacingAfter,
            IHooks hooksAfter,
            uint128 multiplier0After,
            uint128 multiplier1After
        ) = hook.generalConfigs(newTokenId);

        assertEq(feeAfter, feeBefore, "swapPoolFee should copy on remint");
        assertEq(tickSpacingAfter, tickSpacingBefore, "swapPoolTickSpacing should copy on remint");
        assertEq(address(hooksAfter), address(hooksBefore), "swapPoolHooks should copy on remint");
        assertEq(multiplier0After, multiplier0Before, "sqrtPriceMultiplier0 should copy on remint");
        assertEq(multiplier1After, multiplier1Before, "sqrtPriceMultiplier1 should copy on remint");
    }

    function testAutoExit_MultiplePositionsOnSameTriggerExecuteOnceEach() public {
        uint128 extraLiquidity = 10e18;
        (uint256 token4Id,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            extraLiquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        hook.setPositionConfig(token2Id, exitConfig);
        hook.setPositionConfig(token3Id, exitConfig);
        hook.setPositionConfig(token4Id, exitConfig);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        bytes32 autoExitTopic = keccak256("AutoExit(uint256,address,address,uint256,uint256)");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 12e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory firstSwapLogs = vm.getRecordedLogs();
        uint256 firstExecutionCount;
        bool token2Exited;
        bool token3Exited;
        bool token4Exited;
        for (uint256 i; i < firstSwapLogs.length; ++i) {
            if (firstSwapLogs[i].topics.length < 2 || firstSwapLogs[i].topics[0] != autoExitTopic) continue;
            uint256 exitedTokenId = uint256(firstSwapLogs[i].topics[1]);
            if (exitedTokenId == token2Id) {
                token2Exited = true;
                ++firstExecutionCount;
            } else if (exitedTokenId == token3Id) {
                token3Exited = true;
                ++firstExecutionCount;
            } else if (exitedTokenId == token4Id) {
                token4Exited = true;
                ++firstExecutionCount;
            }
        }

        assertEq(firstExecutionCount, 3, "Expected exactly one AUTO_EXIT for each configured token");
        assertTrue(token2Exited && token3Exited && token4Exited, "All three positions should auto-exit");
        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "token2 should be exited");
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "token3 should be exited");
        assertEq(positionManager.getPositionLiquidity(token4Id), 0, "token4 should be exited");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 2e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory secondSwapLogs = vm.getRecordedLogs();
        uint256 duplicateExecutionCount;
        for (uint256 i; i < secondSwapLogs.length; ++i) {
            if (secondSwapLogs[i].topics.length < 2 || secondSwapLogs[i].topics[0] != autoExitTopic) continue;
            uint256 exitedTokenId = uint256(secondSwapLogs[i].topics[1]);
            if (exitedTokenId == token2Id || exitedTokenId == token3Id || exitedTokenId == token4Id) {
                ++duplicateExecutionCount;
            }
        }
        assertEq(duplicateExecutionCount, 0, "Already-exited positions must not execute again");
    }

    function testAutoRangeRemintFailureRestoresOriginalNonVaultPosition() public {
        hook.setMaxTicksFromOracle(1000);
        // Configure a non-existent swap pool so swap-to-ratio fails and remint has no usable token1.
        hook.setGeneralConfig(token3Id, 500, 60, IHooks(address(0)), 0, 0);

        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -poolKey.tickSpacing * 2,
            autoRangeUpperDelta: -poolKey.tickSpacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        assertGt(liquidityBefore, 0, "Position should start with liquidity");

        bytes32 autoRangeTopic = keccak256("AutoRange(uint256,uint256,address,address,uint256,uint256)");
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawFallbackEvent;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != autoRangeTopic) continue;
            if (uint256(logs[i].topics[1]) != token3Id) continue;
            (uint256 newTokenId,,,,) = abi.decode(logs[i].data, (uint256, address, address, uint256, uint256));
            if (newTokenId == token3Id) {
                sawFallbackEvent = true;
            }
        }

        assertTrue(sawFallbackEvent, "Fallback AUTO_RANGE should emit with unchanged tokenId");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Remint failure should not create a new token");
        assertGt(positionManager.getPositionLiquidity(token3Id), 0, "Original position should be restored");

        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_RANGE, "Position config should remain active after fallback");
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should not retain currency0 after fallback");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should not retain currency1 after fallback");
    }

    /// @notice Helper function to set up auto compound test: configures position, generates fees
    /// @param autoCompoundMode The auto compound mode to test
    /// @return token2Liquidity The initial liquidity of the position
    function _setupAutoCompoundTest(RevertHook.AutoCompoundMode autoCompoundMode) internal returns (uint128 token2Liquidity) {
        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: autoCompoundMode,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookState.AutoCompoundMode.AUTO_COMPOUND);
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
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookState.AutoCompoundMode.HARVEST_TOKEN_0);
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
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookState.AutoCompoundMode.HARVEST_TOKEN_1);
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

    function testBasicAutoHarvestTokens() public {
        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookState.AutoCompoundMode.HARVEST_TOKENS);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCompound();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCompound(params);

        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        // Position liquidity should NOT increase (unlike auto-compound)
        assertEq(token2LiquidityAfter, token2Liquidity, "token2Id liquidity should remain the same after harvest");

        _verifyNoLeftoverBalances("harvest");

        // Verify executor received fees in both tokens (reward for harvesting)
        uint256 executorBalance0After = currency0.balanceOf(address(this));
        uint256 executorBalance1After = currency1.balanceOf(address(this));
        uint256 executorFee0 = executorBalance0After - before.executorBalance0;
        uint256 executorFee1 = executorBalance1After - before.executorBalance1;
        assertGt(executorFee0, 0, "Executor should have received fees in token0");
        assertGt(executorFee1, 0, "Executor should have received fees in token1");

        // Verify owner received both tokens (after fees)
        uint256 ownerBalance0After = currency0.balanceOf(address(this));
        uint256 ownerBalance1After = currency1.balanceOf(address(this));
        uint256 ownerReceived0 = ownerBalance0After - before.ownerBalance0;
        uint256 ownerReceived1 = ownerBalance1After - before.ownerBalance1;
        assertGt(ownerReceived0, 0, "Owner should have received harvested token0");
        assertGt(ownerReceived1, 0, "Owner should have received harvested token1");

        // Verify protocolFeeRecipient received fees in both tokens
        address feeRecipient = hook.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0, 0, "ProtocolFeeRecipient should have received fees in token0");
        assertGt(protocolFee1, 0, "ProtocolFeeRecipient should have received fees in token1");
    }

    function testBasicAutoExit() public {

        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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

    function testBasicAutoExit_Relative() public {
        // Get initial position info to understand the tick range
        (, PositionInfo posInfoBefore) = positionManager.getPoolAndPositionInfo(token2Id);
        int24 posTickLower = posInfoBefore.tickLower();
        int24 posTickUpper = posInfoBefore.tickUpper();

        // Configure auto-exit with RELATIVE ticks
        // Setting autoExitTickLower = poolKey.tickSpacing means exit when price drops
        // to (posTickLower - poolKey.tickSpacing)
        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: true, // Use RELATIVE ticks
            autoExitTickLower: poolKey.tickSpacing, // Exit tick = posTickLower - tickSpacing
            autoExitTickUpper: type(int24).max, // Don't exit on upper side
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity before swap
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Calculate the expected absolute exit tick (relative to position's tickLower)
        int24 expectedExitTick = posTickLower - poolKey.tickSpacing;
        console.log("Position tickLower:", posTickLower);
        console.log("Position tickUpper:", posTickUpper);
        console.log("Expected exit tick (relative):", expectedExitTick);

        // Perform a swap to activate auto exit
        // This should trigger when price crosses (posTickLower - tickSpacing)
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
        console.log("currentTick after swap:", currentTick);

        // Verify the exit trigger was hit
        assertTrue(currentTick < expectedExitTick, "Current tick should be below the relative exit tick");

        // Verify auto-exit happened: position should have 0 liquidity
        token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2Liquidity, 0, "token2Id should have 0 liquidity after relative auto-exit");

        // Verify hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0 after auto-exit");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1 after auto-exit");
    }

    function testAutoExitAndAutoRange() public {

        // Configure AUTO_EXIT_AND_AUTO_RANGE mode
        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false, // Use absolute ticks
            autoExitTickLower: type(int24).min, // Set to min so it never triggers on lower side
            autoExitTickUpper: tickUpper3 + poolKey.tickSpacing * 3,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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

        hook.setGeneralConfig(token2Id, 3000, 60, IHooks(address(0)), 0, 0);

        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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
        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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
        hook.setPositionConfig(autolendTokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_LEND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 60,
            autoLeverageTargetBps: 0
        }));

        // for auto lend where new positions may be created we need to approve all positions to the hook
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        // Verify initial state
        uint128 initialLiquidity = positionManager.getPositionLiquidity(autolendTokenId);
        assertGt(initialLiquidity, 0, "Position should have liquidity initially");

        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(autolendTokenId);

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
        (,,,autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
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
        (,,,autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
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
        (,,,autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
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
        (,,,autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
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

        (,,,autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);

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

    // ==================== Mode Combination Coverage ====================

    function testModeMatrixSetup_AllValidNonVaultCombinations() public {
        uint8 validCount;

        // Approve once; setup-only matrix should not execute actions immediately.
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        for (uint8 mode = 1; mode < 16; mode++) {
            // Non-vault invalid combination: AUTO_EXIT + AUTO_LEND.
            if ((mode & PositionModeFlags.MODE_AUTO_EXIT) != 0 && (mode & PositionModeFlags.MODE_AUTO_LEND) != 0) {
                continue;
            }

            hook.setPositionConfig(token3Id, _buildNonVaultModeConfig(mode, false, false, type(int24).min, type(int24).max));

            (uint8 storedMode, RevertHookState.AutoCompoundMode storedAutoCompoundMode,,,,,,,,,) =
                hook.positionConfigs(token3Id);
            assertEq(storedMode, mode, "Stored mode flags mismatch");

            if ((mode & PositionModeFlags.MODE_AUTO_COMPOUND) != 0) {
                assertEq(
                    uint8(storedAutoCompoundMode),
                    uint8(RevertHookState.AutoCompoundMode.AUTO_COMPOUND),
                    "AUTO_COMPOUND mode should be enabled"
                );
            } else {
                assertEq(
                    uint8(storedAutoCompoundMode),
                    uint8(RevertHookState.AutoCompoundMode.NONE),
                    "Auto compound mode should be NONE"
                );
            }

            unchecked {
                ++validCount;
            }
        }

        assertEq(validCount, 11, "Expected 11 valid non-vault mode combinations");
    }

    function testModeMatrixSetup_InvalidNonVaultCombinationsRevert() public {
        uint8 invalidCount;

        for (uint8 mode = 1; mode < 32; mode++) {
            bool hasAutoLeverage = (mode & PositionModeFlags.MODE_AUTO_LEVERAGE) != 0;
            bool hasAutoExit = (mode & PositionModeFlags.MODE_AUTO_EXIT) != 0;
            bool hasAutoLend = (mode & PositionModeFlags.MODE_AUTO_LEND) != 0;
            bool isInvalid = hasAutoLeverage || (hasAutoExit && hasAutoLend);

            if (!isInvalid) {
                continue;
            }

            vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
            hook.setPositionConfig(token3Id, _buildNonVaultModeConfig(mode, false, false, type(int24).min, type(int24).max));

            unchecked {
                ++invalidCount;
            }
        }

        assertEq(invalidCount, 20, "Expected 20 invalid non-vault mode combinations");
    }

    function testSetPositionConfig_AutoRangeInvalidDeltaOrderReverts() public {
        RevertHookState.PositionConfig memory config =
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_RANGE, true, false, type(int24).min, type(int24).max);

        config.autoRangeLowerDelta = 0;
        config.autoRangeUpperDelta = 0;
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(token3Id, config);

        config.autoRangeLowerDelta = poolKey.tickSpacing;
        config.autoRangeUpperDelta = -poolKey.tickSpacing;
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(token3Id, config);

        config.autoRangeLowerDelta = -poolKey.tickSpacing;
        config.autoRangeUpperDelta = 0;
        hook.setPositionConfig(token3Id, config);

        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_RANGE, "Valid AUTO_RANGE config should be accepted");
    }

    function testModeCRL_FullAutomationCoverage() public {
        hook.setMaxTicksFromOracle(1000);

        uint8 modeCRL = PositionModeFlags.MODE_AUTO_COMPOUND
            | PositionModeFlags.MODE_AUTO_RANGE
            | PositionModeFlags.MODE_AUTO_LEND;

        // ----- AutoCompound path (C) -----
        hook.setPositionConfig(tokenId, _buildNonVaultModeConfig(modeCRL, true, false, type(int24).min, type(int24).max));
        IERC721(address(positionManager)).approve(address(hook), tokenId);

        uint128 liquidityBeforeCompound = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityBeforeCompound, 0, "Compound test position must have liquidity");

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

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        hook.autoCompound(tokenIds);

        uint128 liquidityAfterCompound = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfterCompound, liquidityBeforeCompound, "AutoCompound should increase liquidity for C|R|L");

        // ----- Trigger path (R/L) -----
        // Keep mode C|R|L, but use narrow range position to trigger automation by swap.
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);
        RevertHookState.PositionConfig memory expectedCRLConfig =
            _buildNonVaultModeConfig(modeCRL, true, false, type(int24).min, type(int24).max);
        hook.setPositionConfig(token3Id, expectedCRLConfig);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint256 vault0AssetsBefore = vault0.totalAssets();
        uint256 vault1AssetsBefore = vault1.totalAssets();

        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // AUTO_RANGE executes and remints.
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Old position should be empty after AUTO_RANGE");
        uint256 rangedTokenId = nextTokenIdBefore;
        assertGt(positionManager.getPositionLiquidity(rangedTokenId), 0, "AUTO_RANGE should mint a new position");

        // Config must be fully copied and position must remain active.
        _assertPositionConfigEq(rangedTokenId, expectedCRLConfig);
        (,, uint32 rangedLastActivated,,,,,) = hook.positionStates(rangedTokenId);
        assertGt(rangedLastActivated, 0, "Reminted position should stay activated");

        // Current dispatch priority executes RANGE before LEND when both flags are set.
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(rangedTokenId);
        assertEq(autoLendShares, 0, "AUTO_LEND should not hold shares when AUTO_RANGE took priority");
        assertEq(autoLendToken, address(0), "AUTO_LEND token should remain unset when AUTO_RANGE took priority");
        assertEq(vault0.totalAssets(), vault0AssetsBefore, "Vault0 should remain unchanged when AUTO_LEND is not executed");
        assertEq(vault1.totalAssets(), vault1AssetsBefore, "Vault1 should remain unchanged when AUTO_LEND is not executed");

        _verifyNoLeftoverBalances("C|R|L coverage");
    }

    function _buildNonVaultModeConfig(
        uint8 modeFlags,
        bool enableRange,
        bool enableExit,
        int24 exitTickLower,
        int24 exitTickUpper
    ) internal view returns (RevertHookState.PositionConfig memory config) {
        bool hasRangeMode = PositionModeFlags.hasAutoRange(modeFlags);
        bool hasRangeTriggers = hasRangeMode && enableRange;

        config = RevertHookState.PositionConfig({
            modeFlags: modeFlags,
            autoCompoundMode: PositionModeFlags.hasAutoCompound(modeFlags)
                ? RevertHookState.AutoCompoundMode.AUTO_COMPOUND
                : RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: enableExit ? exitTickLower : type(int24).min,
            autoExitTickUpper: enableExit ? exitTickUpper : type(int24).max,
            autoRangeLowerLimit: hasRangeTriggers ? int24(0) : type(int24).min,
            autoRangeUpperLimit: hasRangeTriggers ? int24(0) : type(int24).max,
            autoRangeLowerDelta: hasRangeMode ? -poolKey.tickSpacing : int24(0),
            autoRangeUpperDelta: hasRangeMode ? poolKey.tickSpacing : int24(0),
            autoLendToleranceTick: int24(0),
            autoLeverageTargetBps: 0
        });
    }

    function _assertPositionConfigEq(uint256 tokenId_, RevertHookState.PositionConfig memory expected) internal view {
        (
            uint8 modeFlags,
            RevertHookState.AutoCompoundMode autoCompoundMode,
            bool autoExitIsRelative,
            int24 autoExitTickLower,
            int24 autoExitTickUpper,
            int24 autoRangeLowerLimit,
            int24 autoRangeUpperLimit,
            int24 autoRangeLowerDelta,
            int24 autoRangeUpperDelta,
            int24 autoLendToleranceTick,
            uint16 autoLeverageTargetBps
        ) = hook.positionConfigs(tokenId_);

        assertEq(modeFlags, expected.modeFlags, "modeFlags mismatch");
        assertEq(uint8(autoCompoundMode), uint8(expected.autoCompoundMode), "autoCompoundMode mismatch");
        assertEq(autoExitIsRelative, expected.autoExitIsRelative, "autoExitIsRelative mismatch");
        assertEq(autoExitTickLower, expected.autoExitTickLower, "autoExitTickLower mismatch");
        assertEq(autoExitTickUpper, expected.autoExitTickUpper, "autoExitTickUpper mismatch");
        assertEq(autoRangeLowerLimit, expected.autoRangeLowerLimit, "autoRangeLowerLimit mismatch");
        assertEq(autoRangeUpperLimit, expected.autoRangeUpperLimit, "autoRangeUpperLimit mismatch");
        assertEq(autoRangeLowerDelta, expected.autoRangeLowerDelta, "autoRangeLowerDelta mismatch");
        assertEq(autoRangeUpperDelta, expected.autoRangeUpperDelta, "autoRangeUpperDelta mismatch");
        assertEq(autoLendToleranceTick, expected.autoLendToleranceTick, "autoLendToleranceTick mismatch");
        assertEq(autoLeverageTargetBps, expected.autoLeverageTargetBps, "autoLeverageTargetBps mismatch");
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    // ==================== Price Impact Limit Tests ====================

    function testPriceImpactLimit_ZeroMeansNoLimit() public {
        // Configure auto exit with maxPriceImpact = 0 (no limit)
        hook.setGeneralConfig(token2Id, 3000, 60, IHooks(hook), 0, 0);

        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Record logs to check events
        vm.recordLogs();

        // Perform a swap to trigger auto exit - this swap moves the price significantly
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

        // Verify auto exit happened (position has 0 liquidity)
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(token2Liquidity, 0, "token2Id should have 0 liquidity after auto-exit");

        // Check that HookSwapPartial was NOT emitted (full swap executed)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 partialSwapEventSignature = keccak256("HookSwapPartial(uint256,bool,uint256,uint256)");
        bool partialSwapEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == partialSwapEventSignature && logs[i].emitter == address(hook)) {
                partialSwapEventFound = true;
                break;
            }
        }

        assertFalse(partialSwapEventFound, "HookSwapPartial should NOT be emitted when maxPriceImpact is 0");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testPriceImpactLimit_LimitEnforced() public {
        // Configure auto exit with a very strict price impact limit (10 bps = 0.1%)
        uint32 maxPriceImpactBps = 10;
        hook.setGeneralConfig(token2Id, 3000, 60, IHooks(hook), maxPriceImpactBps, maxPriceImpactBps);

        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Record logs to check for HookSwapPartial event
        vm.recordLogs();

        // Perform a large swap that should trigger the price impact limit
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

        // Check for HookSwapPartial event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 partialSwapEventSignature = keccak256("HookSwapPartial(uint256,bool,uint256,uint256)");
        bool partialSwapEventFound = false;
        uint256 requestedAmount;
        uint256 swappedAmount;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == partialSwapEventSignature && logs[i].emitter == address(hook)) {
                partialSwapEventFound = true;
                // Decode the event data
                (,requestedAmount, swappedAmount) = abi.decode(logs[i].data, (bool,uint256, uint256));
                break;
            }
        }

        assertTrue(partialSwapEventFound, "HookSwapPartial should be emitted when price impact limit is reached");
        assertLt(swappedAmount, requestedAmount, "Swapped amount should be less than requested due to price impact limit");

        // Verify that the partial swap amount is significantly less than the requested amount
        // With 10 bps limit, the hook's swap should be limited to a small fraction
        assertLt(swappedAmount * 10, requestedAmount, "Partial swap should be much smaller than requested with strict limit");

        console.log("Requested swap amount:", requestedAmount);
        console.log("Actual swapped amount:", swappedAmount);
    }

    function testPriceImpactLimit_ModerateLimit() public {
        // Configure auto exit with a moderate price impact limit (100 bps = 1%)
        hook.setGeneralConfig(token2Id, 3000, 60, IHooks(hook), 100, 100);

        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Get initial position liquidity
        uint128 initialLiquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(initialLiquidity, 0, "Position should have initial liquidity");

        // Record logs
        vm.recordLogs();

        // Perform a swap to trigger auto exit
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

        // Verify auto exit happened - position liquidity should be 0
        uint128 finalLiquidity = positionManager.getPositionLiquidity(token2Id);
        assertEq(finalLiquidity, 0, "Position should have 0 liquidity after auto exit");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testPriceImpactLimit_DifferentLimitsPerDirection() public {
        // Configure different limits for each swap direction
        // maxPriceImpact0: 10 bps (0.1%) - Very strict for token0 -> token1
        // maxPriceImpact1: 1000 bps (10%) - Loose for token1 -> token0
        hook.setGeneralConfig(token2Id, 3000, 60, IHooks(hook), 10, 1000);

        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Record logs
        vm.recordLogs();

        // Trigger auto exit with zeroForOne swap (should hit the strict limit)
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true, // This uses maxPriceImpact0 (strict)
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Check for HookSwapPartial event - should be emitted because of strict limit on zeroForOne
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 partialSwapEventSignature = keccak256("HookSwapPartial(uint256,bool,uint256,uint256)");
        bool partialSwapEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == partialSwapEventSignature && logs[i].emitter == address(hook)) {
                partialSwapEventFound = true;
                break;
            }
        }

        // Should find partial swap event due to strict price impact limit
        assertTrue(partialSwapEventFound, "HookSwapPartial should be emitted for zeroForOne swap with strict limit");
    }

    function testPriceImpactLimit_AutoRangeWithLimit() public {
        // Configure auto range with a moderate price impact limit (200 bps = 2%)
        hook.setGeneralConfig(token3Id, 3000, 60, IHooks(hook), 200, 200);

        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        IERC721(address(positionManager)).approve(address(hook), token3Id);

        // Store initial state
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 initialLiquidity = positionManager.getPositionLiquidity(token3Id);
        assertGt(initialLiquidity, 0, "Position should have initial liquidity");

        // Perform swap to activate auto range
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // Verify auto range happened
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Old position should have 0 liquidity after auto-range");

        uint256 nextTokenIdAfter = positionManager.nextTokenId();
        assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "A new position should be minted after auto-range");

        // Verify new position has liquidity
        uint256 newTokenId = nextTokenIdBefore;
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "New position should have liquidity > 0");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testPriceImpactLimit_AutoCompoundWithLimit() public {
        // Configure auto compound with a moderate price impact limit (500 bps = 5%)
        hook.setGeneralConfig(token2Id, 3000, 60, IHooks(hook), 500, 500);

        uint128 token2Liquidity = _setupAutoCompoundTest(RevertHookState.AutoCompoundMode.AUTO_COMPOUND);

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCompound(params);

        // Verify liquidity increased after auto compound
        uint128 token2LiquidityAfter = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2LiquidityAfter, token2Liquidity, "token2Id should have more liquidity after auto compound");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    // ============ Minimum Position Value Tests ============

    function testMinPositionValue_CannotConfigureBelowMinimum() public {
        // Set mock oracle to return value below minimum
        v4Oracle.setMockPositionValue(0.001 ether); // Below default 0.01 ether minimum

        // Try to configure position - should revert
        vm.expectRevert(abi.encodeWithSignature("PositionValueTooLow()"));
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));
    }

    function testMinPositionValue_CanConfigureAboveMinimum() public {
        // Set mock oracle to return value above minimum
        v4Oracle.setMockPositionValue(1 ether); // Above default 0.01 ether minimum

        // Configure position - should succeed
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Verify position is configured and activated
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_COMPOUND, "Position should be configured");

        // Verify position is activated (lastActivated > 0)
        (,, uint32 lastActivated,,,,,) = hook.positionStates(tokenId);
        assertGt(lastActivated, 0, "Position should be activated");
    }

    function testMinPositionValue_TriggersRemovedWhenValueDrops() public {
        // Set mock oracle to return high value initially
        v4Oracle.setMockPositionValue(1 ether);

        // Configure position
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Verify position is activated
        (,, uint32 lastActivatedBefore,,,,,) = hook.positionStates(tokenId);
        assertGt(lastActivatedBefore, 0, "Position should be activated initially");

        // Simulate value drop by setting mock oracle to low value
        v4Oracle.setMockPositionValue(0.001 ether);

        // Remove some liquidity (triggers afterRemoveLiquidity hook)
        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        positionManager.decreaseLiquidity(
            tokenId,
            currentLiquidity / 2, // Remove half
            0,
            0,
            address(this),
            block.timestamp,
            ""
        );

        // Verify position is deactivated (triggers removed due to low value)
        (,, uint32 lastActivatedAfter,,,,,) = hook.positionStates(tokenId);
        assertEq(lastActivatedAfter, 0, "Position should be deactivated after value drops below minimum");
    }

    function testMinPositionValue_TriggersReaddedWhenValueIncreases() public {
        // Set mock oracle to return low value initially
        v4Oracle.setMockPositionValue(0.001 ether);

        // Mint a new position (will not have triggers added due to low value)
        uint128 liquidityAmount = 10e18;
        (uint256 newTokenId,) = positionManager.mint(
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

        // Try to configure - should revert due to low value
        vm.expectRevert(abi.encodeWithSignature("PositionValueTooLow()"));
        hook.setPositionConfig(newTokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Set mock oracle to return high value
        v4Oracle.setMockPositionValue(1 ether);

        // Now configure should succeed
        hook.setPositionConfig(newTokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Verify position is activated
        (,, uint32 lastActivated,,,,,) = hook.positionStates(newTokenId);
        assertGt(lastActivated, 0, "Position should be activated after value increases");
    }

    function testMinPositionValue_OwnerCanChangeMinimum() public {
        // Default minimum is 0.01 ether
        assertEq(hook.minPositionValueNative(), 0.01 ether, "Default minimum should be 0.01 ether");

        // Set mock oracle to return value between old and new minimum
        v4Oracle.setMockPositionValue(0.005 ether);

        // Try to configure - should revert (value below 0.01 ether)
        vm.expectRevert(abi.encodeWithSignature("PositionValueTooLow()"));
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Owner lowers the minimum
        hook.setMinPositionValueNative(0.001 ether);
        assertEq(hook.minPositionValueNative(), 0.001 ether, "Minimum should be updated");

        // Now configure should succeed
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Verify position is configured
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_COMPOUND, "Position should be configured");
    }

    function testMinPositionValue_DisablingPositionAlwaysAllowed() public {
        // Set mock oracle to return high value
        v4Oracle.setMockPositionValue(1 ether);

        // Configure position
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Set mock oracle to return low value
        v4Oracle.setMockPositionValue(0.001 ether);

        // Disabling position (setting mode to NONE) should always work regardless of value
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_NONE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Verify position is disabled
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Position should be disabled");

        // Verify position is deactivated
        (,, uint32 lastActivated,,,,,) = hook.positionStates(tokenId);
        assertEq(lastActivated, 0, "Position should be deactivated");
    }

    function testMinPositionValue_ZeroMinimumAllowsAll() public {
        // Set minimum to 0
        hook.setMinPositionValueNative(0);

        // Set mock oracle to return 0 value
        v4Oracle.setMockPositionValue(0);

        // Configure should succeed even with 0 value
        hook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // Verify position is configured
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_COMPOUND, "Position should be configured with 0 minimum");
    }

    // ==================== Immediate Execution Tests ====================

    function testImmediateExecution_AutoExit() public {
        console.log("=== Test: Immediate Auto Exit Execution ===");

        // First, perform a swap to move the tick out of the position range
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        // Position 2 has range [tickLower2, tickUpper2] = [-60, 60]
        // After swap, currentTick should be < -60, so the position is out of range on the lower side
        assertTrue(currentTick < tickLower2, "Current tick should be below position lower bound");

        // Get initial liquidity
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token2Id);
        assertGt(liquidityBefore, 0, "token2Id should have liquidity before config");
        console.log("liquidityBefore", liquidityBefore);

        // Approve the hook to manage the position
        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Now configure auto-exit with a trigger that should already be met
        // Since the tick is already below tickLower2, setting autoExitTickLower to tickLower2 should trigger immediately
        hook.setPositionConfig(token2Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2,  // Trigger when tick <= -60
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // The auto-exit should have executed immediately
        uint128 liquidityAfter = positionManager.getPositionLiquidity(token2Id);
        console.log("liquidityAfter", liquidityAfter);
        assertEq(liquidityAfter, 0, "token2Id should have 0 liquidity after immediate auto-exit");

        // Verify the position config is disabled
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Position should be disabled after auto-exit");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testImmediateExecution_AutoRange() public {
        console.log("=== Test: Immediate Auto Range Execution ===");

        // First, perform a swap to move the tick out of the position range
        uint256 amountIn = 7e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        // Position 3 has range [tickLower3, tickUpper3] = [-60, 60]
        assertTrue(currentTick < tickLower3, "Current tick should be below position lower bound");

        // Get initial liquidity and position info
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        assertGt(liquidityBefore, 0, "token3Id should have liquidity before config");
        console.log("liquidityBefore", liquidityBefore);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        // Approve the hook to manage the position
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        // Configure auto-range with a trigger that should already be met
        // autoRangeLowerLimit of 0 means trigger when tick reaches tickLower
        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,  // Trigger when tick <= tickLower
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -60,
            autoRangeUpperDelta: 60,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // The auto-range should have executed immediately
        uint128 liquidityAfter = positionManager.getPositionLiquidity(token3Id);
        console.log("liquidityAfter", liquidityAfter);
        assertEq(liquidityAfter, 0, "token3Id should have 0 liquidity after immediate auto-range");

        // Verify a new position was minted
        uint256 nextTokenIdAfter = positionManager.nextTokenId();
        assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "A new position should be minted");

        // Verify new position has liquidity
        uint256 newTokenId = nextTokenIdBefore;
        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        console.log("newLiquidity", newLiquidity);
        assertGt(newLiquidity, 0, "New position should have liquidity > 0");

        // Verify new position is owned by the same owner
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(this),
            "New position should be owned by the same address");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testImmediateExecution_AutoLend() public {
        console.log("=== Test: Immediate Auto Lend Execution ===");

        // First, perform a swap to move the tick out of the position range
        // Need to swap more to get past the AUTO_LEND trigger which is at tickLower - tickSpacing
        uint256 amountIn = 14e17;  // Larger swap to move tick further
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        // Get current tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick after swap", currentTick);

        // Position 3 has range [tickLower3, tickUpper3] = [-60, 60]
        assertTrue(currentTick < tickLower3, "Current tick should be below position lower bound");

        // Get initial liquidity
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        assertGt(liquidityBefore, 0, "token3Id should have liquidity before config");
        console.log("liquidityBefore", liquidityBefore);

        // Approve the hook to manage the position
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        // Configure auto-lend with a trigger that should already be met
        // autoLendToleranceTick controls when the deposit happens - price goes out of range + tolerance
        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_LEND,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,  // No tolerance - trigger immediately when out of range
            autoLeverageTargetBps: 0
        }));

        // The auto-lend deposit should have executed immediately
        uint128 liquidityAfter = positionManager.getPositionLiquidity(token3Id);
        console.log("liquidityAfter", liquidityAfter);
        assertEq(liquidityAfter, 0, "token3Id should have 0 liquidity after immediate auto-lend deposit");

        // Verify position state has auto-lend shares
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        console.log("autoLendShares", autoLendShares);
        assertGt(autoLendShares, 0, "Position should have auto-lend shares");
        assertEq(autoLendToken, Currency.unwrap(currency0), "Auto-lend should be for currency0 since price went down");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testImmediateExecution_NoTriggerWhenInRange() public {
        console.log("=== Test: No Immediate Execution When In Range ===");

        // Don't perform any swap - position should be in range
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("currentTick", currentTick);

        // Position 3 has range [tickLower3, tickUpper3] = [-60, 60]
        // Current tick should be at 0 (within range)
        assertTrue(currentTick >= tickLower3 && currentTick <= tickUpper3, "Current tick should be within position range");

        // Get initial liquidity
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        assertGt(liquidityBefore, 0, "token3Id should have liquidity before config");
        console.log("liquidityBefore", liquidityBefore);

        // Approve the hook to manage the position
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        // Configure auto-exit with triggers outside current tick
        hook.setPositionConfig(token3Id, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower3 - 60,  // Trigger at -120, but we're at 0
            autoExitTickUpper: tickUpper3 + 60,  // Trigger at 120, but we're at 0
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        // No immediate execution should happen - liquidity should remain
        uint128 liquidityAfter = positionManager.getPositionLiquidity(token3Id);
        console.log("liquidityAfter", liquidityAfter);
        assertEq(liquidityAfter, liquidityBefore, "token3Id should still have same liquidity - no immediate execution");

        // Verify position is still configured (not disabled)
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_EXIT, "Position should still be configured for auto-exit");
    }

    function testAutoExitRelative_RecomputedAfterAutoRangeRemint() public {
        hook.setMaxTicksFromOracle(1000);
        int24 spacing = poolKey.tickSpacing;

        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: true,
            autoExitTickLower: 2 * spacing,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -2 * spacing,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        hook.setPositionConfig(token3Id, config);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        (, PositionInfo originalPosInfo) = positionManager.getPoolAndPositionInfo(token3Id);
        int24 oldExitTickLower = originalPosInfo.tickLower() - config.autoExitTickLower;

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        _moveTickDownUntil(originalPosInfo.tickLower(), 2e16, 120);

        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "AUTO_RANGE should remint into a new token");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "Remint should consume exactly one new token id");
        uint256 remintedTokenId = nextTokenIdBefore;

        (, PositionInfo remintedPosInfo) = positionManager.getPoolAndPositionInfo(remintedTokenId);
        int24 newExitTickLower = remintedPosInfo.tickLower() - config.autoExitTickLower;
        assertLt(newExitTickLower, oldExitTickLower, "Reminted position should compute a fresh, lower relative exit tick");

        // Isolate relative AUTO_EXIT checks after remint so subsequent swaps cannot trigger another range remint.
        hook.setPositionConfig(remintedTokenId, RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: true,
            autoExitTickLower: config.autoExitTickLower,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        }));

        _moveTickDownUntil(oldExitTickLower, 1e16, 220);
        (, int24 tickAtOldThreshold,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertGt(tickAtOldThreshold, newExitTickLower, "Price should still be above reminted relative exit trigger");
        assertGt(
            positionManager.getPositionLiquidity(remintedTokenId),
            0,
            "Crossing old relative exit threshold must not exit reminted position"
        );

        _moveTickDownUntil(newExitTickLower - spacing, 2e16, 220);
        assertEq(positionManager.getPositionLiquidity(remintedTokenId), 0, "Reminted position should exit at new relative trigger");
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(remintedTokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Config should clear after reminted relative auto-exit");
    }

    function testTriggerListIntegrity_ConfigDisableAndRemintNoStaleTicks() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        (uint32 lowerInitial, uint32 upperInitial) = _getTriggerListSizes();

        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower3 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper3 + poolKey.tickSpacing,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        hook.setPositionConfig(token3Id, exitConfig);

        (uint32 lowerAfterExitConfig, uint32 upperAfterExitConfig) = _getTriggerListSizes();
        assertEq(lowerAfterExitConfig, lowerInitial + 1, "Lower trigger list should include configured AUTO_EXIT lower tick");
        assertEq(upperAfterExitConfig, upperInitial + 1, "Upper trigger list should include configured AUTO_EXIT upper tick");

        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_NONE, false, false, type(int24).min, type(int24).max)
        );
        (uint32 lowerAfterDisable, uint32 upperAfterDisable) = _getTriggerListSizes();
        assertEq(lowerAfterDisable, lowerInitial, "Disabling position should remove lower trigger ticks");
        assertEq(upperAfterDisable, upperInitial, "Disabling position should remove upper trigger ticks");

        RevertHookState.PositionConfig memory rangeConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: -poolKey.tickSpacing,
            autoRangeUpperDelta: poolKey.tickSpacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        hook.setPositionConfig(token3Id, rangeConfig);

        (uint32 lowerAfterRangeConfig, uint32 upperAfterRangeConfig) = _getTriggerListSizes();
        assertEq(lowerAfterRangeConfig, lowerInitial + 1, "AUTO_RANGE should add exactly one lower trigger tick");
        assertEq(upperAfterRangeConfig, upperInitial + 1, "AUTO_RANGE should add exactly one upper trigger tick");

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint256 steps;
        while (positionManager.nextTokenId() == nextTokenIdBefore && steps < 120) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 1e16,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp
            });
            unchecked {
                ++steps;
            }
        }

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "AUTO_RANGE should remint when lower trigger is crossed");
        uint256 remintedTokenId = nextTokenIdBefore;
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Original token should be emptied after remint");
        assertGt(positionManager.getPositionLiquidity(remintedTokenId), 0, "Reminted token should stay active");

        (uint32 lowerAfterRemint, uint32 upperAfterRemint) = _getTriggerListSizes();
        assertEq(lowerAfterRemint, lowerInitial + 1, "Remint should replace lower tick entry without leaking stale ticks");
        assertEq(upperAfterRemint, upperInitial + 1, "Remint should replace upper tick entry without leaking stale ticks");

        hook.setPositionConfig(
            remintedTokenId,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_NONE, false, false, type(int24).min, type(int24).max)
        );
        (uint32 lowerFinal, uint32 upperFinal) = _getTriggerListSizes();
        assertEq(lowerFinal, lowerInitial, "Final disable should leave lower trigger list in baseline state");
        assertEq(upperFinal, upperInitial, "Final disable should leave upper trigger list in baseline state");
    }

    function testAutoExitFailureIsolation_OnePositionCanFailWithoutBlockingOthers() public {
        uint128 extraLiquidity = 10e18;
        (uint256 token4Id,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            extraLiquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        hook.setPositionConfig(token2Id, exitConfig);
        hook.setPositionConfig(token4Id, exitConfig);

        // Intentionally approve only token2Id. token4Id should fail modifyLiquidities but must not block token2Id.
        IERC721(address(positionManager)).approve(address(hook), token2Id);
        uint128 token4LiquidityBefore = positionManager.getPositionLiquidity(token4Id);

        bytes32 autoExitTopic = keccak256("AutoExit(uint256,address,address,uint256,uint256)");
        bytes32 modifyFailedTopic = keccak256("HookModifyLiquiditiesFailed(bytes,bytes[],bytes)");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 12e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "Approved position should still execute AUTO_EXIT");
        assertEq(
            positionManager.getPositionLiquidity(token4Id),
            token4LiquidityBefore,
            "Failed position should keep liquidity when remove fails"
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawAutoExitForToken2;
        bool sawModifyFailed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == autoExitTopic && logs[i].topics.length > 1 && uint256(logs[i].topics[1]) == token2Id) {
                sawAutoExitForToken2 = true;
            }
            if (logs[i].topics[0] == modifyFailedTopic) {
                sawModifyFailed = true;
            }
        }
        assertTrue(sawAutoExitForToken2, "Successful position should emit AutoExit even if another position fails");
        assertTrue(sawModifyFailed, "Failing position should emit HookModifyLiquiditiesFailed");
    }

    function testMinPositionValue_ActivationFlapsAcrossBoundary() public {
        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2 + poolKey.tickSpacing,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        (uint32 lowerBaseline, uint32 upperBaseline) = _getTriggerListSizes();

        v4Oracle.setMockPositionValue(1 ether);
        hook.setPositionConfig(token2Id, config);
        (uint32 lowerActive, uint32 upperActive) = _getTriggerListSizes();
        assertEq(lowerActive, lowerBaseline + 1, "Configured position should contribute one lower trigger");
        assertEq(upperActive, upperBaseline + 1, "Configured position should contribute one upper trigger");

        for (uint256 cycle; cycle < 3; ++cycle) {
            v4Oracle.setMockPositionValue(0.001 ether);

            uint128 currentLiquidity = positionManager.getPositionLiquidity(token2Id);
            uint128 liquidityStep = currentLiquidity / 20;
            if (liquidityStep == 0) {
                liquidityStep = 1;
            }
            positionManager.decreaseLiquidity(
                token2Id,
                liquidityStep,
                0,
                0,
                address(this),
                block.timestamp,
                Constants.ZERO_BYTES
            );

            (,, uint32 lastActivatedLow,,,,,) = hook.positionStates(token2Id);
            assertEq(lastActivatedLow, 0, "Position should deactivate when value falls below minimum");
            (uint32 lowerAfterLow, uint32 upperAfterLow) = _getTriggerListSizes();
            assertEq(lowerAfterLow, lowerBaseline, "Lower trigger list should return to baseline when deactivated");
            assertEq(upperAfterLow, upperBaseline, "Upper trigger list should return to baseline when deactivated");

            v4Oracle.setMockPositionValue(1 ether);
            positionManager.increaseLiquidity(
                token2Id,
                liquidityStep,
                type(uint256).max,
                type(uint256).max,
                block.timestamp,
                Constants.ZERO_BYTES
            );

            (,, uint32 lastActivatedHigh,,,,,) = hook.positionStates(token2Id);
            assertGt(lastActivatedHigh, 0, "Position should reactivate when value recovers and liquidity is added");
            (uint32 lowerAfterHigh, uint32 upperAfterHigh) = _getTriggerListSizes();
            assertEq(lowerAfterHigh, lowerActive, "Lower trigger list should restore active entry after reactivation");
            assertEq(upperAfterHigh, upperActive, "Upper trigger list should restore active entry after reactivation");
        }
    }

    function _getTriggerListSizes() internal view returns (uint32 lowerSize, uint32 upperSize) {
        (, lowerSize,) = hook.lowerTriggerAfterSwap(poolId);
        (, upperSize,) = hook.upperTriggerAfterSwap(poolId);
    }

    function _moveTickDownUntil(
        int24 targetTick,
        uint256 amountInPerSwap,
        uint256 maxSteps
    ) internal returns (int24 currentTick) {
        (, currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        uint256 steps;
        while (currentTick > targetTick && steps < maxSteps) {
            swapRouter.swapExactTokensForTokens({
                amountIn: amountInPerSwap,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp
            });
            (, currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            unchecked {
                ++steps;
            }
        }

        assertLe(currentTick, targetTick, "Target tick was not reached");
    }
}
