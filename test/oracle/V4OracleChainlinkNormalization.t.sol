// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed, MutableDecimalsToken} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleChainlinkNormalizationTest
/// @notice External audit V4LE-135: for a token with more decimals than the reference token,
///         `_normalizeChainlinkPrice` multiplied the Q96 feed price by Q96 in checked arithmetic before
///         dividing. A valid in-domain ratio (6-decimal reference, 18-decimal token, raw price 2^64, i.e. a
///         feed price of ~2^200 in Q96) overflowed the product although the normalized price (2^160) and
///         its sqrt price (2^128) fit, so every valuation of a position in such a pool reverted. The
///         oracle now forms the 512-bit product.
/// @dev Fork-free, no pool needed: `getPoolSqrtPriceX96` exercises the normalization. The reference token
///      is a 6-decimal stand-in for USDC and the priced token an 18-decimal one.
contract V4OracleChainlinkNormalizationTest is BaseTest {
    uint256 constant Q96 = 2 ** 96;
    uint8 constant FEED_DECIMALS = 8;

    MutableDecimalsToken referenceToken;
    MutableDecimalsToken token;
    MutableChainlinkFeed referenceFeed;
    V4Oracle oracle;

    function setUp() public {
        deployArtifactsAndLabel();
        referenceToken = new MutableDecimalsToken(6);
        token = new MutableDecimalsToken(18);
        referenceFeed = new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS);

        oracle = new V4Oracle(positionManager, address(referenceToken), address(0xdead));
        _configure(address(referenceToken), referenceFeed);
    }

    function testV4LE135_BoundaryRatioWithMoreTokenDecimalsDoesNotOverflow() public {
        // raw pool price 2^64 reference-raw per token-raw: a whole token is worth 2^64 * 10^12 reference
        uint256 rawPriceX96 = uint256(1 << 64) * Q96;
        int256 answer = int256(uint256(1 << 64) * 1e12 * 10 ** FEED_DECIMALS);
        _configure(address(token), new MutableChainlinkFeed(answer, FEED_DECIMALS));

        // the auditor's premise: the checked intermediate product does not fit
        uint256 chainlinkPriceX96 = FullMath.mulDiv(uint256(answer), Q96, 10 ** FEED_DECIMALS);
        assertGt(chainlinkPriceX96, type(uint256).max / Q96, "chainlinkPriceX96 * Q96 overflows uint256");

        // the normalized price is exactly 2^160 and its sqrt price 2^128, inside the TickMath domain
        uint160 sqrtPriceX96 = oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
        assertEq(sqrtPriceX96, uint160(Math.sqrt(rawPriceX96) * (2 ** 48)), "boundary ratio is normalized");
        assertEq(sqrtPriceX96, uint160(1 << 128));
        assertLe(sqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        assertEq(
            oracle.getPoolSqrtPriceX96(address(referenceToken), address(token)),
            uint160(1 << 64),
            "inverse quote is normalized too"
        );
    }

    function testV4LE135_OrdinaryRatioIsUnchanged() public {
        _configure(address(token), new MutableChainlinkFeed(2500 * int256(10 ** FEED_DECIMALS), FEED_DECIMALS));
        // 2500 reference per token in raw units: 2500 * 10^6 / 10^18
        uint256 priceX96 = FullMath.mulDiv(2500 * 10 ** 6, Q96, 10 ** 18);
        assertEq(
            oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)),
            uint160(Math.sqrt(priceX96) * (2 ** 48)),
            "same floor as the checked formula"
        );
    }

    function _configure(address token_, MutableChainlinkFeed feed_) internal {
        oracle.setTokenConfig(
            token_,
            AggregatorV3Interface(address(feed_)),
            1 days,
            IUniswapV3Pool(address(0)),
            address(0),
            0,
            V4Oracle.Mode.CHAINLINK,
            0
        );
    }
}
