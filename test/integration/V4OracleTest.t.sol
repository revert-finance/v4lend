// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {V4ForkTestBase} from "./V4ForkTestBase.sol";
import {V4Oracle, AggregatorV3Interface} from "../../src/V4Oracle.sol";
import {IV4Oracle} from "../../src/interfaces/IV4Oracle.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/**
 * @title V4OracleTest
 * @notice Comprehensive test suite for V4Oracle functionality
 */
contract V4OracleTest is V4ForkTestBase {
    uint256 constant Q96 = 2 ** 96;
    
    function testGetValue() public {
        // Test with the two preconfigured NFT positions from V4ForkTestBase
        uint256[] memory testTokenIds = new uint256[](2);
        testTokenIds[0] = nft1TokenId; // NFT 1 from V4ForkTestBase
        testTokenIds[1] = nft2TokenId; // NFT 2 from V4ForkTestBase
        
        // Test tokens configured in the oracle (from V4ForkTestBase setup)
        address[] memory testTokens = new address[](4);
        testTokens[0] = USDC_ADDRESS;  // USDC (reference token)
        testTokens[1] = DAI_ADDRESS;   // DAI
        testTokens[2] = WETH_ADDRESS;  // WETH
        testTokens[3] = address(0);    // Native ETH
        
        for (uint256 i = 0; i < testTokenIds.length; i++) {
            for (uint256 j = 0; j < testTokens.length; j++) {
                _testGetValueForToken(testTokenIds[i], testTokens[j]);
            }
        }
        
        // Test edge cases
        _testGetValueEdgeCases();
    }
    
    function _testGetValueForToken(uint256 tokenId, address token) internal {
        // Call getValue and assert it doesn't revert
        (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96) = 
            v4Oracle.getValue(tokenId, token);
        
        // Assertions for basic validity
        assertTrue(value >= feeValue, "Total value should be >= fee value");
        assertTrue(price0X96 > 0, "Price0X96 should be positive");
        assertTrue(price1X96 > 0, "Price1X96 should be positive");
        
        // Assert that prices are in reasonable Q96 format (not too small)
        assertTrue(price0X96 >= 1e12, "Price0X96 should be reasonable magnitude");
        assertTrue(price1X96 >= 1e12, "Price1X96 should be reasonable magnitude");
        
        // Test specific token behaviors
        if (token == USDC_ADDRESS) {
            // USDC is the reference token, so one price should be Q96
            assertTrue(price0X96 == 79228162514264337593543950336 || 
                      price1X96 == 79228162514264337593543950336, 
                      "One price should be Q96 for reference token");
        }
        
        // Test that getValue is deterministic (same inputs = same outputs)
        (uint256 value2, uint256 feeValue2, uint256 price0X96_2, uint256 price1X96_2) = 
            v4Oracle.getValue(tokenId, token);
        
        assertEq(value, value2, "getValue should be deterministic");
        assertEq(feeValue, feeValue2, "getValue fee should be deterministic");
        assertEq(price0X96, price0X96_2, "getValue price0 should be deterministic");
        assertEq(price1X96, price1X96_2, "getValue price1 should be deterministic");
    }
    
    function _testGetValueEdgeCases() internal {
        // Test with invalid tokenId (should revert)
        vm.expectRevert();
        v4Oracle.getValue(999999, USDC_ADDRESS);
        
        // Test with unconfigured token (should revert)
        vm.expectRevert();
        v4Oracle.getValue(nft1TokenId, address(0x1234567890123456789012345678901234567890));
    }
    
    function testGetValueWithNonExistingToken() public {
        // Test with a non-existing token address
        address nonExistingToken = address(0x9999999999999999999999999999999999999999);
        
        // Test with both NFT positions
        uint256[] memory testTokenIds = new uint256[](2);
        testTokenIds[0] = nft1TokenId;
        testTokenIds[1] = nft2TokenId;
        
        for (uint256 i = 0; i < testTokenIds.length; i++) {
            uint256 tokenId = testTokenIds[i];
            
            // This should revert with NotConfigured because the token is not configured in the oracle
            vm.expectRevert(abi.encodeWithSignature("NotConfigured()"));
            v4Oracle.getValue(tokenId, nonExistingToken);
        }
    }
    
    function testGetValueWithNonExistingTokenId() public {
 
        // Test with additional non-existing tokenIds
        uint256[] memory additionalTokenIds = new uint256[](3);
        additionalTokenIds[0] = 9999999;
        additionalTokenIds[1] = 20000000;
        additionalTokenIds[2] = 0; // Edge case: tokenId 0
        
        for (uint256 i = 0; i < additionalTokenIds.length; i++) {
            uint256 tokenId = additionalTokenIds[i];
            
            // All should revert because these tokenIds don't exist
            vm.expectRevert();
            v4Oracle.getValue(tokenId, USDC_ADDRESS);
        }
    }
    
    function testGetPositionBreakdownConsistency() public {
        // Test with the two preconfigured NFT positions from V4ForkTestBase
        uint256[] memory testTokenIds = new uint256[](2);
        testTokenIds[0] = nft1TokenId; // NFT 1 from V4ForkTestBase
        testTokenIds[1] = nft2TokenId; // NFT 2 from V4ForkTestBase
        
        for (uint256 i = 0; i < testTokenIds.length; i++) {
            uint256 tokenId = testTokenIds[i];
            
            // Get data from both functions
            (uint128 liquidityFromBreakdown, uint128 fees0FromBreakdown, uint128 fees1FromBreakdown) = 
                _getLiquidityAndFeesFromBreakdown(tokenId);
            (uint128 liquidityFromFees, uint128 fees0FromFees, uint128 fees1FromFees) = 
                v4Oracle.getLiquidityAndFees(tokenId);
            
            // Assert that liquidity values match
            assertEq(liquidityFromBreakdown, liquidityFromFees, 
                "Liquidity from getPositionBreakdown should match getLiquidityAndFees");
            
            // Assert that fee values match
            assertEq(fees0FromBreakdown, fees0FromFees, 
                "Fees0 from getPositionBreakdown should match getLiquidityAndFees");
            assertEq(fees1FromBreakdown, fees1FromFees, 
                "Fees1 from getPositionBreakdown should match getLiquidityAndFees");
            
            // Additional validation: ensure values are reasonable
            assertTrue(liquidityFromBreakdown >= 0, "Liquidity should be non-negative");
            assertTrue(fees0FromBreakdown >= 0, "Fees0 should be non-negative");
            assertTrue(fees1FromBreakdown >= 0, "Fees1 should be non-negative");
        }
    }
    
    function _getLiquidityAndFeesFromBreakdown(uint256 tokenId) internal view returns (
        uint128 liquidity, 
        uint128 fees0, 
        uint128 fees1
    ) {
        (, , , liquidity, , , fees0, fees1) = v4Oracle.getPositionBreakdown(tokenId);
    }

    function testGetPositionBreakdown() public {
        console.log("=== Testing testGetPositionBreakdown with Actual Token Collection ===");
        console.log("");

        // Test with the two preconfigured NFT positions from V4ForkTestBase
        uint256[] memory testTokenIds = new uint256[](2);
        testTokenIds[0] = nft1TokenId; // NFT 1 from V4ForkTestBase
        testTokenIds[1] = nft2TokenId; // NFT 2 from V4ForkTestBase

        address[] memory owners = new address[](2);
        owners[0] = nft1Owner; // NFT 1 owner
        owners[1] = nft2Owner; // NFT 2 owner

        for (uint256 i = 0; i < testTokenIds.length; i++) {
            uint256 tokenId = testTokenIds[i];
            address owner = owners[i];

            console.log(string(abi.encodePacked("=== Testing NFT TokenId: ", vm.toString(tokenId), " ===")));
            console.log("Owner:", owner);

            (
                Currency currency0,
                Currency currency1,
                uint24 fee,
                uint128 liquidity,
                uint256 amount0,
                uint256 amount1,
                uint128 fees0,
                uint128 fees1
            ) = v4Oracle.getPositionBreakdown(tokenId);

            uint balance0 = currency0.balanceOfSelf();
            uint balance1 = currency1.balanceOfSelf();

            bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params_array = new bytes[](2);
            params_array[0] = abi.encode(
                tokenId,
                uint256(0),
                uint128(0), // amount0Min
                uint128(0),
                ""
            );
            params_array[1] = abi.encode(currency0, currency1, address(this));
            vm.prank(owner);
            positionManager.modifyLiquidities(abi.encode(actions, params_array), block.timestamp);

            balance0 = currency0.balanceOfSelf() - balance0;
            balance1 = currency1.balanceOfSelf() - balance1;

            assertEq(balance0, fees0, "Collected amount0 does not match fees0");
            assertEq(balance1, fees1, "Collected amount1 does not match fees1");
        }

        console.log("=== getLiquidityAndFees Validation Tests Complete ===");
        console.log("Summary: Tested oracle accuracy against actual token collections");
        console.log("");
    }

    /// @notice Test comparing pool price to oracle getPriceX96 for the same two tokens
    /// @dev Gets pool price from sqrtPriceX96 and compares it to oracle's getPriceX96 result
    function testGetPriceX96Comparison() public {
        // Test with the two preconfigured NFT positions from V4ForkTestBase
        uint256[] memory testTokenIds = new uint256[](2);
        testTokenIds[0] = nft1TokenId; // NFT 1 from V4ForkTestBase
        testTokenIds[1] = nft2TokenId; // NFT 2 from V4ForkTestBase
        
        for (uint256 i = 0; i < testTokenIds.length; i++) {
            uint256 tokenId = testTokenIds[i];
            _testGetPriceX96ForPosition(tokenId);
        }
    }
    
    /// @notice Helper function to test getPriceX96 comparison for a specific position
    /// @param tokenId The token ID of the position to test
    function _testGetPriceX96ForPosition(uint256 tokenId) internal view {
        // Get pool information from position
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(tokenId);
        
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        
        // Get pool's sqrtPriceX96
        PoolId poolId = PoolIdLibrary.toId(poolKey);
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Get oracle price: price of token1 in terms of token0
        uint256 oracleSqrtPriceX96 = v4Oracle.getPoolSqrtPriceX96(token0, token1);
        
        // Log for debugging
        console.log("=== Testing getPriceX96 Comparison ===");
        console.log("TokenId:", tokenId);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Pool price (token1/token0):", sqrtPriceX96);
        console.log("Oracle price (token1/token0):", oracleSqrtPriceX96);
        
        // Both prices should be positive
        assertTrue(sqrtPriceX96 > 0, "Pool price should be positive");
        assertTrue(oracleSqrtPriceX96 > 0, "Oracle price should be positive");
        
        // Calculate the difference percentage (allowing for some deviation)
        // Prices may differ due to Chainlink vs pool price, but should be reasonably close
        uint256 difference;
        uint256 maxPrice;
        if (sqrtPriceX96 >= oracleSqrtPriceX96) {
            difference = sqrtPriceX96 - oracleSqrtPriceX96;
            maxPrice = sqrtPriceX96;
        } else {
            difference = oracleSqrtPriceX96 - sqrtPriceX96;
            maxPrice = oracleSqrtPriceX96;
        }
        
        // Calculate percentage difference (in basis points * 100, i.e., 200 = 2%)
        // Using maxPoolPriceDifference from oracle (200 = 2%) as tolerance
        uint256 differenceBpsX100 = (difference * 10000) / maxPrice;
        uint256 maxDifferenceBpsX100 = v4Oracle.maxPoolPriceDifference();
        
        console.log("Price difference (bps*100):", differenceBpsX100);
        console.log("Max allowed difference (bps*100):", maxDifferenceBpsX100);
        
        // Assert that the difference is within the oracle's maxPoolPriceDifference
        // This ensures the oracle and pool prices are reasonably aligned
        assertTrue(
            differenceBpsX100 <= maxDifferenceBpsX100 || maxDifferenceBpsX100 == type(uint16).max,
            "Price difference should be within maxPoolPriceDifference"
        );
    }

    // recieves ETH from decreasing liquidity
    receive() external payable {
    }
}
