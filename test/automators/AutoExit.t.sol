// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoExit} from "../../src/automators/AutoExit.sol";
import {Constants} from "src/shared/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoExitTest is AutomatorTestBase {
    AutoExit public autoExit;

    function setUp() public override {
        super.setUp();

        autoExit = new AutoExit(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, withdrawer);
        autoExit.setVault(address(vault));
        vault.setTransformer(address(autoExit), true);
    }

    // --- Access Control ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: 1,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoExit.execute(params);
    }

    // --- Config Tests ---

    function test_ConfigToken() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        int24 tick = _getCurrentTick(poolKey);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: tick - 1000,
            token1TriggerTick: tick + 1000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        (bool isActive,,,,,,,,) = autoExit.positionConfigs(tokenId);
        assertTrue(isActive);
    }

    function test_RevertWhenNonOwnerConfigures() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: -1000,
            token1TriggerTick: 1000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoExit.configToken(tokenId, config);
    }

    function test_RevertWhenInvalidConfigTriggerTicks() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // token0TriggerTick >= token1TriggerTick is invalid
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: 1000,
            token1TriggerTick: 500,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoExit.configToken(tokenId, config);
    }

    // --- Execute Tests ---

    function test_ExecuteLimitOrder() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        int24 tick = _getCurrentTick(poolKey);
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Set trigger ticks so that a large swap will trigger exit
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false, // No swap - limit order style
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        // Approve NFT
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move price below position range (large swap to move tick far enough)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        int24 newTick = _getCurrentTick(poolKey);
        console.log("Tick after swap:", newTick);
        console.log("Position tickLower:", posInfo.tickLower());

        // Execute exit
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoExit.execute(params);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after exit");

        // Config should be deleted
        (bool isActive,,,,,,,,) = autoExit.positionConfigs(tokenId);
        assertFalse(isActive, "Config should be deleted after exit");
    }

    function test_RevertWhenNotReady() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        int24 tick = _getCurrentTick(poolKey);

        // Set trigger ticks very far away
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: tick - 100000,
            token1TriggerTick: tick + 100000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.NotReady.selector);
        autoExit.execute(params);
    }

    function test_ExecuteWithSwap() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure with swap enabled
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: true,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick below range — position holds only token0 (USDC)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Build swap data: USDC → WETH via Universal Router V3 swap
        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoExit.execute(params);

        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Position should be empty");
    }

    function test_RevertWhenSwapExceedsMaxSlippage() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: true,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Make oracle slippage guard stricter than pool fee so swap must fail.
        config.token0SlippageBps = 1;
        config.token1SlippageBps = 1;
        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.SlippageError.selector);
        autoExit.execute(params);
    }

    // --- Native ETH Position Tests ---

    function test_ExecuteLimitOrderETH() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        int24 tick = _getCurrentTick(poolKey);
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Set trigger ticks so exit triggers when price moves
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move price below range (large ETH sell)
        _swapExactInputSingleEth(poolKey, true, 10e18, 0);

        // Execute exit
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        uint256 ethBefore = WHALE_ACCOUNT.balance;
        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        vm.prank(operator);
        autoExit.execute(params);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after ETH exit");

        // Owner should receive tokens (ETH as native, not WETH)
        uint256 ethAfter = WHALE_ACCOUNT.balance;
        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        assertTrue(ethAfter > ethBefore || usdcAfter > usdcBefore, "Owner should receive ETH/USDC after exit");
    }

    function test_ExecuteWithVaultETH() public {
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        // Move price out of range
        _swapExactInputSingleEth(poolKey, true, 10e18, 0);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoExit.executeWithVault(params, address(vault));

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after ETH vault exit");
    }

    // --- Vault Exit Test ---

    function test_ExecuteWithVault() public {
        // Increase oracle tolerance for large swap price impact
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createPool();
        // Create a full-range liquidity position to support swaps
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Add position to vault (no borrowing - just testing exit functionality)
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Configure auto-exit
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        // Approve autoExit to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        // Move price out of range (large swap)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoExit.executeWithVault(params, address(vault));

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after vault exit");
    }
}
