// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoExit} from "../../src/automators/AutoExit.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoExitTest is AutomatorTestBase {
    AutoExit public autoExit;

    function setUp() public override {
        super.setUp();

        autoExit = new AutoExit(positionManager, address(swapRouter), EX0x, permit2, operator, withdrawer);
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
            rewardX64: 0,
            hookData: bytes("")
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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: uint64(Q64 / 200), // 0.5%
            hookData: bytes("")
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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: 0,
            hookData: bytes("")
        });

        vm.prank(operator);
        vm.expectRevert(Constants.NotReady.selector);
        autoExit.execute(params);
    }

    function test_RevertWhenExceedsMaxReward() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick out of range (large swap)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 10), // 10% exceeds maxRewardX64 of 1%
            hookData: bytes("")
        });

        vm.prank(operator);
        vm.expectRevert(Constants.ExceedsMaxReward.selector);
        autoExit.execute(params);
    }

    // --- onlyFees Tests ---

    function test_ExecuteOnlyFeesFalseNoSwap() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure with onlyFees=false, no swap
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick below range — position holds only token0 (USDC)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        uint256 usdcBefore = usdc.balanceOf(address(autoExit));
        uint256 wethBefore = weth.balanceOf(address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 100), // 1%
            hookData: bytes("")
        });

        vm.prank(operator);
        autoExit.execute(params);

        uint256 usdcReward = usdc.balanceOf(address(autoExit)) - usdcBefore;

        // onlyFees=false, no swap: reward from full amount (token0 only since below range)
        assertGt(usdcReward, 0, "Should have USDC reward");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Position should be empty");
    }

    function test_ExecuteOnlyFeesTrueNoSwap() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure with onlyFees=true, no swap
        // In V4, feeAmount == totalAmount (fees bundled with liquidity removal)
        // so onlyFees=true produces identical result as onlyFees=false in no-swap path
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: true,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick below range — position holds only token0 (USDC)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        uint256 usdcBefore = usdc.balanceOf(address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 100), // 1%
            hookData: bytes("")
        });

        vm.prank(operator);
        autoExit.execute(params);

        uint256 usdcReward = usdc.balanceOf(address(autoExit)) - usdcBefore;

        // onlyFees=true, no swap: reward from fee amounts (== total in V4)
        assertGt(usdcReward, 0, "Should have USDC reward");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Position should be empty");
    }

    function test_ExecuteOnlyFeesFalseWithSwap() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure with onlyFees=false, swap enabled
        // When tick drops below range (isAbove=false), token0Swap=true swaps USDC→WETH
        // Target token = token1 (WETH)
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: true,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: uint64(Q64 / 5), // 20% slippage
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick below range — position holds only token0 (USDC)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Build swap data: USDC → WETH via Universal Router V3 swap
        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit));

        uint256 usdcBefore = usdc.balanceOf(address(autoExit));
        uint256 wethBefore = weth.balanceOf(address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 100), // 1%
            hookData: bytes("")
        });

        vm.prank(operator);
        autoExit.execute(params);

        uint256 usdcReward = usdc.balanceOf(address(autoExit)) - usdcBefore;
        uint256 wethReward = weth.balanceOf(address(autoExit)) - wethBefore;

        // onlyFees=false with swap: reward from target token (WETH=token1) only, taken AFTER swap
        // isAbove=false, so reward deducted from amount1 (WETH) after swap
        assertGt(wethReward, 0, "Should have WETH reward (target token)");
        assertEq(usdcReward, 0, "Should have no USDC reward when onlyFees=false");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Position should be empty");
    }

    function test_ExecuteOnlyFeesTrueWithSwap() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure with onlyFees=true, swap enabled
        // When tick drops below range (isAbove=false), token0Swap=true swaps USDC→WETH
        // With onlyFees=true, reward deducted from BOTH tokens BEFORE swap
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: true,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: uint64(Q64 / 5), // 20% slippage
            token1SlippageX64: 0,
            onlyFees: true,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick below range — position holds only token0 (USDC)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Build swap data: USDC → WETH via Universal Router V3 swap
        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit));

        uint256 usdcBefore = usdc.balanceOf(address(autoExit));
        uint256 wethBefore = weth.balanceOf(address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 100), // 1%
            hookData: bytes("")
        });

        vm.prank(operator);
        autoExit.execute(params);

        uint256 usdcReward = usdc.balanceOf(address(autoExit)) - usdcBefore;
        uint256 wethReward = weth.balanceOf(address(autoExit)) - wethBefore;

        // onlyFees=true with swap: reward deducted BEFORE swap from BOTH tokens
        // Position below range holds only USDC, so USDC reward is deducted before swap
        // The USDC reward stays in contract since it's deducted before the swap
        assertGt(usdcReward, 0, "Should have USDC reward when onlyFees=true (pre-swap deduction)");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Position should be empty");
    }

    // --- Native ETH Position Tests ---

    function test_ExecuteLimitOrderETH() public {
        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

        int24 tick = _getCurrentTick(poolKey);
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Set trigger ticks so exit triggers when price moves
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move price below range (large ETH sell)
        _swapExactInputSingleETH(poolKey, true, 10e18, 0);

        // Execute exit
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 200), // 0.5%
            hookData: bytes("")
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

    function test_ExecuteLimitOrderETHWithReward() public {
        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Set trigger ticks so exit triggers when price moves
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move price below range (large ETH sell) — position holds only USDC (token1)
        _swapExactInputSingleETH(poolKey, true, 10e18, 0);

        // Track contract balances before execution
        uint256 contractETHBefore = address(autoExit).balance;
        uint256 contractUSDCBefore = usdc.balanceOf(address(autoExit));

        // Execute exit with 1% reward
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 100), // 1%
            hookData: bytes("")
        });

        vm.prank(operator);
        autoExit.execute(params);

        // Reward should accumulate as ETH or USDC balance in the contract
        uint256 contractETHAfter = address(autoExit).balance;
        uint256 contractUSDCAfter = usdc.balanceOf(address(autoExit));

        uint256 ethReward = contractETHAfter - contractETHBefore;
        uint256 usdcReward = contractUSDCAfter - contractUSDCBefore;
        assertTrue(ethReward > 0 || usdcReward > 0, "Contract should accumulate rewards from ETH position exit");

        // Verify withdrawer can withdraw ETH rewards via withdrawETH()
        if (ethReward > 0) {
            uint256 withdrawerETHBefore = withdrawer.balance;
            vm.prank(withdrawer);
            autoExit.withdrawETH(withdrawer);
            assertEq(withdrawer.balance - withdrawerETHBefore, ethReward, "Withdrawer should receive ETH rewards");
        }

        // Verify withdrawer can withdraw USDC rewards via withdrawBalances()
        if (usdcReward > 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(usdc);
            uint256 withdrawerUSDCBefore = usdc.balanceOf(withdrawer);
            vm.prank(withdrawer);
            autoExit.withdrawBalances(tokens, withdrawer);
            assertEq(usdc.balanceOf(withdrawer) - withdrawerUSDCBefore, usdcReward, "Withdrawer should receive USDC rewards");
        }
    }

    function test_ExecuteWithVaultETH() public {
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        // Move price out of range
        _swapExactInputSingleETH(poolKey, true, 10e18, 0);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            rewardX64: uint64(Q64 / 200),
            hookData: bytes("")
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
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: uint64(Q64 / 200),
            hookData: bytes("")
        });

        vm.prank(operator);
        autoExit.executeWithVault(params, address(vault));

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after vault exit");
    }
}
