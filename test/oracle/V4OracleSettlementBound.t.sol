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
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleSettlementBoundTest
/// @notice Uniswap v4 settles every fee and principal amount of a `modifyLiquidity` call, and every take,
///         through `SafeCast.toInt128`, which rejects amounts >= 2^127. A position cannot pay out more of a
///         currency than exists, so the oracle accepts only tokens whose total supply is below that bound
///         (constructor and `setTokenConfig`, `SettlementBoundExceeded`); fees at or beyond it are reported the
///         same way (v4 could never collect them). The valuation never bounds principal.
///         - External audit V4LE-6: `_calculateUncollectedFees` narrowed with `SafeCast.toUint128` and so
///           accepted fee amounts in [2^127, 2^128) that v4 can never pay out (fees are settled on every
///           collection and liquidity decrease of the position).
///         - External audit V4LE-61: `_getAmounts` returned unbounded uint256 principal amounts, so a
///           position whose current-side principal grew past 2^127 (the pool price crossed its range) was
///           valued and borrowable while v4 rejects the decrease that a liquidation or full withdrawal needs.
///         - External audit V4LE-98: that bound was checked at the oracle-derived price only, while v4
///           settles the decrease at the live pool price, which may sit up to maxPoolPriceDifference away.
///         - External audit V4LE-156: a bound inside the valuation was itself a liquidation lockout once the
///           price drifted past it. The principal tests below build that state with dealt balances far beyond
///           the mock tokens' supply: it is unreachable for a configured token, and the oracle keeps valuing it.
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with mock
///      Chainlink feeds. The oversized fee snapshot and the post-crossing pool price are written straight
///      into PoolManager storage.
contract V4OracleSettlementBoundTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;
    // v4's int128 narrowing of every settled amount; the oracle's bound on token supply and fees
    uint256 constant V4_SETTLEMENT_BOUND = 1 << 127;
    // by signature so the test compiles against the pre-fix oracle and fails there at runtime
    bytes4 constant SETTLEMENT_BOUND_EXCEEDED = bytes4(keccak256("SettlementBoundExceeded()"));
    int24 constant TICK_SPACING = 60;
    int24 constant FEE_TICK_LOWER = -600;
    int24 constant FEE_TICK_UPPER = 600;
    uint128 constant FEE_POSITION_LIQUIDITY = 2 ** 64;
    int24 constant PRINCIPAL_TICK_LOWER = 600000;
    int24 constant PRINCIPAL_TICK_UPPER = 600060;
    int24 constant CROSSED_TICK = 600100;
    // V4LE-98: a range at sqrt price ~2^41 whose live price sits 180 ticks (1.8%, inside the 2% tolerance)
    // above the oracle price at its lower bound
    int24 constant LIVE_TICK_LOWER = 568440;
    int24 constant LIVE_TICK_UPPER = 568800;
    int24 constant LIVE_TICK = 568620;
    uint8 constant FEED_DECIMALS = 8;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    V4Oracle oracle;
    MutableChainlinkFeed feed0;
    MutableChainlinkFeed feed1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        poolKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(address(0)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);

        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        oracle.setMaxPoolPriceDifference(200);
        feed0 = new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS);
        feed1 = new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS);
        _configureToken(Currency.unwrap(currency0), feed0);
        _configureToken(Currency.unwrap(currency1), feed1);
    }

    // ---------------------------------------------------------------- token supply

    function testTokenWithSupplyAtSettlementBoundIsNotConfigurable() public {
        MockERC20 token = new MockERC20("Huge", "HUGE", 18);
        token.mint(address(this), V4_SETTLEMENT_BOUND - 1);
        _configureToken(address(token), feed0);
        token.mint(address(this), 1);
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        _configureToken(address(token), feed0);
        // the reference token is held to the same bound
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        new V4Oracle(positionManager, address(token), address(0xdead));
    }

    // ---------------------------------------------------------------- V4LE-6: fees

    function testFeeAtSettlementBoundIsRejectedLikeV4() public {
        uint256 tokenId = _mintFeePosition();
        _writeUncollectedFees0(tokenId, V4_SETTLEMENT_BOUND);

        // v4 ground truth: the fee cannot be collected and the liquidity cannot be decreased
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        positionManager.modifyLiquidities(_decreaseCalldata(tokenId, 0), block.timestamp);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        positionManager.modifyLiquidities(_decreaseCalldata(tokenId, FEE_POSITION_LIQUIDITY), block.timestamp);

        // the oracle refuses to count it as collateral (the old code reported fees0 == 2^127)
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getLiquidityAndFees(tokenId);
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getValue(tokenId, Currency.unwrap(currency1));
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getPositionBreakdown(tokenId);
    }

    function testFeeJustBelowSettlementBoundIsReported() public {
        uint256 tokenId = _mintFeePosition();
        _writeUncollectedFees0(tokenId, V4_SETTLEMENT_BOUND - 1);

        (uint128 liquidity, uint128 fees0, uint128 fees1) = oracle.getLiquidityAndFees(tokenId);
        assertEq(liquidity, FEE_POSITION_LIQUIDITY);
        assertEq(fees0, V4_SETTLEMENT_BOUND - 1, "largest v4-settleable fee is reported");
        assertEq(fees1, 0);

        (, uint256 feeValue,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(feeValue, V4_SETTLEMENT_BOUND - 1, "fee value follows at the 1:1 price");
    }

    // ---------------------------------------------------------------- V4LE-61 / V4LE-156: principal

    function testPrincipalBeyondSettlementBoundStaysValued() public {
        // minted below its range with a small token0 amount, then the pool price crosses above it
        uint128 liquidity = 2 ** 93;
        uint256 tokenId = _mintPrincipalPosition(liquidity);
        _crossAboveRange();
        uint256 amount1 = _principalAmount1(liquidity);
        assertGe(amount1, V4_SETTLEMENT_BOUND, "scenario: token1 principal at or above the v4 bound");
        assertGt(amount1, currency1Supply(), "scenario: more token1 than exists; unreachable for a configured token");

        // v4 ground truth: one decrease of everything reverts at the int128 narrowing
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        positionManager.modifyLiquidities(_decreaseCalldata(tokenId, liquidity), block.timestamp);

        // the oracle keeps valuing the position: a bound here was the V4LE-156 liquidation lockout
        (uint256 value, uint256 feeValue,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(value, amount1, "valued at its token1 principal");
        assertEq(feeValue, 0);
        (,,,,, uint256 breakdown1,,) = oracle.getPositionBreakdown(tokenId);
        assertEq(breakdown1, amount1);
        (uint128 sized,,,) = oracle.getLiquidityForValue(tokenId, Currency.unwrap(currency1), value);
        assertEq(sized, liquidity, "sized whole");
        oracle.validateBorrow(tokenId, Currency.unwrap(currency1));
    }

    function testPrincipalJustBelowSettlementBoundSettlesWholeAfterCrossing() public {
        uint128 liquidity = 2 ** 92;
        uint256 tokenId = _mintPrincipalPosition(liquidity);
        _crossAboveRange();
        uint256 amount1 = _principalAmount1(liquidity);
        assertLt(amount1, V4_SETTLEMENT_BOUND, "control: token1 principal below the v4 bound");
        assertGt(amount1, V4_SETTLEMENT_BOUND / 4, "control: still a huge position");

        (uint256 value, uint256 feeValue,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(value, amount1, "valued at its token1 principal");
        assertEq(feeValue, 0);
        (,,,, uint256 breakdown0, uint256 breakdown1,,) = oracle.getPositionBreakdown(tokenId);
        assertEq(breakdown0, 0);
        assertEq(breakdown1, amount1);
        (uint128 sized,,,) = oracle.getLiquidityForValue(tokenId, Currency.unwrap(currency1), value);
        assertEq(sized, liquidity);

        // v4 ground truth: one decrease settles all of it
        deal(Currency.unwrap(currency1), address(poolManager), type(uint256).max / 2);
        positionManager.modifyLiquidities(_decreaseCalldata(tokenId, liquidity), block.timestamp);
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "settled whole");
    }

    // ---------------------------------------------------------------- V4LE-98: live-price principal

    function testV4LE98_LivePrincipalBeyondSettlementBoundStaysValued() public {
        uint128 liquidity = 2 ** 95;
        (PoolKey memory key, uint256 tokenId) = _mintLiveDeviationPosition(liquidity);

        // scenario: the composition at the oracle price is tiny, the one v4 would settle at is not
        (uint256 derived0, uint256 derived1) = _liveDeviationAmounts(LIVE_TICK_LOWER, liquidity);
        (, uint256 live1) = _liveDeviationAmounts(LIVE_TICK, liquidity);
        assertLt(derived0, V4_SETTLEMENT_BOUND, "scenario: derived-side token0 principal is settleable");
        assertLt(derived1, V4_SETTLEMENT_BOUND, "scenario: derived-side token1 principal is settleable");
        assertGe(live1, V4_SETTLEMENT_BOUND, "scenario: live-side token1 principal at or above the v4 bound");
        assertGt(live1, currency1Supply(), "scenario: more token1 than exists; unreachable for a configured token");
        assertLe(_priceDeviationBps(key), 200, "scenario: live price inside the deviation tolerance");

        // v4 ground truth: one decrease of everything reverts at the int128 narrowing of the live token1 delta
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        positionManager.modifyLiquidities(_decreaseCalldata(tokenId, liquidity), block.timestamp);

        // the oracle keeps valuing the position (a snapshot bound here was the V4LE-156 liquidation lockout)
        (uint256 value,, uint256 price0X96,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(value, FullMath.mulDiv(price0X96, derived0, Q96), "valued at the derived composition");
        oracle.getPositionBreakdown(tokenId);
        (uint128 sized,,,) = oracle.getLiquidityForValue(tokenId, Currency.unwrap(currency1), value);
        assertEq(sized, liquidity, "sized whole");
    }

    function testV4LE98_LivePrincipalJustBelowSettlementBoundSettlesWhole() public {
        uint128 liquidity = 2 ** 92;
        (, uint256 tokenId) = _mintLiveDeviationPosition(liquidity);
        (uint256 derived0,) = _liveDeviationAmounts(LIVE_TICK_LOWER, liquidity);
        (, uint256 live1) = _liveDeviationAmounts(LIVE_TICK, liquidity);
        assertLt(live1, V4_SETTLEMENT_BOUND, "control: live-side token1 principal below the v4 bound");
        assertGt(live1, V4_SETTLEMENT_BOUND / 8, "control: still a huge position");

        (uint256 value, uint256 feeValue, uint256 price0X96,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertEq(value, FullMath.mulDiv(price0X96, derived0, Q96), "valued at the derived composition");
        assertEq(feeValue, 0);

        // v4 ground truth: one decrease settles all of it at the live price
        deal(Currency.unwrap(currency1), address(poolManager), type(uint256).max / 2);
        positionManager.modifyLiquidities(_decreaseCalldata(tokenId, liquidity), block.timestamp);
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "settled whole");
    }

    function currency1Supply() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency1)).totalSupply();
    }

    /// @dev A second pool (different fee tier) at LIVE_TICK_LOWER: the position is minted in range at its
    ///      lower bound (all token0), the currency0 feed is pointed at that price and the live pool is then
    ///      moved 180 ticks up inside the range (no tick is crossed, so the pool state stays consistent).
    function _mintLiveDeviationPosition(uint128 liquidity) internal returns (PoolKey memory key, uint256 tokenId) {
        key = PoolKey(currency0, currency1, 500, TICK_SPACING, IHooks(address(0)));
        uint160 lowerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(LIVE_TICK_LOWER);
        poolManager.initialize(key, lowerSqrtPriceX96);
        uint256 lowerPriceX96 = FullMath.mulDiv(uint256(lowerSqrtPriceX96), uint256(lowerSqrtPriceX96), Q96);
        feed0.setAnswer(int256(FullMath.mulDiv(lowerPriceX96, 10 ** FEED_DECIMALS, Q96)));
        (tokenId,) = positionManager.mint(
            key,
            LIVE_TICK_LOWER,
            LIVE_TICK_UPPER,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
        _writePoolTick(key.toId(), LIVE_TICK);
    }

    function _liveDeviationAmounts(int24 tick, uint128 liquidity) internal pure returns (uint256, uint256) {
        return LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(tick),
            TickMath.getSqrtPriceAtTick(LIVE_TICK_LOWER),
            TickMath.getSqrtPriceAtTick(LIVE_TICK_UPPER),
            liquidity
        );
    }

    /// @dev Live pool price against the currency0 feed price, as the oracle's deviation check measures it.
    function _priceDeviationBps(PoolKey memory key) internal view returns (uint256) {
        (uint160 liveSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 livePriceX96 = FullMath.mulDiv(uint256(liveSqrtPriceX96), uint256(liveSqrtPriceX96), Q96);
        (, int256 answer,,,) = feed0.latestRoundData();
        uint256 derivedPriceX96 = FullMath.mulDiv(uint256(answer), Q96, 10 ** FEED_DECIMALS);
        uint256 difference = livePriceX96 > derivedPriceX96 ? livePriceX96 - derivedPriceX96 : derivedPriceX96 - livePriceX96;
        return FullMath.mulDiv(difference, 10000, derivedPriceX96);
    }

    function _mintPrincipalPosition(uint128 liquidity) internal returns (uint256 tokenId) {
        (tokenId,) = positionManager.mint(
            poolKey,
            PRINCIPAL_TICK_LOWER,
            PRINCIPAL_TICK_UPPER,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    /// @dev Moves the pool's slot0 above the principal range (no active liquidity is in the way of such
    ///      a crossing on a real pool; writing it directly avoids swapping ~2^127 tokens) and points the
    ///      currency0 feed at the new price so the oracle's pool/feed deviation check passes.
    function _crossAboveRange() internal {
        uint160 sqrtPriceX96 = _writePoolTick(poolId, CROSSED_TICK);
        uint256 livePriceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
        feed0.setAnswer(int256(FullMath.mulDiv(livePriceX96, 10 ** FEED_DECIMALS, Q96)));
    }

    /// @dev Writes the pool's slot0 price and tick directly.
    function _writePoolTick(PoolId id, int24 tick) internal returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(id);
        uint256 slot0 = uint256(vm.load(address(poolManager), stateSlot));
        uint256 priceAndTickMask = (uint256(1) << 184) - 1;
        slot0 = (slot0 & ~priceAndTickMask) | uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        vm.store(address(poolManager), stateSlot, bytes32(slot0));
        (uint160 liveSqrtPriceX96, int24 liveTick,,) = poolManager.getSlot0(id);
        assertEq(liveSqrtPriceX96, sqrtPriceX96, "pool price written");
        assertEq(liveTick, tick, "pool tick written");
    }

    /// @dev Token1 principal of a position entirely above its range, as v4 computes it: its maximum payout.
    function _principalAmount1(uint128 liquidity) internal pure returns (uint256) {
        return LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtPriceAtTick(PRINCIPAL_TICK_LOWER), TickMath.getSqrtPriceAtTick(PRINCIPAL_TICK_UPPER), liquidity
        );
    }

    function _mintFeePosition() internal returns (uint256 tokenId) {
        (tokenId,) = positionManager.mint(
            poolKey,
            FEE_TICK_LOWER,
            FEE_TICK_UPPER,
            FEE_POSITION_LIQUIDITY,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            ""
        );
    }

    /// @dev Rewrites the position's `feeGrowthInside0LastX128` snapshot so that the v4 fee formula
    ///      `(inside - last) * liquidity / Q128` yields exactly `fees0`.
    function _writeUncollectedFees0(uint256 tokenId, uint256 fees0) internal {
        (uint256 inside0,) = poolManager.getFeeGrowthInside(poolId, FEE_TICK_LOWER, FEE_TICK_UPPER);
        uint256 deltaGrowth = FullMath.mulDiv(fees0, FixedPoint128.Q128, FEE_POSITION_LIQUIDITY);
        uint256 last0;
        unchecked {
            last0 = inside0 - deltaGrowth;
        }

        bytes32 positionId =
            keccak256(abi.encodePacked(address(positionManager), FEE_TICK_LOWER, FEE_TICK_UPPER, bytes32(tokenId)));
        bytes32 slot = StateLibrary._getPositionInfoSlot(poolId, positionId);
        vm.store(address(poolManager), bytes32(uint256(slot) + 1), bytes32(last0));

        (uint128 liquidity, uint256 storedLast0,) = poolManager.getPositionInfo(poolId, positionId);
        assertEq(liquidity, FEE_POSITION_LIQUIDITY, "snapshot write hit the right position");
        assertEq(storedLast0, last0, "snapshot written");
        uint256 expectedFees;
        unchecked {
            expectedFees = FullMath.mulDiv(inside0 - storedLast0, liquidity, FixedPoint128.Q128);
        }
        assertEq(expectedFees, fees0, "v4 fee formula yields the target amount");
    }

    /// @dev DECREASE_LIQUIDITY + TAKE_PAIR, as EasyPosm encodes it, for a direct (revert-checkable) call.
    function _decreaseCalldata(uint256 tokenId, uint256 liquidityToRemove) internal view returns (bytes memory) {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidityToRemove, uint256(0), uint256(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));
        return abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);
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
