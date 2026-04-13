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

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookAccess} from "src/hook/RevertHookAccess.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {HookRouteController} from "src/hook/HookRouteController.sol";
import {HookOwnedControllerBase} from "src/hook/HookOwnedControllerBase.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC4626Vault} from "test/utils/MockERC4626Vault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RevertHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q64_TEST = 2 ** 64;

    Currency currency0;
    Currency currency1;

    PoolKey nonHookedPoolKey;
    PoolKey poolKey;

    RevertHook hook;
    HookFeeController feeController;
    HookRouteController routeController;
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
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy V4Oracle
        v4Oracle = new MockV4Oracle(positionManager);

        protocolFeeRecipient = makeAddr("protocolFeeRecipient");

        // Deploy LiquidityCalculator
        liquidityCalculator = new LiquidityCalculator();
        feeController = new HookFeeController(flags, protocolFeeRecipient, 200, 200);
        routeController = new HookRouteController(flags);
        RevertHookSwapActions swapActions = new RevertHookSwapActions(v4Oracle.poolManager(), feeController);

        // Deploy RevertHook action targets
        RevertHookPositionActions positionActions =
            new RevertHookPositionActions(permit2, v4Oracle, liquidityCalculator, routeController, swapActions);
        RevertHookAutoLeverageActions autoLeverageActions =
            new RevertHookAutoLeverageActions(permit2, v4Oracle, liquidityCalculator, routeController, swapActions);
        RevertHookAutoLendActions autoLendActions =
            new RevertHookAutoLendActions(
                permit2, v4Oracle, liquidityCalculator, feeController, routeController, swapActions
            );

        bytes memory constructorArgs = abi.encode(
            address(this), v4Oracle, feeController, positionActions, autoLeverageActions, autoLendActions
        );
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(payable(flags));

        // Deploy MockERC4626Vault for both currencies
        vault0 = new MockERC4626Vault(IERC20(Currency.unwrap(currency0)), "Vault Token0", "vT0");
        vault1 = new MockERC4626Vault(IERC20(Currency.unwrap(currency1)), "Vault Token1", "vT1");

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
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
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
            assertEq(
                IERC721(address(positionManager)).ownerOf(newTokenId),
                address(this),
                "New position should be owned by the same address"
            );

            // Verify current tick is within the new position's range
            assertTrue(
                currentTick >= newTickLower && currentTick <= newTickUpper,
                "Current tick should be within the new position's range"
            );

            // Verify the old position's range is different from the new position's range
            assertTrue(
                newTickLower != initialTickLower || newTickUpper != initialTickUpper,
                "New position should have a different range than the old position"
            );
        }

        // Verify hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0 after auto-range");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1 after auto-range");
    }

    function testAutoRangeCopiesSwapProtectionConfigOnRemint() public {
        hook.setMaxTicksFromOracle(1000);

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        _setSwapProtection(token3Id, 123, 456);
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        (uint128 multiplier0Before, uint128 multiplier1Before) = hook.swapProtectionConfigs(token3Id);

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

        (uint128 multiplier0After, uint128 multiplier1After) = hook.swapProtectionConfigs(newTokenId);
        assertEq(multiplier0After, multiplier0Before, "sqrtPriceMultiplier0 should copy on remint");
        assertEq(multiplier1After, multiplier1Before, "sqrtPriceMultiplier1 should copy on remint");
    }

    function testSingleSwap_CascadesAcrossMultipleTriggerTicks() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        uint128 extraLiquidity = 8e18;
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

        int24 spacing = poolKey.tickSpacing;
        RevertHookState.PositionConfig memory rangeConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        RevertHookState.PositionConfig memory lendConfig =
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max);
        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - 2 * spacing,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        hook.setPositionConfig(token2Id, rangeConfig);
        hook.setPositionConfig(token3Id, lendConfig);
        hook.setPositionConfig(token4Id, exitConfig);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        bytes32 autoRangeTopic = keccak256("AutoRange(uint256,uint256,address,address,uint256,uint256)");
        bytes32 autoLendDepositTopic = keccak256("AutoLendDeposit(uint256,address,uint256,uint256)");
        bytes32 autoExitTopic = keccak256("AutoExit(uint256,address,address,uint256,uint256)");
        bytes32 hookActionFailedTopic = keccak256("HookActionFailed(uint256,uint8)");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 35e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertLe(currentTick, exitConfig.autoExitTickLower, "Single swap should cross all configured lower triggers");

        uint256 remintedTokenId = nextTokenIdBefore;
        uint256 remintedTokenId2 = nextTokenIdBefore + 1;
        assertEq(
            positionManager.nextTokenId(),
            nextTokenIdBefore + 2,
            "Single swap should chain into a second auto-range remint"
        );

        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "Original AUTO_RANGE token should be emptied");
        assertEq(
            positionManager.getPositionLiquidity(remintedTokenId),
            0,
            "First AUTO_RANGE remint should be consumed again in the same swap"
        );
        assertGt(
            positionManager.getPositionLiquidity(remintedTokenId2),
            0,
            "Final AUTO_RANGE remint should hold the active liquidity"
        );
        _assertPositionConfigEq(remintedTokenId2, rangeConfig);
        (uint8 intermediateRangeModeFlags,,,,,,,,,,) = hook.positionConfigs(remintedTokenId);
        assertEq(
            intermediateRangeModeFlags,
            PositionModeFlags.MODE_NONE,
            "Intermediate remint should be disabled after chaining"
        );

        (, PositionInfo finalRangePosInfo) = positionManager.getPoolAndPositionInfo(remintedTokenId2);
        assertTrue(
            currentTick >= finalRangePosInfo.tickLower() && currentTick <= finalRangePosInfo.tickUpper(),
            "Current tick should end inside the final reminted range"
        );

        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "AUTO_LEND should remove LP liquidity");
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(autoLendToken, Currency.unwrap(currency0), "Lower-side AUTO_LEND should park token0");
        assertGt(autoLendShares, 0, "AUTO_LEND should mint lending shares");

        assertEq(positionManager.getPositionLiquidity(token4Id), 0, "AUTO_EXIT should remove all liquidity");
        (uint8 exitedModeFlags,,,,,,,,,,) = hook.positionConfigs(token4Id);
        assertEq(exitedModeFlags, PositionModeFlags.MODE_NONE, "AUTO_EXIT token should be disabled");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[4] memory expectedTopics = [autoRangeTopic, autoLendDepositTopic, autoExitTopic, autoRangeTopic];
        uint256[4] memory expectedTokenIds = [token2Id, token3Id, token4Id, remintedTokenId];
        uint256 matchedEvents;
        uint256 hookActionFailedCount;
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) {
                continue;
            }
            bytes32 topic0 = logs[i].topics[0];
            if (topic0 == hookActionFailedTopic) {
                ++hookActionFailedCount;
                continue;
            }
            if (topic0 != autoRangeTopic && topic0 != autoLendDepositTopic && topic0 != autoExitTopic) {
                continue;
            }

            assertLt(matchedEvents, 4, "Only the expected chained actions should fire during the swap");
            assertEq(topic0, expectedTopics[matchedEvents], "Actions should execute in crossed-tick order");
            assertEq(
                uint256(logs[i].topics[1]), expectedTokenIds[matchedEvents], "Unexpected token executed for action"
            );
            unchecked {
                ++matchedEvents;
            }
        }

        assertEq(matchedEvents, 4, "Single swap should execute the full chained action sequence");
        assertEq(hookActionFailedCount, 0, "Chained action execution should not emit HookActionFailed");
        _verifyNoLeftoverBalances("single-swap action cascade");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory followupLogs = vm.getRecordedLogs();
        assertFalse(
            _sawIndexedTokenEvent(followupLogs, autoRangeTopic, token2Id),
            "Consumed AUTO_RANGE trigger must not fire twice for the original token"
        );
        assertFalse(
            _sawIndexedTokenEvent(followupLogs, autoLendDepositTopic, token3Id),
            "Consumed AUTO_LEND deposit trigger must not fire twice"
        );
        assertFalse(
            _sawIndexedTokenEvent(followupLogs, autoExitTopic, token4Id),
            "Consumed AUTO_EXIT trigger must not fire twice"
        );
        assertFalse(
            _sawIndexedTokenEvent(followupLogs, autoRangeTopic, remintedTokenId),
            "Consumed intermediate AUTO_RANGE remint must not fire twice"
        );
    }

    function testAfterSwap_MaxTriggerBatchCapDefersRemainingTriggers() public {
        hook.setMaxTicksFromOracle(5000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        uint256 batchCap = hook.MAX_TRIGGER_BATCHES_PER_SWAP();
        uint256 totalPositions = batchCap + 2;
        uint256[] memory tokenIds = new uint256[](totalPositions);
        int24[] memory triggerTicks = new int24[](totalPositions);
        int24 spacing = poolKey.tickSpacing;
        int24 nextUpperTrigger = _getTickLower(tickStart, spacing) + spacing;
        uint128 exitLiquidity = 1e18;

        for (uint256 i; i < totalPositions; ++i) {
            (uint256 stagedTokenId,) = positionManager.mint(
                poolKey,
                tickLower2,
                tickUpper2,
                exitLiquidity,
                type(uint256).max,
                type(uint256).max,
                address(this),
                block.timestamp,
                Constants.ZERO_BYTES
            );
            tokenIds[i] = stagedTokenId;
            triggerTicks[i] = nextUpperTrigger;

            hook.setPositionConfig(
                stagedTokenId,
                RevertHookState.PositionConfig({
                    modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                    autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                    autoExitIsRelative: false,
                    autoExitTickLower: type(int24).min,
                    autoExitTickUpper: nextUpperTrigger,
                    autoExitSwapOnLowerTrigger: true,
                    autoExitSwapOnUpperTrigger: true,
                    autoRangeLowerLimit: type(int24).min,
                    autoRangeUpperLimit: type(int24).max,
                    autoRangeLowerDelta: 0,
                    autoRangeUpperDelta: 0,
                    autoLendToleranceTick: 0,
                    autoLeverageTargetBps: 0
                })
            );

            nextUpperTrigger += spacing;
        }

        (, uint32 upperConfigured,) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperConfigured, totalPositions, "Distinct AUTO_EXIT upper ticks should register one batch each");

        bytes32 autoExitTopic = keccak256("AutoExit(uint256,address,address,uint256,uint256)");
        bytes32 hookActionFailedTopic = keccak256("HookActionFailed(uint256,uint8)");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 15e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        bool[] memory executedFirst = new bool[](totalPositions);
        uint256 firstExecutionCount;
        uint256 firstFailureCount;
        uint256 firstLogLength = firstLogs.length;
        for (uint256 i; i < firstLogLength; ++i) {
            if (firstLogs[i].emitter != address(hook) || firstLogs[i].topics.length == 0) {
                continue;
            }
            if (firstLogs[i].topics[0] == hookActionFailedTopic) {
                ++firstFailureCount;
                continue;
            }
            if (firstLogs[i].topics[0] != autoExitTopic || firstLogs[i].topics.length < 2) {
                continue;
            }

            uint256 exitedTokenId = uint256(firstLogs[i].topics[1]);
            for (uint256 j; j < totalPositions; ++j) {
                if (tokenIds[j] != exitedTokenId || executedFirst[j]) {
                    continue;
                }
                executedFirst[j] = true;
                ++firstExecutionCount;
                break;
            }
        }

        assertEq(firstExecutionCount, batchCap, "First swap should stop at the configured batch cap");
        assertEq(firstFailureCount, 0, "Capped processing should not emit HookActionFailed");
        assertEq(
            hook.tickLowerLasts(poolId), triggerTicks[batchCap - 1], "Cursor should stop at the last processed trigger"
        );

        (, int24 currentTickAfterFirst,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLowerAfterFirst = _getTickLower(currentTickAfterFirst, spacing);
        assertGe(
            currentTickLowerAfterFirst,
            triggerTicks[totalPositions - 1],
            "First swap must cross even the deferred triggers so deferral comes from the cap"
        );

        for (uint256 i; i < totalPositions; ++i) {
            if (i < batchCap) {
                assertTrue(executedFirst[i], "Processed batch should emit one AUTO_EXIT");
                assertEq(positionManager.getPositionLiquidity(tokenIds[i]), 0, "Processed token should be fully exited");
                (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenIds[i]);
                assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Processed token should be disabled");
            } else {
                assertFalse(executedFirst[i], "Deferred batch must not execute before the next swap");
                assertGt(positionManager.getPositionLiquidity(tokenIds[i]), 0, "Deferred token should keep liquidity");
                (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenIds[i]);
                assertEq(modeFlags, PositionModeFlags.MODE_AUTO_EXIT, "Deferred token should remain armed");
            }
        }

        (, uint32 upperAfterFirst, int24 upperHeadAfterFirst) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperAfterFirst, totalPositions - batchCap, "Deferred upper triggers should stay registered");
        assertEq(upperHeadAfterFirst, triggerTicks[batchCap], "Head should advance to the first deferred trigger");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory secondLogs = vm.getRecordedLogs();
        bool[] memory executedSecond = new bool[](totalPositions);
        uint256 secondExecutionCount;
        uint256 secondFailureCount;
        uint256 secondLogLength = secondLogs.length;
        for (uint256 i; i < secondLogLength; ++i) {
            if (secondLogs[i].emitter != address(hook) || secondLogs[i].topics.length == 0) {
                continue;
            }
            if (secondLogs[i].topics[0] == hookActionFailedTopic) {
                ++secondFailureCount;
                continue;
            }
            if (secondLogs[i].topics[0] != autoExitTopic || secondLogs[i].topics.length < 2) {
                continue;
            }

            uint256 exitedTokenId = uint256(secondLogs[i].topics[1]);
            for (uint256 j; j < totalPositions; ++j) {
                if (tokenIds[j] != exitedTokenId || executedSecond[j]) {
                    continue;
                }
                executedSecond[j] = true;
                ++secondExecutionCount;
                break;
            }
        }

        assertEq(secondExecutionCount, totalPositions - batchCap, "Next swap should resume and drain deferred triggers");
        assertEq(secondFailureCount, 0, "Deferred processing should complete without HookActionFailed");
        for (uint256 i; i < totalPositions; ++i) {
            if (i < batchCap) {
                assertFalse(executedSecond[i], "Already processed tokens must not execute again");
            } else {
                assertTrue(executedSecond[i], "Deferred token should execute on the later swap");
            }
            assertEq(positionManager.getPositionLiquidity(tokenIds[i]), 0, "All staged tokens should be fully exited");
            (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenIds[i]);
            assertEq(modeFlags, PositionModeFlags.MODE_NONE, "All staged tokens should be disabled after drain");
        }

        (, uint32 upperAfterSecond, int24 upperHeadAfterSecond) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperAfterSecond, 0, "Later swap should drain the deferred upper triggers");
        assertEq(upperHeadAfterSecond, 0, "Drained upper trigger list should return to empty head");
        _verifyNoLeftoverBalances("batch-cap deferred trigger processing");
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
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
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
        // Configure a non-existent routed pool so swap-to-ratio fails and remint has no usable token1.
        _setBidirectionalRoute(
            PoolKey({currency0: poolKey.currency0, currency1: poolKey.currency1, fee: 500, tickSpacing: 60, hooks: IHooks(address(0))})
        );
        (uint32 lowerInitial, uint32 upperInitial) = _getTriggerListSizes();

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -poolKey.tickSpacing * 2,
                autoRangeUpperDelta: -poolKey.tickSpacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        (uint32 lowerConfigured, uint32 upperConfigured) = _getTriggerListSizes();
        assertEq(lowerConfigured, lowerInitial + 1, "AUTO_RANGE config should add the lower trigger");
        assertEq(upperConfigured, upperInitial, "Upper trigger should remain disabled in failure setup");

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        assertGt(liquidityBefore, 0, "Position should start with liquidity");

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
        assertTrue(
            _sawHookActionFailed(logs, token3Id, RevertHookState.Mode.AUTO_RANGE),
            "Failed AUTO_RANGE should emit HookActionFailed"
        );
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Remint failure should not create a new token");
        assertGt(positionManager.getPositionLiquidity(token3Id), 0, "Original position should be restored");

        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_RANGE, "Position config should remain active after fallback");
        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerInitial, "Failed AUTO_RANGE should consume the fired lower trigger");
        assertEq(upperAfter, upperInitial, "Failed AUTO_RANGE should not leave stale trigger nodes");
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should not retain currency0 after fallback");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should not retain currency1 after fallback");
    }

    /// @notice Helper function to set up auto compound test: configures position, generates fees
    /// @param autoCollectMode The auto compound mode to test
    /// @return token2Liquidity The initial liquidity of the position
    function _setupAutoCollectTest(RevertHook.AutoCollectMode autoCollectMode)
        internal
        returns (uint128 token2Liquidity)
    {
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: autoCollectMode,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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

    /// @notice Helper struct to hold balance snapshots before autoCollect
    struct BalanceSnapshot {
        uint256 executorBalance0;
        uint256 executorBalance1;
        uint256 ownerBalance0;
        uint256 ownerBalance1;
        uint256 protocolFeeRecipientBalance0;
        uint256 protocolFeeRecipientBalance1;
    }

    struct SendProtocolFeeEvent {
        bool found;
        uint256 amount0;
        uint256 amount1;
        address recipient;
    }

    /// @notice Helper function to record balances before autoCollect
    /// @return snapshot The balance snapshot
    function _recordBalancesBeforeAutoCollect() internal view returns (BalanceSnapshot memory snapshot) {
        address executor = address(this);
        address feeRecipient = feeController.protocolFeeRecipient();
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
        assertEq(
            currency0.balanceOf(address(hook)),
            0,
            string.concat("Hook should have 0 balance of currency0 after ", context)
        );
        assertEq(
            currency1.balanceOf(address(hook)),
            0,
            string.concat("Hook should have 0 balance of currency1 after ", context)
        );
    }

    function testBasicAutoCollect() public {
        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.AUTO_COLLECT);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCollect(params);

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
        address feeRecipient = feeController.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0 + protocolFee1, 0, "ProtocolFeeRecipient should have received fees");
    }

    function testBasicAutoHarvestToken0() public {
        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.HARVEST_TOKEN_0);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCollect(params);

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
        address feeRecipient = feeController.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0, 0, "ProtocolFeeRecipient should have received fees in token0");
        assertGt(protocolFee1, 0, "ProtocolFeeRecipient should have received fees in token1");
    }

    function testBasicAutoHarvestToken1() public {
        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.HARVEST_TOKEN_1);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCollect(params);

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
        address feeRecipient = feeController.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0, 0, "ProtocolFeeRecipient should have received fees in token0");
        assertGt(protocolFee1, 0, "ProtocolFeeRecipient should have received fees in token1");
    }

    function testBasicAutoHarvestTokens() public {
        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.HARVEST_TOKENS);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCollect(params);

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
        address feeRecipient = feeController.protocolFeeRecipient();
        uint256 protocolFeeRecipientBalance0After = currency0.balanceOf(feeRecipient);
        uint256 protocolFeeRecipientBalance1After = currency1.balanceOf(feeRecipient);
        uint256 protocolFee0 = protocolFeeRecipientBalance0After - before.protocolFeeRecipientBalance0;
        uint256 protocolFee1 = protocolFeeRecipientBalance1After - before.protocolFeeRecipientBalance1;
        assertGt(protocolFee0, 0, "ProtocolFeeRecipient should have received fees in token0");
        assertGt(protocolFee1, 0, "ProtocolFeeRecipient should have received fees in token1");
    }

    function testSwapFees_AutoCollectRebalanceChargesSwapOutput() public {
        feeController.setLpFeeBps(0);
        feeController.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), 500);

        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.AUTO_COLLECT);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;

        vm.recordLogs();
        hook.autoCollect(params);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, token2Id);
        assertTrue(feeEvent.found, "swap fee event should be emitted");
        assertEq(feeEvent.recipient, protocolFeeRecipient, "swap fee recipient mismatch");
        assertTrue(
            (feeEvent.amount0 > 0 && feeEvent.amount1 == 0) || (feeEvent.amount0 == 0 && feeEvent.amount1 > 0),
            "swap fee should be charged on exactly one output token"
        );

        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "currency0 fee balance mismatch"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "currency1 fee balance mismatch"
        );
        assertGt(positionManager.getPositionLiquidity(token2Id), token2Liquidity, "auto collect should still compound");
    }

    function testSwapFees_HarvestToken1ChargesBoughtToken() public {
        feeController.setLpFeeBps(0);
        feeController.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), 500);

        _setupAutoCollectTest(RevertHookState.AutoCollectMode.HARVEST_TOKEN_1);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;

        vm.recordLogs();
        hook.autoCollect(params);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, token2Id);
        assertTrue(feeEvent.found, "swap fee event should be emitted");
        assertEq(feeEvent.amount0, 0, "harvest token1 swap fee should not charge token0");
        assertGt(feeEvent.amount1, 0, "harvest token1 swap fee should charge bought token1");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient),
            before.protocolFeeRecipientBalance0,
            "recipient should not receive token0 swap fees"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "recipient should receive token1 swap fees"
        );
    }

    function testSwapRouting_AutoCollectFallsBackToHookedPoolAfterClearingRoute() public {
        feeController.setLpFeeBps(0);
        feeController.setPoolOverrideSwapFeeBps(poolId, uint8(RevertHookState.Mode.AUTO_COLLECT), 500);

        _setBidirectionalRoute(nonHookedPoolKey);
        routeController.clearRoute(Currency.unwrap(currency0), Currency.unwrap(currency1));
        routeController.clearRoute(Currency.unwrap(currency1), Currency.unwrap(currency0));

        (bool hasForwardRoute,,, ) = routeController.route(Currency.unwrap(currency0), Currency.unwrap(currency1));
        (bool hasReverseRoute,,, ) = routeController.route(Currency.unwrap(currency1), Currency.unwrap(currency0));
        assertFalse(hasForwardRoute, "forward route should be cleared before fallback test");
        assertFalse(hasReverseRoute, "reverse route should be cleared before fallback test");

        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.AUTO_COLLECT);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        PoolId nonHookedPoolId = nonHookedPoolKey.toId();
        (uint160 hookedSqrtPriceBefore, int24 hookedTickBefore,,) = StateLibrary.getSlot0(poolManager, poolId);
        (uint160 nonHookedSqrtPriceBefore, int24 nonHookedTickBefore,,) =
            StateLibrary.getSlot0(poolManager, nonHookedPoolId);

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;

        vm.recordLogs();
        hook.autoCollect(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, token2Id);
        assertTrue(feeEvent.found, "fallback swap should charge fees using the hooked pool override");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "fallback currency0 fee balance mismatch"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "fallback currency1 fee balance mismatch"
        );

        (uint160 hookedSqrtPriceAfter, int24 hookedTickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);
        (uint160 nonHookedSqrtPriceAfter, int24 nonHookedTickAfter,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolId);

        assertTrue(
            hookedSqrtPriceAfter != hookedSqrtPriceBefore || hookedTickAfter != hookedTickBefore,
            "fallback should execute the rebalance swap in the hooked pool"
        );
        assertEq(nonHookedSqrtPriceAfter, nonHookedSqrtPriceBefore, "non-hooked pool price should stay unchanged");
        assertEq(nonHookedTickAfter, nonHookedTickBefore, "non-hooked pool tick should stay unchanged");
        assertGt(positionManager.getPositionLiquidity(token2Id), token2Liquidity, "fallback should still compound");
    }

    function testSwapRouting_AutoCollectConfiguredHookedPoolRouteExecutesSwap() public {
        feeController.setLpFeeBps(0);
        feeController.setPoolOverrideSwapFeeBps(poolId, uint8(RevertHookState.Mode.AUTO_COLLECT), 500);

        _setBidirectionalRoute(poolKey);

        (bool hasForwardRoute, uint24 forwardFee, int24 forwardTickSpacing, IHooks forwardHooks) =
            routeController.route(Currency.unwrap(currency0), Currency.unwrap(currency1));
        (bool hasReverseRoute, uint24 reverseFee, int24 reverseTickSpacing, IHooks reverseHooks) =
            routeController.route(Currency.unwrap(currency1), Currency.unwrap(currency0));
        assertTrue(hasForwardRoute && hasReverseRoute, "same-pool route should be configured for both directions");
        assertEq(forwardFee, poolKey.fee, "forward route fee should match the hooked pool");
        assertEq(reverseFee, poolKey.fee, "reverse route fee should match the hooked pool");
        assertEq(forwardTickSpacing, poolKey.tickSpacing, "forward route spacing should match the hooked pool");
        assertEq(reverseTickSpacing, poolKey.tickSpacing, "reverse route spacing should match the hooked pool");
        assertEq(address(forwardHooks), address(hook), "forward route should point to the hooked pool");
        assertEq(address(reverseHooks), address(hook), "reverse route should point to the hooked pool");

        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.AUTO_COLLECT);
        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        PoolId nonHookedPoolId = nonHookedPoolKey.toId();
        (uint160 hookedSqrtPriceBefore, int24 hookedTickBefore,,) = StateLibrary.getSlot0(poolManager, poolId);
        (uint160 nonHookedSqrtPriceBefore, int24 nonHookedTickBefore,,) =
            StateLibrary.getSlot0(poolManager, nonHookedPoolId);

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;

        vm.recordLogs();
        hook.autoCollect(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, token2Id);
        assertTrue(feeEvent.found, "configured same-pool route should still execute the rebalance swap");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "same-pool route currency0 fee balance mismatch"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "same-pool route currency1 fee balance mismatch"
        );

        (uint160 hookedSqrtPriceAfter, int24 hookedTickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);
        (uint160 nonHookedSqrtPriceAfter, int24 nonHookedTickAfter,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolId);

        assertTrue(
            hookedSqrtPriceAfter != hookedSqrtPriceBefore || hookedTickAfter != hookedTickBefore,
            "configured same-pool route should swap in the hooked pool"
        );
        assertEq(nonHookedSqrtPriceAfter, nonHookedSqrtPriceBefore, "non-hooked pool price should stay unchanged");
        assertEq(nonHookedTickAfter, nonHookedTickBefore, "non-hooked pool tick should stay unchanged");
        assertGt(positionManager.getPositionLiquidity(token2Id), token2Liquidity, "same-pool route should still compound");
    }

    function testSwapRouting_AutoCollectUsesAsymmetricRoutesAtRuntime() public {
        PoolKey memory reversePoolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0))});
        PoolId reversePoolId = reversePoolKey.toId();
        poolManager.initialize(reversePoolKey, Constants.SQRT_PRICE_1_1);

        uint128 liquidityAmount = 100e18;
        positionManager.mint(
            reversePoolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        _setRoute(Currency.unwrap(currency0), Currency.unwrap(currency1), nonHookedPoolKey.fee, nonHookedPoolKey.tickSpacing, nonHookedPoolKey.hooks);
        _setRoute(Currency.unwrap(currency1), Currency.unwrap(currency0), reversePoolKey.fee, reversePoolKey.tickSpacing, reversePoolKey.hooks);

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;

        _setupAutoCollectTest(RevertHookState.AutoCollectMode.HARVEST_TOKEN_1);
        (uint160 forwardPoolSqrtBefore, int24 forwardPoolTickBefore,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolKey.toId());
        (uint160 reversePoolSqrtBefore, int24 reversePoolTickBefore,,) = StateLibrary.getSlot0(poolManager, reversePoolId);

        hook.autoCollect(params);

        (uint160 forwardPoolSqrtAfter, int24 forwardPoolTickAfter,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolKey.toId());
        (uint160 reversePoolSqrtAfter, int24 reversePoolTickAfter,,) = StateLibrary.getSlot0(poolManager, reversePoolId);

        assertTrue(
            forwardPoolSqrtAfter != forwardPoolSqrtBefore || forwardPoolTickAfter != forwardPoolTickBefore,
            "token0 -> token1 harvest should use the forward route"
        );
        assertEq(reversePoolSqrtAfter, reversePoolSqrtBefore, "reverse route pool should stay unchanged on forward swap");
        assertEq(reversePoolTickAfter, reversePoolTickBefore, "reverse route tick should stay unchanged on forward swap");

        _setupAutoCollectTest(RevertHookState.AutoCollectMode.HARVEST_TOKEN_0);
        (forwardPoolSqrtBefore, forwardPoolTickBefore,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolKey.toId());
        (reversePoolSqrtBefore, reversePoolTickBefore,,) = StateLibrary.getSlot0(poolManager, reversePoolId);

        hook.autoCollect(params);

        (forwardPoolSqrtAfter, forwardPoolTickAfter,,) = StateLibrary.getSlot0(poolManager, nonHookedPoolKey.toId());
        (reversePoolSqrtAfter, reversePoolTickAfter,,) = StateLibrary.getSlot0(poolManager, reversePoolId);

        assertEq(forwardPoolSqrtAfter, forwardPoolSqrtBefore, "forward route pool should stay unchanged on reverse swap");
        assertEq(forwardPoolTickAfter, forwardPoolTickBefore, "forward route tick should stay unchanged on reverse swap");
        assertTrue(
            reversePoolSqrtAfter != reversePoolSqrtBefore || reversePoolTickAfter != reversePoolTickBefore,
            "token1 -> token0 harvest should use the reverse route"
        );
    }

    function testSwapFees_AutoRangeUsesAlternateSwapPoolOverride() public {
        feeController.setLpFeeBps(0);
        feeController.setPoolOverrideSwapFeeBps(nonHookedPoolKey.toId(), uint8(RevertHookState.Mode.AUTO_RANGE), 500);

        _setBidirectionalRoute(nonHookedPoolKey);
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();
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
        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, token3Id);
        assertTrue(feeEvent.found, "pool override should enable swap fee collection");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "currency0 override fee balance mismatch"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "currency1 override fee balance mismatch"
        );
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "auto range should consume the original position");
    }

    function testSwapFees_PartialSwapChargesOnActualOutput() public {
        feeController.setLpFeeBps(0);
        feeController.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_EXIT), 500);

        uint32 maxPriceImpactBps = 10;
        _setSwapProtection(token2Id, maxPriceImpactBps, maxPriceImpactBps);
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        IERC721(address(positionManager)).approve(address(hook), token2Id);

        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();
        vm.recordLogs();

        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(
            _sawEventTopic(logs, keccak256("HookSwapPartial(uint256,bool,uint256,uint256)")),
            "partial swap should still emit HookSwapPartial"
        );

        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, token2Id);
        assertTrue(feeEvent.found, "partial swap should still charge a fee on actual output");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "currency0 partial fee balance mismatch"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "currency1 partial fee balance mismatch"
        );
    }

    function testBasicAutoExit() public {
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: true, // Use RELATIVE ticks
                autoExitTickLower: poolKey.tickSpacing, // Exit tick = posTickLower - tickSpacing
                autoExitTickUpper: type(int24).max, // Don't exit on upper side
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false, // Use absolute ticks
                autoExitTickLower: type(int24).min, // Set to min so it never triggers on lower side
                autoExitTickUpper: tickUpper3 + poolKey.tickSpacing * 3,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        assertEq(
            positionManager.getPositionLiquidity(token3Id), 0, "Old position should have 0 liquidity after auto-range"
        );

        uint256 nextTokenIdAfter = positionManager.nextTokenId();
        assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "A new position should be minted after auto-range");

        // Get the new position info
        uint256 newTokenId = nextTokenIdBefore;
        (, PositionInfo posInfoNew) = positionManager.getPoolAndPositionInfo(newTokenId);
        int24 newTickLower = posInfoNew.tickLower();
        int24 newTickUpper = posInfoNew.tickUpper();

        // Verify new position has different range
        assertTrue(
            newTickLower != initialTickLower || newTickUpper != initialTickUpper,
            "New position should have a different range than the old position"
        );

        // Verify new position has liquidity
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "New position should have liquidity > 0");

        // Verify current tick is within the new position's range
        assertTrue(
            currentTickAfterRange >= newTickLower && currentTickAfterRange <= newTickUpper,
            "Current tick should be within the new position's range"
        );

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
        _setBidirectionalRoute(nonHookedPoolKey);

        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        IERC721(address(positionManager)).approve(address(hook), token2Id);

        // Assert that token2Id position has > 0 liquidity after swap (out of range)
        uint128 token2Liquidity = positionManager.getPositionLiquidity(token2Id);
        assertGt(token2Liquidity, 0, "token2Id should have > 0 liquidity");

        // Record initial state of nonHookedPool before swap
        PoolId nonHookedPoolId = nonHookedPoolKey.toId();
        (uint160 sqrtPriceX96NonHookedBefore, int24 tickNonHookedBefore,,) =
            StateLibrary.getSlot0(poolManager, nonHookedPoolId);
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
        (uint160 sqrtPriceX96NonHookedAfter, int24 tickNonHookedAfter,,) =
            StateLibrary.getSlot0(poolManager, nonHookedPoolId);
        assertGt(sqrtPriceX96NonHookedAfter, 0, "NonHookedPool should be initialized and have a price");

        console.log("NonHookedPool sqrtPrice AFTER swap:", sqrtPriceX96NonHookedAfter);
        console.log("NonHookedPool tick AFTER swap:", tickNonHookedAfter);

        // Verify the price changed in the nonHookedPool (proving swap happened there)
        assertTrue(
            sqrtPriceX96NonHookedAfter != sqrtPriceX96NonHookedBefore,
            "NonHookedPool price should have changed after swap"
        );
        assertTrue(tickNonHookedAfter != tickNonHookedBefore, "NonHookedPool tick should have changed after swap");

        console.log(
            "Price change:", sqrtPriceX96NonHookedAfter > sqrtPriceX96NonHookedBefore ? "increased" : "decreased"
        );
        console.log("Tick change:", int256(tickNonHookedAfter) - int256(tickNonHookedBefore));

        // Verify the nonHookedPool has liquidity (from the initial mint in setUp)
        uint128 nonHookedLiquidity = poolManager.getLiquidity(nonHookedPoolId);
        assertGt(nonHookedLiquidity, 0, "NonHookedPool should have liquidity");
        console.log("NonHookedPool liquidity:", nonHookedLiquidity);
    }

    function testAutoExit_NotApproved() public {
        // Set up autoExit config for token2Id
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        assertGt(
            token2LiquidityAfter, 0, "token2Id should still have liquidity because autoExit failed without approval"
        );
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
        PoolKey memory newPoolKey = PoolKey({ currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 10, hooks: IHooks(address(0)) });
        PoolId newPoolId = newPoolKey.toId();

        // Initialize the new pool
        poolManager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

        // Get initial tick
        int24 initialTick = TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_1);
        console.log("Initial tick:", initialTick);

        // Calculate liquidity amounts for the narrow range
        uint128 liquidityAmount = 50e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-10), TickMath.getSqrtPriceAtTick(10), liquidityAmount
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
        hook.setPositionConfig(
            autolendTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 60,
                autoLeverageTargetBps: 0
            })
        );

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
        (,,, autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
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
        (,,, autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendShares, 0, "Should have no autolend shares after currency0 withdraw");
        assertEq(autoLendToken, address(0), "Should have no autolend token after withdraw");
        assertLt(vault0.totalAssets(), vault0BalanceBefore, "Vault0 should have less assets after withdraw");

        uint128 liquidityAfterCurrency0Withdraw = positionManager.getPositionLiquidity(autolendTokenId);
        assertGt(
            liquidityAfterCurrency0Withdraw,
            liquidityAfterCurrency0Deposit,
            "Position liquidity should increase after currency0 withdraw"
        );

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
        (,,, autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
        assertGt(autoLendShares, 0, "Should have autolend shares after currency1 deposit");
        assertEq(autoLendToken, Currency.unwrap(currency1), "Should have currency1 as autolend token");
        assertGt(vault1.totalAssets(), vault1BalanceBefore, "Vault1 should have received assets");

        uint128 liquidityAfterCurrency1Deposit = positionManager.getPositionLiquidity(autolendTokenId);
        assertEq(liquidityAfterCurrency1Deposit, 0, "Position liquidity be 0 after currency1 deposit");

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
        (,,, autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendShares, 0, "Should have no autolend shares after currency1 withdraw");
        assertEq(autoLendToken, address(0), "Should have no autolend token after withdraw");
        assertLt(vault1.totalAssets(), vault1BalanceBefore, "Vault1 should have less assets after withdraw");

        assertGt(
            positionManager.getPositionLiquidity(autolendTokenId),
            liquidityAfterCurrency1Deposit,
            "Position liquidity should increase after currency1 withdraw"
        );

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

        (,,, autoLendToken, autoLendShares,,,) = hook.positionStates(autolendTokenId);

        // Verify currency0 deposit was triggered again
        assertGt(autoLendShares, 0, "Should have autolend shares after second currency0 deposit");
        assertEq(autoLendToken, Currency.unwrap(currency0), "Should have currency0 as autolend token again");
        assertGt(vault0.totalAssets(), vault0BalanceBefore, "Vault0 should have received assets in second deposit");

        assertEq(
            positionManager.getPositionLiquidity(autolendTokenId),
            0,
            "Position liquidity be 0 after second currency0 deposit"
        );

        // Final verification: hook contract has no leftover token balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testAutoLend_WithdrawSendsProtocolFeesToRecipient() public {
        uint256 autolendTokenId = _createActiveAutoLendPosition();

        (,,, address autoLendToken, uint256 shares, uint256 autoLendAmount,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendToken, Currency.unwrap(currency0), "Position should be parked in vault0 before withdraw");
        assertGt(shares, 0, "Position should hold auto-lend shares before withdraw");

        uint256 donatedYield = autoLendAmount + 1;
        IERC20(Currency.unwrap(currency0)).transfer(address(vault0), donatedYield);
        vault0.simulatePositiveYield(10000);

        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, autolendTokenId);
        assertTrue(feeEvent.found, "withdraw should emit protocol fee event");
        assertEq(feeEvent.recipient, protocolFeeRecipient, "withdraw protocol fee recipient mismatch");
        assertGt(feeEvent.amount0, 0, "withdraw should charge token0 auto-lend fee");
        assertEq(feeEvent.amount1, 0, "withdraw should not charge token1 auto-lend fee");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "recipient token0 balance should match the fee event"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            0,
            "recipient should not receive token1 fees on token0 withdraw"
        );
        _verifyNoLeftoverBalances("auto-lend withdraw");
    }

    function testDirectAutoLendForceExit_SendsProtocolFeesToRecipient() public {
        uint256 autolendTokenId = _createActiveAutoLendPosition();

        (,,, address autoLendToken, uint256 shares, uint256 autoLendAmount,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendToken, Currency.unwrap(currency0), "Position should be parked in vault0 before exit");
        assertGt(shares, 0, "Position should hold auto-lend shares before exit");

        uint256 donatedYield = autoLendAmount + 1;
        IERC20(Currency.unwrap(currency0)).transfer(address(vault0), donatedYield);
        vault0.simulatePositiveYield(10000);

        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        vm.recordLogs();
        hook.autoLendForceExit(autolendTokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, autolendTokenId);
        assertTrue(feeEvent.found, "force exit should emit protocol fee event");
        assertEq(feeEvent.recipient, protocolFeeRecipient, "force exit protocol fee recipient mismatch");
        assertGt(feeEvent.amount0, 0, "force exit should charge token0 auto-lend fee");
        assertEq(feeEvent.amount1, 0, "force exit should not charge token1 auto-lend fee");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            feeEvent.amount0,
            "recipient token0 balance should match the force-exit fee event"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            0,
            "recipient should not receive token1 fees on token0 force exit"
        );
        _verifyNoLeftoverBalances("auto-lend force exit");
    }

    function testAutoLend_Token1WithdrawSendsProtocolFeesToRecipient() public {
        uint256 autolendTokenId = _createActiveAutoLendPositionToken1();

        (,,, address autoLendToken, uint256 shares, uint256 autoLendAmount,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendToken, Currency.unwrap(currency1), "Position should be parked in vault1 before withdraw");
        assertGt(shares, 0, "Position should hold token1 auto-lend shares before withdraw");

        uint256 donatedYield = autoLendAmount + 1;
        IERC20(Currency.unwrap(currency1)).transfer(address(vault1), donatedYield);
        vault1.simulatePositiveYield(10000);

        BalanceSnapshot memory before = _recordBalancesBeforeAutoCollect();

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SendProtocolFeeEvent memory feeEvent = _findSendProtocolFee(logs, autolendTokenId);
        assertTrue(feeEvent.found, "token1 withdraw should emit protocol fee event");
        assertEq(feeEvent.recipient, protocolFeeRecipient, "token1 withdraw protocol fee recipient mismatch");
        assertEq(feeEvent.amount0, 0, "token1 withdraw should not charge token0 auto-lend fee");
        assertGt(feeEvent.amount1, 0, "token1 withdraw should charge token1 auto-lend fee");
        assertEq(
            currency0.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance0,
            0,
            "recipient should not receive token0 fees on token1 withdraw"
        );
        assertEq(
            currency1.balanceOf(protocolFeeRecipient) - before.protocolFeeRecipientBalance1,
            feeEvent.amount1,
            "recipient token1 balance should match the fee event"
        );
        _verifyNoLeftoverBalances("token1 auto-lend withdraw");
    }

    function testDirectAutoExit_RevertsWhenCalledExternally() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.autoExit(poolKey, token3Id, false);
    }

    function testDirectAutoRange_RevertsWhenCalledExternally() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.autoRange(poolKey, token3Id);
    }

    function testDirectAutoLeverage_RevertsWhenCalledExternally() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.autoLeverage(poolKey, token3Id, false);
    }

    function testDirectAutoCollectForVault_RevertsWhenCalledExternally() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.autoCollectForVault(token3Id, address(this));
    }

    function testDirectAutoLendForceExit_RevertsWhenCallerIsNotOwner() public {
        uint256 autolendTokenId = _createActiveAutoLendPosition();
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.autoLendForceExit(autolendTokenId);
    }

    function testDirectAutoLendForceExit_OwnerCanExit() public {
        uint256 autolendTokenId = _createActiveAutoLendPosition();

        (,,, address autoLendTokenBefore, uint256 sharesBefore,,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendTokenBefore, Currency.unwrap(currency0), "Position should be parked in vault0 before exit");
        assertGt(sharesBefore, 0, "Position should hold auto-lend shares before exit");

        hook.autoLendForceExit(autolendTokenId);

        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(autolendTokenId);
        (,,, address autoLendTokenAfter, uint256 sharesAfter,,,) = hook.positionStates(autolendTokenId);

        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Force exit should disable the position");
        assertEq(autoLendTokenAfter, address(0), "Auto-lend token should be cleared after force exit");
        assertEq(sharesAfter, 0, "Auto-lend shares should be cleared after force exit");
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should not retain currency0 after force exit");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should not retain currency1 after force exit");
    }

    function testUnlockCallback_RevertsWhenCallerIsNotPoolManager() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.unlockCallback(bytes(""));
    }

    function testUnlockCallback_AutoCollectPayloadExecutes() public {
        _setupAutoCollectTest(RevertHookState.AutoCollectMode.AUTO_COLLECT);

        vm.recordLogs();
        vm.prank(address(poolManager));
        bytes memory result =
            hook.unlockCallback(abi.encode(RevertHookState.UnlockAction.AUTO_COLLECT, token2Id, address(this)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(result.length, 0, "unlockCallback should return empty bytes");
        assertTrue(
            _sawEventTopic(logs, keccak256("HookModifyLiquiditiesFailed(bytes,bytes[],bytes)")),
            "Tagged payload should route to the auto-collect liquidity path"
        );
        assertFalse(
            _sawHookActionFailed(logs, token2Id, RevertHookState.Mode.AUTO_COLLECT),
            "Auto-collect routing failures inside modifyLiquidities should not be masked as HookActionFailed"
        );
    }

    function testUnlockCallback_RevertsOnMalformedPayload() public {
        vm.prank(address(poolManager));
        vm.expectRevert();
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function testUnlockCallback_ImmediateActionPayloadExecutes() public {
        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_RANGE, true, false, type(int24).min, type(int24).max)
        );

        vm.recordLogs();
        vm.prank(address(poolManager));
        bytes memory result =
            hook.unlockCallback(abi.encode(RevertHookState.UnlockAction.IMMEDIATE_ACTION, token3Id, true, int24(0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(result.length, 0, "unlockCallback should return empty bytes");
        assertTrue(
            _sawHookActionFailed(logs, token3Id, RevertHookState.Mode.AUTO_RANGE),
            "Tagged payload should route to the immediate action path"
        );
    }

    function testAutoLendWithdrawRemintCopiesSwapProtectionConfig() public {
        hook.setMaxTicksFromOracle(1000);

        int24 testTickLower = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        int24 testTickUpper = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;
        uint128 liquidityAmount = 50e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(testTickLower),
            TickMath.getSqrtPriceAtTick(testTickUpper),
            liquidityAmount
        );

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

        hook.setPositionConfig(
            autolendTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 60,
                autoLeverageTargetBps: 0
            })
        );
        _setSwapProtection(autolendTokenId, 123, 456);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        (uint128 multiplier0Before, uint128 multiplier1Before) = hook.swapProtectionConfigs(autolendTokenId);

        uint256 swapAmount = 20e17;
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(autolendTokenId);
        assertEq(
            positionManager.getPositionLiquidity(autolendTokenId), 0, "Deposit should remove the original liquidity"
        );
        assertGt(autoLendShares, 0, "Deposit should create lend shares");
        assertEq(autoLendToken, Currency.unwrap(currency0), "Deposit should lend token0 on the lower side");

        uint256 nextTokenIdBeforeWithdraw = positionManager.nextTokenId();
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        assertEq(
            positionManager.nextTokenId(), nextTokenIdBeforeWithdraw + 1, "Withdraw should remint exactly one token"
        );
        uint256 newTokenId = nextTokenIdBeforeWithdraw;

        (uint128 multiplier0After, uint128 multiplier1After) = hook.swapProtectionConfigs(newTokenId);
        assertEq(multiplier0After, multiplier0Before, "sqrtPriceMultiplier0 should copy on auto-lend remint");
        assertEq(multiplier1After, multiplier1Before, "sqrtPriceMultiplier1 should copy on auto-lend remint");
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

            hook.setPositionConfig(
                token3Id, _buildNonVaultModeConfig(mode, false, false, type(int24).min, type(int24).max)
            );

            (uint8 storedMode, RevertHookState.AutoCollectMode storedAutoCollectMode,,,,,,,,,) =
                hook.positionConfigs(token3Id);
            assertEq(storedMode, mode, "Stored mode flags mismatch");

            if ((mode & PositionModeFlags.MODE_AUTO_COLLECT) != 0) {
                assertEq(
                    uint8(storedAutoCollectMode),
                    uint8(RevertHookState.AutoCollectMode.AUTO_COLLECT),
                    "AUTO_COLLECT mode should be enabled"
                );
            } else {
                assertEq(
                    uint8(storedAutoCollectMode),
                    uint8(RevertHookState.AutoCollectMode.NONE),
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
            hook.setPositionConfig(
                token3Id, _buildNonVaultModeConfig(mode, false, false, type(int24).min, type(int24).max)
            );

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

    function testSetAutoLendVault_RejectsMismatchedVaultAsset() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setAutoLendVault(Currency.unwrap(currency0), vault1);
    }

    function testSetAutoLendVault_RejectsNativeTokenConfig() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setAutoLendVault(address(0), vault0);
    }

    function testRouteController_StoresOrderedRoutes() public {
        _setRoute(Currency.unwrap(currency0), Currency.unwrap(currency1), 500, 60, IHooks(hook));
        _setRoute(Currency.unwrap(currency1), Currency.unwrap(currency0), 3000, 120, IHooks(address(0)));

        (bool hasForwardRoute, uint24 forwardFee, int24 forwardTickSpacing, IHooks forwardHooks) =
            routeController.route(Currency.unwrap(currency0), Currency.unwrap(currency1));
        (bool hasReverseRoute, uint24 reverseFee, int24 reverseTickSpacing, IHooks reverseHooks) =
            routeController.route(Currency.unwrap(currency1), Currency.unwrap(currency0));

        assertTrue(hasForwardRoute, "forward route should be stored");
        assertEq(forwardFee, 500, "forward fee should match route config");
        assertEq(forwardTickSpacing, 60, "forward tick spacing should match route config");
        assertEq(address(forwardHooks), address(hook), "forward hooks should match route config");

        assertTrue(hasReverseRoute, "reverse route should be stored independently");
        assertEq(reverseFee, 3000, "reverse fee should match route config");
        assertEq(reverseTickSpacing, 120, "reverse tick spacing should match route config");
        assertEq(address(reverseHooks), address(0), "reverse hooks should match route config");
    }

    function testSetSwapProtectionConfig_StoresPriceImpactConfig() public {
        uint32 maxPriceImpactBps0 = 125;
        uint32 maxPriceImpactBps1 = 250;

        _setSwapProtection(token3Id, maxPriceImpactBps0, maxPriceImpactBps1);

        (uint128 multiplier0, uint128 multiplier1) = hook.swapProtectionConfigs(token3Id);
        assertEq(
            multiplier0,
            _expectedSqrtPriceMultiplier(maxPriceImpactBps0, true),
            "sqrtPriceMultiplier0 should match config formula"
        );
        assertEq(
            multiplier1,
            _expectedSqrtPriceMultiplier(maxPriceImpactBps1, false),
            "sqrtPriceMultiplier1 should match config formula"
        );
    }

    function testSetSwapProtectionConfig_RevertsWhenPriceImpactExceedsMax() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        _setSwapProtection(token3Id, 10001, 0);

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        _setSwapProtection(token3Id, 0, 10001);
    }

    function testSetPositionConfig_StoresCustomAutoCollectAndRangeConfig() public {
        RevertHookState.PositionConfig memory config = _buildNonVaultModeConfig(
            PositionModeFlags.MODE_AUTO_COLLECT | PositionModeFlags.MODE_AUTO_RANGE,
            true,
            false,
            type(int24).min,
            type(int24).max
        );
        config.autoCollectMode = RevertHookState.AutoCollectMode.HARVEST_TOKEN_1;

        hook.setPositionConfig(token3Id, config);

        _assertPositionConfigEq(token3Id, config);
    }

    function testSetPositionConfig_StoresCustomAutoExitConfig() public {
        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: true,
            autoExitTickLower: -2 * poolKey.tickSpacing,
            autoExitTickUpper: 2 * poolKey.tickSpacing,
            autoExitSwapOnLowerTrigger: false,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        hook.setPositionConfig(token3Id, config);

        _assertPositionConfigEq(token3Id, config);
    }

    function testSetPositionConfig_StoresCustomAutoLendConfig() public {
        RevertHookState.PositionConfig memory config =
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max);
        config.autoLendToleranceTick = 2 * poolKey.tickSpacing;

        hook.setPositionConfig(token3Id, config);

        _assertPositionConfigEq(token3Id, config);
    }

    function testSetPositionConfig_AutoLendRequiresVaultsForBothPoolTokens() public {
        hook.setAutoLendVault(Currency.unwrap(currency0), IERC4626(address(0)));

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max)
        );
    }

    function testSetSwapProtectionConfig_RevertsWhenCallerIsNotOwner() public {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.setSwapProtectionConfig(token3Id, 0, 0);
    }

    function testSetPositionConfig_RevertsWhenCallerIsNotOwner() public {
        address notOwner = makeAddr("notOwner");
        RevertHookState.PositionConfig memory config =
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_RANGE, true, false, type(int24).min, type(int24).max);

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.setPositionConfig(token3Id, config);
    }

    function testAdminSetters_OwnerCanUpdateProtocolConfigAndVault() public {
        address newRecipient = makeAddr("newRecipient");
        address newVault = makeAddr("newVault");

        hook.setAutoLendVault(Currency.unwrap(currency0), IERC4626(address(0)));
        hook.setMaxTicksFromOracle(321);
        hook.setMinPositionValueNative(0.123 ether);
        feeController.setLpFeeBps(321);
        feeController.setAutoLendFeeBps(654);
        feeController.setProtocolFeeRecipient(newRecipient);
        hook.setVault(newVault);

        assertEq(address(hook.autoLendVaults(Currency.unwrap(currency0))), address(0), "auto-lend vault should update");
        assertEq(hook.maxTicksFromOracle(), 321, "max ticks from oracle should update");
        assertEq(hook.minPositionValueNative(), 0.123 ether, "minimum position value should update");
        assertEq(feeController.lpFeeBps(), 321, "lp fee bps should update");
        assertEq(feeController.autoLendFeeBps(), 654, "auto-lend fee bps should update");
        assertEq(feeController.protocolFeeRecipient(), newRecipient, "protocol fee recipient should update");
        assertTrue(hook.vaults(newVault), "vault should be allowlisted");
    }

    function testAdminSetters_RevertWhenNonOwnerCalls() public {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        feeController.setLpFeeBps(123);

        vm.prank(notOwner);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        feeController.setAutoLendFeeBps(456);

        vm.prank(notOwner);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        feeController.setProtocolFeeRecipient(makeAddr("feeRecipient"));

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(RevertHookAccess.OwnableUnauthorizedAccount.selector, notOwner));
        hook.setVault(makeAddr("vault"));

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(RevertHookAccess.OwnableUnauthorizedAccount.selector, notOwner));
        hook.setAutoLendVault(Currency.unwrap(currency0), vault0);

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(RevertHookAccess.OwnableUnauthorizedAccount.selector, notOwner));
        hook.setMaxTicksFromOracle(123);

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(RevertHookAccess.OwnableUnauthorizedAccount.selector, notOwner));
        hook.setMinPositionValueNative(1 ether);
    }

    function testGetHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertFalse(permissions.beforeInitialize, "beforeInitialize should be disabled");
        assertTrue(permissions.afterInitialize, "afterInitialize should be enabled");
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(permissions.afterAddLiquidity, "afterAddLiquidity should be enabled");
        assertFalse(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be disabled");
        assertTrue(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be enabled");
        assertFalse(permissions.beforeSwap, "beforeSwap should be disabled");
        assertTrue(permissions.afterSwap, "afterSwap should be enabled");
        assertFalse(permissions.beforeDonate, "beforeDonate should be disabled");
        assertFalse(permissions.afterDonate, "afterDonate should be disabled");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be disabled");
        assertFalse(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be disabled");
        assertTrue(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be enabled");
        assertTrue(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be enabled");
    }

    function testAfterInitialize_SeedsTickCursor() public view {
        assertEq(
            hook.tickLowerLasts(poolId),
            _getTickLower(tickStart, poolKey.tickSpacing),
            "afterInitialize should seed the pool cursor to the initial tick lower"
        );
    }

    function testFeeController_RevertWhenBpsAboveMax() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        feeController.setLpFeeBps(10001);

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        feeController.setAutoLendFeeBps(10001);
    }

    function testTransferOwnershipAndRenounceOwnership() public {
        address newOwner = makeAddr("newOwner");

        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner, "ownership should transfer");

        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        feeController.setLpFeeBps(123);

        vm.prank(newOwner);
        feeController.setLpFeeBps(456);
        assertEq(feeController.lpFeeBps(), 456, "new owner should control fee controller");

        vm.prank(newOwner);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0), "ownership should be cleared");

        vm.prank(newOwner);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        feeController.setProtocolFeeRecipient(makeAddr("recipientAfterRenounce"));
    }

    function testTransferOwnership_RevertWhenNewOwnerIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(RevertHookAccess.OwnableInvalidOwner.selector, address(0)));
        hook.transferOwnership(address(0));
    }

    function testModeCRL_FullAutomationCoverage() public {
        hook.setMaxTicksFromOracle(1000);

        uint8 modeCRL =
            PositionModeFlags.MODE_AUTO_COLLECT | PositionModeFlags.MODE_AUTO_RANGE | PositionModeFlags.MODE_AUTO_LEND;

        // ----- AutoCollect path (C) -----
        hook.setPositionConfig(
            tokenId, _buildNonVaultModeConfig(modeCRL, true, false, type(int24).min, type(int24).max)
        );
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
        hook.autoCollect(tokenIds);

        uint128 liquidityAfterCompound = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfterCompound, liquidityBeforeCompound, "AutoCollect should increase liquidity for C|R|L");

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
        assertEq(
            vault0.totalAssets(), vault0AssetsBefore, "Vault0 should remain unchanged when AUTO_LEND is not executed"
        );
        assertEq(
            vault1.totalAssets(), vault1AssetsBefore, "Vault1 should remain unchanged when AUTO_LEND is not executed"
        );

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
            autoCollectMode: PositionModeFlags.hasAutoCollect(modeFlags)
                ? RevertHookState.AutoCollectMode.AUTO_COLLECT
                : RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: enableExit ? exitTickLower : type(int24).min,
            autoExitTickUpper: enableExit ? exitTickUpper : type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: hasRangeTriggers ? int24(0) : type(int24).min,
            autoRangeUpperLimit: hasRangeTriggers ? int24(0) : type(int24).max,
            autoRangeLowerDelta: hasRangeMode ? -poolKey.tickSpacing : int24(0),
            autoRangeUpperDelta: hasRangeMode ? poolKey.tickSpacing : int24(0),
            autoLendToleranceTick: int24(0),
            autoLeverageTargetBps: 0
        });
    }

    function _createActiveAutoLendPosition() internal returns (uint256 autolendTokenId) {
        hook.setMaxTicksFromOracle(1000);

        int24 testTickLower = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        int24 testTickUpper = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;
        uint128 liquidityAmount = 50e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(testTickLower),
            TickMath.getSqrtPriceAtTick(testTickUpper),
            liquidityAmount
        );

        (autolendTokenId,) = positionManager.mint(
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

        hook.setPositionConfig(
            autolendTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 60,
                autoLeverageTargetBps: 0
            })
        );

        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        swapRouter.swapExactTokensForTokens({
            amountIn: 20e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendToken, Currency.unwrap(currency0), "Position should lend currency0 after setup");
        assertGt(autoLendShares, 0, "Position should hold auto-lend shares after setup");
    }

    function _createActiveAutoLendPositionToken1() internal returns (uint256 autolendTokenId) {
        hook.setMaxTicksFromOracle(1000);

        int24 testTickLower = _getTickLower(tickStart, poolKey.tickSpacing) - poolKey.tickSpacing;
        int24 testTickUpper = _getTickLower(tickStart, poolKey.tickSpacing) + poolKey.tickSpacing;
        uint128 liquidityAmount = 50e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(testTickLower),
            TickMath.getSqrtPriceAtTick(testTickUpper),
            liquidityAmount
        );

        (autolendTokenId,) = positionManager.mint(
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

        hook.setPositionConfig(
            autolendTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 60,
                autoLeverageTargetBps: 0
            })
        );

        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        swapRouter.swapExactTokensForTokens({
            amountIn: 20e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(autolendTokenId);
        assertEq(autoLendToken, Currency.unwrap(currency1), "Position should lend currency1 after setup");
        assertGt(autoLendShares, 0, "Position should hold token1 auto-lend shares after setup");
    }

    function _assertPositionConfigEq(uint256 tokenId_, RevertHookState.PositionConfig memory expected) internal view {
        (
            uint8 modeFlags,
            RevertHookState.AutoCollectMode autoCollectMode,
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
        assertEq(uint8(autoCollectMode), uint8(expected.autoCollectMode), "autoCollectMode mismatch");
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

    function _expectedSqrtPriceMultiplier(uint32 maxPriceImpactBps, bool zeroForOne)
        internal
        pure
        returns (uint128 multiplier)
    {
        if (maxPriceImpactBps == 0) {
            return 0;
        }

        uint256 q64Squared = Q64_TEST * Q64_TEST;
        uint256 numerator = zeroForOne
            ? (10000 - maxPriceImpactBps) * q64Squared / 10000
            : (10000 + maxPriceImpactBps) * q64Squared / 10000;
        multiplier = uint128(Math.sqrt(numerator));
    }

    function _setSwapProtection(uint256 positionTokenId, uint32 maxPriceImpactBps0, uint32 maxPriceImpactBps1)
        internal
    {
        hook.setSwapProtectionConfig(positionTokenId, maxPriceImpactBps0, maxPriceImpactBps1);
    }

    function _setRoute(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, IHooks hooks) internal {
        routeController.setRoute(tokenIn, tokenOut, fee, tickSpacing, hooks);
    }

    function _setBidirectionalRoute(PoolKey memory routePoolKey) internal {
        address token0 = Currency.unwrap(routePoolKey.currency0);
        address token1 = Currency.unwrap(routePoolKey.currency1);
        _setRoute(token0, token1, routePoolKey.fee, routePoolKey.tickSpacing, routePoolKey.hooks);
        _setRoute(token1, token0, routePoolKey.fee, routePoolKey.tickSpacing, routePoolKey.hooks);
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    // ==================== Price Impact Limit Tests ====================

    function testPriceImpactLimit_ZeroMeansNoLimit() public {
        // Configure auto exit with maxPriceImpact = 0 (no limit)
        _setSwapProtection(token2Id, 0, 0);

        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
            if (
                logs[i].topics.length > 0 && logs[i].topics[0] == partialSwapEventSignature
                    && logs[i].emitter == address(hook)
            ) {
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
        _setSwapProtection(token2Id, maxPriceImpactBps, maxPriceImpactBps);

        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
            if (
                logs[i].topics.length > 0 && logs[i].topics[0] == partialSwapEventSignature
                    && logs[i].emitter == address(hook)
            ) {
                partialSwapEventFound = true;
                // Decode the event data
                (, requestedAmount, swappedAmount) = abi.decode(logs[i].data, (bool, uint256, uint256));
                break;
            }
        }

        assertTrue(partialSwapEventFound, "HookSwapPartial should be emitted when price impact limit is reached");
        assertLt(
            swappedAmount, requestedAmount, "Swapped amount should be less than requested due to price impact limit"
        );

        // Verify that the partial swap amount is significantly less than the requested amount
        // With 10 bps limit, the hook's swap should be limited to a small fraction
        assertLt(
            swappedAmount * 10, requestedAmount, "Partial swap should be much smaller than requested with strict limit"
        );

        console.log("Requested swap amount:", requestedAmount);
        console.log("Actual swapped amount:", swappedAmount);
    }

    function testPriceImpactLimit_ModerateLimit() public {
        // Configure auto exit with a moderate price impact limit (100 bps = 1%)
        _setSwapProtection(token2Id, 100, 100);

        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        _setSwapProtection(token2Id, 10, 1000);

        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2 - poolKey.tickSpacing,
                autoExitTickUpper: tickUpper2,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
            if (
                logs[i].topics.length > 0 && logs[i].topics[0] == partialSwapEventSignature
                    && logs[i].emitter == address(hook)
            ) {
                partialSwapEventFound = true;
                break;
            }
        }

        // Should find partial swap event due to strict price impact limit
        assertTrue(partialSwapEventFound, "HookSwapPartial should be emitted for zeroForOne swap with strict limit");
    }

    function testPriceImpactLimit_AutoRangeWithLimit() public {
        // Configure auto range with a moderate price impact limit (200 bps = 2%)
        _setSwapProtection(token3Id, 200, 200);

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        assertEq(
            positionManager.getPositionLiquidity(token3Id), 0, "Old position should have 0 liquidity after auto-range"
        );

        uint256 nextTokenIdAfter = positionManager.nextTokenId();
        assertEq(nextTokenIdAfter, nextTokenIdBefore + 1, "A new position should be minted after auto-range");

        // Verify new position has liquidity
        uint256 newTokenId = nextTokenIdBefore;
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "New position should have liquidity > 0");

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testPriceImpactLimit_AutoCollectWithLimit() public {
        // Configure auto compound with a moderate price impact limit (500 bps = 5%)
        _setSwapProtection(token2Id, 500, 500);

        uint128 token2Liquidity = _setupAutoCollectTest(RevertHookState.AutoCollectMode.AUTO_COLLECT);

        uint256[] memory params = new uint256[](1);
        params[0] = token2Id;
        hook.autoCollect(params);

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
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
    }

    function testMinPositionValue_CanConfigureAboveMinimum() public {
        // Set mock oracle to return value above minimum
        v4Oracle.setMockPositionValue(1 ether); // Above default 0.01 ether minimum

        // Configure position - should succeed
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Verify position is configured and activated
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_COLLECT, "Position should be configured");

        // Verify position is activated (lastActivated > 0)
        (,, uint32 lastActivated,,,,,) = hook.positionStates(tokenId);
        assertGt(lastActivated, 0, "Position should be activated");
    }

    function testMinPositionValue_TriggersRemovedWhenValueDrops() public {
        // Set mock oracle to return high value initially
        v4Oracle.setMockPositionValue(1 ether);

        // Configure position
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        hook.setPositionConfig(
            newTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Set mock oracle to return high value
        v4Oracle.setMockPositionValue(1 ether);

        // Now configure should succeed
        hook.setPositionConfig(
            newTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Owner lowers the minimum
        hook.setMinPositionValueNative(0.001 ether);
        assertEq(hook.minPositionValueNative(), 0.001 ether, "Minimum should be updated");

        // Now configure should succeed
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Verify position is configured
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_COLLECT, "Position should be configured");
    }

    function testMinPositionValue_DisablingPositionAlwaysAllowed() public {
        // Set mock oracle to return high value
        v4Oracle.setMockPositionValue(1 ether);

        // Configure position
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Set mock oracle to return low value
        v4Oracle.setMockPositionValue(0.001 ether);

        // Disabling position (setting mode to NONE) should always work regardless of value
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_NONE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // Verify position is configured
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(tokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_COLLECT, "Position should be configured with 0 minimum");
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
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower2, // Trigger when tick <= -60
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0, // Trigger when tick <= tickLower
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

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
        assertEq(
            IERC721(address(positionManager)).ownerOf(newTokenId),
            address(this),
            "New position should be owned by the same address"
        );

        // Verify hook has no leftover balances
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency0");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook should have 0 balance of currency1");
    }

    function testImmediateExecution_AutoLend() public {
        console.log("=== Test: Immediate Auto Lend Execution ===");

        // First, perform a swap to move the tick out of the position range
        // Need to swap more to get past the AUTO_LEND trigger which is at tickLower - tickSpacing
        uint256 amountIn = 14e17; // Larger swap to move tick further
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
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0, // No tolerance - trigger immediately when out of range
                autoLeverageTargetBps: 0
            })
        );

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
        assertTrue(
            currentTick >= tickLower3 && currentTick <= tickUpper3, "Current tick should be within position range"
        );

        // Get initial liquidity
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        assertGt(liquidityBefore, 0, "token3Id should have liquidity before config");
        console.log("liquidityBefore", liquidityBefore);

        // Approve the hook to manage the position
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        // Configure auto-exit with triggers outside current tick
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: tickLower3 - 60, // Trigger at -120, but we're at 0
                autoExitTickUpper: tickUpper3 + 60, // Trigger at 120, but we're at 0
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // No immediate execution should happen - liquidity should remain
        uint128 liquidityAfter = positionManager.getPositionLiquidity(token3Id);
        console.log("liquidityAfter", liquidityAfter);
        assertEq(liquidityAfter, liquidityBefore, "token3Id should still have same liquidity - no immediate execution");

        // Verify position is still configured (not disabled)
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_EXIT, "Position should still be configured for auto-exit");
    }

    function testImmediateExecution_AutoExitWinsOverAutoRange_Lower() public {
        hook.setMaxTicksFromOracle(1000);

        int24 spacing = poolKey.tickSpacing;
        int24 rangeLower = tickLower3 - 3 * spacing;
        int24 exitLower = tickLower3 - spacing;
        _moveTickDownUntil(rangeLower - spacing, 2e16, 160);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: exitLower,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: tickLower3 - rangeLower,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Immediate lower-side setup should exit old token");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Exit should win over range and avoid remint");
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Exit should disable the position");
        _verifyNoLeftoverBalances("immediate lower E|R priority");
    }

    function testImmediateExecution_AutoExitWinsOverAutoRange_Upper() public {
        hook.setMaxTicksFromOracle(1000);

        int24 spacing = poolKey.tickSpacing;
        int24 rangeUpper = tickUpper3 + 3 * spacing;
        int24 exitUpper = tickUpper3 + spacing;
        _moveTickUpUntil(rangeUpper + spacing, 2e16, 160);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        IERC721(address(positionManager)).approve(address(hook), token3Id);

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: exitUpper,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: rangeUpper - tickUpper3,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Immediate upper-side setup should exit old token");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Exit should win over range and avoid remint");
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Exit should disable the position");
        _verifyNoLeftoverBalances("immediate upper E|R priority");
    }

    function testImmediateExecution_AutoExitTriggersAtExactLowerTick() public {
        hook.setMaxTicksFromOracle(1000);

        _moveTickDownUntil(tickLower2 - poolKey.tickSpacing, 2e16, 160);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLower = _getTickLower(currentTick, poolKey.tickSpacing);
        assertLt(currentTickLower, tickLower2, "Position must be below range before exact-boundary check");

        IERC721(address(positionManager)).approve(address(hook), token2Id);
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: currentTickLower,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(
            positionManager.getPositionLiquidity(token2Id), 0, "Exact lower-tick AUTO_EXIT should execute immediately"
        );
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Position should be disabled after exact-boundary exit");
    }

    function testImmediateExecution_AutoRangeTriggersAtExactLowerTick() public {
        hook.setMaxTicksFromOracle(1000);

        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLower = _getTickLower(currentTick, poolKey.tickSpacing);
        assertLt(currentTickLower, tickLower3, "Position must be below range before exact-boundary check");

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: tickLower3 - currentTickLower,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -poolKey.tickSpacing,
                autoRangeUpperDelta: poolKey.tickSpacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(
            positionManager.getPositionLiquidity(token3Id), 0, "Exact lower-tick AUTO_RANGE should remint immediately"
        );
        assertEq(
            positionManager.nextTokenId(), nextTokenIdBefore + 1, "Immediate exact-boundary range should mint one token"
        );
    }

    function testImmediateExecution_AutoLendTriggersAtExactLowerTick() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        int24 currentTickLower = _moveTickDownUntilAutoLendEqualityTick(tickLower3, 5e15, 240);
        int24 tolerance = (tickLower3 - poolKey.tickSpacing - currentTickLower) / 2;

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: tolerance,
                autoLeverageTargetBps: 0
            })
        );

        uint128 liquidityAfter = positionManager.getPositionLiquidity(token3Id);
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(liquidityAfter, 0, "Exact lower-tick AUTO_LEND should remove liquidity immediately");
        assertGt(autoLendShares, 0, "Exact lower-tick AUTO_LEND should mint lending shares");
        assertEq(autoLendToken, Currency.unwrap(currency0), "Lower exact-boundary lend should use token0");
    }

    function testImmediateExecution_AutoExitTriggersAtExactUpperTick() public {
        hook.setMaxTicksFromOracle(1000);

        _moveTickUpUntil(tickUpper2 + poolKey.tickSpacing, 2e16, 160);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLower = _getTickLower(currentTick, poolKey.tickSpacing);
        assertGe(currentTickLower, tickUpper2, "Position must be at or above range before exact upper-bound check");

        IERC721(address(positionManager)).approve(address(hook), token2Id);
        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: currentTickLower,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(
            positionManager.getPositionLiquidity(token2Id), 0, "Exact upper-tick AUTO_EXIT should execute immediately"
        );
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Position should be disabled after exact upper-bound exit");
    }

    function testImmediateExecution_AutoRangeTriggersAtExactUpperTick() public {
        hook.setMaxTicksFromOracle(1000);

        _moveTickUpUntil(tickUpper3 + poolKey.tickSpacing, 2e16, 160);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLower = _getTickLower(currentTick, poolKey.tickSpacing);
        assertGe(currentTickLower, tickUpper3, "Position must be at or above range before exact upper-bound check");

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: currentTickLower - tickUpper3,
                autoRangeLowerDelta: -poolKey.tickSpacing,
                autoRangeUpperDelta: poolKey.tickSpacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(
            positionManager.getPositionLiquidity(token3Id), 0, "Exact upper-tick AUTO_RANGE should remint immediately"
        );
        assertEq(
            positionManager.nextTokenId(),
            nextTokenIdBefore + 1,
            "Immediate exact upper-bound range should mint one token"
        );
    }

    function testSetPositionConfig_AutoRangeUpperTriggerSameRangeReverts() public {
        hook.setMaxTicksFromOracle(1000);

        _moveTickUpUntil(tickUpper3 + poolKey.tickSpacing, 2e16, 160);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLower = _getTickLower(currentTick, poolKey.tickSpacing);
        assertGe(currentTickLower, tickUpper3, "Position must be at or above range before same-range check");

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();
        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: currentTickLower - tickUpper3,
            autoRangeLowerDelta: tickLower3 - currentTickLower,
            autoRangeUpperDelta: tickUpper3 - currentTickLower,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(token3Id, config);

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Rejected config should not mint a replacement");
        assertEq(
            positionManager.getPositionLiquidity(token3Id),
            liquidityBefore,
            "Rejected config should leave the original position untouched"
        );

        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore, "Rejected config should not change lower triggers");
        assertEq(upperAfter, upperBefore, "Rejected config should not change upper triggers");
    }

    function testSetPositionConfig_AutoRangeLowerSideFutureSameRangeReverts() public {
        int24 spacing = poolKey.tickSpacing;
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: -spacing,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 2 * spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Rejected config should not mint a replacement");
        assertEq(
            positionManager.getPositionLiquidity(token3Id),
            liquidityBefore,
            "Rejected config should leave the original position untouched"
        );

        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore, "Rejected config should not change lower triggers");
        assertEq(upperAfter, upperBefore, "Rejected config should not change upper triggers");
    }

    function testSetPositionConfig_AutoRangeUpperSideFutureSameRangeReverts() public {
        int24 spacing = poolKey.tickSpacing;
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: -spacing,
                autoRangeLowerDelta: -2 * spacing,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Rejected config should not mint a replacement");
        assertEq(
            positionManager.getPositionLiquidity(token3Id),
            liquidityBefore,
            "Rejected config should leave the original position untouched"
        );

        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore, "Rejected config should not change lower triggers");
        assertEq(upperAfter, upperBefore, "Rejected config should not change upper triggers");
    }

    function testImmediateExecution_AutoLendTriggersAtExactUpperTick() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        int24 currentTickLower = _moveTickUpUntilAutoLendEqualityTick(tickUpper3, 5e15, 240);
        int24 tolerance = (currentTickLower - tickUpper3) / 2;

        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: tolerance,
                autoLeverageTargetBps: 0
            })
        );

        uint128 liquidityAfter = positionManager.getPositionLiquidity(token3Id);
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(liquidityAfter, 0, "Exact upper-tick AUTO_LEND should remove liquidity immediately");
        assertGt(autoLendShares, 0, "Exact upper-tick AUTO_LEND should mint lending shares");
        assertEq(autoLendToken, Currency.unwrap(currency1), "Upper exact-boundary lend should use token1");
        _verifyNoLeftoverBalances("exact upper auto-lend");
    }

    function testAutoLendMissingVaultAtRuntime_ConsumesTriggeredTickAndEmitsActionFailure() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max)
        );

        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();
        hook.setAutoLendVault(Currency.unwrap(currency0), IERC4626(address(0)));

        vm.recordLogs();
        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);

        assertEq(
            positionManager.getPositionLiquidity(token3Id), liquidityBefore, "Missing vault must not strip LP liquidity"
        );
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_LEND, "Missing vault must not disable config");
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(autoLendShares, 0, "Missing vault must not mint shares");
        assertEq(autoLendToken, address(0), "Missing vault must not set lend token");
        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore - 1, "Missing vault must consume the fired lower trigger");
        assertEq(upperAfter, upperBefore, "Missing vault must keep the unfired upper trigger");
        _verifyNoLeftoverBalances("missing auto-lend vault");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(
            _sawEventTopic(logs, keccak256("HookAutoLendFailed(address,address,bytes)")),
            "Missing vault path should emit HookAutoLendFailed"
        );
        assertTrue(
            _sawHookActionFailed(logs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Missing vault path should emit HookActionFailed"
        );
    }

    function testAutoLendDepositFailure_RestoresLiquidityAndConsumesTriggeredTick() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        RevertingERC4626Vault failingVault =
            new RevertingERC4626Vault(IERC20(Currency.unwrap(currency0)), "Failing Vault", "FAIL");
        hook.setAutoLendVault(Currency.unwrap(currency0), failingVault);
        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max)
        );

        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();
        uint256 failingVaultAssetsBefore = failingVault.totalAssets();

        vm.recordLogs();
        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);

        assertGe(
            positionManager.getPositionLiquidity(token3Id), liquidityBefore, "Failed deposit must restore liquidity"
        );
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_LEND, "Failed deposit must keep config active");
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(autoLendShares, 0, "Failed deposit must not leave lending shares");
        assertEq(autoLendToken, address(0), "Failed deposit must not keep lend token state");
        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore - 1, "Failed deposit must consume the fired lower trigger");
        assertEq(upperAfter, upperBefore, "Failed deposit must keep the unfired upper trigger");
        assertEq(failingVault.totalAssets(), failingVaultAssetsBefore, "Failed vault must not keep deposited assets");
        _verifyNoLeftoverBalances("failed auto-lend deposit");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(
            _sawEventTopic(logs, keccak256("HookAutoLendFailed(address,address,bytes)")),
            "Deposit failure should emit HookAutoLendFailed"
        );
        assertTrue(
            _sawHookActionFailed(logs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Deposit failure should emit HookActionFailed"
        );
    }

    function testImmediateExecution_AutoLendFailureConsumesImmediateTrigger() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        RevertingERC4626Vault failingVault =
            new RevertingERC4626Vault(IERC20(Currency.unwrap(currency0)), "Failing Vault", "FAIL");
        hook.setAutoLendVault(Currency.unwrap(currency0), failingVault);

        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();

        vm.recordLogs();
        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max)
        );

        assertGe(
            positionManager.getPositionLiquidity(token3Id),
            liquidityBefore,
            "Immediate failure must leave LP liquidity in place"
        );
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_LEND, "Immediate failure must keep config active");
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(autoLendShares, 0, "Immediate failure must not mint shares");
        assertEq(autoLendToken, address(0), "Immediate failure must not set lend state");

        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore, "Immediate failure must consume the lower trigger immediately");
        assertEq(upperAfter, upperBefore + 1, "Immediate failure must leave the unfired upper trigger active");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(
            _sawEventTopic(logs, keccak256("HookAutoLendFailed(address,address,bytes)")),
            "Immediate failure should emit HookAutoLendFailed"
        );
        assertTrue(
            _sawHookActionFailed(logs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Immediate failure should emit HookActionFailed"
        );
    }

    function testAutoLendWithdrawFailure_ConsumesTriggeredTickAndDoesNotRetry() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        ConfigurableERC4626Vault configurableVault =
            new ConfigurableERC4626Vault(IERC20(Currency.unwrap(currency0)), "Configurable Vault", "CFG");
        hook.setAutoLendVault(Currency.unwrap(currency0), configurableVault);
        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max)
        );

        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);
        (,,, address autoLendTokenBefore, uint256 sharesBefore,,,) = hook.positionStates(token3Id);
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Successful deposit should remove LP liquidity");
        assertEq(autoLendTokenBefore, Currency.unwrap(currency0), "Lower-side lend should hold token0 in the vault");
        assertGt(sharesBefore, 0, "Successful deposit should mint lending shares");

        (uint32 lowerBeforeFailure, uint32 upperBeforeFailure) = _getTriggerListSizes();
        configurableVault.setFailRedeem(true);

        vm.recordLogs();
        _moveTickUpUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);

        (,,, address autoLendTokenAfter, uint256 sharesAfter,,,) = hook.positionStates(token3Id);
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Failed withdraw must not restore liquidity");
        assertEq(autoLendTokenAfter, autoLendTokenBefore, "Failed withdraw must keep lent token state");
        assertEq(sharesAfter, sharesBefore, "Failed withdraw must keep lending shares");
        (uint32 lowerAfterFailure, uint32 upperAfterFailure) = _getTriggerListSizes();
        assertEq(lowerAfterFailure, lowerBeforeFailure, "Failed withdraw must not add unrelated lower triggers");
        assertEq(upperAfterFailure, upperBeforeFailure - 1, "Failed withdraw must consume the fired re-entry trigger");

        Vm.Log[] memory failureLogs = vm.getRecordedLogs();
        assertTrue(
            _sawEventTopic(failureLogs, keccak256("HookAutoLendFailed(address,address,bytes)")),
            "Failed withdraw should emit HookAutoLendFailed"
        );
        assertTrue(
            _sawHookActionFailed(failureLogs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Failed withdraw should emit HookActionFailed"
        );

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory retryLogs = vm.getRecordedLogs();
        assertFalse(
            _sawHookActionFailed(retryLogs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Consumed withdraw trigger must not retry on subsequent swaps"
        );
        assertFalse(
            _sawEventTopic(retryLogs, keccak256("HookAutoLendFailed(address,address,bytes)")),
            "Consumed withdraw trigger must not emit duplicate failures"
        );
        (,,, address autoLendTokenFinal, uint256 sharesFinal,,,) = hook.positionStates(token3Id);
        assertEq(autoLendTokenFinal, autoLendTokenBefore, "No retry should keep the original lend token state");
        assertEq(sharesFinal, sharesBefore, "No retry should leave vault shares unchanged");
    }

    function testAutoLendWithdrawReentryFailure_DisablesZeroLiquidityPosition() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);
        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max)
        );

        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);
        (,,, address autoLendTokenBefore, uint256 sharesBefore,,,) = hook.positionStates(token3Id);
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Successful deposit should remove LP liquidity");
        assertEq(autoLendTokenBefore, Currency.unwrap(currency0), "Lower-side lend should hold token0 in the vault");
        assertGt(sharesBefore, 0, "Successful deposit should mint lending shares");

        IERC721(address(positionManager)).setApprovalForAll(address(hook), false);
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        (uint32 lowerBeforeFailure, uint32 upperBeforeFailure) = _getTriggerListSizes();

        vm.recordLogs();
        _moveTickUpUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);

        assertEq(
            positionManager.nextTokenId(), nextTokenIdBefore, "Failed re-entry should not mint a replacement token"
        );
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Failed re-entry must leave the old token empty");
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Empty position must be disabled after failed re-entry");
        (,,, address autoLendTokenAfter, uint256 sharesAfter,,,) = hook.positionStates(token3Id);
        assertEq(sharesAfter, 0, "Failed re-entry must clear lending shares");
        assertEq(autoLendTokenAfter, address(0), "Failed re-entry must clear lent token state");

        (uint32 lowerAfterFailure, uint32 upperAfterFailure) = _getTriggerListSizes();
        assertEq(lowerAfterFailure, lowerBeforeFailure, "Failed re-entry must not add new lower triggers");
        assertEq(upperAfterFailure, upperBeforeFailure - 1, "Failed re-entry must consume the fired withdraw trigger");
        _verifyNoLeftoverBalances("failed auto-lend withdraw re-entry");

        Vm.Log[] memory failureLogs = vm.getRecordedLogs();
        assertTrue(
            _sawEventTopic(failureLogs, keccak256("HookModifyLiquiditiesFailed(bytes,bytes[],bytes)")),
            "Failed re-entry should emit HookModifyLiquiditiesFailed"
        );
        assertTrue(
            _sawHookActionFailed(failureLogs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Failed re-entry should emit HookActionFailed"
        );
    }

    function testAutoExitExecution_RemovesOppositeTriggerNode() public {
        hook.setMaxTicksFromOracle(1000);

        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2 + poolKey.tickSpacing,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        (uint32 lowerInitial, uint32 upperInitial) = _getTriggerListSizes();
        hook.setPositionConfig(token2Id, exitConfig);
        IERC721(address(positionManager)).approve(address(hook), token2Id);

        (uint32 lowerConfigured, uint32 upperConfigured) = _getTriggerListSizes();
        assertEq(lowerConfigured, lowerInitial + 1, "Exit config should add one lower trigger");
        assertEq(upperConfigured, upperInitial + 1, "Exit config should add one upper trigger");

        _moveTickDownUntil(exitConfig.autoExitTickLower, 2e16, 160);

        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "AUTO_EXIT should remove liquidity after trigger");
        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerInitial, "Triggered lower exit should not leave stale lower nodes");
        assertEq(upperAfter, upperInitial, "Triggered lower exit should remove stale upper node");
    }

    function testAutoExitLowerWithSwap_OneSidedToken1() public {
        _assertImmediateNonVaultAutoExitCase(false, true);
    }

    function testAutoExitLowerWithoutSwap_LeavesBothTokens() public {
        _assertImmediateNonVaultAutoExitCase(false, false);
    }

    function testAutoExitUpperWithSwap_OneSidedToken0() public {
        _assertImmediateNonVaultAutoExitCase(true, true);
    }

    function testAutoExitUpperWithoutSwap_LeavesBothTokens() public {
        _assertImmediateNonVaultAutoExitCase(true, false);
    }

    function _assertImmediateNonVaultAutoExitCase(bool isUpperTrigger, bool swapOnExit) internal {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).approve(address(hook), token2Id);

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 currentTickLower = _getTickLower(currentTick, poolKey.tickSpacing);
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(token2Id);
        assertLt(posInfo.tickLower(), currentTickLower, "Test setup requires price inside the position range");
        assertGt(posInfo.tickUpper(), currentTickLower, "Test setup requires price inside the position range");

        uint256 balance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        hook.setPositionConfig(
            token2Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: isUpperTrigger ? type(int24).min : currentTickLower,
                autoExitTickUpper: isUpperTrigger ? currentTickLower : type(int24).max,
                autoExitSwapOnLowerTrigger: isUpperTrigger ? true : swapOnExit,
                autoExitSwapOnUpperTrigger: isUpperTrigger ? swapOnExit : true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        assertEq(
            positionManager.getPositionLiquidity(token2Id), 0, "Immediate lower AUTO_EXIT should remove all liquidity"
        );
        (uint8 modeAfter,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(modeAfter, PositionModeFlags.MODE_NONE, "Immediate AUTO_EXIT should disable the position");

        uint256 balance0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        if (swapOnExit) {
            if (isUpperTrigger) {
                assertGt(balance0After, balance0Before, "Upper AUTO_EXIT with swap should finish in token0");
                assertEq(balance1After, balance1Before, "Upper AUTO_EXIT with swap should fully rotate out of token1");
            } else {
                assertEq(balance0After, balance0Before, "Lower AUTO_EXIT with swap should fully rotate out of token0");
                assertGt(balance1After, balance1Before, "Lower AUTO_EXIT with swap should finish in token1");
            }
        } else {
            assertGt(balance0After, balance0Before, "No-swap AUTO_EXIT should return token0");
            assertGt(balance1After, balance1Before, "No-swap AUTO_EXIT should keep token1");
        }

        _verifyNoLeftoverBalances(
            isUpperTrigger
                ? (swapOnExit ? "upper auto-exit with swap" : "upper auto-exit without swap")
                : (swapOnExit ? "lower auto-exit with swap" : "lower auto-exit without swap")
        );
    }

    function testSetPositionConfig_AutoRangeLowerTriggerSameRangeReverts() public {
        hook.setMaxTicksFromOracle(1000);

        int24 spacing = poolKey.tickSpacing;
        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 2 * spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token3Id);
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes();

        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(token3Id, config);

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Rejected config should not mint a replacement");
        assertEq(
            positionManager.getPositionLiquidity(token3Id),
            liquidityBefore,
            "Rejected config should keep the original position"
        );

        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes();
        assertEq(lowerAfter, lowerBefore, "Rejected config should not change lower triggers");
        assertEq(upperAfter, upperBefore, "Rejected config should not change upper triggers");
    }

    function testAutoExitRelative_RecomputedAfterAutoRangeRemint() public {
        hook.setMaxTicksFromOracle(1000);
        int24 spacing = poolKey.tickSpacing;

        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: true,
            autoExitTickLower: 2 * spacing,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
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
        assertLt(
            newExitTickLower, oldExitTickLower, "Reminted position should compute a fresh, lower relative exit tick"
        );

        // Isolate relative AUTO_EXIT checks after remint so subsequent swaps cannot trigger another range remint.
        hook.setPositionConfig(
            remintedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: true,
                autoExitTickLower: config.autoExitTickLower,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        _moveTickDownUntil(oldExitTickLower, 1e16, 220);
        (, int24 tickAtOldThreshold,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertGt(tickAtOldThreshold, newExitTickLower, "Price should still be above reminted relative exit trigger");
        assertGt(
            positionManager.getPositionLiquidity(remintedTokenId),
            0,
            "Crossing old relative exit threshold must not exit reminted position"
        );

        _moveTickDownUntil(newExitTickLower - spacing, 2e16, 220);
        assertEq(
            positionManager.getPositionLiquidity(remintedTokenId),
            0,
            "Reminted position should exit at new relative trigger"
        );
        (uint8 modeFlags,,,,,,,,,,) = hook.positionConfigs(remintedTokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_NONE, "Config should clear after reminted relative auto-exit");
    }

    function testTriggerListIntegrity_ConfigDisableAndRemintNoStaleTicks() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        (uint32 lowerInitial, uint32 upperInitial) = _getTriggerListSizes();

        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower3 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper3 + poolKey.tickSpacing,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        hook.setPositionConfig(token3Id, exitConfig);

        (uint32 lowerAfterExitConfig, uint32 upperAfterExitConfig) = _getTriggerListSizes();
        assertEq(
            lowerAfterExitConfig, lowerInitial + 1, "Lower trigger list should include configured AUTO_EXIT lower tick"
        );
        assertEq(
            upperAfterExitConfig, upperInitial + 1, "Upper trigger list should include configured AUTO_EXIT upper tick"
        );

        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_NONE, false, false, type(int24).min, type(int24).max)
        );
        (uint32 lowerAfterDisable, uint32 upperAfterDisable) = _getTriggerListSizes();
        assertEq(lowerAfterDisable, lowerInitial, "Disabling position should remove lower trigger ticks");
        assertEq(upperAfterDisable, upperInitial, "Disabling position should remove upper trigger ticks");

        RevertHookState.PositionConfig memory rangeConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
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

        assertEq(
            positionManager.nextTokenId(),
            nextTokenIdBefore + 1,
            "AUTO_RANGE should remint when lower trigger is crossed"
        );
        uint256 remintedTokenId = nextTokenIdBefore;
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "Original token should be emptied after remint");
        assertGt(positionManager.getPositionLiquidity(remintedTokenId), 0, "Reminted token should stay active");

        (uint32 lowerAfterRemint, uint32 upperAfterRemint) = _getTriggerListSizes();
        assertEq(
            lowerAfterRemint, lowerInitial + 1, "Remint should replace lower tick entry without leaking stale ticks"
        );
        assertEq(
            upperAfterRemint, upperInitial + 1, "Remint should replace upper tick entry without leaking stale ticks"
        );

        hook.setPositionConfig(
            remintedTokenId,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_NONE, false, false, type(int24).min, type(int24).max)
        );
        (uint32 lowerFinal, uint32 upperFinal) = _getTriggerListSizes();
        assertEq(lowerFinal, lowerInitial, "Final disable should leave lower trigger list in baseline state");
        assertEq(upperFinal, upperInitial, "Final disable should leave upper trigger list in baseline state");
    }

    function testDisableWhileOutOfRange_RemovesPendingOldTrigger() public {
        hook.setMaxTicksFromOracle(1000);

        int24 staleExitTick = tickLower3 - 5 * poolKey.tickSpacing;
        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: staleExitTick,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });

        (uint32 lowerInitial, uint32 upperInitial) = _getTriggerListSizes();
        hook.setPositionConfig(token3Id, exitConfig);
        _moveTickDownUntil(tickLower3 - poolKey.tickSpacing, 2e16, 160);

        hook.setPositionConfig(
            token3Id,
            _buildNonVaultModeConfig(PositionModeFlags.MODE_NONE, false, false, type(int24).min, type(int24).max)
        );
        (uint32 lowerAfterDisable, uint32 upperAfterDisable) = _getTriggerListSizes();
        assertEq(lowerAfterDisable, lowerInitial, "Disable should remove the pending lower trigger");
        assertEq(upperAfterDisable, upperInitial, "Disable should leave upper trigger list at baseline");

        vm.recordLogs();
        _moveTickDownUntil(staleExitTick - poolKey.tickSpacing, 2e16, 160);

        assertGt(
            positionManager.getPositionLiquidity(token3Id),
            0,
            "Disabled out-of-range position must not execute stale AUTO_EXIT"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(
            _sawIndexedTokenEvent(logs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), token3Id),
            "Disabled position must not emit AutoExit at the old trigger"
        );
    }

    function testSameTickMixedSuccessAndFailure_ConsumeTriggerOnceEach() public {
        hook.setMaxTicksFromOracle(1000);
        IERC721(address(positionManager)).approve(address(hook), token2Id);
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        RevertHookState.PositionConfig memory exitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        RevertHookState.PositionConfig memory failingLendConfig =
            _buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_LEND, false, false, type(int24).min, type(int24).max);

        (uint32 lowerInitial, uint32 upperInitial) = _getTriggerListSizes();
        hook.setPositionConfig(token2Id, exitConfig);
        hook.setPositionConfig(token3Id, failingLendConfig);
        (uint32 lowerConfigured, uint32 upperConfigured) = _getTriggerListSizes();
        assertEq(lowerConfigured, lowerInitial + 1, "Same-tick configs should share one lower trigger node");
        assertEq(upperConfigured, upperInitial + 1, "AUTO_LEND should keep its unfired upper trigger active");

        uint128 token3LiquidityBefore = positionManager.getPositionLiquidity(token3Id);
        hook.setAutoLendVault(Currency.unwrap(currency0), IERC4626(address(0)));

        vm.recordLogs();
        _moveTickDownUntil(tickLower2 - poolKey.tickSpacing, 2e16, 160);

        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "AUTO_EXIT should still succeed on the shared tick");
        assertEq(
            positionManager.getPositionLiquidity(token3Id),
            token3LiquidityBefore,
            "Failed AUTO_LEND should leave the original position untouched"
        );
        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(token3Id);
        assertEq(autoLendShares, 0, "Failed AUTO_LEND should not leave lending shares");
        assertEq(autoLendToken, address(0), "Failed AUTO_LEND should not set lend token state");

        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        assertTrue(
            _sawIndexedTokenEvent(firstLogs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), token2Id),
            "Shared tick should execute AUTO_EXIT for token2"
        );
        assertTrue(
            _sawHookActionFailed(firstLogs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Shared tick should emit HookActionFailed for the failed AUTO_LEND"
        );
        assertTrue(
            _sawEventTopic(firstLogs, keccak256("HookAutoLendFailed(address,address,bytes)")),
            "Shared tick should emit HookAutoLendFailed for the failed AUTO_LEND"
        );

        (uint32 lowerAfterFirst, uint32 upperAfterFirst) = _getTriggerListSizes();
        assertEq(lowerAfterFirst, lowerInitial, "Processed shared tick must not leave stale lower triggers");
        assertEq(upperAfterFirst, upperInitial + 1, "Failed lower AUTO_LEND should keep only the unfired upper trigger");

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e16,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        Vm.Log[] memory secondLogs = vm.getRecordedLogs();
        assertFalse(
            _sawIndexedTokenEvent(secondLogs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), token2Id),
            "Consumed AUTO_EXIT must not fire twice on later swaps"
        );
        assertFalse(
            _sawHookActionFailed(secondLogs, token3Id, RevertHookState.Mode.AUTO_LEND),
            "Consumed failed AUTO_LEND trigger must not retry on later swaps"
        );
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
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
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
            if (
                logs[i].topics[0] == autoExitTopic && logs[i].topics.length > 1
                    && uint256(logs[i].topics[1]) == token2Id
            ) {
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
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2 + poolKey.tickSpacing,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
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
                token2Id, liquidityStep, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
            );

            (,, uint32 lastActivatedLow,,,,,) = hook.positionStates(token2Id);
            assertEq(lastActivatedLow, 0, "Position should deactivate when value falls below minimum");
            (uint32 lowerAfterLow, uint32 upperAfterLow) = _getTriggerListSizes();
            assertEq(lowerAfterLow, lowerBaseline, "Lower trigger list should return to baseline when deactivated");
            assertEq(upperAfterLow, upperBaseline, "Upper trigger list should return to baseline when deactivated");

            v4Oracle.setMockPositionValue(1 ether);
            positionManager.increaseLiquidity(
                token2Id, liquidityStep, type(uint256).max, type(uint256).max, block.timestamp, Constants.ZERO_BYTES
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

    function _sawEventTopic(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    function _sawHookActionFailed(Vm.Log[] memory logs, uint256 expectedTokenId, RevertHookState.Mode expectedMode)
        internal
        view
        returns (bool)
    {
        bytes32 eventTopic = keccak256("HookActionFailed(uint256,uint8)");
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(hook)) {
                continue;
            }
            if (logs[i].topics.length < 2 || logs[i].topics[0] != eventTopic) {
                continue;
            }
            if (uint256(logs[i].topics[1]) != expectedTokenId) {
                continue;
            }
            uint8 actualMode = abi.decode(logs[i].data, (uint8));
            if (actualMode == uint8(expectedMode)) {
                return true;
            }
        }
        return false;
    }

    function _sawIndexedTokenEvent(Vm.Log[] memory logs, bytes32 topic, uint256 expectedTokenId)
        internal
        view
        returns (bool)
    {
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(hook)) {
                continue;
            }
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic) {
                continue;
            }
            if (uint256(logs[i].topics[1]) == expectedTokenId) {
                return true;
            }
        }
        return false;
    }

    function _findSendProtocolFee(Vm.Log[] memory logs, uint256 expectedTokenId)
        internal
        view
        returns (SendProtocolFeeEvent memory feeEvent)
    {
        bytes32 eventTopic = keccak256("SendProtocolFee(uint256,address,address,uint256,uint256,address)");
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(hook)) {
                continue;
            }
            if (logs[i].topics.length < 2 || logs[i].topics[0] != eventTopic) {
                continue;
            }
            if (uint256(logs[i].topics[1]) != expectedTokenId) {
                continue;
            }

            feeEvent.found = true;
            (, , feeEvent.amount0, feeEvent.amount1, feeEvent.recipient) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, address));
            if (feeEvent.amount0 == 0 && feeEvent.amount1 == 0) {
                feeEvent.found = false;
                continue;
            }
            return feeEvent;
        }
    }

    function _moveTickDownUntil(int24 targetTick, uint256 amountInPerSwap, uint256 maxSteps)
        internal
        returns (int24 currentTick)
    {
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

    function _moveTickUpUntil(int24 targetTick, uint256 amountInPerSwap, uint256 maxSteps)
        internal
        returns (int24 currentTick)
    {
        (, currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        uint256 steps;
        while (currentTick < targetTick && steps < maxSteps) {
            swapRouter.swapExactTokensForTokens({
                amountIn: amountInPerSwap,
                amountOutMin: 0,
                zeroForOne: false,
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

        assertGe(currentTick, targetTick, "Target tick was not reached");
    }

    function _moveTickDownUntilAutoLendEqualityTick(int24 positionTickLower, uint256 amountInPerSwap, uint256 maxSteps)
        internal
        returns (int24 currentTickLower)
    {
        int24 spacing = poolKey.tickSpacing;
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        currentTickLower = _getTickLower(currentTick, spacing);

        uint256 steps;
        while (
            (currentTickLower > positionTickLower - spacing
                    || (positionTickLower - spacing - currentTickLower) % (2 * spacing) != 0) && steps < maxSteps
        ) {
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
            currentTickLower = _getTickLower(currentTick, spacing);
            unchecked {
                ++steps;
            }
        }

        assertLe(currentTickLower, positionTickLower - spacing, "Auto-lend equality tick was not reached");
        assertEq(
            (positionTickLower - spacing - currentTickLower) % (2 * spacing),
            0,
            "Auto-lend equality tick must allow an aligned tolerance"
        );
    }

    function _moveTickUpUntilAutoLendEqualityTick(int24 positionTickUpper, uint256 amountInPerSwap, uint256 maxSteps)
        internal
        returns (int24 currentTickLower)
    {
        int24 spacing = poolKey.tickSpacing;
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        currentTickLower = _getTickLower(currentTick, spacing);

        uint256 steps;
        while (
            (currentTickLower < positionTickUpper || (currentTickLower - positionTickUpper) % (2 * spacing) != 0)
                && steps < maxSteps
        ) {
            swapRouter.swapExactTokensForTokens({
                amountIn: amountInPerSwap,
                amountOutMin: 0,
                zeroForOne: false,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp
            });
            (, currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            currentTickLower = _getTickLower(currentTick, spacing);
            unchecked {
                ++steps;
            }
        }

        assertGe(currentTickLower, positionTickUpper, "Auto-lend equality tick was not reached");
        assertEq(
            (currentTickLower - positionTickUpper) % (2 * spacing),
            0,
            "Auto-lend upper equality tick must allow an aligned tolerance"
        );
    }
}

contract RevertingERC4626Vault is MockERC4626Vault {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626Vault(asset_, name_, symbol_) {}

    function deposit(uint256, address) public pure override returns (uint256) {
        revert("deposit failed");
    }
}

contract ConfigurableERC4626Vault is MockERC4626Vault {
    bool public failDeposit;
    bool public failRedeem;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626Vault(asset_, name_, symbol_) {}

    function setFailDeposit(bool value) external {
        failDeposit = value;
    }

    function setFailRedeem(bool value) external {
        failRedeem = value;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (failDeposit) {
            revert("deposit failed");
        }
        return super.deposit(assets, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (failRedeem) {
            revert("redeem failed");
        }
        return super.redeem(shares, receiver, owner);
    }
}
