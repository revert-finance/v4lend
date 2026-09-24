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

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed} from "test/oracle/support/OracleMocks.sol";

/// @title V4OracleSettlementBoundTest
/// @notice Uniswap v4 settles every fee and principal amount of a `modifyLiquidity` call through
///         `SafeCast.toInt128`, which rejects amounts >= 2^127. The oracle must not certify such amounts as
///         collateral: it reports them with `SettlementBoundExceeded`.
///         - External audit V4LE-6: `_calculateUncollectedFees` narrowed with `SafeCast.toUint128` and so
///           accepted fee amounts in [2^127, 2^128) that v4 can never pay out (fees are settled on every
///           collection and liquidity decrease of the position).
/// @dev Fork-free: real PoolManager / PositionManager from BaseTest, mock tokens, a real V4Oracle with mock
///      1:1 Chainlink feeds. The oversized fee snapshot is written straight into PoolManager storage.
contract V4OracleSettlementBoundTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant Q96 = 2 ** 96;
    uint256 constant V4_SETTLEMENT_BOUND = 1 << 127;
    // by signature so the test compiles against the pre-fix oracle and fails there at runtime
    bytes4 constant SETTLEMENT_BOUND_EXCEEDED = bytes4(keccak256("SettlementBoundExceeded()"));
    int24 constant TICK_SPACING = 60;
    int24 constant FEE_TICK_LOWER = -600;
    int24 constant FEE_TICK_UPPER = 600;
    uint128 constant FEE_POSITION_LIQUIDITY = 2 ** 64;

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
        feed0 = new MutableChainlinkFeed(1e8, 8);
        feed1 = new MutableChainlinkFeed(1e8, 8);
        _configureToken(Currency.unwrap(currency0), feed0);
        _configureToken(Currency.unwrap(currency1), feed1);
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
