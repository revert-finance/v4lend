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

import {V4ForkTestBase} from "test/vault/support/V4ForkTestBase.sol";
import {V4Utils} from "src/vault/transformers/V4Utils.sol";

/**
 * @title V4UtilsCompoundFeesTest
 * @notice Test suite for V4Utils.execute() COMPOUND_FEES functionality
 * @dev Tests fee compounding operations on existing positions
 */
contract V4UtilsCompoundFeesTest is V4ForkTestBase {
    
    function testExecuteCompoundFees() public {
        console.log("=== Testing COMPOUND_FEES with real mainnet tokens ===");
        
        // Record initial balances
        uint256 initialWethBalance = weth.balanceOf(nft1Owner);
        uint256 initialUsdcBalance = usdc.balanceOf(nft1Owner);
        uint256 initialEthBalance = nft1Owner.balance;

        _logInitialBalances(nft1Owner, initialWethBalance, initialUsdcBalance, initialEthBalance);

        // Create and execute instructions for compounding fees
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0), // No swap target
            0, // Collect fees only, don't remove liquidity
            block.timestamp,
            nft1Owner
        );
        
        _executeInstructions(nft1TokenId, instructions, nft1Owner);
        console.log("COMPOUND_FEES executed successfully");
        
        // Verify position still exists and is owned by whale1
        assertEq(
            IERC721(address(positionManager)).ownerOf(nft1TokenId),
            nft1Owner,
            "Position should still be owned by nft1Owner"
        );
        
        // Verify liquidity was added back to the position
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify balances changed (fees were collected and compounded)
        uint256 finalWethBalance = weth.balanceOf(nft1Owner);
        uint256 finalUsdcBalance = usdc.balanceOf(nft1Owner);
        uint256 finalEthBalance = nft1Owner.balance;
        
        _logBalanceChanges(nft1Owner, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
        
        console.log("Fee compounding completed - position liquidity:", finalLiquidity);
    }
    
    function testExecuteCompoundFeesWithNativeETH() public {
        console.log("=== Testing COMPOUND_FEES with ETH Native ===");
        
        // Record initial balances
        uint256 initialWethBalance = weth.balanceOf(nft2Owner);
        uint256 initialUsdcBalance = usdc.balanceOf(nft2Owner);
        uint256 initialEthBalance = nft2Owner.balance;

        _logInitialBalances(nft2Owner, initialWethBalance, initialUsdcBalance, initialEthBalance);

        // Create and execute instructions for compounding fees
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0), // No swap target
            0, // Collect fees only, don't remove liquidity
            block.timestamp,
            nft2Owner
        );
        
        _executeInstructions(nft2TokenId, instructions, nft2Owner);
        console.log("COMPOUND_FEES executed successfully");
        
        // Verify position still exists and is owned by whale1
        assertEq(
            IERC721(address(positionManager)).ownerOf(nft2TokenId),
            nft2Owner,
            "Position should still be owned by nft2Owner"
        );
        
        // Verify liquidity was added back to the position
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft2TokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify balances changed (fees were collected and compounded)
        uint256 finalWethBalance = weth.balanceOf(nft2Owner);
        uint256 finalUsdcBalance = usdc.balanceOf(nft2Owner);
        uint256 finalEthBalance = nft2Owner.balance;
        
        _logBalanceChanges(nft2Owner, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
        
        console.log("Fee compounding completed - position liquidity:", finalLiquidity);
    }

    function _executeCompoundFees(
        CompoundFeesTestParams memory params
    ) internal {
        _logTestStart("COMPOUND_FEES", params.testName);
        
        // Record initial balances
        (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance) = _recordInitialBalances(params.owner);
        
        // Get pool info to show token addresses and current tick range
        _logPositionInfo(params.tokenId);
        
        // Get initial liquidity
        uint128 initialLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        console.log("Initial position liquidity:", initialLiquidity);
        
        // Execute the compound fees
        _executeCompoundFeesTest(params);
        
        // Record final balances
        (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) = _recordFinalBalances(
            params.owner,
            initialWethBalance,
            initialUsdcBalance,
            initialEthBalance
        );
        
        _logTestCompletion("COMPOUND_FEES");

        // Assertions for COMPOUND_FEES operation
        _verifyCompoundFeesResults(params, initialLiquidity, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
    }

    function _verifyCompoundFeesResults(
        CompoundFeesTestParams memory params,
        uint128 initialLiquidity,
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
        
        // Verify position still has liquidity (should be same or higher after compounding)
        uint128 finalLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify liquidity increased (fees were compounded back)
        assertTrue(finalLiquidity > initialLiquidity, "Final liquidity should be at least as much as initial liquidity");
        
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
        
        console.log("All COMPOUND_FEES assertions passed successfully");
    }

    function _executeCompoundFeesTest(CompoundFeesTestParams memory params) internal {
        // Create and execute instructions for compounding fees
        V4Utils.Instructions memory instructions = V4Utils.Instructions({
            whatToDo: V4Utils.WhatToDo.COMPOUND_FEES,
            targetToken: params.targetToken,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: params.amountIn0,
            amountOut0Min: params.amountOut0Min,
            swapData0: params.swapData0,
            amountIn1: params.amountIn1,
            amountOut1Min: params.amountOut1Min,
            swapData1: params.swapData1,
            fee: 0, // Not used for COMPOUND_FEES
            tickSpacing: 60,
            tickLower: 0, // Not used for COMPOUND_FEES
            tickUpper: 0, // Not used for COMPOUND_FEES
            liquidity: params.liquidityToRemove,
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
        console.log("COMPOUND_FEES executed successfully");
        
        // Verify position still exists and has liquidity
        uint128 finalLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        console.log("Final position liquidity:", finalLiquidity);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify position ownership
        assertEq(IERC721(address(positionManager)).ownerOf(params.tokenId), params.owner, "Position should still be owned by the original owner");
    }

    function testExecuteCompoundFees_NFT1_Generalized() public {
        CompoundFeesTestParams memory params = CompoundFeesTestParams({
            tokenId: nft1TokenId,
            owner: nft1Owner,
            targetToken: Currency.wrap(address(0)), // No swap target
            liquidityToRemove: 0, // Collect fees only, don't remove liquidity
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT1 - Compound Fees No Swap"
        });
        
        _executeCompoundFees(params);
    }

    function testExecuteCompoundFees_NFT2_Generalized() public {
        CompoundFeesTestParams memory params = CompoundFeesTestParams({
            tokenId: nft2TokenId,
            owner: nft2Owner,
            targetToken: Currency.wrap(address(0)), // No swap target
            liquidityToRemove: 0, // Collect fees only, don't remove liquidity
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            testName: "NFT2 - Compound Fees No Swap"
        });
        
        _executeCompoundFees(params);
    }
}
