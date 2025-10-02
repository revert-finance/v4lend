// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {V4Utils} from "../src/transformers/V4Utils.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import "./V4UtilsExecuteTestBase.sol";

/**
 * @title V4UtilsSwapAndMintTest
 * @notice Test suite for V4Utils.swapAndMint() functionality
 * @dev Tests creating new liquidity positions with optional token swaps
 */
contract V4UtilsSwapAndMintTest is V4UtilsExecuteTestBase {

    struct SwapAndMintTestParams {
        Currency token0;
        Currency token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address recipient;
        address recipientNFT;
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
        bytes returnData;
        string testName;
        address hook;
    }

    function _executeSwapAndMint(
        SwapAndMintTestParams memory params
    ) internal {
        _logTestStart("SWAP_AND_MINT", params.testName);
        
        // Record initial balances
        (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance) = _recordInitialBalances(params.recipient);
        
        // Log pool parameters
        console.log("Token0 address:", Currency.unwrap(params.token0));
        console.log("Token1 address:", Currency.unwrap(params.token1));
        console.log("Fee:", params.fee);
        console.log("Tick lower:", params.tickLower);
        console.log("Tick upper:", params.tickUpper);
        console.log("Amount0:", params.amount0);
        console.log("Amount1:", params.amount1);
        
        // Execute the swap and mint
        _executeSwapAndMintTest(params);
        
        // Record final balances
        (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) = _recordFinalBalances(
            params.recipient,
            initialWethBalance,
            initialUsdcBalance,
            initialEthBalance
        );
        
        _logTestCompletion("SWAP_AND_MINT");

        // Assertions for SWAP_AND_MINT operation
        _verifySwapAndMintResults(params, initialWethBalance, finalWethBalance, initialUsdcBalance, finalUsdcBalance, initialEthBalance, finalEthBalance);
    }

    function _executeSwapAndMintTest(SwapAndMintTestParams memory params) internal {
        // First initialize the pool (required for V4)
        PoolKey memory poolKey = PoolKey({
            currency0: params.token0,
            currency1: params.token1,
            fee: params.fee,
            tickSpacing: params.fee == 3000 ? int24(60) : int24(10), // Tick spacing based on fee
            hooks: IHooks(params.hook)
        });
        
        // Initialize the pool with the hook if needed
        _initializePoolWithHook(poolKey);
        
        // Set up direct ERC20 allowances from user to V4Utils (since swapAndMint uses direct transfers)
        if (Currency.unwrap(params.token0) != address(0)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(params.token0)).approve(address(v4Utils), type(uint256).max);
        }
        if (Currency.unwrap(params.token1) != address(0)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(params.token1)).approve(address(v4Utils), type(uint256).max);
        }
        if (Currency.unwrap(params.swapSourceToken) != address(0)) {
            vm.prank(params.recipient);
            IERC20(Currency.unwrap(params.swapSourceToken)).approve(address(v4Utils), type(uint256).max);
        }

        // Create swap and mint parameters
        V4Utils.SwapAndMintParams memory swapAndMintParams = V4Utils.SwapAndMintParams({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickSpacing: 60,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0: params.amount0,
            amount1: params.amount1,
            recipient: params.recipient,
            recipientNFT: params.recipientNFT,
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
            returnData: params.returnData,
            hook: params.hook,
            mintHookData: ""
        });

        // Execute swap and mint
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        
        vm.prank(params.recipient);
        // If token0 is ETH, send the ETH value with the call
        if (Currency.unwrap(params.token0) == address(0)) {
            (tokenId, liquidity, amount0, amount1) = v4Utils.swapAndMint{value: params.amount0}(swapAndMintParams);
        } else if (Currency.unwrap(params.token1) == address(0)) {
            (tokenId, liquidity, amount0, amount1) = v4Utils.swapAndMint{value: params.amount1}(swapAndMintParams);
        } else {
            (tokenId, liquidity, amount0, amount1) = v4Utils.swapAndMint(swapAndMintParams);
        }
        console.log("SwapAndMint successful - TokenId:", tokenId);
        console.log("Liquidity added:", liquidity);
        console.log("Amount0 used:", amount0);
        console.log("Amount1 used:", amount1);
        
        console.log("SWAP_AND_MINT executed successfully");
        console.log("New NFT Token ID:", tokenId);
        console.log("Position liquidity:", liquidity);
        console.log("Amount0 used:", amount0);
        console.log("Amount1 used:", amount1);
        
        // Verify NFT was created and owned by recipient
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), params.recipientNFT, "NFT should be owned by recipient");
        assertGt(tokenId, 0, "Token ID should be valid");
        
        // Verify position has liquidity
        uint128 positionLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(positionLiquidity, 0, "Position should have liquidity");
        
        // Verify amounts were consumed (at least one should be > 0)
        assertTrue(amount0 > 0 || amount1 > 0, "At least one amount should be greater than 0");
    }

    function _verifySwapAndMintResults(
        SwapAndMintTestParams memory params,
        uint256 /* initialWethBalance */,
        uint256 /* finalWethBalance */,
        uint256 /* initialUsdcBalance */,
        uint256 /* finalUsdcBalance */,
        uint256 /* initialEthBalance */,
        uint256 /* finalEthBalance */
    ) internal {
        _verifyContractCleanup();
        
        // Get the latest token ID (should be the one we just created)
        uint256 latestTokenId = positionManager.nextTokenId() - 1;
        
        // Verify position exists and has liquidity
        uint128 positionLiquidity = positionManager.getPositionLiquidity(latestTokenId);
        assertGt(positionLiquidity, 0, "New position should have liquidity");
        
        // Verify position parameters match expected values
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(latestTokenId);
        assertEq(poolKey.fee, params.fee, "Position fee should match expected fee");
        assertEq(positionInfo.tickLower(), params.tickLower, "Position tick lower should match expected value");
        assertEq(positionInfo.tickUpper(), params.tickUpper, "Position tick upper should match expected value");
        
        // Verify position ownership
        assertEq(IERC721(address(positionManager)).ownerOf(latestTokenId), params.recipientNFT, "Position should be owned by the recipient");
        
        // Verify token addresses are correct
        assertEq(Currency.unwrap(poolKey.currency0), Currency.unwrap(params.token0), "Token0 should match expected token");
        assertEq(Currency.unwrap(poolKey.currency1), Currency.unwrap(params.token1), "Token1 should match expected token");
        
        // Verify tick spacing is correct for the fee tier
        if (params.fee == 3000) {
            assertEq(poolKey.tickSpacing, 60, "Tick spacing should be 60 for 0.3% fee");
        } else if (params.fee == 500) {
            assertEq(poolKey.tickSpacing, 10, "Tick spacing should be 10 for 0.05% fee");
        }
        
        // Verify tick alignment
        assertTrue(positionInfo.tickLower() % poolKey.tickSpacing == 0, "Tick lower should be aligned with tick spacing");
        assertTrue(positionInfo.tickUpper() % poolKey.tickSpacing == 0, "Tick upper should be aligned with tick spacing");
        
        // Verify tick range is valid (lower < upper)
        assertTrue(positionInfo.tickLower() < positionInfo.tickUpper(), "Tick lower should be less than tick upper");
        
        console.log("All SWAP_AND_MINT assertions passed successfully");
    }

    function testSwapAndMint_WETH_USDC_NoSwap() public {
        SwapAndMintTestParams memory params = SwapAndMintTestParams({
            token0: Currency.wrap(address(usdc)),
            token1: Currency.wrap(address(realWeth)),
            fee: 3000, // 0.3% fee
            tickLower: -1200, // Tick range aligned with tick spacing 60
            tickUpper: 1200,
            amount0: 100000000, // 100 USDC (smaller amount)
            amount1: 100000000000000000, // 0.1 WETH (user has ~0.1 WETH)
            recipient: nft1Owner,
            recipientNFT: nft1Owner,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: hex"",
            testName: "WETH/USDC - No Swap",
            hook: address(0)
        });
        
        _executeSwapAndMint(params);
    }

    function testSwapAndMint_ETH_USDC_NoSwap() public {
        SwapAndMintTestParams memory params = SwapAndMintTestParams({
            token0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            token1: Currency.wrap(address(usdc)),
            fee: 3000, // 0.3% fee
            tickLower: -1200, // Tick range aligned with tick spacing 60
            tickUpper: 1200,
            amount0: 10000000000000000, // 0.01 ETH (user has ~0.028 ETH)
            amount1: 100000000, // 100 USDC (smaller amount)
            recipient: nft2Owner,
            recipientNFT: nft2Owner,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: hex"",
            testName: "ETH/USDC - No Swap",
            hook: address(0)
        });
        
        _executeSwapAndMint(params);
    }

    function testSwapAndMint_ETH_USDC_Swap() public {
        SwapAndMintTestParams memory params = SwapAndMintTestParams({
            token0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            token1: Currency.wrap(address(usdc)),
            fee: 3000, // 0.3% fee
            tickLower: -1200, // Tick range aligned with tick spacing 60
            tickUpper: 1200,
            amount0: 10000000000000000, // 0.01 ETH (user has ~0.028 ETH)
            amount1: 100000000, // 100 USDC (smaller amount)
            recipient: nft2Owner,
            recipientNFT: nft2Owner,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 1000000000000000,
            amountOut1Min: 4128717,
            swapData1: _getETHToUSDCSwapData(),
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: hex"",
            testName: "ETH/USDC - Swap ETH to USDC",
            hook: address(0)
        });
        
        _executeSwapAndMint(params);
    }

    function testSwapAndMint_USDC_ETH_Swap() public {
        SwapAndMintTestParams memory params = SwapAndMintTestParams({
            token0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            token1: Currency.wrap(address(usdc)),
            fee: 3000, // 0.3% fee
            tickLower: -1200, // Tick range aligned with tick spacing 60
            tickUpper: 1200,
            amount0: 10000000000000000, // 0.01 ETH (user has ~0.028 ETH)
            amount1: 100000000, // 100 USDC (smaller amount)
            recipient: nft2Owner,
            recipientNFT: nft2Owner,
            deadline: block.timestamp,
            swapSourceToken: Currency.wrap(address(usdc)),
            amountIn0: 6274987,
            amountOut0Min: 756050291375000,
            swapData0: _getUSDCtoETHSwapData(),
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: hex"",
            testName: "ETH/USDC - Swap USDC to ETH",
            hook: address(0)
        });
        
        _executeSwapAndMint(params);
    }

    function testSwapAndMint_WETH_USDC_WithHook() public {
        SwapAndMintTestParams memory params = SwapAndMintTestParams({
            token0: Currency.wrap(address(usdc)),
            token1: Currency.wrap(address(realWeth)),
            fee: 3000, // 0.3% fee
            tickLower: -1200, // Tick range aligned with tick spacing 60
            tickUpper: 1200,
            amount0: 100000000, // 100 USDC (smaller amount)
            amount1: 100000000000000000, // 0.1 WETH (user has ~0.1 WETH)
            recipient: nft1Owner,
            recipientNFT: nft1Owner,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO, // No swap
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: hex"",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: hex"",
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: hex"",
            testName: "WETH/USDC - No Swap With Hook",
            hook: 0xeE20cE89b34815f7DE29eBdf33e2861AA128C444
        });
        
        _executeSwapAndMint(params);
    }

}
