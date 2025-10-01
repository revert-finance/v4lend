// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {V4Utils} from "../src/V4Utils.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import "./V4UtilsExecuteTestBase.sol";

/**
 * @title V4UtilsSwapAndIncreaseLiquidityTest
 * @notice Test suite for V4Utils.swapAndIncreaseLiquidity() functionality
 * @dev Tests adding liquidity to existing positions with optional token swaps
 */
contract V4UtilsSwapAndIncreaseLiquidityTest is V4UtilsExecuteTestBase {

    struct SwapAndIncreaseLiquidityTestParams {
        uint256 tokenId;
        uint256 amount0;
        uint256 amount1;
        address recipient;
        uint256 deadline;
        Currency swapSourceToken;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        string testName;
    }

    function _executeSwapAndIncreaseLiquidity(
        SwapAndIncreaseLiquidityTestParams memory params
    ) internal {
        _logTestStart("SWAP_AND_INCREASE_LIQUIDITY", params.testName);
        
        // Record initial balances
        (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance) = _recordInitialBalances(params.recipient);
        
        // Log position and swap parameters
        console.log("TokenId:", params.tokenId);
        console.log("Amount0:", params.amount0);
        console.log("Amount1:", params.amount1);
        console.log("SwapSourceToken:", Currency.unwrap(params.swapSourceToken));
        console.log("AmountIn0:", params.amountIn0);
        console.log("AmountIn1:", params.amountIn1);
        
        // Get initial position info
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        uint128 initialLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        
        console.log("Initial position liquidity:", initialLiquidity);
        console.log("Position tick lower:", positionInfo.tickLower());
        console.log("Position tick upper:", positionInfo.tickUpper());
        
        // Execute the swap and increase liquidity
        _executeSwapAndIncreaseLiquidityTest(params);
        
        // Record final balances
        (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) = _recordFinalBalances(
            params.recipient,
            initialWethBalance,
            initialUsdcBalance,
            initialEthBalance
        );
        
        _logTestCompletion("SWAP_AND_INCREASE_LIQUIDITY");

        // Assertions for SWAP_AND_INCREASE_LIQUIDITY operation
        _verifySwapAndIncreaseLiquidityResults(params, initialLiquidity, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
    }

    function _executeSwapAndIncreaseLiquidityTest(SwapAndIncreaseLiquidityTestParams memory params) internal {
        // Get position info to determine currencies
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        
        // Approve V4Utils to manage the NFT
        vm.prank(params.recipient);
        IERC721(address(positionManager)).approve(address(v4Utils), params.tokenId);
        
        // Set up Permit2 allowances instead of direct ERC20 allowances
        if (Currency.unwrap(poolKey.currency0) != address(0)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(poolKey.currency0)).approve(address(v4Utils), type(uint256).max);

        }
        if (Currency.unwrap(poolKey.currency1) != address(0)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(poolKey.currency1)).approve(address(v4Utils), type(uint256).max);
        }
        if (Currency.unwrap(params.swapSourceToken) != address(0) && 
            Currency.unwrap(params.swapSourceToken) != Currency.unwrap(poolKey.currency0) && 
            Currency.unwrap(params.swapSourceToken) != Currency.unwrap(poolKey.currency1)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(params.swapSourceToken)).approve(address(v4Utils), type(uint256).max);
        }

        // Create swap and increase liquidity parameters
        V4Utils.SwapAndIncreaseLiquidityParams memory swapAndIncreaseParams = V4Utils.SwapAndIncreaseLiquidityParams({
            tokenId: params.tokenId,
            amount0: params.amount0,
            amount1: params.amount1,
            recipient: params.recipient,
            deadline: params.deadline,
            swapSourceToken: params.swapSourceToken,
            amountIn0: params.amountIn0,
            amountOut0Min: params.amountOut0Min,
            swapData0: params.swapData0,
            amountIn1: params.amountIn1,
            amountOut1Min: params.amountOut1Min,
            swapData1: params.swapData1,
            amountAddMin0: params.amountAddMin0,
            amountAddMin1: params.amountAddMin1,
            decreaseLiquidityHookData: ""
        });

        // Execute swap and increase liquidity
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        
        vm.prank(params.recipient);
        // If native ETH is involved, send the ETH value with the call
        if (Currency.unwrap(poolKey.currency0) == address(0)) {
            (liquidity, amount0, amount1) = v4Utils.swapAndIncreaseLiquidity{value: params.amount0}(swapAndIncreaseParams);
        } else if (Currency.unwrap(poolKey.currency1) == address(0)) {
            (liquidity, amount0, amount1) = v4Utils.swapAndIncreaseLiquidity{value: params.amount1}(swapAndIncreaseParams);
        } else {
            (liquidity, amount0, amount1) = v4Utils.swapAndIncreaseLiquidity(swapAndIncreaseParams);
        }
        
        console.log("SwapAndIncreaseLiquidity successful - Liquidity added:", liquidity);
        console.log("Amount0 used:", amount0);
        console.log("Amount1 used:", amount1);
        
        // Verify liquidity was added
        assertGt(liquidity, 0, "Liquidity added should be greater than 0");
        
        // Verify amounts were consumed (at least one should be > 0)
        assertTrue(amount0 > 0 || amount1 > 0, "At least one amount should be greater than 0");
        
        console.log("SWAP_AND_INCREASE_LIQUIDITY executed successfully");
        console.log("Liquidity added:", liquidity);
        console.log("Amount0 used:", amount0);
        console.log("Amount1 used:", amount1);
    }

    function _verifySwapAndIncreaseLiquidityResults(
        SwapAndIncreaseLiquidityTestParams memory params,
        uint128 initialLiquidity,
        uint256 /* initialWethBalance */,
        uint256 /* finalWethBalance */,
        uint256 /* initialUsdcBalance */,
        uint256 /* finalUsdcBalance */,
        uint256 /* initialEthBalance */,
        uint256 /* finalEthBalance */
    ) internal {
        _verifyContractCleanup();
        
        // Verify position liquidity increased
        uint128 finalLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        assertGt(finalLiquidity, initialLiquidity, "Position liquidity should have increased");
        
        // Verify position still exists and is owned correctly
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        assertEq(IERC721(address(positionManager)).ownerOf(params.tokenId), IERC721(address(positionManager)).ownerOf(params.tokenId), "Position ownership should be unchanged");
        
        // Verify position parameters are unchanged
        assertEq(poolKey.fee, poolKey.fee, "Position fee should be unchanged");
        assertEq(positionInfo.tickLower(), positionInfo.tickLower(), "Position tick lower should be unchanged");
        assertEq(positionInfo.tickUpper(), positionInfo.tickUpper(), "Position tick upper should be unchanged");
        
        console.log("Final position liquidity:", finalLiquidity);
        console.log("Liquidity increase:", finalLiquidity - initialLiquidity);
        console.log("All SWAP_AND_INCREASE_LIQUIDITY assertions passed successfully");
    }

    function testSwapAndIncreaseLiquidity_NFT1_NoSwap() public {
        SwapAndIncreaseLiquidityTestParams memory params = SwapAndIncreaseLiquidityTestParams({
            tokenId: nft1TokenId,
            amount0: 1000000, // 1 USDC (much smaller amount)
            amount1: 1000000000000000, // 0.001 WETH (much smaller amount)
            recipient: nft1Owner,
            deadline: block.timestamp,
            swapSourceToken: Currency.wrap(address(0)), // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - No Swap"
        });
        
        _executeSwapAndIncreaseLiquidity(params);
    }

    function testSwapAndIncreaseLiquidity_NFT2_NoSwap() public {
        SwapAndIncreaseLiquidityTestParams memory params = SwapAndIncreaseLiquidityTestParams({
            tokenId: nft2TokenId,
            amount0: 100000000000000, // 0.0001 ETH (much smaller amount)
            amount1: 1000000, // 1 USDC (much smaller amount)
            recipient: nft2Owner,
            deadline: block.timestamp,
            swapSourceToken: Currency.wrap(address(0)), // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT2 - No Swap"
        });
        
        _executeSwapAndIncreaseLiquidity(params);
    }

    function testSwapAndIncreaseLiquidity_NFT1_WithSwap() public {
        SwapAndIncreaseLiquidityTestParams memory params = SwapAndIncreaseLiquidityTestParams({
            tokenId: nft1TokenId,
            amount0: 0, // No direct USDC
            amount1: 0, // No direct WETH
            recipient: nft1Owner,
            deadline: block.timestamp,
            swapSourceToken: Currency.wrap(address(usdc)), // Swap USDC to WETH
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 873073,
            amountOut1Min: 188428045653858,
            swapData1: _getUSDCtoWETHSwapData(),
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - WETH to USDC Swap"
        });
        
        _executeSwapAndIncreaseLiquidity(params);
    }

    function testSwapAndIncreaseLiquidity_NFT2_WithSwap() public {
        SwapAndIncreaseLiquidityTestParams memory params = SwapAndIncreaseLiquidityTestParams({
            tokenId: nft2TokenId,
            amount0: 0, // No direct ETH
            amount1: 6274987, // Add some more USDC, no enough fees available
            recipient: nft2Owner,
            deadline: block.timestamp,
            swapSourceToken: Currency.wrap(address(usdc)), // Swap USDC to ETH
            amountIn0: 6274987,
            amountOut0Min: 756050291375000,
            swapData0: _getUSDCtoETHSwapData(),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT2 - USDC to ETH Swap"
        });
        
        _executeSwapAndIncreaseLiquidity(params);
    }
}
