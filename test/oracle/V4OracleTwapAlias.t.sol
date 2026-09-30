// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {MockUniswapV3Pool} from "test/utils/MockUniswapV3Pool.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed, MutableDecimalsToken} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleTwapAliasTest
/// @notice External audit V4LE-147: `setTokenConfig` accepts a `twapTokenAlias` (the token the v3 reference
///         pool trades, e.g. WETH for native ETH) but bound only the configured token's decimals. The TWAP
///         leg is read in the alias's raw unit and applied to the token's, so an alias whose units differ
///         from the token's, at configuration or after an upgrade, mispriced the token by 10^k with nothing
///         in a single-source TWAP read to catch it. The alias must now carry the token's decimals when
///         configured, and unverified TWAP reads re-check both units live; verified two-source reads keep
///         failing closed through the deviation check and pay nothing.
/// @dev Fork-free, no v4 pool needed: `getPoolSqrtPriceX96` exercises the whole price path. The reference
///      token is a 6-decimal stand-in for USDC, the token and its alias 18-decimal ones worth 2500 reference.
contract V4OracleTwapAliasTest is BaseTest {
    uint256 constant Q96 = 2 ** 96;
    bytes4 constant TOKEN_DECIMALS_CHANGED = bytes4(keccak256("TokenDecimalsChanged()"));
    bytes4 constant INVALID_CONFIG = bytes4(keccak256("InvalidConfig()"));
    int24 constant TWAP_TICK = -198080; // ~2.5e-9 reference-raw per token-raw, i.e. 2500 USDC per token

    MutableDecimalsToken referenceToken;
    MutableDecimalsToken token;
    MutableDecimalsToken alias_;
    MutableChainlinkFeed referenceFeed;
    MutableChainlinkFeed feed;
    MockUniswapV3Pool aliasPool;
    V4Oracle oracle;

    function setUp() public {
        deployArtifactsAndLabel();
        referenceToken = new MutableDecimalsToken(6);
        token = new MutableDecimalsToken(18);
        alias_ = new MutableDecimalsToken(18);
        referenceFeed = new MutableChainlinkFeed(1e8, 8);
        feed = new MutableChainlinkFeed(2500e8, 8);
        aliasPool = new MockUniswapV3Pool(address(alias_), address(referenceToken), TWAP_TICK);

        oracle = new V4Oracle(positionManager, address(referenceToken), address(0xdead));
        oracle.setTokenConfig(
            address(referenceToken), AggregatorV3Interface(address(referenceFeed)), 1 days, IUniswapV3Pool(address(0)),
            address(0), 0, V4Oracle.Mode.CHAINLINK, 0
        );
        _configureWithAlias(V4Oracle.Mode.TWAP, 0);
    }

    /// @dev Price a Chainlink-sourced read reports: 2500 reference per token in raw units.
    function _expectedFeedSqrtPriceX96() internal pure returns (uint160) {
        uint256 priceX96 = Math.mulDiv(2500 * 10 ** 6, Q96, 10 ** 18);
        return uint160(Math.sqrt(priceX96) * (2 ** 48));
    }

    /// @dev Price a TWAP-sourced read reports: the alias pool's tick price (alias is token0 there).
    function _expectedTwapSqrtPriceX96() internal pure returns (uint160) {
        uint160 tickSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TWAP_TICK);
        uint256 priceX96 = FullMath.mulDiv(tickSqrtPriceX96, tickSqrtPriceX96, Q96);
        return uint160(Math.sqrt(priceX96) * (2 ** 48));
    }

    function testHonestAliasPrices() public view {
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedTwapSqrtPriceX96());
        assertApproxEqRel(
            uint256(_expectedTwapSqrtPriceX96()), uint256(_expectedFeedSqrtPriceX96()), 1e14, "sources agree"
        );
    }

    function testV4LE147_AliasMustCarryTheTokenUnitAtConfiguration() public {
        MutableDecimalsToken sixDecimalAlias = new MutableDecimalsToken(6);
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(sixDecimalAlias), address(referenceToken), 0);
        vm.expectRevert(INVALID_CONFIG);
        oracle.setTokenConfig(
            address(token), AggregatorV3Interface(address(feed)), 1 days, pool, address(sixDecimalAlias), 1800,
            V4Oracle.Mode.TWAP, 0
        );
    }

    function testV4LE147_AliasUnitsChangeIsRejectedInTwapMode() public {
        // the upgradeable alias switches to 6 decimals; the alias pool's raw price now means something else
        alias_.setDecimals(6);

        // the old code kept applying the alias-raw price to the token and mispriced it by 1e12
        vm.expectRevert(TOKEN_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
        vm.expectRevert(TOKEN_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(referenceToken), address(token));

        // the alias no longer fits the token: reconfiguring with it is refused until a fitting alias exists
        vm.expectRevert(INVALID_CONFIG);
        _configureWithAlias(V4Oracle.Mode.TWAP, 0);
        alias_.setDecimals(18);
        _configureWithAlias(V4Oracle.Mode.TWAP, 0);
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedTwapSqrtPriceX96());
    }

    function testV4LE147_TokenUnitsChangeIsRejectedInTwapModeWithAlias() public {
        token.setDecimals(6);
        vm.expectRevert(TOKEN_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
    }

    function testV4LE147_TwoSourceReadWithDisabledDeviationChecksTheAlias() public {
        _configureWithAlias(V4Oracle.Mode.CHAINLINK_TWAP_VERIFY, type(uint16).max);
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedFeedSqrtPriceX96());

        alias_.setDecimals(6);
        vm.expectRevert(TOKEN_DECIMALS_CHANGED);
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
    }

    function testV4LE147_VerifiedTwoSourceReadPaysNothingAndFailsClosed() public {
        _configureWithAlias(V4Oracle.Mode.CHAINLINK_TWAP_VERIFY, 200);
        vm.expectCall(address(alias_), abi.encodeWithSignature("decimals()"), 0);
        vm.expectCall(address(token), abi.encodeWithSignature("decimals()"), 0);
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedFeedSqrtPriceX96());

        // an alias that really rebased its units moves the alias pool's price against the Chainlink leg
        alias_.setDecimals(6);
        aliasPool.setTick(TWAP_TICK + 276324); // 1e12 times the raw price
        vm.expectRevert(bytes4(keccak256("PriceDifferenceExceeded()")));
        oracle.getPoolSqrtPriceX96(address(token), address(referenceToken));
    }

    function testV4LE147_TokenAsItsOwnAliasIsNotChecked() public {
        MockUniswapV3Pool ownPool = new MockUniswapV3Pool(address(token), address(referenceToken), TWAP_TICK);
        oracle.setTokenConfig(
            address(token), AggregatorV3Interface(address(feed)), 1 days, ownPool, address(0), 1800, V4Oracle.Mode.TWAP, 0
        );
        // a token trading against itself in both pools stays self-consistent in raw units
        token.setDecimals(6);
        vm.expectCall(address(token), abi.encodeWithSignature("decimals()"), 0);
        assertEq(oracle.getPoolSqrtPriceX96(address(token), address(referenceToken)), _expectedTwapSqrtPriceX96());
    }

    function _configureWithAlias(V4Oracle.Mode mode, uint16 maxDifference) internal {
        oracle.setTokenConfig(
            address(token), AggregatorV3Interface(address(feed)), 1 days, aliasPool, address(alias_), 1800, mode,
            maxDifference
        );
    }
}
