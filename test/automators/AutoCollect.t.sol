// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoCollect} from "../../src/automators/AutoCollect.sol";
import {Constants} from "src/shared/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoCollectTest is AutomatorTestBase {
    AutoCollect public autoCollect;

    function setUp() public override {
        super.setUp();

        autoCollect = new AutoCollect(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, withdrawer);

        // Register vault
        autoCollect.setVault(address(vault));
        vault.setTransformer(address(autoCollect), true);
    }

    function _collectConfig(
        uint64 maxRewardX64,
        uint16 token0SlippageBps,
        uint16 token1SlippageBps,
        uint128 minCollectAmount0,
        uint128 minCollectAmount1
    ) internal pure returns (AutoCollect.PositionConfig memory) {
        return AutoCollect.PositionConfig({
            maxRewardX64: maxRewardX64,
            token0SlippageBps: token0SlippageBps,
            token1SlippageBps: token1SlippageBps,
            minCollectAmount0: minCollectAmount0,
            minCollectAmount1: minCollectAmount1
        });
    }

    // --- Access Control Tests ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
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
        autoCollect.execute(params);
    }

    function test_SetOperator() public {
        address newOperator = makeAddr("newOperator");
        autoCollect.setOperator(newOperator, true);
        assertTrue(autoCollect.operators(newOperator));
        autoCollect.setOperator(newOperator, false);
        assertFalse(autoCollect.operators(newOperator));
    }

    function test_SetWithdrawer() public {
        address newWithdrawer = makeAddr("newWithdrawer");

        autoCollect.setWithdrawer(newWithdrawer);

        assertEq(autoCollect.withdrawer(), newWithdrawer, "withdrawer should update");

        vm.prank(withdrawer);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCollect.withdrawETH(withdrawer);
    }

    function test_RevertWhenNonOwnerSetsWithdrawer() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        autoCollect.setWithdrawer(makeAddr("newWithdrawer"));
    }

    function test_RevertWhenNonWithdrawerCallsWithdrawETH() public {
        vm.prank(makeAddr("notWithdrawer"));
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCollect.withdrawETH(makeAddr("recipient"));
    }

    function test_RevertWhenNonWithdrawerCallsWithdrawBalances() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.prank(makeAddr("notWithdrawer"));
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCollect.withdrawBalances(tokens, makeAddr("recipient"));
    }

    // --- AutoCollect Mode Tests ---

    function test_AutoCollect() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Approve NFT to autoCollect
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Execute auto-compound (no swap for simplicity)
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after auto-compound");
    }

    function test_AutoCollectRevertsWhenBelowMinAmounts() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(0, 10000, 10000, type(uint128).max, 0));

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.AmountError.selector);
        autoCollect.execute(params);
    }

    function test_AutoCollectWithVault() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve autoCollect to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoCollect), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Execute via vault
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.executeWithVault(params, address(vault));

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
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 wethBefore = weth.balanceOf(WHALE_ACCOUNT);

        // Execute harvest
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 wethAfter = weth.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens
        assertTrue(usdcAfter > usdcBefore || wethAfter > wethBefore, "Owner should receive harvested tokens");

        // Liquidity should not change (harvest doesn't add liquidity)
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidity, 0, "Position should still have liquidity");
    }

    function test_HarvestTokensRevertsWhenBelowMinAmounts() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(0, 10000, 10000, type(uint128).max, 0));

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.AmountError.selector);
        autoCollect.execute(params);
    }

    function test_HarvestToken0() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKEN_0,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        assertGt(usdcAfter, usdcBefore, "Owner should receive token0 (USDC)");
    }

    function test_HarvestToken1() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Track ETH balance since WETH gets unwrapped by _transferToken
        uint256 ethBefore = WHALE_ACCOUNT.balance;

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKEN_1,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        // Owner receives WETH unwrapped as ETH, or direct WETH
        assertTrue(ethAfter > ethBefore || weth.balanceOf(WHALE_ACCOUNT) > 0, "Owner should receive token1 (WETH/ETH)");
    }

    // --- Leftovers paid out immediately ---

    function test_AutoCollectDoesNotRetainPositionBalances() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 contractUsdcBefore = usdc.balanceOf(address(autoCollect));
        uint256 contractWethBefore = weth.balanceOf(address(autoCollect));
        uint256 contractEthBefore = address(autoCollect).balance;

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        // No protocol reward configured: contract must not keep position leftovers.
        assertEq(usdc.balanceOf(address(autoCollect)), contractUsdcBefore);
        assertEq(weth.balanceOf(address(autoCollect)), contractWethBefore);
        assertEq(address(autoCollect).balance, contractEthBefore);
    }

    // --- Native ETH Position Tests ---

    function test_AutoCollectETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        // Generate fees with native ETH swaps
        _generateFeesEth(poolKey);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Approve NFT to autoCollect
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Execute auto-compound
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH auto-compound");
    }

    function test_AutoCollectETHWithVault() public {
        // Increase oracle tolerance for custom pool price
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        // Generate fees
        _generateFeesEth(poolKey);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve autoCollect to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoCollect), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Execute via vault
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.executeWithVault(params, address(vault));

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH vault auto-compound");

        // Verify position still owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    function test_AutoCollectDoesNotRetainPositionBalancesETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 contractUsdcBefore = usdc.balanceOf(address(autoCollect));
        uint256 contractEthBefore = address(autoCollect).balance;

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        // No protocol reward configured: contract must not keep position leftovers.
        assertEq(usdc.balanceOf(address(autoCollect)), contractUsdcBefore);
        assertEq(address(autoCollect).balance, contractEthBefore);
    }

    // --- Withdraw protocol fees ---

    function test_WithdrawETHCollectsProtocolFees() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        // Generate fees
        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Configure with reward so protocol reward accumulates in contract
        uint64 maxReward = type(uint64).max;
        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(maxReward, 10000, 10000, 0, 0));

        // Take 100% of collected fees as protocol reward.
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: type(uint64).max
        });

        uint256 contractEthBefore = address(autoCollect).balance;
        vm.prank(operator);
        autoCollect.execute(params);

        uint256 contractEthAfter = address(autoCollect).balance;
        assertGt(contractEthAfter, contractEthBefore, "Contract should retain ETH protocol fees");

        uint256 withdrawerEthBefore = withdrawer.balance;
        vm.prank(withdrawer);
        autoCollect.withdrawETH(withdrawer);

        assertEq(address(autoCollect).balance, 0, "Withdrawer should be able to collect all ETH protocol fees");
        assertGt(withdrawer.balance, withdrawerEthBefore, "Withdrawer should receive ETH protocol fees");
    }

    function test_WithdrawBalancesCollectsProtocolFees() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Configure with reward
        uint64 maxReward = type(uint64).max;
        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(maxReward, 10000, 10000, 0, 0));

        // Take 100% of collected fees as protocol reward.
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: type(uint64).max
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint256 contractUsdcAfter = usdc.balanceOf(address(autoCollect));
        uint256 contractWethAfter = weth.balanceOf(address(autoCollect));
        assertTrue(contractUsdcAfter > 0 || contractWethAfter > 0, "Contract should retain protocol fees");

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        vm.prank(withdrawer);
        autoCollect.withdrawBalances(tokens, withdrawer);

        assertEq(usdc.balanceOf(address(autoCollect)), 0, "Withdrawer should collect all USDC protocol fees");
        assertEq(weth.balanceOf(address(autoCollect)), 0, "Withdrawer should collect all WETH protocol fees");
    }

    function test_HarvestTokensETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 ethBefore = WHALE_ACCOUNT.balance;
        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoCollect.execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens (ETH and/or USDC)
        assertTrue(ethAfter > ethBefore || usdcAfter > usdcBefore, "Owner should receive harvested ETH/USDC tokens");
    }
}
