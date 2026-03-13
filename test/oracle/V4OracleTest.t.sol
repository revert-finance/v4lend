// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {V4ForkTestBase} from "test/vault/support/V4ForkTestBase.sol";
import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";
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
            bytes[] memory paramsArray = new bytes[](2);
            paramsArray[0] = abi.encode(
                tokenId,
                uint256(0),
                uint128(0), // amount0Min
                uint128(0),
                ""
            );
            paramsArray[1] = abi.encode(currency0, currency1, address(this));
            vm.prank(owner);
            positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);

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

    /// @notice Test that getPoolSqrtPriceX96 is calculated correctly from Chainlink feeds
    /// @dev Manually calculates the expected sqrtPriceX96 and compares to oracle result
    function testGetPoolSqrtPriceX96Calculation() public {
        console.log("=== Testing getPoolSqrtPriceX96 Calculation ===");

        // Test pairs: (token0, token1)
        // 1. WETH/USDC
        _testSqrtPriceCalculation(WETH_ADDRESS, USDC_ADDRESS, "WETH/USDC");

        // 2. USDC/WETH (reversed)
        _testSqrtPriceCalculation(USDC_ADDRESS, WETH_ADDRESS, "USDC/WETH");

        // 3. WBTC/USDC
        _testSqrtPriceCalculation(WBTC_ADDRESS, USDC_ADDRESS, "WBTC/USDC");

        // 4. DAI/USDC (stablecoin pair)
        _testSqrtPriceCalculation(DAI_ADDRESS, USDC_ADDRESS, "DAI/USDC");

        // 5. Native ETH/USDC
        _testSqrtPriceCalculation(address(0), USDC_ADDRESS, "ETH/USDC");

        // 6. Same token (edge case - should return Q96)
        _testSqrtPriceCalculation(USDC_ADDRESS, USDC_ADDRESS, "USDC/USDC");

        console.log("=== All getPoolSqrtPriceX96 Calculation Tests Passed ===");
    }

    /// @notice Helper to test sqrtPriceX96 calculation for a specific token pair
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param pairName Name of the pair for logging
    function _testSqrtPriceCalculation(address token0, address token1, string memory pairName) internal view {
        console.log("");
        console.log("--- Testing pair:", pairName, "---");

        // Get oracle's sqrtPriceX96
        uint160 oracleSqrtPriceX96 = v4Oracle.getPoolSqrtPriceX96(token0, token1);
        console.log("Oracle sqrtPriceX96:", oracleSqrtPriceX96);

        // Edge case: same token should return Q96
        if (token0 == token1) {
            assertEq(oracleSqrtPriceX96, uint160(Q96), "Same token should return Q96");
            console.log("Verified: same token returns Q96");
            return;
        }

        // Manually calculate expected sqrtPriceX96
        // Formula: sqrt(price0X96 * Q96 / price1X96) * 2^48

        // Get individual prices from Chainlink (in reference token terms)
        uint256 price0X96 = _getManualPriceX96(token0);
        uint256 price1X96 = _getManualPriceX96(token1);

        console.log("Manual price0X96:", price0X96);
        console.log("Manual price1X96:", price1X96);

        // Calculate expected sqrtPriceX96
        uint256 priceRatioX96 = price0X96 * Q96 / price1X96;
        uint256 expectedSqrtPriceX96 = Math.sqrt(priceRatioX96) * (2 ** 48);

        console.log("Expected sqrtPriceX96:", expectedSqrtPriceX96);

        // Verify they match exactly
        assertEq(oracleSqrtPriceX96, uint160(expectedSqrtPriceX96),
            string(abi.encodePacked("sqrtPriceX96 mismatch for ", pairName)));

        // Verify the price is reasonable (non-zero)
        assertTrue(oracleSqrtPriceX96 > 0, "sqrtPriceX96 should be positive");

        // Verify the actual price derived from sqrtPriceX96
        // price = (sqrtPriceX96 / Q96)^2 = sqrtPriceX96^2 / Q96
        uint256 derivedPriceX96 = (uint256(oracleSqrtPriceX96) * uint256(oracleSqrtPriceX96)) / Q96;
        console.log("Derived priceX96 (token0/token1):", derivedPriceX96);

        // The derived price should equal price0X96/price1X96
        uint256 expectedPriceX96 = price0X96 * Q96 / price1X96;

        // Allow small rounding error (< 0.01% due to sqrt precision)
        uint256 priceDiff;
        if (derivedPriceX96 >= expectedPriceX96) {
            priceDiff = derivedPriceX96 - expectedPriceX96;
        } else {
            priceDiff = expectedPriceX96 - derivedPriceX96;
        }

        uint256 maxAllowedDiff = expectedPriceX96 / 10000; // 0.01%
        assertTrue(priceDiff <= maxAllowedDiff,
            "Derived price should match expected within 0.01%");

        console.log("Verified:", pairName, "calculation is correct");
    }

    /// @notice Manually get priceX96 for a token using the same logic as V4Oracle
    /// @dev Replicates _getReferenceTokenPriceX96 logic for verification
    /// @param token Token address to get price for
    /// @return priceX96 Price in Q96 format relative to reference token
    function _getManualPriceX96(address token) internal view returns (uint256 priceX96) {
        address referenceToken = v4Oracle.referenceToken();

        // If token is the reference token, price is Q96
        if (token == referenceToken) {
            return Q96;
        }

        // Get Chainlink price for the token
        uint256 chainlinkPriceX96 = _getManualChainlinkPriceX96(token);

        // Get Chainlink price for reference token
        uint256 chainlinkReferencePriceX96 = _getManualChainlinkPriceX96(referenceToken);

        // Get token decimals
        (,,,uint8 tokenDecimals) = v4Oracle.feedConfigs(token);
        uint8 referenceTokenDecimals = v4Oracle.referenceTokenDecimals();

        // Calculate price with decimal adjustment (same as V4Oracle._getReferenceTokenPriceX96)
        if (referenceTokenDecimals > tokenDecimals) {
            priceX96 = (10 ** (referenceTokenDecimals - tokenDecimals)) * chainlinkPriceX96
                * Q96 / chainlinkReferencePriceX96;
        } else if (referenceTokenDecimals < tokenDecimals) {
            priceX96 = chainlinkPriceX96 * Q96 / chainlinkReferencePriceX96
                / (10 ** (tokenDecimals - referenceTokenDecimals));
        } else {
            priceX96 = chainlinkPriceX96 * Q96 / chainlinkReferencePriceX96;
        }
    }

    /// @notice Manually get Chainlink price in X96 format
    /// @param token Token address
    /// @return Chainlink price in Q96 format
    function _getManualChainlinkPriceX96(address token) internal view returns (uint256) {
        address chainlinkReferenceToken = v4Oracle.chainlinkReferenceToken();

        // If token is the chainlink reference token (e.g., 0xdead for USD), return Q96
        if (token == chainlinkReferenceToken) {
            return Q96;
        }

        // Get feed config
        (AggregatorV3Interface feed,, uint8 feedDecimals,) = v4Oracle.feedConfigs(token);

        // Get latest price from Chainlink
        (, int256 answer,,,) = feed.latestRoundData();

        // Convert to Q96 format
        return uint256(answer) * Q96 / (10 ** feedDecimals);
    }

    /// @notice Test sqrtPriceX96 symmetry - swapping token order should give inverse
    function testGetPoolSqrtPriceX96Symmetry() public {
        console.log("=== Testing getPoolSqrtPriceX96 Symmetry ===");

        // Get sqrtPriceX96 for WETH/USDC
        uint160 sqrtPrice_WETH_USDC = v4Oracle.getPoolSqrtPriceX96(WETH_ADDRESS, USDC_ADDRESS);

        // Get sqrtPriceX96 for USDC/WETH (reversed)
        uint160 sqrtPrice_USDC_WETH = v4Oracle.getPoolSqrtPriceX96(USDC_ADDRESS, WETH_ADDRESS);

        console.log("sqrtPrice(WETH/USDC):", sqrtPrice_WETH_USDC);
        console.log("sqrtPrice(USDC/WETH):", sqrtPrice_USDC_WETH);

        // Calculate prices from sqrtPrices
        uint256 price_WETH_USDC = (uint256(sqrtPrice_WETH_USDC) * uint256(sqrtPrice_WETH_USDC)) / Q96;
        uint256 price_USDC_WETH = (uint256(sqrtPrice_USDC_WETH) * uint256(sqrtPrice_USDC_WETH)) / Q96;

        console.log("price(WETH/USDC):", price_WETH_USDC);
        console.log("price(USDC/WETH):", price_USDC_WETH);

        // Verify: price_WETH_USDC * price_USDC_WETH should approximately equal Q96^2 / Q96 = Q96
        // Because if WETH/USDC = X, then USDC/WETH = 1/X
        // So X * (1/X) = 1, and in Q96 terms: priceX96 * inversePriceX96 / Q96 = Q96
        uint256 product = (price_WETH_USDC * price_USDC_WETH) / Q96;

        console.log("Product (should be ~Q96):", product);
        console.log("Q96:", Q96);

        // Allow 1% tolerance for rounding
        uint256 tolerance = Q96 / 100;
        uint256 diff = product > Q96 ? product - Q96 : Q96 - product;

        assertTrue(diff < tolerance, "Price * inverse price should equal Q96 (within 1%)");

        console.log("=== Symmetry Test Passed ===");
    }

    // recieves ETH from decreasing liquidity
    receive() external payable {
    }
}
