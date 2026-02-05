// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
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
            rewardX64: 0,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
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
            rewardX64: 0,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActive, uint16 targetBps, uint16 threshold, bool onlyFees, uint64 maxReward) =
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        // Approve transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        // Record debt before
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        console.log("Debt before leverage up:", debtBefore);

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
            rewardX64: uint64(Q64 / 200),
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        // Debt should have increased
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        console.log("Debt after leverage up:", debtAfter);
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        console.log("Debt before leverage down:", debtBefore);

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
            rewardX64: uint64(Q64 / 200),
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        console.log("Debt after leverage down:", debtAfter);
        assertLt(debtAfter, debtBefore, "Debt should decrease after leverage down");
    }

    // --- onlyFees Tests ---

    function test_LeverageUpOnlyFeesFalse() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees so onlyFees has something to differentiate
        _generateFees(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 10 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure with onlyFees=false (reward from total amounts)
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: uint64(Q64 / 200),
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertGt(debtAfter, debtBefore, "Debt should increase after leverage up (onlyFees=false)");
    }

    function test_LeverageUpOnlyFeesTrue() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees so onlyFees has something to differentiate
        _generateFees(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 10 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure with onlyFees=true (reward from fees only — smaller reward)
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 100,
            onlyFees: true,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: uint64(Q64 / 200),
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertGt(debtAfter, debtBefore, "Debt should increase after leverage up (onlyFees=true)");
    }

    function test_LeverageDownOnlyFeesFalse() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees so onlyFees has something to differentiate
        _generateFees(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 70 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for leverage down with onlyFees=false (reward from total)
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: uint64(Q64 / 200),
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertLt(debtAfter, debtBefore, "Debt should decrease after leverage down (onlyFees=false)");
    }

    function test_LeverageDownOnlyFeesTrue() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees so onlyFees has something to differentiate
        _generateFees(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 70 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        // Configure for leverage down with onlyFees=true (reward from fees only — smaller reward)
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            onlyFees: true,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: uint64(Q64 / 200),
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        autoLeverage.execute(params);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertLt(debtAfter, debtBefore, "Debt should decrease after leverage down (onlyFees=true)");
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
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
            rewardX64: 0,
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        // Inner NotReady() gets wrapped by vault.transform() as TransformFailed()
        vm.expectRevert(Constants.TransformFailed.selector);
        autoLeverage.execute(params);
    }

    function test_RevertWhenExceedsMaxReward() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, collateralValue * 10 / 100);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 100,
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100) // 1%
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

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
            rewardX64: uint64(Q64 / 10), // 10% > 1% max
            decreaseLiquidityHookData: bytes(""),
            increaseLiquidityHookData: bytes("")
        });

        vm.prank(operator);
        // Inner ExceedsMaxReward() gets wrapped by vault.transform() as TransformFailed()
        vm.expectRevert(Constants.TransformFailed.selector);
        autoLeverage.execute(params);
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
            onlyFees: false,
            maxRewardX64: uint64(Q64 / 100)
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActiveBefore,,,,) = autoLeverage.positionConfigs(tokenId);
        assertTrue(isActiveBefore);

        // Deactivate
        config.isActive = false;
        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActiveAfter,,,,) = autoLeverage.positionConfigs(tokenId);
        assertFalse(isActiveAfter);
    }
}
