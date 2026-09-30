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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed, ObligationQuoterHook} from "test/oracle/support/OracleMocks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";

/// @title V4OracleFeeObligationTest
/// @notice Valuation and liquidation sizing of a hooked position against the carried protocol-fee
///         obligation its hook's fee quoter reports.
///         - External audit V4LE-139: `getLiquidityForValue` divided by the position's floored principal
///           value, which is zero for a leg whose per-unit quote price is below one Q96 unit although the
///           leg has real value. With a carried obligation in that leg the fee value made the target
///           pass while more value was needed, and the sizing (and with it the vault's liquidation)
///           reverted with a division by zero instead of taking the whole liquidity. A charge the whole
///           live payout cannot fund is reported as `HookChargeUnfundable` (Codex, PR #45).
///         - External audit V4LE-113: a quoted obligation was accepted without the 2^127 settlement bound
///           that fees and principal are held to. The hook takes its whole obligation in the fee-first
///           INCREASE(0) of every removal and narrows it with `SafeCast.toInt128`, so an obligation at or
///           beyond the bound blocks every decrease; the oracle netted it to zero and kept counting the
///           other currency as collateral.
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with mock
///      Chainlink feeds, and a pool hook that only quotes a configurable obligation. currency1 is the
///      reference token, so the derived pool price is currency0's feed price.
contract V4OracleFeeObligationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;
    uint256 constant V4_SETTLEMENT_BOUND = 1 << 127;
    bytes4 constant SETTLEMENT_BOUND_EXCEEDED = bytes4(keccak256("SettlementBoundExceeded()"));
    int24 constant TICK_SPACING = 60;
    uint8 constant FEED_DECIMALS = 8;
    // a pool above this range at tick 700000 leaves the position entirely in token1, whose per-unit
    // price in token0 (~1.0001^-700000) is far below one Q96 unit
    int24 constant SUB_Q96_POOL_TICK = 700000;
    int24 constant SUB_Q96_TICK_LOWER = 699780;
    int24 constant SUB_Q96_TICK_UPPER = 699960;

    Currency currency0;
    Currency currency1;
    V4Oracle oracle;
    ObligationQuoterHook hook;
    MutableChainlinkFeed feed0;
    MutableChainlinkFeed feed1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) ^ (0x4444 << 144));
        deployCodeTo("OracleMocks.sol:ObligationQuoterHook", "", flags);
        hook = ObligationQuoterHook(flags);

        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        oracle.setMaxPoolPriceDifference(200);
        feed0 = new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS);
        feed1 = new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS);
        _configureToken(Currency.unwrap(currency0), feed0);
        _configureToken(Currency.unwrap(currency1), feed1);
        oracle.setHookFeeQuoter(address(hook), address(hook));
    }

    // ---------------------------------------------------------------- V4LE-139: sub-Q96 principal

    function testV4LE139_SubQ96PrincipalWithCarriedObligationSizesAllLiquidity() public {
        (PoolKey memory key, uint256 price0X96) = _initializeHookedPool(SUB_Q96_POOL_TICK);
        uint128 liquidity = 2 ** 50;
        deal(Currency.unwrap(currency1), address(this), uint256(1) << 126);
        uint256 tokenId = _mint(key, SUB_Q96_TICK_LOWER, SUB_Q96_TICK_UPPER, liquidity);
        address quote = Currency.unwrap(currency0);

        // scenario: the token1 principal is real but its floored quote in token0 is zero
        (,,,, uint256 amount0, uint256 amount1,,) = oracle.getPositionBreakdown(tokenId);
        assertEq(amount0, 0, "position holds no token0");
        assertGt(amount1, 0, "position holds token1");
        assertEq(FullMath.mulDiv(amount1, Q96, price0X96), 0, "scenario: principal quote floors to zero");

        // uncollected token0 fees give the position a fee value, and the hook carries an obligation in
        // the sub-Q96 currency worth 600,000 token0 units (more than the principal can fund)
        _writeUncollectedFees0(key, tokenId, SUB_Q96_TICK_LOWER, SUB_Q96_TICK_UPPER, liquidity, 1_000_000);
        hook.setObligation(0, FullMath.mulDiv(600_000, price0X96, Q96));
        (uint256 value, uint256 feeValue,,) = oracle.getValue(tokenId, quote);
        assertEq(value, 1_000_000, "the obligation consumes the sub-Q96 principal, the fees remain");
        assertEq(feeValue, 1_000_000);

        // target below the value, yet the charge means more than the fees is needed: the old code
        // divided by the zero principal value here. The whole payout cannot fund this charge, which is
        // reported as such (Codex, PR #45) instead of a removal whose unlock v4 would reject.
        vm.expectRevert(abi.encodeWithSignature("HookChargeUnfundable()"));
        oracle.getLiquidityForValue(tokenId, quote, 500_000);

        // a fundable charge in the sub-Q96 currency: the fees cover the target and the charge needs half
        // the principal, so the sizing is the charge-funding floor (half the liquidity), with no division
        // by the zero principal value along the way
        hook.setObligation(0, amount1 / 2);
        uint128 sized = oracle.getLiquidityForValue(tokenId, quote, 500_000).liquidity;
        assertEq(sized, liquidity / 2, "sized to fund the charge from the live payout");
    }

    // ---------------------------------------------------------------- V4LE-113: obligation bound

    function testV4LE113_ObligationAtSettlementBoundIsRejectedLikeV4() public {
        (PoolKey memory key,) = _initializeHookedPool(0);
        uint256 tokenId = _mint(key, -600, 600, 2 ** 64);
        address quote = Currency.unwrap(currency1);

        hook.setObligation(V4_SETTLEMENT_BOUND, 0);
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getValue(tokenId, quote);
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getLiquidityForValue(tokenId, quote, 1);
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getPositionBreakdown(tokenId);

        hook.setObligation(0, V4_SETTLEMENT_BOUND);
        vm.expectRevert(SETTLEMENT_BOUND_EXCEEDED);
        oracle.getValue(tokenId, quote);
    }

    function testV4LE113_ObligationJustBelowSettlementBoundIsNetted() public {
        (PoolKey memory key,) = _initializeHookedPool(0);
        uint256 tokenId = _mint(key, -600, 600, 2 ** 64);
        address quote = Currency.unwrap(currency1);

        // the largest settleable obligation consumes the token0 principal; token1 remains collateral
        hook.setObligation(V4_SETTLEMENT_BOUND - 1, 0);
        (,,,, uint256 amount0, uint256 amount1,,) = oracle.getPositionBreakdown(tokenId);
        assertEq(amount0, 0, "token0 principal consumed by the obligation");
        assertGt(amount1, 0, "token1 principal remains");
        (uint256 value, uint256 feeValue,,) = oracle.getValue(tokenId, quote);
        assertEq(value, amount1, "valued at the remaining token1 principal (1:1 prices)");
        assertEq(feeValue, 0);
    }

    /// @dev Pool with the obligation hook at `tick`; the currency0 feed is pointed at that price.
    // ---------------------------------------------------------------- Codex (PR #45): live-payout funding

    /// @dev A carried token0 charge with the oracle price at the range's lower tick (all token0 at the
    ///      derived price) while the live pool sits above the range inside the tolerance (no token0 paid
    ///      out at all): no removal can fund the charge, and the sizing says so instead of reporting a
    ///      removal whose unlock v4 would reject.
    function testCodex_ChargeNoLivePayoutCanFundIsReported() public {
        (PoolKey memory key,) = _initializeHookedPool(0);
        uint128 liquidity = 1e18;
        uint256 tokenId = _mint(key, 0, 60, liquidity);
        _writePoolTick(key.toId(), 60);
        (,,,, uint256 derived0,,,) = oracle.getPositionBreakdown(tokenId);
        assertGt(derived0, 0, "scenario: token0 principal at the derived price");
        (uint256 live0,) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(60), TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(60), liquidity
        );
        assertEq(live0, 0, "scenario: no token0 paid out at the live price");
        hook.setObligation(1e15, 0);
        // still valued (the charge consumes derived principal), but not sizable
        oracle.getValue(tokenId, Currency.unwrap(currency1));
        vm.expectRevert(abi.encodeWithSignature("HookChargeUnfundable()"));
        oracle.getLiquidityForValue(tokenId, Currency.unwrap(currency1), 1);
    }

    /// @dev With the live pool inside the range the token0 payout per liquidity is smaller than at the
    ///      derived price; the funding floor is sized on the live payout so the removal actually releases
    ///      the charge (the derived-price floor released too little and the unlock reverted).
    function testCodex_ChargeFundingFloorUsesLivePayout() public {
        (PoolKey memory key,) = _initializeHookedPool(0);
        uint128 liquidity = 1e18;
        uint256 tokenId = _mint(key, 0, 60, liquidity);
        (,,,, uint256 derived0,,,) = oracle.getPositionBreakdown(tokenId);
        _writePoolTick(key.toId(), 30);
        (uint256 live0,) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(30), TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(60), liquidity
        );
        assertLt(live0, derived0, "scenario: less token0 paid out at the live price than valued");
        uint256 charge0 = derived0 * 4 / 10;
        assertLe(charge0, live0, "scenario: the whole live payout can fund the charge");
        hook.setObligation(charge0, 0);

        IV4Oracle.RemovalPlan memory plan = oracle.getLiquidityForValue(tokenId, Currency.unwrap(currency1), 1);
        assertEq(plan.charge0, charge0);
        uint256 derivedFloor = FullMath.mulDiv(charge0, liquidity, derived0);
        assertGt(plan.liquidity, derivedFloor, "sized beyond the derived-price floor");
        (uint256 paid0,) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(30), TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(60), plan.liquidity
        );
        assertGe(paid0, charge0, "the sized removal's live payout funds the charge");
    }

    /// @dev Writes the pool's slot0 price and tick directly (inside the deviation tolerance).
    function _writePoolTick(PoolId id, int24 tick) internal {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(id);
        uint256 slot0 = uint256(vm.load(address(poolManager), stateSlot));
        uint256 priceAndTickMask = (uint256(1) << 184) - 1;
        slot0 = (slot0 & ~priceAndTickMask) | uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        vm.store(address(poolManager), stateSlot, bytes32(slot0));
    }

    function _initializeHookedPool(int24 tick) internal returns (PoolKey memory key, uint256 price0X96) {
        key = PoolKey(currency0, currency1, 500, TICK_SPACING, IHooks(address(hook)));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        poolManager.initialize(key, sqrtPriceX96);
        uint256 livePriceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
        uint256 answer = Math.mulDiv(livePriceX96, 10 ** FEED_DECIMALS, Q96, Math.Rounding.Ceil);
        feed0.setAnswer(int256(answer));
        price0X96 = FullMath.mulDiv(answer, Q96, 10 ** FEED_DECIMALS);
    }

    function _mint(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        (tokenId,) = positionManager.mint(
            key, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), block.timestamp, ""
        );
    }

    /// @dev Rewrites the position's `feeGrowthInside0LastX128` snapshot so that the v4 fee formula
    ///      `(inside - last) * liquidity / Q128` yields exactly `fees0`.
    function _writeUncollectedFees0(
        PoolKey memory key,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 fees0
    ) internal {
        PoolId id = key.toId();
        (uint256 inside0,) = poolManager.getFeeGrowthInside(id, tickLower, tickUpper);
        uint256 deltaGrowth = FullMath.mulDiv(fees0, FixedPoint128.Q128, liquidity);
        uint256 last0;
        unchecked {
            last0 = inside0 - deltaGrowth;
        }
        bytes32 positionId = keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper, bytes32(tokenId)));
        bytes32 slot = StateLibrary._getPositionInfoSlot(id, positionId);
        vm.store(address(poolManager), bytes32(uint256(slot) + 1), bytes32(last0));

        (uint128 storedLiquidity, uint256 storedLast0,) = poolManager.getPositionInfo(id, positionId);
        assertEq(storedLiquidity, liquidity, "snapshot write hit the right position");
        assertEq(storedLast0, last0, "snapshot written");
        (, uint128 reported0,) = oracle.getLiquidityAndFees(tokenId);
        assertEq(reported0, fees0, "v4 fee formula yields the target amount");
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
