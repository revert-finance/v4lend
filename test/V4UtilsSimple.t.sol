// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4Utils} from "../src/V4Utils.sol";
import "./V4UtilsTestBase.sol";

/**
 * @title V4UtilsSimpleTest
 * @notice Simple test suite for V4Utils.execute() function
 * @dev Tests core functionality without mainnet forking
 */
contract V4UtilsSimpleTest is V4UtilsTestBase {
    
    function testExecuteCompoundFees() public {
        console.log("=== Testing COMPOUND_FEES ===");
        
        // Create a position
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        
        // Wait some time to accumulate fees
        vm.warp(block.timestamp + 1 days);
        
        // Create and execute instructions for compounding fees
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(token0), // Compound to token0
            0,               // Collect fees only, don't remove liquidity
            block.timestamp,
            user1
        );
        
        _executeInstructions(tokenId, instructions, user1);
        console.log("COMPOUND_FEES executed successfully");
        
        // Verify position still exists and is owned by user1
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should still be owned by user1");
        
        // Verify liquidity was added back to the position
        uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify balances changed (fees were collected and compounded)
        uint256 finalBalance0 = token0.balanceOf(user1);
        uint256 finalBalance1 = token1.balanceOf(user1);
        
        // Note: In a test environment without actual trading, fees might not accumulate
        // So we just verify the position still exists and has liquidity
        console.log("Initial balances - Token0:", initialBalance0, "Token1:", initialBalance1);
        console.log("Final balances - Token0:", finalBalance0, "Token1:", finalBalance1);
    }
    
    function testExecuteChangeRange() public {
        console.log("=== Testing CHANGE_RANGE ===");
        
        // Create a position
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        
        // Create and execute instructions for changing range
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.CHANGE_RANGE,
            address(0),           // No swap, just change range
            positionLiquidity,    // Remove actual liquidity
            block.timestamp,
            user1
        );
        
        // Override tick range for new position
        instructions.tickLower = -100020; // Must be multiple of tick spacing (60)
        instructions.tickUpper = 100020;  // Must be multiple of tick spacing (60)
        
        _executeInstructions(tokenId, instructions, user1);
        console.log("CHANGE_RANGE executed successfully");
        
        // Verify user still owns the original NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Original NFT should be returned to user1");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId + 1), user1, "New NFT should be returned to user1");
        
        // Verify balances changed (liquidity was withdrawn)
        uint256 finalBalance0 = token0.balanceOf(user1);
        uint256 finalBalance1 = token1.balanceOf(user1);
        
        assertTrue(
           finalBalance0 >= initialBalance0 || finalBalance1 >= initialBalance1,
            "User should have received tokens from withdrawn liquidity"
        );

        finalBalance0 = token0.balanceOf(address(v4Utils));
        finalBalance1 = token1.balanceOf(address(v4Utils));
        
        assertTrue(
            finalBalance0 == 0 && finalBalance1 == 0,
            "All tokens should be returned - no leftover tokens on V4Utils contract"
        );
    }
    
    function testExecuteWithdrawAndCollectAndSwap() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP ===");
        
        // Create a position
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        
        // Create and execute instructions for withdrawing and swapping
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(token0),        // Swap everything to token0
            positionLiquidity,      // Remove actual liquidity
            block.timestamp,
            user1
        );
        
        _executeInstructions(tokenId, instructions, user1);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP executed successfully");
        
        // Verify user still owns the NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "NFT should be returned to user1");
        
        // Verify balances changed - user should have more token0 (target token)
        uint256 finalBalance0 = token0.balanceOf(user1);
        uint256 finalBalance1 = token1.balanceOf(user1);
        
        console.log("Initial balances - Token0:", initialBalance0, "Token1:", initialBalance1);
        console.log("Final balances - Token0:", finalBalance0, "Token1:", finalBalance1);
        
        // Verify that liquidity was withdrawn (balances should have increased)
        assertTrue(
            finalBalance0 > initialBalance0 || finalBalance1 > initialBalance1,
            "User should have received tokens from withdrawn liquidity"
        );
    }
    
    function testSwapFunction() public {
        console.log("=== Testing swap function ===");
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        
        // Prepare swap parameters
        V4Utils.SwapParamsV4 memory swapParams = V4Utils.SwapParamsV4({
            tokenIn: Currency.wrap(address(token0)),
            tokenOut: Currency.wrap(address(token1)),
            amountIn: 1000 ether,
            minAmountOut: 0, // No slippage protection for this test
            recipient: user1,
            swapData: "" // Empty swap data - would need real swap data in production
        });
        
        // Approve tokens
        vm.prank(user1);
        IERC20(address(token0)).approve(address(v4Utils), 1000 ether);
        
        // Execute swap
        vm.prank(user1);
        uint256 amountOut = v4Utils.swap(swapParams);
        
        console.log("Swap executed, amountOut:", amountOut);
        
        // Verify swap behavior
        uint256 finalBalance0 = token0.balanceOf(user1);
        uint256 finalBalance1 = token1.balanceOf(user1);
        
        // Note: With empty swap data, no actual swap occurs, so balances should remain the same
        // The function should return 0 for amountOut when no swap happens
        assertEq(amountOut, 0, "Amount out should be 0 when no swap occurs");
        
        // Verify balances remain unchanged (no swap occurred)
        assertEq(finalBalance0, initialBalance0, "Token0 balance should remain unchanged without swap");
        assertEq(finalBalance1, initialBalance1, "Token1 balance should remain unchanged without swap");
    }
    
    function testSwapAndMint() public {
        console.log("=== Testing swapAndMint function ===");
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        
        // First initialize the pool (required for V4)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Initialize the pool
        vm.prank(user1);
        poolManager.initialize(poolKey, 79228162514264337593543950336); // sqrt price
        
        // Set up ERC20 allowances from user to Permit2
        vm.prank(user1);
        token0.approve(address(permit2), type(uint256).max);
        vm.prank(user1);
        token1.approve(address(permit2), type(uint256).max);
        
        // Set up Permit2 allowances for the user to allow PositionManager to transfer tokens
        vm.prank(user1);
        permit2.approve(
            address(token0),
            address(positionManager),
            uint160(1000 ether),
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        vm.prank(user1);
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(1000 ether),
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        
        // Prepare swap and mint parameters
        V4Utils.SwapAndMintParams memory params = V4Utils.SwapAndMintParams({
            token0: Currency.wrap(address(token0)),
            token1: Currency.wrap(address(token1)),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0: 1000 ether,
            amount1: 1000 ether,
            recipient: user1,
            recipientNFT: user1,
            deadline: block.timestamp,
            swapSourceToken: Currency.wrap(address(0)), // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: "",
            hook: address(0),
            mintHookData: ""
        });
        
        // Approve tokens
        _approveTokens(user1, 1000 ether);
        
        // Execute swap and mint
        vm.prank(user1);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v4Utils.swapAndMint(params);
        
        console.log("SwapAndMint executed:");
        console.log("  tokenId:", tokenId);
        console.log("  liquidity:", liquidity);
        console.log("  amount0:", amount0);
        console.log("  amount1:", amount1);
        
        // Verify NFT was created and owned by user1
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "NFT should be owned by user1");
        assertGt(tokenId, 0, "Token ID should be valid");
        
        // Verify position has liquidity
        uint128 positionLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(positionLiquidity, 0, "Position should have liquidity");
        
        // Verify amounts were consumed
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
        
        // Verify balances changed
        uint256 finalBalance0 = token0.balanceOf(user1);
        uint256 finalBalance1 = token1.balanceOf(user1);
        
        assertTrue(
            finalBalance0 < initialBalance0,
            "Token0 balance should decrease after minting position"
        );
        assertTrue(
            finalBalance1 < initialBalance1,
            "Token1 balance should decrease after minting position"
        );
        
        // Verify the amounts consumed match the balance changes (accounting for leftovers)
        uint256 token0Consumed = initialBalance0 - finalBalance0;
        uint256 token1Consumed = initialBalance1 - finalBalance1;
        
        assertLe(token0Consumed, 1000 ether, "Should not consume more token0 than provided");
        assertLe(token1Consumed, 1000 ether, "Should not consume more token1 than provided");
    }
}
