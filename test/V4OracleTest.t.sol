// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./V4ForkTestBase.sol";
import "../src/V4Oracle.sol";
import "../src/interfaces/IV4Oracle.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title V4OracleTest
 * @notice Comprehensive test suite for V4Oracle functionality
 */
contract V4OracleTest is V4ForkTestBase {
    
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

    // recieves ETH from decreasing liquidity
    receive() external payable {
    }
}
