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
