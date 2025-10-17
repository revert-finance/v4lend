// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {V4Utils} from "../src/transformers/V4Utils.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import "./V4ForkTestBase.sol";

/**
 * @title V4UtilsSwapTest
 * @notice Test suite for V4Utils.swap() functionality
 * @dev Tests token swaps with optional permit2 signatures
 */
contract V4UtilsSwapTest is V4ForkTestBase {

    struct SwapTestParams {
        Currency tokenIn;
        Currency tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        bytes swapData;
        string testName;
    }

    function _executeSwap(
        SwapTestParams memory params
    ) internal {
        _logTestStart("SWAP", params.testName);
        
        // Record initial balances
        (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance) = _recordInitialBalances(params.recipient);
        
        // Log swap parameters
        console.log("TokenIn address:", Currency.unwrap(params.tokenIn));
        console.log("TokenOut address:", Currency.unwrap(params.tokenOut));
        console.log("AmountIn:", params.amountIn);
        console.log("MinAmountOut:", params.minAmountOut);
        console.log("Recipient:", params.recipient);
        
        // Execute the swap
        _executeSwapTest(params);
        
        // Record final balances
        (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) = _recordFinalBalances(
            params.recipient,
            initialWethBalance,
            initialUsdcBalance,
            initialEthBalance
        );
        
        _logTestCompletion("SWAP");

        // Assertions for SWAP operation
        _verifySwapResults(params, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
    }

    function _executeSwapTest(SwapTestParams memory params) internal {
        // Set up direct ERC20 allowances from user to V4Utils (since swap uses direct transfers)
        if (Currency.unwrap(params.tokenIn) != address(0)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(params.tokenIn)).approve(address(v4Utils), type(uint256).max);
        }

        // Create swap parameters
        V4Utils.SwapParamsV4 memory swapParams = V4Utils.SwapParamsV4({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            amountIn: params.amountIn,
            minAmountOut: params.minAmountOut,
            recipient: params.recipient,
            swapData: params.swapData
        });

        // Execute swap
        uint256 amountOut;
        
        vm.prank(params.recipient);
        // If tokenIn is ETH, send the ETH value with the call
        if (Currency.unwrap(params.tokenIn) == address(0)) {
            amountOut = v4Utils.swap{value: params.amountIn}(swapParams);
        } else {
            amountOut = v4Utils.swap(swapParams);
        }
        
        console.log("Swap successful - AmountOut:", amountOut);
        
        // Verify swap was successful
        assertGt(amountOut, 0, "Amount out should be greater than 0");
        assertGe(amountOut, params.minAmountOut, "Amount out should meet minimum requirement");
        
        console.log("SWAP executed successfully");
        console.log("Amount out:", amountOut);
    }

    function _verifySwapResults(
        SwapTestParams memory /* params */,
        uint256 /* initialWethBalance */,
        uint256 /* finalWethBalance */,
        uint256 /* initialUsdcBalance */,
        uint256 /* finalUsdcBalance */,
        uint256 /* initialEthBalance */,
        uint256 /* finalEthBalance */
    ) internal {
        _verifyContractCleanup();
        
        console.log("All SWAP assertions passed successfully");
    }

    function testSwap_USDC_to_WETH() public {
        SwapTestParams memory params = SwapTestParams({
            tokenIn: Currency.wrap(address(usdc)),
            tokenOut: Currency.wrap(address(weth)),
            amountIn: 873073,
            minAmountOut: 188428045653858,
            recipient: nft1Owner,
            swapData: _getUSDCtoWETHSwapData(),
            testName: "USDC to WETH"
        });
        
        _executeSwap(params);
    }

    function testSwap_ETH_to_USDC() public {
        SwapTestParams memory params = SwapTestParams({
            tokenIn: CurrencyLibrary.ADDRESS_ZERO, // ETH
            tokenOut: Currency.wrap(address(usdc)),
            amountIn: 1000000000000000,
            minAmountOut: 4128717,
            recipient: nft1Owner,
            swapData: _getETHToUSDCSwapData(),
            testName: "ETH to USDC"
        });
        
        _executeSwap(params);
    }

    function testSwap_USDC_to_ETH() public {
        SwapTestParams memory params = SwapTestParams({
            tokenIn: Currency.wrap(address(usdc)),
            tokenOut: CurrencyLibrary.ADDRESS_ZERO, // ETH
            amountIn: 6274987, 
            minAmountOut: 756050291375000,
            recipient: nft1Owner,
            swapData: _getUSDCtoETHSwapData(),
            testName: "USDC to ETH"
        });
        
        _executeSwap(params);
    }

    function testSwap_WETH_to_ETH() public {
        SwapTestParams memory params = SwapTestParams({
            tokenIn: Currency.wrap(address(weth)),
            tokenOut: CurrencyLibrary.ADDRESS_ZERO, // ETH
            amountIn: 1000000000000000,
            minAmountOut: 1000000000000000,
            recipient: nft1Owner,
            swapData: hex"", // No swap data needed for direct WETH->ETH
            testName: "WETH to ETH (Direct)"
        });
        
        _executeSwap(params);
    }

    function testSwap_ETH_to_WETH() public {
        SwapTestParams memory params = SwapTestParams({
            tokenIn: CurrencyLibrary.ADDRESS_ZERO, // ETH
            tokenOut: Currency.wrap(address(weth)),
            amountIn: 1000000000000000,
            minAmountOut: 1000000000000000,
            recipient: nft1Owner,
            swapData: hex"", // No swap data needed for direct ETH->WETH
            testName: "ETH to WETH (Direct)"
        });
        
        _executeSwap(params);
    }

}
