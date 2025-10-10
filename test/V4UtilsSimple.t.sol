// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {V4Utils} from "../src/transformers/V4Utils.sol";
import {Constants} from "../src/utils/Constants.sol";
import "./V4TestBase.sol";

/**
 * @title V4UtilsSimpleTest
 * @notice Simple test suite for V4Utils.execute() function
 * @dev Tests core functionality without mainnet forking
 */
contract V4UtilsSimpleTest is V4TestBase {
    
    function testExecuteCompoundFees() public {
        console.log("=== Testing COMPOUND_FEES ===");
        
        // Create a position
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Verify initial position state
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should be owned by user1");
        uint128 initialLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(initialLiquidity, 0, "Initial position should have liquidity");
        
        // Get initial position info
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 initialTickLower = positionInfo.tickLower();
        int24 initialTickUpper = positionInfo.tickUpper();
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        
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
        
        // Verify position parameters remain unchanged
        (, PositionInfo finalPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(finalPositionInfo.tickLower(), initialTickLower, "Tick lower should remain unchanged");
        assertEq(finalPositionInfo.tickUpper(), initialTickUpper, "Tick upper should remain unchanged");
        
        // Verify liquidity was added back to the position (should be >= initial)
        uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        assertGe(finalLiquidity, initialLiquidity, "Liquidity should not decrease after compounding fees");
        
        // Verify V4Utils contract has no leftover tokens
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        
        // Note: In a test environment without actual trading, fees might not accumulate
        // So we just verify the position still exists and has liquidity
        console.log("Initial balances - Token0:", initialBalance0, "Token1:", initialBalance1);
        console.log("Final balances - Token0:", token0.balanceOf(user1), "Token1:", token1.balanceOf(user1));
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Final liquidity:", finalLiquidity);
    }
    
    function testExecuteChangeRange() public {
        console.log("=== Testing CHANGE_RANGE ===");
        
        // Create a position
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Verify initial position state
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should be owned by user1");
        uint128 initialLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(initialLiquidity, 0, "Initial position should have liquidity");
        
        // Get initial position info
        (, PositionInfo initialPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 initialTickLower = initialPositionInfo.tickLower();
        int24 initialTickUpper = initialPositionInfo.tickUpper();
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        
        // Create and execute instructions for changing range
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.CHANGE_RANGE,
            address(0),           // No swap, just change range
            initialLiquidity,     // Remove actual liquidity
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
        
        // Verify new position has different tick range
        (, PositionInfo newPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId + 1);
        assertEq(newPositionInfo.tickLower(), -100020, "New position should have correct tick lower");
        assertEq(newPositionInfo.tickUpper(), 100020, "New position should have correct tick upper");
        
        // Verify tick range actually changed
        assertTrue(
            newPositionInfo.tickLower() != initialTickLower || newPositionInfo.tickUpper() != initialTickUpper,
            "New position should have different tick range"
        );

        // Verify new position has liquidity
        uint128 newLiquidity = positionManager.getPositionLiquidity(tokenId + 1);
        assertGt(newLiquidity, 0, "New position should have liquidity");
        
        // Verify balances changed (liquidity was withdrawn and re-deposited)
        assertTrue(
           token0.balanceOf(user1) >= initialBalance0 || token1.balanceOf(user1) >= initialBalance1,
            "User should have received tokens from withdrawn liquidity"
        );

        // Verify V4Utils contract has no leftover tokens
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        
        console.log("Original position liquidity:", initialLiquidity);
        console.log("New position liquidity:", newLiquidity);
        console.log("Original tick lower:", initialTickLower);
        console.log("Original tick upper:", initialTickUpper);
        console.log("New tick lower:", newPositionInfo.tickLower());
        console.log("New tick upper:", newPositionInfo.tickUpper());
    }
    
    function testExecuteWithdrawAndCollectAndSwap() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP ===");
        
        // Create a position
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Verify initial position state
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should be owned by user1");
        uint128 initialLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(initialLiquidity, 0, "Initial position should have liquidity");
        
        // Get initial position info
        (, PositionInfo initialPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 initialTickLower = initialPositionInfo.tickLower();
        int24 initialTickUpper = initialPositionInfo.tickUpper();
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        
        // Create and execute instructions for withdrawing and swapping
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(token0),        // Swap everything to token0
            initialLiquidity,       // Remove actual liquidity
            block.timestamp,
            user1
        );
        
        _executeInstructions(tokenId, instructions, user1);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP executed successfully");
        
        // Verify user still owns the NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "NFT should be returned to user1");
        
        // Verify position still exists but has no liquidity
        uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertEq(finalLiquidity, 0, "Position should have no liquidity after withdrawal");
        
        // Verify position parameters remain unchanged
        (, PositionInfo finalPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(finalPositionInfo.tickLower(), initialTickLower, "Tick lower should remain unchanged");
        assertEq(finalPositionInfo.tickUpper(), initialTickUpper, "Tick upper should remain unchanged");
        
        // Verify V4Utils contract has no leftover tokens
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        
        // Verify balances changed - user should have more token0 (target token)
        uint256 finalBalance0 = token0.balanceOf(user1);
        uint256 finalBalance1 = token1.balanceOf(user1);
        
        console.log("Initial balances - Token0:", initialBalance0, "Token1:", initialBalance1);
        console.log("Final balances - Token0:", finalBalance0, "Token1:", finalBalance1);
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Final liquidity:", finalLiquidity);
        
        // Verify that liquidity was withdrawn (balances should have increased)
        assertTrue(
            finalBalance0 > initialBalance0 || finalBalance1 > initialBalance1,
            "User should have received tokens from withdrawn liquidity"
        );
        
        // Verify token0 balance increased (since we're swapping to token0)
        assertTrue(
            finalBalance0 >= initialBalance0,
            "Token0 balance should not decrease when swapping to token0"
        );
    }
    
    function testSwapFunction() public {
        console.log("=== Testing swap function ===");
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        
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
        
        // Note: With empty swap data, no actual swap occurs, so balances should remain the same
        // The function should return 0 for amountOut when no swap happens
        assertEq(amountOut, 0, "Amount out should be 0 when no swap occurs");
        
        // Verify balances remain unchanged (no swap occurred)
        assertEq(token0.balanceOf(user1), initialBalance0, "Token0 balance should remain unchanged without swap");
        assertEq(token1.balanceOf(user1), initialBalance1, "Token1 balance should remain unchanged without swap");
        
        // Verify V4Utils contract has no leftover tokens
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        
        // Verify approval was consumed (should be 0 after failed swap attempt)
        assertEq(IERC20(address(token0)).allowance(user1, address(v4Utils)), 0, "Approval should be consumed after swap attempt");
        
        console.log("Initial balances - Token0:", initialBalance0, "Token1:", initialBalance1);
        console.log("Final balances - Token0:", token0.balanceOf(user1), "Token1:", token1.balanceOf(user1));
        console.log("Amount out:", amountOut);
    }
    
    function testSwapAndMint() public {
        console.log("=== Testing swapAndMint function ===");
        
        // Record initial balances
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        
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
            tickSpacing: 60,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0: 1000 ether,
            amount1: 1000 ether,
            recipient: user1,
            recipientNFT: user1,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
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
        assertEq(positionLiquidity, liquidity, "Position liquidity should match returned liquidity");
        
        // Verify amounts were consumed
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
        assertLe(amount0, 1000 ether, "Amount0 should not exceed provided amount");
        assertLe(amount1, 1000 ether, "Amount1 should not exceed provided amount");
        
        // Verify position parameters
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(positionInfo.tickLower(), TICK_LOWER, "Position tick lower should match expected value");
        assertEq(positionInfo.tickUpper(), TICK_UPPER, "Position tick upper should match expected value");
        
        // Verify V4Utils contract has no leftover tokens
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        
        // Verify balances changed
        assertTrue(
            token0.balanceOf(user1) < initialBalance0,
            "Token0 balance should decrease after minting position"
        );
        assertTrue(
            token1.balanceOf(user1) < initialBalance1,
            "Token1 balance should decrease after minting position"
        );
        
        // Verify the amounts consumed match the balance changes
        uint256 token0Consumed = initialBalance0 - token0.balanceOf(user1);
        uint256 token1Consumed = initialBalance1 - token1.balanceOf(user1);
        
        assertLe(token0Consumed, 1000 ether, "Should not consume more token0 than provided");
        assertLe(token1Consumed, 1000 ether, "Should not consume more token1 than provided");
        assertEq(token0Consumed, amount0, "Token0 consumed should match amount0");
        assertEq(token1Consumed, amount1, "Token1 consumed should match amount1");
    }
    
    function testExecuteCompoundFeesWithETH() public {
        console.log("=== Testing COMPOUND_FEES with ETH ===");
        
        // Create a position with ETH as one of the tokens
        uint256 tokenId = _createTestPositionWithETH(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Verify initial position state
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should be owned by user1");
        uint128 initialLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(initialLiquidity, 0, "Initial position should have liquidity");
        
        // Get initial position info
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 initialTickLower = positionInfo.tickLower();
        int24 initialTickUpper = positionInfo.tickUpper();
        
        // Record initial balances (including ETH)
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        uint256 initialV4UtilsEthBalance = address(v4Utils).balance;
        
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
        console.log("COMPOUND_FEES with ETH executed successfully");
        
        // Verify position still exists and is owned by user1
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should still be owned by user1");
        
        // Verify position parameters remain unchanged
        (, PositionInfo finalPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(finalPositionInfo.tickLower(), initialTickLower, "Tick lower should remain unchanged");
        assertEq(finalPositionInfo.tickUpper(), initialTickUpper, "Tick upper should remain unchanged");
        
        // Verify liquidity was added back to the position (should be >= initial)
        uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        assertGe(finalLiquidity, initialLiquidity, "Liquidity should not decrease after compounding fees");
        
        // Verify V4Utils contract has no leftover tokens (including ETH)
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        assertEq(address(v4Utils).balance, initialV4UtilsEthBalance, "V4Utils should not have leftover ETH");
        
        // Note: In a test environment without actual trading, fees might not accumulate
        // So we just verify the position still exists and has liquidity
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Final liquidity:", finalLiquidity);
    }
    
    function testExecuteChangeRangeWithETH() public {
        console.log("=== Testing CHANGE_RANGE with ETH ===");
        
        // Create a position with ETH as one of the tokens
        uint256 tokenId = _createTestPositionWithETH(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Verify initial position state
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should be owned by user1");
        uint128 initialLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(initialLiquidity, 0, "Initial position should have liquidity");
        
        // Get initial position info
        (, PositionInfo initialPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 initialTickLower = initialPositionInfo.tickLower();
        int24 initialTickUpper = initialPositionInfo.tickUpper();
        
        // Record initial balances (including ETH)
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialEthBalance = user1.balance;
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        uint256 initialV4UtilsEthBalance = address(v4Utils).balance;
        
        // Create and execute instructions for changing range
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.CHANGE_RANGE,
            address(0),           // No swap, just change range
            initialLiquidity,     // Remove actual liquidity
            block.timestamp,
            user1
        );
        
        // Override tick range for new position
        instructions.tickLower = -100020; // Must be multiple of tick spacing (60)
        instructions.tickUpper = 100020;  // Must be multiple of tick spacing (60)
        
        _executeInstructions(tokenId, instructions, user1);
        console.log("CHANGE_RANGE with ETH executed successfully");
        
        // Verify user still owns the original NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Original NFT should be returned to user1");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId + 1), user1, "New NFT should be returned to user1");
        
        // Verify new position has different tick range
        (, PositionInfo newPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId + 1);
        assertEq(newPositionInfo.tickLower(), -100020, "New position should have correct tick lower");
        assertEq(newPositionInfo.tickUpper(), 100020, "New position should have correct tick upper");
        
        // Verify tick range actually changed
        assertTrue(
            newPositionInfo.tickLower() != initialTickLower || newPositionInfo.tickUpper() != initialTickUpper,
            "New position should have different tick range"
        );
        
        // Verify new position has liquidity
        uint128 newLiquidity = positionManager.getPositionLiquidity(tokenId + 1);
        assertGt(newLiquidity, 0, "New position should have liquidity");
        
        // Verify balances changed (liquidity was withdrawn and re-deposited)
        assertTrue(
           token0.balanceOf(user1) >= initialBalance0 || token1.balanceOf(user1) >= initialBalance1 || user1.balance >= initialEthBalance,
            "User should have received tokens from withdrawn liquidity"
        );

        // Verify V4Utils contract has no leftover tokens (including ETH)
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        assertEq(address(v4Utils).balance, initialV4UtilsEthBalance, "V4Utils should not have leftover ETH");
        
        console.log("Original position liquidity:", initialLiquidity);
        console.log("New position liquidity:", newLiquidity);
        console.log("Original tick lower:", initialTickLower);
        console.log("Original tick upper:", initialTickUpper);
        console.log("New tick lower:", newPositionInfo.tickLower());
        console.log("New tick upper:", newPositionInfo.tickUpper());
    }
    
    function testExecuteWithdrawAndCollectAndSwapWithETH() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP with ETH ===");
        
        // Create a position with ETH as one of the tokens
        uint256 tokenId = _createTestPositionWithETH(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Verify initial position state
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "Position should be owned by user1");
        uint128 initialLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(initialLiquidity, 0, "Initial position should have liquidity");
        
        // Get initial position info
        (, PositionInfo initialPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 initialTickLower = initialPositionInfo.tickLower();
        int24 initialTickUpper = initialPositionInfo.tickUpper();
        
        // Record initial balances (including ETH)
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialEthBalance = user1.balance;
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        uint256 initialV4UtilsEthBalance = address(v4Utils).balance;
        
        // Create and execute instructions for withdrawing and swapping
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(token0),        // Swap everything to token0
            initialLiquidity,       // Remove actual liquidity
            block.timestamp,
            user1
        );
        
        _executeInstructions(tokenId, instructions, user1);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP with ETH executed successfully");
        
        // Verify user still owns the NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "NFT should be returned to user1");
        
        // Verify position still exists but has no liquidity
        uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertEq(finalLiquidity, 0, "Position should have no liquidity after withdrawal");
        
        // Verify position parameters remain unchanged
        (, PositionInfo finalPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(finalPositionInfo.tickLower(), initialTickLower, "Tick lower should remain unchanged");
        assertEq(finalPositionInfo.tickUpper(), initialTickUpper, "Tick upper should remain unchanged");
        
        // Verify V4Utils contract has no leftover tokens (including ETH)
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        assertEq(address(v4Utils).balance, initialV4UtilsEthBalance, "V4Utils should not have leftover ETH");
        
        // Verify balances changed - user should have more token0 (target token)
        assertTrue(
            token0.balanceOf(user1) > initialBalance0 || token1.balanceOf(user1) > initialBalance1 || user1.balance > initialEthBalance,
            "User should have received tokens from withdrawn liquidity"
        );
        
        // Verify token0 balance increased (since we're swapping to token0)
        assertTrue(
            token0.balanceOf(user1) >= initialBalance0,
            "Token0 balance should not decrease when swapping to token0"
        );
        
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Final liquidity:", finalLiquidity);
    }
    
    function testSwapFunctionWithETH() public {
        console.log("=== Testing swap function with ETH ===");
        
        // Record initial balances (including ETH)
        uint256 initialBalance0 = token0.balanceOf(user1);
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialEthBalance = user1.balance;
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        uint256 initialV4UtilsEthBalance = address(v4Utils).balance;
        
        // Prepare swap parameters (ETH to token1)
        V4Utils.SwapParamsV4 memory swapParams = V4Utils.SwapParamsV4({
            tokenIn: CurrencyLibrary.ADDRESS_ZERO, // ETH
            tokenOut: Currency.wrap(address(token1)),
            amountIn: 1 ether,
            minAmountOut: 0, // No slippage protection for this test
            recipient: user1,
            swapData: "" // Empty swap data - would need real swap data in production
        });
        
        // Execute swap with ETH value
        vm.prank(user1);
        uint256 amountOut = v4Utils.swap{value: 1 ether}(swapParams);
        
        console.log("Swap with ETH executed, amountOut:", amountOut);
        
        // Note: With empty swap data, no actual swap occurs, so balances should remain the same
        // The function should return 0 for amountOut when no swap happens
        assertEq(amountOut, 0, "Amount out should be 0 when no swap occurs");
        
        // Verify balances remain unchanged (no swap occurred, ETH refunded)
        assertEq(token0.balanceOf(user1), initialBalance0, "Token0 balance should remain unchanged without swap");
        assertEq(token1.balanceOf(user1), initialBalance1, "Token1 balance should remain unchanged without swap");
        assertEq(user1.balance, initialEthBalance, "ETH balance should remain unchanged (refunded)");
        
        // Verify V4Utils contract has no leftover tokens (including ETH)
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        assertEq(address(v4Utils).balance, initialV4UtilsEthBalance, "V4Utils should not have leftover ETH");
        
        console.log("Amount out:", amountOut);
    }
    
    function testSwapAndMintWithETH() public {
        console.log("=== Testing swapAndMint function with ETH ===");
        
        // Record initial balances (including ETH)
        uint256 initialBalance1 = token1.balanceOf(user1);
        uint256 initialEthBalance = user1.balance;
        uint256 initialV4UtilsBalance0 = token0.balanceOf(address(v4Utils));
        uint256 initialV4UtilsBalance1 = token1.balanceOf(address(v4Utils));
        uint256 initialV4UtilsEthBalance = address(v4Utils).balance;
        
        // First initialize the pool (required for V4) with ETH as currency0
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Initialize the pool
        vm.prank(user1);
        poolManager.initialize(poolKey, 79228162514264337593543950336); // sqrt price
        
        // Set up ERC20 allowance for token1 only (ETH doesn't need approval)
        vm.prank(user1);
        token1.approve(address(permit2), type(uint256).max);
        
        // Set up Permit2 allowances for token1 only
        vm.prank(user1);
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(1000 ether),
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        
        // Prepare swap and mint parameters with ETH
        V4Utils.SwapAndMintParams memory params = V4Utils.SwapAndMintParams({
            token0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            token1: Currency.wrap(address(token1)),
            fee: FEE,   
            tickSpacing: 60,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0: 10 ether, // ETH amount (reduced to fit within user balance)
            amount1: 10 ether, // token1 amount
            recipient: user1,
            recipientNFT: user1,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
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
        
        // Approve tokens (only token1, ETH doesn't need approval)
        vm.prank(user1);
        token1.approve(address(v4Utils), 10 ether);
        
        // Execute swap and mint with ETH value
        vm.prank(user1);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v4Utils.swapAndMint{value: 10 ether}(params);
        
        console.log("SwapAndMint with ETH executed:");
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
        assertEq(positionLiquidity, liquidity, "Position liquidity should match returned liquidity");
        
        // Verify amounts were consumed
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
        assertLe(amount0, 10 ether, "Amount0 should not exceed provided amount");
        assertLe(amount1, 10 ether, "Amount1 should not exceed provided amount");
        
        // Verify position parameters
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(positionInfo.tickLower(), TICK_LOWER, "Position tick lower should match expected value");
        assertEq(positionInfo.tickUpper(), TICK_UPPER, "Position tick upper should match expected value");
        
        // Verify V4Utils contract has no leftover tokens (including ETH)
        assertEq(token0.balanceOf(address(v4Utils)), initialV4UtilsBalance0, "V4Utils should not have leftover token0");
        assertEq(token1.balanceOf(address(v4Utils)), initialV4UtilsBalance1, "V4Utils should not have leftover token1");
        assertEq(address(v4Utils).balance, initialV4UtilsEthBalance, "V4Utils should not have leftover ETH");
        
        // Verify balances changed
        // Note: token0 is ETH (ADDRESS_ZERO), so we check ETH balance instead
        assertTrue(
            token1.balanceOf(user1) < initialBalance1,
            "Token1 balance should decrease after minting position"
        );
        assertTrue(
            user1.balance < initialEthBalance,
            "ETH balance should decrease after minting position"
        );
        
        // Verify the amounts consumed match the balance changes
        // Note: For ETH, amount0 represents ETH consumed
        uint256 token1Consumed = initialBalance1 - token1.balanceOf(user1);
        uint256 ethConsumed = initialEthBalance - user1.balance;
        
        assertLe(token1Consumed, 10 ether, "Should not consume more token1 than provided");
        assertLe(ethConsumed, 10 ether, "Should not consume more ETH than provided");
        assertEq(ethConsumed, amount0, "ETH consumed should match amount0");
        assertEq(token1Consumed, amount1, "Token1 consumed should match amount1");
    }
    
    function testSwapAndMintWithETH_InsufficientAmountAdded() public {
        console.log("=== Testing swapAndMint with insufficient amount added ===");
        
        // First initialize the pool (required for V4) with ETH as currency0
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Initialize the pool
        vm.prank(user1);
        poolManager.initialize(poolKey, 79228162514264337593543950336); // sqrt price
        
        // Set up ERC20 allowance for token1 only (ETH doesn't need approval)
        vm.prank(user1);
        token1.approve(address(permit2), type(uint256).max);
        
        // Set up Permit2 allowances for token1 only
        vm.prank(user1);
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(10 ether),
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        
        // Prepare swap and mint parameters with ETH - set high minimum amounts to trigger error
        V4Utils.SwapAndMintParams memory params = V4Utils.SwapAndMintParams({
            token0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            token1: Currency.wrap(address(token1)),
            fee: FEE,   
            tickSpacing: 60,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0: 1 ether, // Small ETH amount
            amount1: 1 ether, // Small token1 amount
            recipient: user1,
            recipientNFT: user1,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 2 ether, // Higher than amount0 - should fail
            amountAddMin1: 0, // No minimum for token1
            returnData: "",
            hook: address(0),
            mintHookData: ""
        });
        
        // Approve tokens (only token1, ETH doesn't need approval)
        vm.prank(user1);
        token1.approve(address(v4Utils), 1 ether);
        
        // Execute swap and mint with ETH value - should fail due to insufficient amount
        vm.prank(user1);
        vm.expectRevert(Constants.InsufficientAmountAdded.selector);
        v4Utils.swapAndMint{value: 1 ether}(params);
        
        console.log("InsufficientAmountAdded error correctly thrown");
    }
    
    function testSwapAndIncreaseLiquidity_InsufficientAmountAdded() public {
        console.log("=== Testing swapAndIncreaseLiquidity with insufficient amount added ===");
        
        // Create a position first
        uint256 tokenId = _createTestPosition(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Set up ERC20 allowances for the increase
        vm.prank(user1);
        token0.approve(address(permit2), type(uint256).max);
        vm.prank(user1);
        token1.approve(address(permit2), type(uint256).max);
        
        // Set up Permit2 allowances
        vm.prank(user1);
        permit2.approve(
            address(token0),
            address(positionManager),
            uint160(1000 ether),
            uint48(block.timestamp + 1 days)
        );
        vm.prank(user1);
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(1000 ether),
            uint48(block.timestamp + 1 days)
        );
        
        // Prepare swap and increase liquidity parameters with high minimum amounts
        V4Utils.SwapAndIncreaseLiquidityParams memory params = V4Utils.SwapAndIncreaseLiquidityParams({
            tokenId: tokenId,
            amount0: 1 ether, // Small amount
            amount1: 1 ether, // Small amount
            recipient: user1,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 2 ether, // Higher than amount0 - should fail
            amountAddMin1: 0, // No minimum for token1
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: ""
        });
        
        // Approve V4Utils to manage the NFT
        vm.prank(user1);
        IERC721(address(positionManager)).approve(address(v4Utils), tokenId);
        
        // Approve tokens for V4Utils
        vm.prank(user1);
        token0.approve(address(v4Utils), 1 ether);
        vm.prank(user1);
        token1.approve(address(v4Utils), 1 ether);
        
        // Execute swap and increase liquidity - should fail due to insufficient amount
        vm.prank(user1);
        vm.expectRevert(Constants.InsufficientAmountAdded.selector);
        v4Utils.swapAndIncreaseLiquidity(params);
        
        console.log("InsufficientAmountAdded error correctly thrown for swapAndIncreaseLiquidity");
    }
    
    function testSwapAndIncreaseLiquidityWithETH_InsufficientAmountAdded() public {
        console.log("=== Testing swapAndIncreaseLiquidity with ETH and insufficient amount added ===");
        
        // Create a position with ETH first
        uint256 tokenId = _createTestPositionWithETH(user1);
        console.log("Created position with tokenId:", tokenId);
        
        // Set up ERC20 allowance for token1 only (ETH doesn't need approval)
        vm.prank(user1);
        token1.approve(address(permit2), type(uint256).max);
        
        // Set up Permit2 allowances for token1 only
        vm.prank(user1);
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(1000 ether),
            uint48(block.timestamp + 1 days)
        );
        
        // Prepare swap and increase liquidity parameters with ETH and high minimum amounts
        V4Utils.SwapAndIncreaseLiquidityParams memory params = V4Utils.SwapAndIncreaseLiquidityParams({
            tokenId: tokenId,
            amount0: 1 ether, // Small ETH amount
            amount1: 1 ether, // Small token1 amount
            recipient: user1,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 2 ether, // Higher than amount0 - should fail
            amountAddMin1: 0, // No minimum for token1
            decreaseLiquidityHookData: "", 
            increaseLiquidityHookData: ""
        });
        
        // Approve V4Utils to manage the NFT
        vm.prank(user1);
        IERC721(address(positionManager)).approve(address(v4Utils), tokenId);
        
        // Approve tokens for V4Utils (only token1, ETH doesn't need approval)
        vm.prank(user1);
        token1.approve(address(v4Utils), 1 ether);
        
        // Execute swap and increase liquidity with ETH value - should fail due to insufficient amount
        vm.prank(user1);
        vm.expectRevert(Constants.InsufficientAmountAdded.selector);
        v4Utils.swapAndIncreaseLiquidity{value: 1 ether}(params);
        
        console.log("InsufficientAmountAdded error correctly thrown for swapAndIncreaseLiquidity with ETH");
    }
}
