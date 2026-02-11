// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoLeverage} from "../../src/automators/AutoLeverage.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoLeverageTest is AutomatorTestBase {
    AutoLeverage public autoLeverage;

    function setUp() public override {
        super.setUp();

        autoLeverage =
            new AutoLeverage(positionManager, address(swapRouter), EX0x, permit2, operator, withdrawer);
        autoLeverage.setVault(address(vault));
        vault.setTransformer(address(autoLeverage), true);

        // Increase oracle tolerance for testing
        v4Oracle.setMaxPoolPriceDifference(10000);
    }

    // --- Access Control ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: 1,
            vault: address(vault),
            leverageUp: true,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLeverage.execute(params);
    }

    function test_RevertWhenInvalidVault() public {
        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: 1,
            vault: makeAddr("fakeVault"),
            leverageUp: true,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLeverage.execute(params);
    }

    // --- Config Tests ---

    function test_ConfigToken() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Must be vault-owned
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 500,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActive, uint16 targetBps, uint16 threshold,) =
            autoLeverage.positionConfigs(tokenId);
        assertTrue(isActive);
        assertEq(targetBps, 5000);
        assertEq(threshold, 500);
    }

    function test_RevertWhenNonVaultOwnedPositionConfigured() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Position is NOT in vault
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 500,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLeverage.configToken(tokenId, config);
    }

    function test_RevertWhenTargetTooHigh() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 10000, // 100% - invalid
            rebalanceThresholdBps: 500,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoLeverage.configToken(tokenId, config);
    }

    function test_RevertWhenThresholdZero() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 0, // Zero threshold - invalid
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoLeverage.configToken(tokenId, config);
    }

    // --- Execute Tests ---

    function test_LeverageUp() public {
        PoolKey memory poolKey = _createPool();
        // Create liquidity position for swaps
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Setup vault position
        _depositToVault(50000000000, WHALE_ACCOUNT); // 50k USDC
        _addPositionToVault(tokenId);

        // Borrow small amount (10% of collateral)
        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 10 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for 50% target leverage
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 100, // 1% threshold - easily triggered
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        // Approve transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        // Record debt before
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);

        // Execute leverage up
        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: true,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        // Debt should have increased
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertGt(debtAfter, debtBefore, "Debt should increase after leverage up");

        // Position should still be owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    function test_LeverageDown() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Setup vault position with high leverage
        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        // Borrow 70% of collateral
        uint256 borrowAmount = collateralValue * 70 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for 30% target (current is ~70%, want to go down)
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);

        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: false,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertLt(debtAfter, debtBefore, "Debt should decrease after leverage down");
    }

    // --- Native ETH Position Tests ---

    function test_LeverageUpETH() public {
        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        // Setup vault position
        _depositToVault(50000000000, WHALE_ACCOUNT); // 50k USDC
        _addPositionToVault(tokenId);

        // Borrow small amount (10% of collateral)
        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 10 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for 50% target leverage
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 100,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);

        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: true,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertGt(debtAfter, debtBefore, "Debt should increase after ETH leverage up");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    function test_LeverageDownETH() public {
        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        // Setup vault position with high leverage
        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 70 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for 30% target
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);

        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: false,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertLt(debtAfter, debtBefore, "Debt should decrease after ETH leverage down");
    }

    // --- Revert Tests ---

    function test_RevertWhenNotReady() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        // Borrow exactly at target (50%)
        uint256 borrowAmount = collateralValue * 50 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for 50% target with 10% threshold = range [40%, 60%]
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 1000, // 10% threshold
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        // Current ratio is ~50%, which is within [40%, 60%]
        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: true,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        // Inner NotReady() gets wrapped by vault.transform() as TransformFailed()
        vm.expectRevert(Constants.TransformFailed.selector);
        autoLeverage.execute(params);
    }

    // --- Reward Retention Test ---

    function test_RewardStaysInContract() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Setup vault position with high leverage
        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        // Borrow 70% of collateral — above the 30% target, triggers leverage down
        uint256 borrowAmount = collateralValue * 70 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Generate fees with moderate swaps (avoid large price impact)
        _swapExactInputSingle(poolKey, true, 100e6, 0);
        _swapExactInputSingle(poolKey, false, 0.1e18, 0);
        _swapExactInputSingle(poolKey, true, 100e6, 0);
        _swapExactInputSingle(poolKey, false, 0.1e18, 0);

        // Configure for 30% target (current ~70% → need leverage down) with 50% reward
        uint64 maxReward = uint64(Q64 * 50 / 100);
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            maxRewardX64: maxReward
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        // Check contract balances before
        uint256 contractUsdcBefore = usdc.balanceOf(address(autoLeverage));

        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: false,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: bytes(""),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: bytes(""),
            amountAddMin0: 0,
            amountAddMin1: 0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes(""),
            rewardX64: maxReward
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        // Contract should retain reward (fees collected in both tokens)
        uint256 contractUsdcAfter = usdc.balanceOf(address(autoLeverage));
        uint256 contractWethAfter = weth.balanceOf(address(autoLeverage));
        assertTrue(
            contractUsdcAfter > contractUsdcBefore || contractWethAfter > 0,
            "Contract should retain protocol reward"
        );

        // Withdrawer can collect the reward
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        uint256 withdrawerUsdcBefore = usdc.balanceOf(withdrawer);
        uint256 withdrawerWethBefore = weth.balanceOf(withdrawer);

        vm.prank(withdrawer);
        autoLeverage.withdrawBalances(tokens, withdrawer);

        assertTrue(
            usdc.balanceOf(withdrawer) > withdrawerUsdcBefore || weth.balanceOf(withdrawer) > withdrawerWethBefore,
            "Withdrawer should be able to collect reward"
        );
    }

    // --- Deactivation Test ---

    function test_DeactivateConfig() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Activate
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 500,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActiveBefore,,,) = autoLeverage.positionConfigs(tokenId);
        assertTrue(isActiveBefore);

        // Deactivate
        config.isActive = false;
        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActiveAfter,,,) = autoLeverage.positionConfigs(tokenId);
        assertFalse(isActiveAfter);
    }
}
