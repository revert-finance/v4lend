// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {AutoLeverage} from "../../src/automators/AutoLeverage.sol";
import {Constants} from "src/shared/Constants.sol";
import {Swapper} from "src/shared/swap/Swapper.sol";
import {IUniversalRouter} from "src/shared/swap/IUniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoLeverageTest is AutomatorTestBase {
    AutoLeverage public autoLeverage;

    function setUp() public override {
        super.setUp();

        autoLeverage =
            new AutoLeverage(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);
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
            maxSwapSlippageBps: 10000,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);

        (bool isActive, uint16 targetBps, uint16 threshold,,) =
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
            maxSwapSlippageBps: 10000,
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
            maxSwapSlippageBps: 10000,
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
            maxSwapSlippageBps: 10000,
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
            maxSwapSlippageBps: 10000,
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
            maxSwapSlippageBps: 10000,
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

    function test_LeverageDownIgnoresDustedBalances() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, collateralValue * 70 / 100);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            maxSwapSlippageBps: 10000,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        uint256 dustAmount = 111;
        deal(address(weth), address(autoLeverage), dustAmount);

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

        assertEq(weth.balanceOf(address(autoLeverage)), dustAmount, "dusted WETH should not be attributed to leverage down");
    }

    function test_LeverageDownThirdTokenFeesReduceLiquidityRemoval() public {
        // Enable DAI collateral for this vault-backed scenario.
        vault.setTokenConfig(address(dai), uint32(Q32 * 9 / 10), type(uint32).max);

        PoolKey memory poolKey = _createDaiWethPool();
        _createFullRangePositionDaiWeth(poolKey);
        uint256 tokenId = _createFullRangePositionDaiWeth(poolKey);
        v4Oracle.setMaxPoolPriceDifference(type(uint16).max);

        _generateFeesDaiWeth(poolKey);
        (, uint128 fee0, uint128 fee1) = v4Oracle.getLiquidityAndFees(tokenId);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        uint16 maxSwapSlippageBps = 100;
        uint256 conservativeFeeRepayCapacity =
            _quoteTokenToUsdcWithHaircut(address(dai), fee0, maxSwapSlippageBps)
            + _quoteTokenToUsdcWithHaircut(address(weth), fee1, maxSwapSlippageBps);
        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 repayAmountTarget = conservativeFeeRepayCapacity * 9 / 10;
        uint256 borrowAmount = (3000 * collateralValue + repayAmountTarget * (10000 - 3000)) / 10000;

        assertGt(fee0, 0, "expected DAI fees");
        assertGt(fee1, 0, "expected WETH fees");
        assertGt(conservativeFeeRepayCapacity, repayAmountTarget, "fees should cover deleverage target");
        assertGt(borrowAmount, conservativeFeeRepayCapacity, "position should remain leveraged after fee-only deleverage");

        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            maxSwapSlippageBps: maxSwapSlippageBps,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);

        AutoLeverage.ExecuteParams memory params = AutoLeverage.ExecuteParams({
            tokenId: tokenId,
            vault: address(vault),
            leverageUp: false,
            amountIn0: fee0,
            amountOut0Min: 0,
            swapData0: _createSwapDataWithFee(fee0, 0, address(dai), address(usdc), 500, address(autoLeverage)),
            amountIn1: fee1,
            amountOut1Min: 0,
            swapData1: _createSwapDataWithFee(fee1, 0, address(weth), address(usdc), 500, address(autoLeverage)),
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

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        (uint256 debtAfter, uint256 debtSharesAfter, uint256 collateralAfter,,) = vault.loanInfo(tokenId);

        assertEq(liquidityAfter, liquidityBefore, "fees alone should avoid liquidity removal");
        assertLt(debtAfter, debtBefore, "fees should still repay debt");
        assertEq(usdc.balanceOf(address(autoLeverage)), 0, "automator should not retain lend token leftovers");
        assertGt(debtSharesAfter, 0, "position should remain leveraged after fee-only deleverage");
        assertGt(collateralAfter, 0, "position should remain open after fee-only deleverage");
    }

    // --- Native ETH Position Tests ---

    function test_LeverageUpETH() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createFullRangePositionEth(poolKey);

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
            maxSwapSlippageBps: 10000,
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
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createFullRangePositionEth(poolKey);

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
            maxSwapSlippageBps: 10000,
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

    function test_RewardSentToProtocolFeeRecipientInETH() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue * 70 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, borrowAmount);

        _generateFeesEth(poolKey);

        uint64 maxReward = uint64(Q64 * 50 / 100);
        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 3000,
            rebalanceThresholdBps: 100,
            maxSwapSlippageBps: 10000,
            maxRewardX64: maxReward
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        uint256 recipientEthBefore = protocolFeeRecipient.balance;

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

        assertEq(address(autoLeverage).balance, 0, "contract should not retain native protocol fees");
        assertEq(usdc.balanceOf(address(autoLeverage)), 0, "contract should not retain USDC protocol fees");
        assertGt(protocolFeeRecipient.balance, recipientEthBefore, "recipient should receive native ETH protocol fees");
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
            maxSwapSlippageBps: 10000,
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

    function test_ExecuteAtExactLowerThresholdBoundary() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, collateralValue * 40 / 100);

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: 5000,
            rebalanceThresholdBps: 1000,
            maxSwapSlippageBps: 10000,
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
        assertGt(debtAfter, debtBefore, "exact lower threshold boundary should still rebalance up");
    }

    function test_ExecuteAtExactUpperThresholdBoundary() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createFullRangePosition(poolKey);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, collateralValue * 70 / 100);

        (uint256 currentDebt,, uint256 currentCollateralValue,,) = vault.loanInfo(tokenId);
        uint16 thresholdBps = uint16(currentDebt * 10_000 / currentCollateralValue / 2);
        uint16 targetBps = uint16(currentDebt * 10_000 / currentCollateralValue) - thresholdBps;

        AutoLeverage.PositionConfig memory config = AutoLeverage.PositionConfig({
            isActive: true,
            targetLeverageBps: targetBps,
            rebalanceThresholdBps: thresholdBps,
            maxSwapSlippageBps: 10000,
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
        assertLt(debtAfter, debtBefore, "exact upper threshold boundary should still rebalance down");
    }

    // --- Reward Retention Test ---

    function test_RewardSentToProtocolFeeRecipient() public {
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
            maxSwapSlippageBps: 10000,
            maxRewardX64: maxReward
        });

        vm.prank(WHALE_ACCOUNT);
        autoLeverage.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoLeverage), true);

        // Check contract balances before
        uint256 recipientUsdcBefore = usdc.balanceOf(protocolFeeRecipient);
        uint256 recipientWethBefore = weth.balanceOf(protocolFeeRecipient);

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

        uint256 contractUsdcAfter = usdc.balanceOf(address(autoLeverage));
        uint256 contractWethAfter = weth.balanceOf(address(autoLeverage));
        assertTrue(
            usdc.balanceOf(protocolFeeRecipient) > recipientUsdcBefore
                || weth.balanceOf(protocolFeeRecipient) > recipientWethBefore,
            "recipient should receive protocol fees"
        );
        assertEq(contractUsdcAfter, 0, "contract should not retain USDC protocol fees");
        assertEq(contractWethAfter, 0, "contract should not retain WETH protocol fees");
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
            maxSwapSlippageBps: 10000,
            maxRewardX64: 0
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

    function _createDaiWethPool() internal returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(dai)),
            currency1: Currency.wrap(address(weth)),
            fee: 7778,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(poolKey, v4Oracle.getPoolSqrtPriceX96(address(dai), address(weth)));
    }

    function _approveWhaleDaiAndWeth() internal {
        deal(address(dai), WHALE_ACCOUNT, 1_000_000e18);
        deal(address(weth), WHALE_ACCOUNT, 1_000e18);

        vm.prank(WHALE_ACCOUNT);
        dai.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        weth.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(dai), address(positionManager), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _createFullRangePositionDaiWeth(PoolKey memory poolKey) internal returns (uint256 tokenId) {
        _approveWhaleDaiAndWeth();
        tokenId = _mintPosition(poolKey, -887220, 887220, 1e16);
    }

    function _swapExactInputSingleDaiWeth(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut) internal {
        _approveWhaleDaiAndWeth();
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(dai), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        bytes memory commands = hex"10";
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, minAmountOut);
        inputs[0] = abi.encode(actions, params);

        vm.prank(WHALE_ACCOUNT);
        IUniversalRouter(address(swapRouter)).execute(commands, inputs, block.timestamp);
    }

    function _generateFeesDaiWeth(PoolKey memory poolKey) internal {
        _swapExactInputSingleDaiWeth(poolKey, true, 200e18, 0);
        _swapExactInputSingleDaiWeth(poolKey, false, 5e16, 0);
        _swapExactInputSingleDaiWeth(poolKey, true, 200e18, 0);
        _swapExactInputSingleDaiWeth(poolKey, false, 5e16, 0);
    }

    function _createSwapDataWithFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient
    ) internal view returns (bytes memory swapData) {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(recipient, amountIn, amountOutMin, abi.encodePacked(tokenIn, fee, tokenOut), false);
        inputs[1] = abi.encode(tokenIn, recipient, 0);
        swapData = abi.encode(
            address(swapRouter), abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp))
        );
    }

    function _quoteTokenToUsdcWithHaircut(address tokenIn, uint256 amountIn, uint16 maxSwapSlippageBps)
        internal
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            return 0;
        }
        if (tokenIn == address(usdc)) {
            return amountIn;
        }

        uint160 oracleSqrtPriceX96 = v4Oracle.getPoolSqrtPriceX96(tokenIn, address(usdc));
        uint256 oraclePriceX96 = FullMath.mulDiv(uint256(oracleSqrtPriceX96), uint256(oracleSqrtPriceX96), Q96);
        uint256 oracleOut = FullMath.mulDiv(amountIn, oraclePriceX96, Q96);
        amountOut = FullMath.mulDiv(oracleOut, 10000 - uint256(maxSwapSlippageBps), 10000);
    }
}
