// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";

/// @dev Minimal Chainlink-compatible feed: always fresh, fixed answer.
contract FixedChainlinkFeed {
    int256 public immutable answer;
    uint8 public immutable decimals;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @title V4OracleSqrtBoundaryTest
/// @notice External audit: with the live pool at `TickMath.MAX_SQRT_PRICE - 1`, an honest feed
///         ratio ~0.1% higher passes the pool/oracle deviation check (200 bps) but its derived sqrt
///         price exceeds uint160, so a plain `SafeCast.toUint160` blocked `getValue` and with it
///         every vault health check and liquidation of the position. The derived sqrt price only
///         splits liquidity into amounts, which saturates beyond the position's range, so the oracle
///         now clamps it to the TickMath bounds (exact) and `getPoolSqrtPriceX96`, whose result is
///         used numerically, reports the out-of-range ratio with a protocol error.
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with
///      mock Chainlink feeds; currency1 is the reference token so `price1X96 == Q96` and the derived
///      pool price is exactly currency0's feed price.
contract V4OracleSqrtBoundaryTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;
    int24 constant TICK_SPACING = 60;
    uint16 constant MAX_POOL_DIFFERENCE = 200;
    uint8 constant FEED_DECIMALS = 8;
    uint128 constant POSITION_LIQUIDITY = 1e3;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    V4Oracle oracle;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    uint256 livePriceX96;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        poolKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(address(0)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, TickMath.MAX_SQRT_PRICE - 1);
        (uint160 liveSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        livePriceX96 = FullMath.mulDiv(uint256(liveSqrtPriceX96), uint256(liveSqrtPriceX96), Q96);

        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        oracle.setMaxPoolPriceDifference(MAX_POOL_DIFFERENCE);
        _configureToken(Currency.unwrap(currency1), new FixedChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS));

        // the pool price sits above the whole range, so the position is entirely currency1
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        tickLower = tickUpper - 100 * TICK_SPACING;
        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            POSITION_LIQUIDITY,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    /// @dev currency0 feed answer whose derived Q96 price is `livePriceX96 * numerator / 1000`
    ///      (rounded up so the ratio lands on or above the target side of the boundary).
    function _setCurrency0FeedRelativeToPool(uint256 numerator) internal returns (uint256 derivedPriceX96) {
        uint256 answer = Math.mulDiv(livePriceX96 * numerator / 1000, 10 ** FEED_DECIMALS, Q96, Math.Rounding.Ceil);
        _configureToken(Currency.unwrap(currency0), new FixedChainlinkFeed(int256(answer), FEED_DECIMALS));
        derivedPriceX96 = FullMath.mulDiv(answer, Q96, 10 ** FEED_DECIMALS);
    }

    function _expectedAmount1() internal view returns (uint256 amount1) {
        (, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.MAX_SQRT_PRICE,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            POSITION_LIQUIDITY
        );
    }

    function testDerivedSqrtPriceAboveUint160KeepsPositionValuable() public {
        uint256 derivedPriceX96 = _setCurrency0FeedRelativeToPool(1001);

        // the auditor's premise: inside the deviation window, yet beyond the uint160 sqrt domain
        uint256 differenceBps = Math.mulDiv(derivedPriceX96 - livePriceX96, 10_000, derivedPriceX96);
        assertLe(differenceBps, MAX_POOL_DIFFERENCE, "ratio passes the deviation check");
        assertGt(Math.sqrt(derivedPriceX96) * (2 ** 48), type(uint160).max, "raw sqrt cast would overflow");

        // valuation works and is exact: beyond its range the position is all currency1
        (uint256 value, uint256 feeValue,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(value, _expectedAmount1(), "clamped derived price yields the saturated composition");
        assertEq(feeValue, 0);
        (uint256 valueIn0,,,) = oracle.getValue(tokenId, Currency.unwrap(currency0));
        assertEq(valueIn0, FullMath.mulDiv(_expectedAmount1(), Q96, derivedPriceX96), "quote in currency0 works too");

        // the numeric sqrt-price view reports the unrepresentable ratio explicitly, both ways round
        vm.expectRevert(V4Oracle.SqrtPriceOutOfRange.selector);
        oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1));
        vm.expectRevert(V4Oracle.SqrtPriceOutOfRange.selector);
        oracle.getPoolSqrtPriceX96(Currency.unwrap(currency1), Currency.unwrap(currency0));
    }

    function testDerivedSqrtPriceJustBelowBoundaryIsUnchanged() public {
        uint256 derivedPriceX96 = _setCurrency0FeedRelativeToPool(999);
        uint256 expectedSqrt = Math.sqrt(derivedPriceX96) * (2 ** 48);
        assertLe(expectedSqrt, TickMath.MAX_SQRT_PRICE, "control ratio is representable");

        (uint256 value,,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(value, _expectedAmount1(), "same saturated composition below the boundary");
        assertEq(
            oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1)),
            uint160(expectedSqrt),
            "in-range ratio is returned unchanged"
        );
    }

    function _configureToken(address token, FixedChainlinkFeed feed) internal {
        oracle.setTokenConfig(
            token,
            AggregatorV3Interface(address(feed)),
            1 days,
            IUniswapV3Pool(address(0)),
            address(0),
            0,
            V4Oracle.Mode.CHAINLINK,
            0
        );
    }
}
