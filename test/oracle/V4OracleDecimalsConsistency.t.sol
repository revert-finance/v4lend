// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {MockUniswapV3Pool} from "test/utils/MockUniswapV3Pool.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed, MutableDecimalsToken} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleDecimalsConsistencyTest
/// @notice `setTokenConfig` caches `feed.decimals()` and `token.decimals()`. In the single-source
///         `Mode.CHAINLINK` path nothing else reads the price, so an honest upgrade that changes either
///         precision (a feed proxy migrating from 8 to 18 decimals, an upgradeable token changing its
///         units) was scaled with the stale exponent and mispriced by 10^|delta| until noticed.
///         - External audit V4LE-15: feed decimals.
///         The oracle now re-reads the live metadata on unverified Chainlink reads and reverts when it
///         differs from the cached value; the owner re-runs `setTokenConfig` to accept the new precision.
///         Verified two-source reads keep failing closed through the deviation check and pay nothing.
/// @dev Fork-free, no pool needed: `getPoolSqrtPriceX96` exercises the whole price path. The reference
///      token is a 6-decimal stand-in for USDC and the priced token an 18-decimal one worth 2500 reference.
contract V4OracleDecimalsConsistencyTest is BaseTest {
    uint256 constant Q96 = 2 ** 96;
    // by signature so the tests compile against the pre-fix oracle and fail there at runtime
    bytes4 constant FEED_DECIMALS_CHANGED = bytes4(keccak256("FeedDecimalsChanged()"));
    bytes4 constant PRICE_DIFFERENCE_EXCEEDED = bytes4(keccak256("PriceDifferenceExceeded()"));
    int24 constant TWAP_TICK = -198080; // ~2.5e-9 reference-raw per token-raw, i.e. 2500 USDC per token

    MutableDecimalsToken referenceToken;
    MutableDecimalsToken token;
    MutableChainlinkFeed referenceFeed;
    MutableChainlinkFeed feed;
    MockUniswapV3Pool twapPool;
    V4Oracle oracle;

    function setUp() public {
        deployArtifactsAndLabel();
        referenceToken = new MutableDecimalsToken(6);
        token = new MutableDecimalsToken(18);
        referenceFeed = new MutableChainlinkFeed(1e8, 8);
        feed = new MutableChainlinkFeed(2500e8, 8);
        twapPool = new MockUniswapV3Pool(address(token), address(referenceToken), TWAP_TICK);

        oracle = new V4Oracle(positionManager, address(referenceToken), address(0xdead));
        _configure(address(referenceToken), referenceFeed, V4Oracle.Mode.CHAINLINK);
        _configure(address(token), feed, V4Oracle.Mode.CHAINLINK);
    }

    /// @dev 2500 reference per token in raw units: 2500 * 10^6 / 10^18, as a Q96 sqrt price.
    function _expectedSqrtPriceX96(uint8 tokenDecimals) internal view returns (uint160) {
        uint256 priceX96 = Math.mulDiv(2500 * 10 ** referenceToken.decimals(), Q96, 10 ** tokenDecimals);
        return uint160(Math.sqrt(priceX96) * (2 ** 48));
    }

    function testHonestConfigurationPrices() public view {
        assertEq(
            oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedSqrtPriceX96(18), "baseline"
        );
    }

    // ---------------------------------------------------------------- V4LE-15: feed decimals

    function testFeedPrecisionUpgradeIsRejectedUntilReconfigured() public {
        // the provider migrates the feed to 18 decimals while preserving the economic price
        feed.setDecimals(18);
        feed.setAnswer(2500e18);

        // the old code scaled the honest answer with the cached 8 and priced the token 1e10 too high
        vm.expectRevert(FEED_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
        vm.expectRevert(FEED_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(referenceToken), address(token));

        // the owner acknowledges the new precision and the price is right again
        _configure(address(token), feed, V4Oracle.Mode.CHAINLINK);
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedSqrtPriceX96(18));
    }

    function testReferenceFeedPrecisionUpgradeIsRejected() public {
        referenceFeed.setDecimals(18);
        referenceFeed.setAnswer(1e18);

        vm.expectRevert(FEED_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));

        _configure(address(referenceToken), referenceFeed, V4Oracle.Mode.CHAINLINK);
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedSqrtPriceX96(18));
    }

    function testVerifiedTwoSourceReadFailsClosedWithoutMetadataCalls() public {
        _configure(address(token), feed, V4Oracle.Mode.CHAINLINK_TWAP_VERIFY);
        uint160 twoSourceSqrtPrice = oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
        assertEq(twoSourceSqrtPrice, _expectedSqrtPriceX96(18), "two-source baseline agrees with the TWAP");

        feed.setDecimals(18);
        feed.setAnswer(2500e18);

        // the TWAP exposes the mis-scaled Chainlink leg; no decimals() call is spent on the hot path
        vm.expectCall(address(feed), abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), 0);
        vm.expectRevert(PRICE_DIFFERENCE_EXCEEDED);
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
    }

    function _configure(address token_, MutableChainlinkFeed feed_, V4Oracle.Mode mode) internal {
        bool twoSource = mode == V4Oracle.Mode.CHAINLINK_TWAP_VERIFY || mode == V4Oracle.Mode.TWAP_CHAINLINK_VERIFY;
        oracle.setTokenConfig(
            token_,
            AggregatorV3Interface(address(feed_)),
            1 days,
            twoSource ? twapPool : IUniswapV3Pool(address(0)),
            address(0),
            1800,
            mode,
            twoSource ? 200 : 0
        );
    }
}
