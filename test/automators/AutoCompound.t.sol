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
            hookData: bytes("")
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCompound.execute(params);
    }

    function test_RevertWhenNonWithdrawerCallsWithdrawBalances() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCompound.withdrawBalances(tokens, randomUser);
    }

    function test_SetOperator() public {
        address newOperator = makeAddr("newOperator");
        autoCompound.setOperator(newOperator, true);
        assertTrue(autoCompound.operators(newOperator));
        autoCompound.setOperator(newOperator, false);
        assertFalse(autoCompound.operators(newOperator));
    }

    function test_SetReward() public {
        uint64 rewardX64 = uint64(Q64 * 3 / 100); // 3%
        autoCompound.setReward(rewardX64);
        assertEq(autoCompound.totalRewardX64(), rewardX64);
    }

    function test_RevertWhenRewardTooHigh() public {
        uint64 rewardX64 = uint64(Q64 * 6 / 100); // 6% > 5% max
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoCompound.setReward(rewardX64);
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
            hookData: bytes("")
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
            hookData: bytes("")
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

        // Set small reward
        autoCompound.setReward(uint64(Q64 * 1 / 100)); // 1%

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
            hookData: bytes("")
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

        autoCompound.setReward(uint64(Q64 * 1 / 100));
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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        assertGt(usdcAfter, usdcBefore, "Owner should receive token0 (USDC)");
    }

    function test_HarvestToken1() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        autoCompound.setReward(uint64(Q64 * 1 / 100));
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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        // Owner receives WETH unwrapped as ETH, or direct WETH
        assertTrue(ethAfter > ethBefore || weth.balanceOf(WHALE_ACCOUNT) > 0, "Owner should receive token1 (WETH/ETH)");
    }

    // --- Leftover Balance & Withdrawal Tests ---

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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Owner can withdraw leftover balances
        vm.prank(WHALE_ACCOUNT);
        autoCompound.withdrawLeftoverBalances(tokenId, WHALE_ACCOUNT);
    }

    function test_WithdrawProtocolFees() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Set reward to accumulate protocol fees
        autoCompound.setReward(uint64(Q64 * 5 / 100)); // 5%

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCompound), tokenId);

        // Auto-compound to generate protocol fees
        AutoCompound.ExecuteParams memory params = AutoCompound.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCompound.CompoundMode.AUTO_COMPOUND,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Check protocol fees accumulated
        uint256 protocolFees0 = autoCompound.positionBalances(0, address(usdc));
        uint256 protocolFees1 = autoCompound.positionBalances(0, address(weth));
        assertTrue(protocolFees0 > 0 || protocolFees1 > 0, "Protocol fees should have accumulated");

        // Withdrawer can withdraw protocol fees
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        vm.prank(withdrawer);
        autoCompound.withdrawBalances(tokens, withdrawer);
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
            hookData: bytes("")
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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.executeWithVault(params, address(vault));

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH vault auto-compound");

        // Verify position still owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    function test_AutoCompoundETHWithReward() public {
        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        // Set 5% reward
        autoCompound.setReward(uint64(Q64 * 5 / 100));

        // Generate fees with native ETH swaps
        _generateFeesETH(poolKey);

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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Check protocol fees accumulated for native ETH (address(0))
        uint256 protocolFeesETH = autoCompound.positionBalances(0, address(0));
        uint256 protocolFeesUSDC = autoCompound.positionBalances(0, address(usdc));
        assertTrue(protocolFeesETH > 0 || protocolFeesUSDC > 0, "Protocol fees should accumulate for ETH position");

        // Verify withdrawer can withdraw protocol fees including native ETH
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(usdc);

        uint256 withdrawerETHBefore = withdrawer.balance;
        uint256 withdrawerUSDCBefore = usdc.balanceOf(withdrawer);

        vm.prank(withdrawer);
        autoCompound.withdrawBalances(tokens, withdrawer);

        // Verify protocol fees were withdrawn
        if (protocolFeesETH > 0) {
            assertEq(withdrawer.balance - withdrawerETHBefore, protocolFeesETH, "Withdrawer should receive ETH protocol fees");
        }
        if (protocolFeesUSDC > 0) {
            assertEq(usdc.balanceOf(withdrawer) - withdrawerUSDCBefore, protocolFeesUSDC, "Withdrawer should receive USDC protocol fees");
        }

        // Verify balances zeroed out
        assertEq(autoCompound.positionBalances(0, address(0)), 0, "ETH protocol balance should be 0 after withdrawal");
        assertEq(autoCompound.positionBalances(0, address(usdc)), 0, "USDC protocol balance should be 0 after withdrawal");
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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        // Check leftover balances
        uint256 leftoverETH = autoCompound.positionBalances(tokenId, address(0));
        uint256 leftoverUSDC = autoCompound.positionBalances(tokenId, address(usdc));

        uint256 ownerETHBefore = WHALE_ACCOUNT.balance;
        uint256 ownerUSDCBefore = usdc.balanceOf(WHALE_ACCOUNT);

        // Owner can withdraw leftover balances including native ETH
        vm.prank(WHALE_ACCOUNT);
        autoCompound.withdrawLeftoverBalances(tokenId, WHALE_ACCOUNT);

        // Verify leftovers were withdrawn
        if (leftoverETH > 0) {
            assertEq(WHALE_ACCOUNT.balance - ownerETHBefore, leftoverETH, "Owner should receive ETH leftovers");
        }
        if (leftoverUSDC > 0) {
            assertEq(usdc.balanceOf(WHALE_ACCOUNT) - ownerUSDCBefore, leftoverUSDC, "Owner should receive USDC leftovers");
        }

        // Verify balances zeroed out
        assertEq(autoCompound.positionBalances(tokenId, address(0)), 0, "ETH leftover should be 0");
        assertEq(autoCompound.positionBalances(tokenId, address(usdc)), 0, "USDC leftover should be 0");
    }

    function test_HarvestTokensETH() public {
        PoolKey memory poolKey = _createETHPool();
        uint256 tokenId = _createFullRangePositionETH(poolKey);

        autoCompound.setReward(uint64(Q64 * 1 / 100)); // 1%
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
            hookData: bytes("")
        });

        vm.prank(operator);
        autoCompound.execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens (ETH and/or USDC)
        assertTrue(ethAfter > ethBefore || usdcAfter > usdcBefore, "Owner should receive harvested ETH/USDC tokens");
    }
}
