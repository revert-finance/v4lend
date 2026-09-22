// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";

/// @dev Minimal Chainlink-compatible feed: always fresh, fixed answer.
contract MockChainlinkFeed {
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

/// @title V4OracleFeeGrowthWrapTest
/// @notice Regression for H-01: `V4Oracle._calculateUncollectedFees` must subtract the position's
///         `feeGrowthInsideLast` snapshot with modular (unchecked) arithmetic, exactly like Uniswap's
///         `Position.update`. Uniswap derives `feeGrowthInside` from `feeGrowthGlobal` minus the
///         `feeGrowthOutside` of both ticks, all mod 2^256, so a position whose upper tick was
///         initialized (with `feeGrowthOutside = 0`) before its lower tick (initialized after some fees
///         accrued, with `feeGrowthOutside = global`) while price sat above both snapshots
///         `last = 0 - global`, a numerically huge value. Once in-range accrual exceeds that `global`,
///         the live `feeGrowthInside` wraps back to a small number and `inside < last` numerically
///         even though the true accrued growth (`inside - last` mod 2^256) is small and positive.
///         With checked arithmetic this state panics and blocks `getValue`, every vault health check
///         and every liquidation of the position until the borrower touches it.
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with
///      mock 1:1 Chainlink feeds. With the checked subtraction restored the wrapped-snapshot tests fail
///      with Panic(0x11).
contract V4OracleFeeGrowthWrapTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using PositionInfoLibrary for PositionInfo;

    int24 constant TICK_SPACING = 60;
    uint128 constant BACKGROUND_LIQUIDITY = 1000e18;
    uint128 constant POSITION_LIQUIDITY = 100e18;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    V4Oracle oracle;

    struct SwapCallbackData {
        SwapParams params;
    }

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        poolKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(address(0)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);

        // Real oracle: currency1 is the reference token, both tokens priced 1:1 through mock feeds.
        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        MockChainlinkFeed feed = new MockChainlinkFeed(1e8, 8);
        _configureToken(Currency.unwrap(currency0), feed);
        _configureToken(Currency.unwrap(currency1), feed);
        // The scenario moves the pool ~15% away from the (static) feed price; the pool/oracle
        // deviation guard is not what is under test here.
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        // Background liquidity so swaps have something to trade against across the whole range.
        positionManager.mint(
            poolKey,
            TickMath.minUsableTick(TICK_SPACING),
            TickMath.maxUsableTick(TICK_SPACING),
            BACKGROUND_LIQUIDITY,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    /// @notice Builds the wrapped-snapshot state and checks the oracle values the position exactly
    ///         like a Uniswap fee collection does.
    function testWrappedFeeGrowthSnapshotDoesNotRevertAndMatchesCollectedFees() public {
        uint256 tokenId = _buildWrappedSnapshotPosition();

        // Precondition: the state is really wrapped for token0 (numerically inside < last).
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, -1800, -1200);
        (uint128 liquidity, uint256 last0, uint256 last1) = _positionInfo(tokenId);
        assertEq(liquidity, POSITION_LIQUIDITY);
        assertGt(last0, 2 ** 255, "snapshot must be wrapped (numerically huge)");
        assertLt(inside0, last0, "live feeGrowthInside must be numerically below the snapshot");

        // Uniswap's own formula (Position.update): unchecked difference times liquidity.
        uint256 expectedFees0;
        uint256 expectedFees1;
        unchecked {
            expectedFees0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            expectedFees1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
        assertGt(expectedFees0, 0, "scenario must have accrued token0 fees");
        assertGt(expectedFees1, 0, "scenario must have accrued token1 fees");

        // H-01: this reverted with Panic(0x11) under checked subtraction.
        (uint128 oracleLiquidity, uint128 fees0, uint128 fees1) = oracle.getLiquidityAndFees(tokenId);
        assertEq(oracleLiquidity, POSITION_LIQUIDITY);
        assertEq(fees0, expectedFees0, "fees0 must follow the Uniswap formula");
        assertEq(fees1, expectedFees1, "fees1 must follow the Uniswap formula");

        // getValue is what the vault's health check and liquidation depend on. Both tokens are priced
        // 1:1 in the reference token, so the fee value is simply the sum of the two fee amounts.
        (uint256 value, uint256 feeValue,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(feeValue, uint256(fees0) + fees1, "fee value must reflect the wrapped-snapshot fees");
        assertGe(value, feeValue);

        (,,, uint128 breakdownLiquidity,,, uint128 breakdownFees0, uint128 breakdownFees1) =
            oracle.getPositionBreakdown(tokenId);
        assertEq(breakdownLiquidity, POSITION_LIQUIDITY);
        assertEq(breakdownFees0, fees0);
        assertEq(breakdownFees1, fees1);

        // Ground truth: a fee-only DECREASE (liquidity 0) collects exactly what the oracle reported.
        BalanceDelta collected = positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        assertEq(uint256(int256(collected.amount0())), fees0, "collected token0 fees must equal oracle fees0");
        assertEq(uint256(int256(collected.amount1())), fees1, "collected token1 fees must equal oracle fees1");

        // After collection the snapshot is refreshed and nothing is owed.
        (, uint128 fees0After, uint128 fees1After) = oracle.getLiquidityAndFees(tokenId);
        assertEq(fees0After, 0);
        assertEq(fees1After, 0);
    }

    /// @notice The same wrapped snapshot valued while the price sits below the range, exercising the
    ///         `tickCurrent < tickLower` branch of `getFeeGrowthInside` (inside = lower.outside - upper.outside).
    function testWrappedFeeGrowthSnapshotValuedBelowRange() public {
        uint256 tokenId = _buildWrappedSnapshotPosition();

        // Leave the range downwards (this last traversal still accrues in-range fees), then trade
        // only below the range: the position must earn nothing more.
        _swapToTick(true, -2400);
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        assertLt(tick, -1800, "price must be below the range");
        (, uint128 fees0Before, uint128 fees1Before) = oracle.getLiquidityAndFees(tokenId);
        assertGt(fees0Before, 0);

        _swapToTick(true, -3000);
        _swapToTick(false, -2400);

        (uint256 inside0,) = poolManager.getFeeGrowthInside(poolId, -1800, -1200);
        (uint128 liquidity, uint256 last0,) = _positionInfo(tokenId);
        assertLt(inside0, last0, "state must still be wrapped");

        (, uint128 fees0, uint128 fees1) = oracle.getLiquidityAndFees(tokenId);
        assertEq(fees0, fees0Before, "out-of-range position accrues no more token0 fees");
        assertEq(fees1, fees1Before, "out-of-range position accrues no more token1 fees");
        assertEq(liquidity, POSITION_LIQUIDITY);

        BalanceDelta collected = positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        assertEq(uint256(int256(collected.amount0())), fees0);
        assertEq(uint256(int256(collected.amount1())), fees1);
    }

    /// @notice Sanity: a position with a plain (non-wrapped) snapshot is still valued correctly by the
    ///         same code path, so the unchecked subtraction does not change the ordinary case.
    function testPlainSnapshotStillMatchesCollectedFees() public {
        (uint256 tokenId,) = positionManager.mint(
            poolKey, -600, 600, POSITION_LIQUIDITY, type(uint128).max, type(uint128).max, address(this), block.timestamp, ""
        );
        _swapExactIn(true, 5e18);
        _swapExactIn(false, 5e18);

        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, -600, 600);
        (uint128 liquidity, uint256 last0, uint256 last1) = _positionInfo(tokenId);
        assertGe(inside0, last0, "plain snapshot is not wrapped");
        assertGe(inside1, last1, "plain snapshot is not wrapped");

        (, uint128 fees0, uint128 fees1) = oracle.getLiquidityAndFees(tokenId);
        assertEq(fees0, FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128));
        assertEq(fees1, FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128));

        BalanceDelta collected = positionManager.collect(tokenId, 0, 0, address(this), block.timestamp, "");
        assertEq(uint256(int256(collected.amount0())), fees0);
        assertEq(uint256(int256(collected.amount1())), fees1);
    }

    // ---------------------------------------------------------------- scenario

    /// @dev Reproduces the H-01 state for a [-1800, -1200] position with price starting at tick 0:
    ///      1. mint [-1200, -1140]: initializes tick -1200 with feeGrowthOutside0 = 0 (no fees yet)
    ///      2. one 0->1 swap above the range: feeGrowthGlobal0 = g1 > 0
    ///      3. mint [-1800, -1200]: tick -1800 is initialized with feeGrowthOutside0 = g1, so the
    ///         position's snapshot is upper.outside - lower.outside = 0 - g1 (wrapped)
    ///      4. swap the price into the range (crossing -1200 flips its outside to the then-global)
    ///      5. a larger in-range 0->1 swap accrues more than g1 of token0 growth, so the live
    ///         feeGrowthInside0 wraps back below the snapshot
    ///      6. an in-range 1->0 swap so token1 fees are non-zero as well
    function _buildWrappedSnapshotPosition() internal returns (uint256 tokenId) {
        positionManager.mint(
            poolKey, -1200, -1140, 1e18, type(uint128).max, type(uint128).max, address(this), block.timestamp, ""
        );

        _swapExactIn(true, 1e18);
        (uint256 global0,) = poolManager.getFeeGrowthGlobals(poolId);
        assertGt(global0, 0, "first swap must accrue token0 fees");

        (tokenId,) = positionManager.mint(
            poolKey, -1800, -1200, POSITION_LIQUIDITY, type(uint128).max, type(uint128).max, address(this), block.timestamp, ""
        );
        (, uint256 last0,) = _positionInfo(tokenId);
        assertGt(last0, 2 ** 255, "snapshot must be wrapped right after mint");

        // Into the range, then accrue in-range token0 fees well beyond g1.
        _swapToTick(true, -1500);
        _swapToTick(true, -1790);
        // Back up inside the range for token1 fees.
        _swapToTick(false, -1300);

        (, int24 tick,,) = poolManager.getSlot0(poolId);
        assertTrue(tick >= -1800 && tick < -1200, "price must end inside the range");
    }

    function _configureToken(address token, MockChainlinkFeed feed) internal {
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

    function _positionInfo(uint256 tokenId)
        internal
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        return poolManager.getPositionInfo(
            key.toId(), address(positionManager), info.tickLower(), info.tickUpper(), bytes32(tokenId)
        );
    }

    // ---------------------------------------------------------------- swaps

    /// @dev Exact-input swap with no price limit.
    function _swapExactIn(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(
            zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// @dev Swaps with an oversized exact input and a price limit, so the pool stops exactly at
    ///      `targetTick` (as close as the tick math allows).
    function _swapToTick(bool zeroForOne, int24 targetTick) internal returns (BalanceDelta) {
        return _swap(zeroForOne, -int256(1_000_000e18), TickMath.getSqrtPriceAtTick(targetTick));
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        return abi.decode(poolManager.unlock(abi.encode(SwapCallbackData(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(poolKey, data.params, "");

        if (delta.amount0() < 0) {
            currency0.settle(poolManager, address(this), uint256(int256(-delta.amount0())), false);
        } else if (delta.amount0() > 0) {
            currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            currency1.settle(poolManager, address(this), uint256(int256(-delta.amount1())), false);
        } else if (delta.amount1() > 0) {
            currency1.take(poolManager, address(this), uint256(int256(delta.amount1())), false);
        }
        return abi.encode(delta);
    }
}
