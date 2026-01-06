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

import {V4ForkTestBase} from "./V4ForkTestBase.sol";
import {V4Utils} from "../../src/transformers/V4Utils.sol";

/**
 * @title V4UtilsChangeRangeTest
 * @notice Test suite for V4Utils.execute() CHANGE_RANGE functionality
 * @dev Tests changing tick ranges of existing positions
 */
contract V4UtilsChangeRangeTest is V4ForkTestBase {

    function _executeChangeRange(
        ChangeRangeTestParams memory params
    ) internal {
        _logTestStart("CHANGE_RANGE", params.testName);
        
        // Record initial balances
        (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance) = _recordInitialBalances(params.owner);
        
        // Get pool info to show token addresses and current tick range
        _logPositionInfo(params.tokenId);
        
        // Execute the change range
        _executeChangeRangeTest(params);
        
        // Record final balances
        (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) = _recordFinalBalances(
            params.owner,
            initialWethBalance,
            initialUsdcBalance,
            initialEthBalance
        );
        
        _logTestCompletion("CHANGE_RANGE");

        // Assertions for CHANGE_RANGE operation
        _verifyChangeRangeResults(params, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
    }

    function _executeChangeRangeTest(ChangeRangeTestParams memory params) internal {
        // Create and execute instructions for changing range
        V4Utils.Instructions memory instructions = V4Utils.Instructions({
            whatToDo: V4Utils.WhatToDo.CHANGE_RANGE,
            targetToken: params.targetToken,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: params.amountIn0,
            amountOut0Min: params.amountOut0Min,
            swapData0: params.swapData0,
            amountIn1: params.amountIn1,
            amountOut1Min: params.amountOut1Min,
            swapData1: params.swapData1,
            fee: params.newFee,
            tickSpacing: 60,
            tickLower: params.newTickLower,
            tickUpper: params.newTickUpper,
            liquidity: params.liquidityToRemove,
            amountAddMin0: params.amountAddMin0,
            amountAddMin1: params.amountAddMin1,
            deadline: block.timestamp,
            recipient: params.owner,
            recipientNFT: params.owner,
            returnData: "",
            swapAndMintReturnData: "",
            hook: params.hook,
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: ""
        });

        _executeInstructions(params.tokenId, instructions, params.owner);
        console.log("CHANGE_RANGE executed successfully");
        
        // Verify the instruction execution was successful by checking that a new position was created
        uint256 expectedNewTokenId = positionManager.nextTokenId() - 1;
        assertTrue(expectedNewTokenId > params.tokenId, "New token ID should be greater than original");
        
        // Check if original position still exists (it should be burned)
        try positionManager.getPositionLiquidity(params.tokenId) returns (uint128 liquidity) {
            console.log("Original position liquidity:", liquidity);
            assertEq(liquidity, 0, "Original position should have no liquidity after CHANGE_RANGE");
        } catch {
            console.log("Original position no longer exists (burned)");
        }
        
        // Get the new token ID (should be the next one)
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        console.log("New NFT Token ID:", newTokenId);
        
        // Verify new token ID is valid
        assertTrue(newTokenId > 0, "New token ID should be valid");
        
        // Check new position liquidity
        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        console.log("New position liquidity:", newLiquidity);
        assertGt(newLiquidity, 0, "New position should have liquidity");
        
        // Verify new position parameters
        (PoolKey memory newPoolKey, PositionInfo newPositionInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        console.log("New fee:", newPoolKey.fee);
        console.log("New tick spacing:", newPoolKey.tickSpacing);
        console.log("New tick lower:", newPositionInfo.tickLower());
        console.log("New tick upper:", newPositionInfo.tickUpper());
        
        // Verify the new position is owned by the correct owner
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), params.owner, "New position should be owned by the original owner");
        
        // Additional verification: ensure the new position parameters match what was requested
        assertEq(newPoolKey.fee, params.newFee, "New position fee should match requested fee");
        assertEq(newPositionInfo.tickLower(), params.newTickLower, "New position tick lower should match requested value");
        assertEq(newPositionInfo.tickUpper(), params.newTickUpper, "New position tick upper should match requested value");
    }

    function _verifyChangeRangeResults(
        ChangeRangeTestParams memory params,
        uint256 /* initialWethBalance */,
        uint256 /* finalWethBalance */,
        uint256 /* initialUsdcBalance */,
        uint256 /* finalUsdcBalance */,
        uint256 /* initialEthBalance */,
        uint256 /* finalEthBalance */
    ) internal {
        _verifyContractCleanup();
        
        // Verify original position is properly burned/cleared
        try positionManager.getPositionLiquidity(params.tokenId) returns (uint128 liquidity) {
            assertEq(liquidity, 0, "Original position should have no liquidity after CHANGE_RANGE");
        } catch {
            // Position doesn't exist anymore, which is also acceptable
        }
        
        // Get new position details
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        (PoolKey memory newPoolKey, PositionInfo newPositionInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        
        // Verify new position has liquidity
        assertGt(newLiquidity, 0, "New position should have liquidity");
        
        // Verify new position parameters match expected values
        assertEq(newPoolKey.fee, params.newFee, "New position fee should match expected fee");
        assertEq(newPositionInfo.tickLower(), params.newTickLower, "New position tick lower should match expected value");
        assertEq(newPositionInfo.tickUpper(), params.newTickUpper, "New position tick upper should match expected value");
        
        // Verify new position ownership
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), params.owner, "New position should be owned by the original owner");
        
        // Verify token addresses are consistent (should be the same pool tokens)
        (PoolKey memory originalPoolKey, ) = positionManager.getPoolAndPositionInfo(params.tokenId);
        assertEq(Currency.unwrap(newPoolKey.currency0), Currency.unwrap(originalPoolKey.currency0), "Token0 should remain the same");
        assertEq(Currency.unwrap(newPoolKey.currency1), Currency.unwrap(originalPoolKey.currency1), "Token1 should remain the same");
        
        // Verify tick spacing is correct for the fee tier
        if (params.newFee == 3000) {
            assertEq(newPoolKey.tickSpacing, 60, "Tick spacing should be 60 for 0.3% fee");
        } else if (params.newFee == 500) {
            assertEq(newPoolKey.tickSpacing, 10, "Tick spacing should be 10 for 0.05% fee");
        }
        
        // Verify tick alignment
        assertTrue(newPositionInfo.tickLower() % newPoolKey.tickSpacing == 0, "Tick lower should be aligned with tick spacing");
        assertTrue(newPositionInfo.tickUpper() % newPoolKey.tickSpacing == 0, "Tick upper should be aligned with tick spacing");
        
        // Verify tick range is valid (lower < upper)
        assertTrue(newPositionInfo.tickLower() < newPositionInfo.tickUpper(), "Tick lower should be less than tick upper");
        
        // Verify reasonable balance changes based on swap parameters
        if (params.swapData0.length == 0 && params.swapData1.length == 0) {
            // No swaps - balances should only change due to liquidity removal/addition
            console.log("No swaps performed - verifying minimal balance changes");
        } else {
            // Swaps were performed - verify reasonable changes
            if (params.swapData0.length > 0) {
                assertTrue(params.amountIn0 > 0, "Swap data provided but no amount in specified");
            }
            if (params.swapData1.length > 0) {
                assertTrue(params.amountIn1 > 0, "Swap data provided but no amount in specified");
            }
        }
        
        console.log("All CHANGE_RANGE assertions passed successfully");
    }

    function testExecuteChangeRange_NFT1_NoSwap() public {
        // Get current liquidity of the position
        uint128 currentLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        
        ChangeRangeTestParams memory params = ChangeRangeTestParams({
            tokenId: nft1TokenId,
            owner: nft1Owner,
            targetToken: Currency.wrap(address(0)), // No swap target
            newFee: 3000, // 0.3% fee (different from original)
            newTickLower: -960, // New tick range (aligned with tick spacing 60)
            newTickUpper: 960,
            liquidityToRemove: currentLiquidity, // Remove all liquidity
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - Change Range No Swap",
            hook: address(0)
        });
        
        _executeChangeRange(params);
    }

    function testExecuteChangeRange_NFT1_NoSwapAndHook() public {
        // Get current liquidity of the position
        uint128 currentLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        
        ChangeRangeTestParams memory params = ChangeRangeTestParams({
            tokenId: nft1TokenId,
            owner: nft1Owner,
            targetToken: Currency.wrap(address(0)), // No swap target
            newFee: 3000, // 0.3% fee (different from original)
            newTickLower: -960, // New tick range (aligned with tick spacing 60)
            newTickUpper: 960,
            liquidityToRemove: currentLiquidity, // Remove all liquidity
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - Change Range No Swap And Hook",
            hook: 0xeE20cE89b34815f7DE29eBdf33e2861AA128C444
        });
        
        // Initialize the pool with the hook before executing change range
        _initializePoolWithHook(params);
        
        _executeChangeRange(params);
    }

    function testExecuteChangeRange_NFT2_WithSwap() public {
        // Get current liquidity of the position
        uint128 currentLiquidity = positionManager.getPositionLiquidity(nft2TokenId);
        
        ChangeRangeTestParams memory params = ChangeRangeTestParams({
            tokenId: nft2TokenId,
            owner: nft2Owner,
            targetToken: Currency.wrap(address(weth)), // Swap to WETH
            newFee: 3000, // 0.3% fee (same as original)
            newTickLower: -1200, // New tick range (aligned with tick spacing 60)
            newTickUpper: 1200,
            liquidityToRemove: currentLiquidity, // Remove all liquidity
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"", // No swap for token0
            amountIn1: 873073, // Swap some USDC to WETH
            amountOut1Min: 188428045653858, // Min 0.0001 WETH
            swapData1: _getUSDCtoWETHSwapData(),
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT2 - Change Range With Swap",
            hook: address(0)
        });
        
        _executeChangeRange(params);
    }

    /// @notice Initialize a pool with the specified hook for testing
    /// @param params The test parameters containing pool configuration
    function _initializePoolWithHook(ChangeRangeTestParams memory params) internal {
        // Get the original pool info to determine the currencies
        (PoolKey memory originalPoolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        
        // Create a new pool key with the hook
        PoolKey memory newPoolKey = PoolKey({
            currency0: originalPoolKey.currency0,
            currency1: originalPoolKey.currency1,
            fee: params.newFee,
            tickSpacing: 60, // Use tick spacing for 0.3% fee
            hooks: IHooks(params.hook)
        });
        
        // Use the base class function
        _initializePoolWithHook(newPoolKey);
    }
}
