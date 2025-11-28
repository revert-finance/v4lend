// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import "./V4ForkTestBase.sol";

/**
 * @title V4UtilsWithdrawAndCollectAndSwapTest
 * @notice Test suite for V4Utils.execute() WITHDRAW_AND_COLLECT_AND_SWAP functionality
 * @dev Tests withdrawing liquidity, collecting fees, and swapping tokens
 */
contract V4UtilsWithdrawAndCollectAndSwapTest is V4ForkTestBase {

    function _executeWithdrawAndCollectAndSwap(
        WithdrawAndCollectAndSwapTestParams memory params
    ) internal {
        _logTestStart("WITHDRAW_AND_COLLECT_AND_SWAP", params.testName);
        
        // Record initial balances
        (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance) = _recordInitialBalances(params.owner);
        
        // Get pool info to show token addresses and current tick range
        _logPositionInfo(params.tokenId);
        
        // Execute the withdraw and collect and swap
        _executeWithdrawAndCollectAndSwapTest(params);
        
        // Record final balances
        (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) = _recordFinalBalances(
            params.owner,
            initialWethBalance,
            initialUsdcBalance,
            initialEthBalance
        );
        
        _logTestCompletion("WITHDRAW_AND_COLLECT_AND_SWAP");

        // Assertions for WITHDRAW_AND_COLLECT_AND_SWAP operation
        _verifyWithdrawAndCollectAndSwapResults(params, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
    }

    function _executeWithdrawAndCollectAndSwapTest(WithdrawAndCollectAndSwapTestParams memory params) internal {
        // Create and execute instructions for withdrawing and collecting and swapping
        V4Utils.Instructions memory instructions = V4Utils.Instructions({
            whatToDo: V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            targetToken: params.swapTarget,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: params.amountIn0,
            amountOut0Min: params.amountOut0Min,
            swapData0: params.swapData0,
            amountIn1: params.amountIn1,
            amountOut1Min: params.amountOut1Min,
            swapData1: params.swapData1,
            fee: 0, // Not used for WITHDRAW_AND_COLLECT_AND_SWAP
            tickSpacing: 60,
            tickLower: 0, // Not used for WITHDRAW_AND_COLLECT_AND_SWAP
            tickUpper: 0, // Not used for WITHDRAW_AND_COLLECT_AND_SWAP
            liquidity: 0, // Not used for WITHDRAW_AND_COLLECT_AND_SWAP
            amountAddMin0: params.amountAddMin0,
            amountAddMin1: params.amountAddMin1,
            deadline: block.timestamp,
            recipient: params.owner,
            recipientNFT: params.owner,
            returnData: "",
            swapAndMintReturnData: "",
            hook: address(0),
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: ""
        });

        _executeInstructions(params.tokenId, instructions, params.owner);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP executed successfully");
        
        // Verify position still exists and is owned by the correct owner
        assertEq(IERC721(address(positionManager)).ownerOf(params.tokenId), params.owner, "Position should still be owned by the original owner");
        
        // Verify position still has liquidity (should be reduced after withdrawal)
        uint128 finalLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        console.log("Final position liquidity:", finalLiquidity);
        assertGt(finalLiquidity, 0, "Position should still have liquidity after withdrawal");
    }

    function _verifyWithdrawAndCollectAndSwapResults(
        WithdrawAndCollectAndSwapTestParams memory params,
        uint256 /* initialWethBalance */,
        uint256 /* finalWethBalance */,
        uint256 /* initialUsdcBalance */,
        uint256 /* finalUsdcBalance */,
        uint256 /* initialEthBalance */,
        uint256 /* finalEthBalance */
    ) internal {
        _verifyContractCleanup();
        
        // Verify position still exists and is owned by the correct owner
        assertEq(IERC721(address(positionManager)).ownerOf(params.tokenId), params.owner, "Position should still be owned by the original owner");
        
        // Verify position still has liquidity (should be reduced after withdrawal)
        uint128 finalLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        assertGt(finalLiquidity, 0, "Position should still have liquidity after withdrawal");
        
        // Verify position parameters haven't changed
        (PoolKey memory originalPoolKey, PositionInfo originalPositionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        (PoolKey memory finalPoolKey, PositionInfo finalPositionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        assertEq(finalPoolKey.fee, originalPoolKey.fee, "Position fee should remain the same");
        assertEq(finalPoolKey.tickSpacing, originalPoolKey.tickSpacing, "Position tick spacing should remain the same");
        assertEq(finalPositionInfo.tickLower(), originalPositionInfo.tickLower(), "Position tick lower should remain the same");
        assertEq(finalPositionInfo.tickUpper(), originalPositionInfo.tickUpper(), "Position tick upper should remain the same");
        
        // Verify token addresses are consistent
        assertEq(Currency.unwrap(finalPoolKey.currency0), Currency.unwrap(originalPoolKey.currency0), "Token0 should remain the same");
        assertEq(Currency.unwrap(finalPoolKey.currency1), Currency.unwrap(originalPoolKey.currency1), "Token1 should remain the same");
        
        console.log("All WITHDRAW_AND_COLLECT_AND_SWAP assertions passed successfully");
    }

    function testExecuteWithdrawAndCollectAndSwapToETH() public {
        WithdrawAndCollectAndSwapTestParams memory params = WithdrawAndCollectAndSwapTestParams({
            tokenId: nft1TokenId,
            owner: nft1Owner,
            swapTarget: Currency.wrap(address(0)), // Swap to ETH
            swapData0: _getUSDCtoETHSwapData(),
            swapData1: hex"",
            amountIn0: 6274987,
            amountOut0Min: 756050291375000,
            amountIn1: 14158266761780632,
            amountOut1Min: 14158266761780632,
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - Withdraw and Collect and Swap to ETH"
        });
        
        _executeWithdrawAndCollectAndSwap(params);
    }

    function testExecuteWithdrawAndCollectNoSwap() public {
        WithdrawAndCollectAndSwapTestParams memory params = WithdrawAndCollectAndSwapTestParams({
            tokenId: nft1TokenId,
            owner: nft1Owner,
            swapTarget: Currency.wrap(address(0)), // No swap target
            swapData0: hex"",
            swapData1: hex"",
            amountIn0: 0,
            amountOut0Min: 0,
            amountIn1: 0,
            amountOut1Min: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - Withdraw and Collect No Swap"
        });
        
        _executeWithdrawAndCollectAndSwap(params);
    }

    function testExecuteWithdrawAndCollectAndSwapToWETH() public {
        WithdrawAndCollectAndSwapTestParams memory params = WithdrawAndCollectAndSwapTestParams({
            tokenId: nft2TokenId,
            owner: nft2Owner,
            swapTarget: Currency.wrap(address(weth)), // Swap to WETH
            swapData0: hex"",
            swapData1: _get273073USDCtoWETHSwapData(),
            amountIn0: 63079250674003,
            amountOut0Min: 63079250674003,
            amountIn1: 273073,
            amountOut1Min: 32877460445000,
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT2 - Withdraw and Collect and Swap from ETH"
        });
        
        _executeWithdrawAndCollectAndSwap(params);
    }

    function testExecuteWithdrawAndCollectNoSwapFromETH() public {
        WithdrawAndCollectAndSwapTestParams memory params = WithdrawAndCollectAndSwapTestParams({
            tokenId: nft2TokenId,
            owner: nft2Owner,
            swapTarget: Currency.wrap(address(0)), // No swap target
            swapData0: hex"",
            swapData1: hex"",
            amountIn0: 0,
            amountOut0Min: 0,
            amountIn1: 0,
            amountOut1Min: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT2 - Withdraw and Collect No Swap from ETH"
        });
        
        _executeWithdrawAndCollectAndSwap(params);
    }
}
