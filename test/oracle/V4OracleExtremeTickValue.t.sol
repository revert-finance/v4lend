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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleExtremeTickValueTest
/// @notice External audit V4LE-64: `getValue` multiplied each Q96 oracle price by the token amount as a
///         checked uint256 product before dividing by the quote price. At tick ~887000 the token0 price
///         is ~2^224 in Q96, so a modest token0 amount (~2^37) overflowed the product although the
///         quotient (the value in either pool token) fits comfortably, and every health check and
///         liquidation of the position reverted. The oracle now divides each term with full precision.
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with
///      mock Chainlink feeds; currency1 is the reference token so the derived pool price is currency0's
///      feed price. With the checked products restored the value tests fail with Panic(0x11).
contract V4OracleExtremeTickValueTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;
    int24 constant TICK_SPACING = 60;
    int24 constant POOL_TICK = 887000;
    int24 constant TICK_LOWER = 887040;
    int24 constant TICK_UPPER = 887220;
    uint128 constant POSITION_LIQUIDITY = 2 ** 108;
    uint8 constant FEED_DECIMALS = 8;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    V4Oracle oracle;
    uint256 tokenId;
    uint256 price0X96;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        poolKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(address(0)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(POOL_TICK));
        (uint160 liveSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 livePriceX96 = FullMath.mulDiv(uint256(liveSqrtPriceX96), uint256(liveSqrtPriceX96), Q96);

        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        oracle.setMaxPoolPriceDifference(200);
        _configureToken(
            Currency.unwrap(currency1), new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS)
        );
        // currency0 feed at the live pool price (rounded up to the feed's precision)
        uint256 answer = Math.mulDiv(livePriceX96, 10 ** FEED_DECIMALS, Q96, Math.Rounding.Ceil);
        _configureToken(Currency.unwrap(currency0), new MutableChainlinkFeed(int256(answer), FEED_DECIMALS));
        price0X96 = FullMath.mulDiv(answer, Q96, 10 ** FEED_DECIMALS);

        // the range sits above the pool price, so the position is entirely currency0
        (tokenId,) = positionManager.mint(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            POSITION_LIQUIDITY,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    function testExtremeTickPositionIsValuableInBothPoolTokens() public view {
        (,,,, uint256 amount0, uint256 amount1,,) = oracle.getPositionBreakdown(tokenId);
        assertGt(amount0, 0, "position holds currency0");
        assertEq(amount1, 0, "position holds no currency1");

        // the auditor's premise: the checked price-times-amount product does not fit uint256
        assertGt(price0X96, type(uint256).max / amount0, "price0X96 * amount0 overflows uint256");

        // quoted in currency0 the position is worth exactly its currency0 amount
        (uint256 valueIn0, uint256 feeValueIn0, uint256 p0In0, uint256 p1In0) =
            oracle.getValue(tokenId, Currency.unwrap(currency0));
        assertEq(valueIn0, amount0, "value in currency0 is the currency0 amount");
        assertEq(feeValueIn0, 0);
        assertEq(p0In0, Q96);
        assertEq(p1In0, FullMath.mulDiv(Q96, Q96, price0X96));

        // quoted in the reference token it is amount0 * price0
        (uint256 valueIn1, uint256 feeValueIn1, uint256 p0In1, uint256 p1In1) =
            oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(valueIn1, FullMath.mulDiv(price0X96, amount0, Q96), "value in currency1 is amount0 * price0");
        assertEq(feeValueIn1, 0);
        assertEq(p0In1, price0X96);
        assertEq(p1In1, Q96);
    }

    function _configureToken(address token, MutableChainlinkFeed feed) internal {
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
