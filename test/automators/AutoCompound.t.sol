// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoCompound} from "../../src/automators/AutoCompound.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoCompoundTest is AutomatorTestBase {
    AutoCompound public autoCompound;

    function setUp() public override {
        super.setUp();

        autoCompound = new AutoCompound(positionManager, address(swapRouter), EX0x, permit2, operator, withdrawer);

        // Register vault
        autoCompound.setVault(address(vault));
        vault.setTransformer(address(autoCompound), true);
    }

    // --- Access Control Tests ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCompound.execute(params);
    }

    function test_SetOperator() public {
        address newOperator = makeAddr("newOperator");
        autoCompound.setOperator(newOperator, true);
        assertTrue(autoCompound.operators(newOperator));
        autoCompound.setOperator(newOperator, false);
        assertFalse(autoCompound.operators(newOperator));
    }

    // --- AutoCompound Mode Tests ---

    function test_AutoCompound() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Approve NFT to autoCompound
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Execute auto-compound (no swap for simplicity)
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after auto-compound");
    }

    function test_AutoCompoundWithVault() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve autoCompound to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoCompound), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Execute via vault
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.executeWithVault(params, address(vault));

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after vault auto-compound");

        // Verify position still owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    // --- Harvest Mode Tests ---

    function test_HarvestTokens() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        // Approve NFT
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 wethBefore = weth.balanceOf(WHALE_ACCOUNT);

        // Execute harvest
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 wethAfter = weth.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens
        assertTrue(usdcAfter > usdcBefore || wethAfter > wethBefore, "Owner should receive harvested tokens");

        // Liquidity should not change (harvest doesn't add liquidity)
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidity, 0, "Position should still have liquidity");
    }

    function test_HarvestToken0() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.HARVEST_TOKEN_0,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        assertGt(usdcAfter, usdcBefore, "Owner should receive token0 (USDC)");
    }

    function test_HarvestToken1() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Track ETH balance since WETH gets unwrapped by _transferToken
        uint256 ethBefore = WHALE_ACCOUNT.balance;

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.HARVEST_TOKEN_1,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        // Owner receives WETH unwrapped as ETH, or direct WETH
        assertTrue(ethAfter > ethBefore || weth.balanceOf(WHALE_ACCOUNT) > 0, "Owner should receive token1 (WETH/ETH)");
    }

    // --- Leftover Balance Tests ---

    function test_WithdrawLeftoverBalances() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Auto-compound to potentially create leftovers
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Owner can withdraw leftover balances
        vm.prank(WHALE_ACCOUNT);
        autoCompound.withdrawLeftoverBalances(tokenId, WHALE_ACCOUNT);
    }

    // --- Unauthorized leftover withdrawal ---

    function test_RevertWhenNonOwnerWithdrawsLeftovers() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCompound.withdrawLeftoverBalances(tokenId, randomUser);
    }

    function test_OnlyFeesFlagAffectsRewardOnLeftovers() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenIdOnlyFees = _createFullRangePosition(poolKey);
        uint256 tokenIdTotal = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoCompound), true);

        AutoCompound.ExecuteParams memory compoundParams = AutoCompound.ExecuteParams({
            tokenId: tokenIdOnlyFees,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(compoundParams);

        compoundParams.tokenId = tokenIdTotal;
        vm.prank(operator);
        autoCompound.execute(compoundParams);

        bool hasLeftoversOnlyFees = autoCompound.positionBalances(tokenIdOnlyFees, address(usdc)) > 0
            || autoCompound.positionBalances(tokenIdOnlyFees, address(weth)) > 0;
        bool hasLeftoversTotal =
            autoCompound.positionBalances(tokenIdTotal, address(usdc)) > 0
                || autoCompound.positionBalances(tokenIdTotal, address(weth)) > 0;
        assertTrue(hasLeftoversOnlyFees && hasLeftoversTotal, "Setup should create leftovers");

        uint64 maxReward = type(uint64).max;

        vm.startPrank(WHALE_ACCOUNT);
        autoCompound.configToken(tokenIdOnlyFees, AutoCompound.PositionConfig({maxRewardX64: maxReward, onlyFees: true}));
        autoCompound.configToken(tokenIdTotal, AutoCompound.PositionConfig({maxRewardX64: maxReward, onlyFees: false}));
        vm.stopPrank();

        AutoCompound.ExecuteParams memory harvestParams = AutoCompound.ExecuteParams({
            tokenId: tokenIdOnlyFees,
            mode: AutoCompound.CompoundMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        uint256 balanceUsdc = usdc.balanceOf(address(autoCompound));
        uint256 balanceWeth = weth.balanceOf(address(autoCompound));
        uint256 reservedUsdc = autoCompound.totalPositionBalances(address(usdc));
        uint256 reservedWeth = autoCompound.totalPositionBalances(address(weth));
        uint256 availableUsdcBefore = balanceUsdc > reservedUsdc ? balanceUsdc - reservedUsdc : 0;
        uint256 availableWethBefore = balanceWeth > reservedWeth ? balanceWeth - reservedWeth : 0;
        vm.prank(operator);
        autoCompound.execute(harvestParams);
        balanceUsdc = usdc.balanceOf(address(autoCompound));
        balanceWeth = weth.balanceOf(address(autoCompound));
        reservedUsdc = autoCompound.totalPositionBalances(address(usdc));
        reservedWeth = autoCompound.totalPositionBalances(address(weth));
        uint256 availableUsdcAfter = balanceUsdc > reservedUsdc ? balanceUsdc - reservedUsdc : 0;
        uint256 availableWethAfter = balanceWeth > reservedWeth ? balanceWeth - reservedWeth : 0;
        uint256 onlyFeesRewardUsdc =
            availableUsdcAfter > availableUsdcBefore ? availableUsdcAfter - availableUsdcBefore : 0;
        uint256 onlyFeesRewardWeth =
            availableWethAfter > availableWethBefore ? availableWethAfter - availableWethBefore : 0;

        harvestParams.tokenId = tokenIdTotal;
        balanceUsdc = usdc.balanceOf(address(autoCompound));
        balanceWeth = weth.balanceOf(address(autoCompound));
        reservedUsdc = autoCompound.totalPositionBalances(address(usdc));
        reservedWeth = autoCompound.totalPositionBalances(address(weth));
        availableUsdcBefore = balanceUsdc > reservedUsdc ? balanceUsdc - reservedUsdc : 0;
        availableWethBefore = balanceWeth > reservedWeth ? balanceWeth - reservedWeth : 0;
        vm.prank(operator);
        autoCompound.execute(harvestParams);
        balanceUsdc = usdc.balanceOf(address(autoCompound));
        balanceWeth = weth.balanceOf(address(autoCompound));
        reservedUsdc = autoCompound.totalPositionBalances(address(usdc));
        reservedWeth = autoCompound.totalPositionBalances(address(weth));
        availableUsdcAfter = balanceUsdc > reservedUsdc ? balanceUsdc - reservedUsdc : 0;
        availableWethAfter = balanceWeth > reservedWeth ? balanceWeth - reservedWeth : 0;
        uint256 totalRewardUsdc =
            availableUsdcAfter > availableUsdcBefore ? availableUsdcAfter - availableUsdcBefore : 0;
        uint256 totalRewardWeth =
            availableWethAfter > availableWethBefore ? availableWethAfter - availableWethBefore : 0;

        assertTrue(totalRewardUsdc > 0 || totalRewardWeth > 0, "onlyFees=false should collect leftover reward");
        assertTrue(
            totalRewardUsdc > onlyFeesRewardUsdc || totalRewardWeth > onlyFeesRewardWeth,
            "onlyFees=false should collect more reward than onlyFees=true on leftover-only runs"
        );
    }

    // --- Native ETH Position Tests ---

    function test_AutoCompoundETH() public {
        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        // Generate fees with native ETH swaps
        _generateFeesETH(poolKey);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Approve NFT to autoCompound
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Execute auto-compound
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH auto-compound");
    }

    function test_AutoCompoundETHWithVault() public {
        // Increase oracle tolerance for custom pool price
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        // Generate fees
        _generateFeesETH(poolKey);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve autoCompound to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoCompound), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Execute via vault
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.executeWithVault(params, address(vault));

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH vault auto-compound");

        // Verify position still owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    function test_WithdrawLeftoverBalancesETH() public {
        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        _generateFeesETH(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Auto-compound to potentially create leftovers
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Owner can withdraw leftover balances including native ETH
        vm.prank(WHALE_ACCOUNT);
        autoCompound.withdrawLeftoverBalances(tokenId, WHALE_ACCOUNT);
    }

    // --- Withdraw preserves leftover balances ---

    function test_WithdrawETHPreservesLeftovers() public {
        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        // Generate fees
        _generateFeesETH(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Configure with reward so protocol reward accumulates in contract
        uint64 maxReward = uint64(Q64 * 10 / 100);
        vm.prank(WHALE_ACCOUNT);
        autoCompound.configToken(tokenId, AutoCompound.PositionConfig({maxRewardX64: maxReward, onlyFees: false}));

        // Auto-compound (no swap → one side will have leftovers)
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Check that native ETH leftovers exist (address(0) is token0 in ETH pool)
        uint256 ethLeftover = autoCompound.positionBalances(tokenId, address(0));
        uint256 usdcLeftover = autoCompound.positionBalances(tokenId, address(usdc));
        assertTrue(ethLeftover > 0 || usdcLeftover > 0, "Should have some leftover after no-swap compound");

        // Withdrawer calls withdrawETH — should NOT drain position leftover
        vm.prank(withdrawer);
        autoCompound.withdrawETH(withdrawer);

        // Contract should still have at least the reserved amount
        assertGe(address(autoCompound).balance, ethLeftover, "ETH leftovers should be preserved after withdrawETH");

        // Position owner can still claim their leftovers
        uint256 ownerEthBefore = WHALE_ACCOUNT.balance;
        vm.prank(WHALE_ACCOUNT);
        autoCompound.withdrawLeftoverBalances(tokenId, WHALE_ACCOUNT);

        if (ethLeftover > 0) {
            assertEq(WHALE_ACCOUNT.balance - ownerEthBefore, ethLeftover, "Owner should receive exact ETH leftover");
        }
    }

    function test_WithdrawBalancesPreservesLeftovers() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Configure with reward
        uint64 maxReward = uint64(Q64 * 10 / 100);
        vm.prank(WHALE_ACCOUNT);
        autoCompound.configToken(tokenId, AutoCompound.PositionConfig({maxRewardX64: maxReward, onlyFees: false}));

        // Auto-compound (no swap → leftovers will exist)
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Check leftovers exist
        uint256 usdcLeftover = autoCompound.positionBalances(tokenId, address(usdc));
        uint256 wethLeftover = autoCompound.positionBalances(tokenId, address(weth));
        assertTrue(usdcLeftover > 0 || wethLeftover > 0, "Should have some leftover after no-swap compound");

        // Withdrawer calls withdrawBalances — should NOT drain position leftovers
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        vm.prank(withdrawer);
        autoCompound.withdrawBalances(tokens, withdrawer);

        // Contract should still have at least the reserved amounts
        assertGe(
            usdc.balanceOf(address(autoCompound)), usdcLeftover, "USDC leftovers should be preserved after withdrawBalances"
        );
        assertGe(
            weth.balanceOf(address(autoCompound)), wethLeftover, "WETH leftovers should be preserved after withdrawBalances"
        );

        // Position owner can still claim their leftovers
        uint256 ownerUsdcBefore = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 ownerWethBefore = weth.balanceOf(WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        autoCompound.withdrawLeftoverBalances(tokenId, WHALE_ACCOUNT);

        if (usdcLeftover > 0) {
            assertEq(
                usdc.balanceOf(WHALE_ACCOUNT) - ownerUsdcBefore,
                usdcLeftover,
                "Owner should receive exact USDC leftover"
            );
        }
        if (wethLeftover > 0) {
            assertEq(
                weth.balanceOf(WHALE_ACCOUNT) - ownerWethBefore,
                wethLeftover,
                "Owner should receive exact WETH leftover"
            );
        }
    }

    function test_HarvestTokensETH() public {
        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        _generateFeesETH(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        uint256 ethBefore = WHALE_ACCOUNT.balance;
        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens (ETH and/or USDC)
        assertTrue(ethAfter > ethBefore || usdcAfter > usdcBefore, "Owner should receive harvested ETH/USDC tokens");
    }
}
