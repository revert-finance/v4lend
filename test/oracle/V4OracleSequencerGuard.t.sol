// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockUniswapV3Pool} from "test/utils/MockUniswapV3Pool.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleSequencerGuardTest
/// @notice External audit V4LE-2: the L2 sequencer uptime / grace-period guard lived inside
///         `_getChainlinkPriceX96`, so a token in `Mode.TWAP` (the documented emergency fallback) was priced
///         from the v3 pool's observations with no sequencer check at all, and `getPoolSqrtPriceX96` /
///         `getValue` kept returning usable prices while the uptime feed reported the sequencer down or
///         restarting. The guard now runs once per external read, for every mode.
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with a
///      mock uptime feed and a mock v3 TWAP pool; currency1 is the reference token.
contract V4OracleSequencerGuardTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant Q96 = 2 ** 96;
    int24 constant TICK_SPACING = 60;
    uint256 constant START_TIME = 1_000_000;
    uint256 constant GRACE = 600;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    V4Oracle oracle;
    MutableChainlinkFeed sequencerFeed;
    MutableChainlinkFeed feed0;
    MutableChainlinkFeed feed1;
    MockUniswapV3Pool twapPool;
    uint256 tokenId;

    function setUp() public {
        vm.warp(START_TIME);
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        poolKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(address(0)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);

        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        oracle.setMaxPoolPriceDifference(200);
        feed0 = new MutableChainlinkFeed(1e8, 8);
        feed1 = new MutableChainlinkFeed(1e8, 8);
        // v3 reference pool at tick 0: currency0 is worth exactly one reference token
        twapPool = new MockUniswapV3Pool(Currency.unwrap(currency0), Currency.unwrap(currency1), 0);
        _configure(Currency.unwrap(currency0), feed0, V4Oracle.Mode.TWAP);
        _configure(Currency.unwrap(currency1), feed1, V4Oracle.Mode.CHAINLINK);

        // healthy sequencer, restarted long ago
        sequencerFeed = new MutableChainlinkFeed(0, 0);
        sequencerFeed.setRoundTimes(START_TIME - 1 days, START_TIME - 1 days);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));

        (tokenId,) = positionManager.mint(
            poolKey, -600, 600, 1e18, type(uint128).max, type(uint128).max, address(this), block.timestamp, ""
        );
    }

    function testHealthySequencerPricesTwapMode() public view {
        assertEq(oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1)), uint160(Q96));
        (uint256 value,,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertGt(value, 0);
    }

    function testSequencerDownBlocksTwapMode() public {
        sequencerFeed.setAnswer(1);

        vm.expectRevert(abi.encodeWithSignature("SequencerDown()"));
        oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1));
        vm.expectRevert(abi.encodeWithSignature("SequencerDown()"));
        oracle.getValue(tokenId, Currency.unwrap(currency1));
        vm.expectRevert(abi.encodeWithSignature("SequencerDown()"));
        oracle.getLiquidityAndFees(tokenId);
        vm.expectRevert(abi.encodeWithSignature("SequencerDown()"));
        oracle.getPositionBreakdown(tokenId);
    }

    function testSequencerGracePeriodBlocksTwapMode() public {
        // restarted GRACE seconds ago: the grace period is inclusive, so the read is still blocked
        sequencerFeed.setRoundTimes(START_TIME - GRACE, START_TIME - GRACE);

        vm.expectRevert(abi.encodeWithSignature("SequencerGracePeriodNotOver()"));
        oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1));
        vm.expectRevert(abi.encodeWithSignature("SequencerGracePeriodNotOver()"));
        oracle.getValue(tokenId, Currency.unwrap(currency1));

        // one second later the grace period is over
        vm.warp(START_TIME + 1);
        assertEq(oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1)), uint160(Q96));
        (uint256 value,,,) = oracle.getValue(tokenId, Currency.unwrap(currency1));
        assertGt(value, 0);
    }

    function testSequencerDownStillBlocksChainlinkMode() public {
        _configure(Currency.unwrap(currency0), feed0, V4Oracle.Mode.CHAINLINK);
        sequencerFeed.setAnswer(1);

        vm.expectRevert(abi.encodeWithSignature("SequencerDown()"));
        oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1));
        vm.expectRevert(abi.encodeWithSignature("SequencerDown()"));
        oracle.getValue(tokenId, Currency.unwrap(currency1));
    }

    function testSequencerFeedIsConsultedOncePerValueRead() public {
        // two Chainlink legs (currency0 and the reference token) used to trigger two sequencer reads
        _configure(Currency.unwrap(currency0), feed0, V4Oracle.Mode.CHAINLINK);
        vm.expectCall(address(sequencerFeed), abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), 1);
        oracle.getValue(tokenId, Currency.unwrap(currency1));
    }

    function testSequencerFeedIsConsultedOncePerPriceRead() public {
        _configure(Currency.unwrap(currency0), feed0, V4Oracle.Mode.CHAINLINK);
        vm.expectCall(address(sequencerFeed), abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), 1);
        oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1));
    }

    function _configure(address token, MutableChainlinkFeed feed, V4Oracle.Mode mode) internal {
        oracle.setTokenConfig(
            token,
            AggregatorV3Interface(address(feed)),
            1 days,
            token == Currency.unwrap(currency0) ? twapPool : IUniswapV3Pool(address(0)),
            address(0),
            1800,
            mode,
            type(uint16).max
        );
    }
}
