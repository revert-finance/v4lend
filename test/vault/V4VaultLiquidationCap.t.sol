// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {MutableChainlinkFeed} from "test/oracle/support/OracleMocks.sol";
import {V4VaultOracleLiquidationBase} from "test/vault/support/V4VaultOracleLiquidationBase.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";

/// @notice External audit V4LE-23: the liquidation quote (fullValue, feeValue, liquidationValue) is priced
///         by the oracle, but the removal settles at the live pool price, which may sit up to
///         maxPoolPriceDifference away. The liquidator received the actual pool delta, worth more than the
///         quote at the oracle's own prices. The payout must be capped at the authorized value.
contract V4VaultLiquidationCapTest is V4VaultOracleLiquidationBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ==================== V4LE-23 ====================

    function testPartialLiquidationPayoutIsCappedAtTheOracleQuote() public {
        uint256 tokenId = _partialLiquidationSetup();

        // live pool 1.5% above the oracle price: inside the 2% tolerance, and the position is now mostly token1
        _movePoolUp(plainKey, 150, DEEP_LIQUIDITY + 1e22);
        (, int24 tick,,) = poolManager.getSlot0(plainKey.toId());
        assertGe(tick, 120, "pool moved");
        assertLe(tick, 179, "still inside the position range");

        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        (uint256 valueNow,, uint256 price0X96, uint256 price1X96) = oracle.getValue(tokenId, asset);
        assertGt(liquidationValue, 0, "liquidatable");
        assertLt(liquidationValue, valueNow, "partial liquidation");

        uint256 owner0Before = currency0.balanceOf(borrower);
        uint256 owner1Before = currency1.balanceOf(borrower);
        (uint256 amount0, uint256 amount1) = _liquidateAs(liquidator, tokenId);

        uint256 received = _oracleValue(amount0, amount1, price0X96, price1X96);
        assertLe(received, liquidationValue, "recipient must not receive more than the quote authorizes");
        assertGt(received, liquidationValue * 999 / 1000, "and receives the quote");
        assertEq(currency0.balanceOf(liquidator), amount0, "returned amounts are what the recipient got");
        assertEq(currency1.balanceOf(liquidator), amount1);

        uint256 ownerExcess = _oracleValue(
            currency0.balanceOf(borrower) - owner0Before, currency1.balanceOf(borrower) - owner1Before, price0X96, price1X96
        );
        assertGt(ownerExcess, liquidationValue / 1000, "the live-price excess stays with the owner");
        assertEq(vault.loans(tokenId), 0, "debt cleared");
    }

    /// @dev Control: with the pool at the oracle price the cap is a no-op and the liquidator receives the quote.
    function testPartialLiquidationAtOraclePricePaysTheQuote() public {
        uint256 tokenId = _partialLiquidationSetup();
        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        (,, uint256 price0X96, uint256 price1X96) = oracle.getValue(tokenId, asset);

        uint256 owner0Before = currency0.balanceOf(borrower);
        uint256 owner1Before = currency1.balanceOf(borrower);
        (uint256 amount0, uint256 amount1) = _liquidateAs(liquidator, tokenId);

        uint256 received = _oracleValue(amount0, amount1, price0X96, price1X96);
        assertLe(received, liquidationValue);
        assertApproxEqRel(received, liquidationValue, 1e9, "the whole quote reaches the liquidator");
        assertLe(currency0.balanceOf(borrower) - owner0Before, 1, "nothing but rounding dust for the owner");
        assertLe(currency1.balanceOf(borrower) - owner1Before, 1);
    }
}

/// @notice External audit V4LE-104: the payout cap valued the removal's proceeds with the per-leg prices
///         getValue returns, which are already rounded to Q96 in asset terms and are zero for a leg whose
///         per-unit asset price is below one Q96 unit. That leg then contributed nothing to the received
///         value, the cap did not bind, and the liquidator kept the whole leg although the removal
///         (settled at a live price inside the tolerance) was worth more than the quote.
/// @dev Same shape as the V4LE-23 cap test, at tick ~700000 with currency0 as the vault asset: one raw
///      token1 is worth ~1.0001^-700000 raw token0, far below 2^-96, so token1's Q96 asset price is zero
///      while the position is mostly token1 once the live pool sits 150 ticks above the oracle price.
///      The oracle is in Chainlink mode with currency1 as reference (the derived pool price is currency0's
///      feed price), so the vault asset is the non-reference token.
contract V4VaultLiquidationSubQ96CapTest is V4VaultOracleLiquidationBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 constant ORACLE_TICK = 700020;
    int24 constant RANGE_UPPER = 700200;
    int24 constant LIVE_TICK = 700170;
    uint128 constant LIQUIDITY = 2 ** 82;
    uint8 constant FEED_DECIMALS = 8;

    function setUp() public override {
        vm.warp(30 days);
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        asset = Currency.unwrap(currency0);

        plainKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        uint160 oracleSqrtPriceX96 = TickMath.getSqrtPriceAtTick(ORACLE_TICK);
        poolManager.initialize(plainKey, oracleSqrtPriceX96);
        uint256 oraclePriceX96 = FullMath.mulDiv(uint256(oracleSqrtPriceX96), uint256(oracleSqrtPriceX96), Q96);

        oracle = new V4Oracle(positionManager, Currency.unwrap(currency1), address(0xdead));
        oracle.setMaxPoolPriceDifference(200);
        _configureToken(Currency.unwrap(currency1), new MutableChainlinkFeed(int256(10 ** FEED_DECIMALS), FEED_DECIMALS));
        uint256 answer = Math.mulDiv(oraclePriceX96, 10 ** FEED_DECIMALS, Q96, Math.Rounding.Ceil);
        _configureToken(Currency.unwrap(currency0), new MutableChainlinkFeed(int256(answer), FEED_DECIMALS));

        vault = new V4Vault(
            "Revert Lend Test", "rlTEST", asset, positionManager, new InterestRateModel(0, 0, 0, 0), oracle, IWETH9(address(0))
        );
        _setBothCollateralFactors(uint32(Q32 * 9 / 10));
        vault.setLimits(0, 1e30, 1e30, 1e30, 1e30);
        vault.setHookAllowList(address(0), true);
        IERC20(asset).approve(address(vault), type(uint256).max);
        vault.deposit(1e12, address(this));
        // the swap that moves the pool up pays ~2^125 raw token1 at this price
        deal(Currency.unwrap(currency1), address(this), uint256(1) << 127);
    }

    function testV4LE104_PayoutCapCountsTheLegWhoseQ96PriceRoundsToZero() public {
        // in range at its lower bound: entirely token0 at the oracle price
        uint256 tokenId = _createLoan(plainKey, ORACLE_TICK, RANGE_UPPER, LIQUIDITY);
        (, uint256 fullValue,,,) = vault.loanInfo(tokenId);
        vm.prank(borrower);
        vault.borrow(tokenId, fullValue * 85 / 100);
        _setBothCollateralFactors(uint32(Q32 * 8 / 10));

        // live pool 1.5% above the oracle price: inside the tolerance, and the position is now mostly token1
        _swapUpTo(LIVE_TICK);
        (, int24 tick,,) = poolManager.getSlot0(plainKey.toId());
        assertGe(tick, LIVE_TICK - 30, "pool moved");
        assertLt(tick, RANGE_UPPER, "still inside the position range");

        // the auditor's premise: token1 has value, but its per-leg price in asset terms rounds to zero
        (uint256 valueNow,, uint256 roundedPrice0X96, uint256 roundedPrice1X96) = oracle.getValue(tokenId, asset);
        IV4Oracle.RemovalPlan memory plan = oracle.getLiquidityForValue(tokenId, asset, 0);
        (uint256 price0X96, uint256 price1X96, uint256 quotePriceX96) = (plan.price0X96, plan.price1X96, plan.quotePriceX96);
        assertEq(roundedPrice0X96, Q96, "asset leg");
        assertEq(roundedPrice1X96, 0, "token1's Q96 asset price rounds to zero");
        assertGt(_rawValue(0, 1e35, price0X96, price1X96, quotePriceX96), 0, "yet token1 has value");
        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertGt(liquidationValue, 0, "liquidatable");
        assertLt(liquidationValue, valueNow, "partial liquidation");

        uint256 owner0Before = currency0.balanceOf(borrower);
        uint256 owner1Before = currency1.balanceOf(borrower);
        (uint256 amount0, uint256 amount1) = _liquidateAs(liquidator, tokenId);
        assertGt(amount1, 0, "the liquidator is paid in the sub-Q96 leg");

        uint256 received = _rawValue(amount0, amount1, price0X96, price1X96, quotePriceX96);
        assertLe(received, liquidationValue, "recipient must not receive more than the quote authorizes");
        assertGt(received, liquidationValue * 999 / 1000, "and receives the quote");
        assertEq(currency0.balanceOf(liquidator), amount0, "returned amounts are what the recipient got");
        assertEq(currency1.balanceOf(liquidator), amount1);

        uint256 ownerExcess = _rawValue(
            currency0.balanceOf(borrower) - owner0Before,
            currency1.balanceOf(borrower) - owner1Before,
            price0X96,
            price1X96,
            quotePriceX96
        );
        assertGt(ownerExcess, liquidationValue / 1000, "the live-price excess stays with the owner");
        assertEq(vault.loans(tokenId), 0, "debt cleared");
    }

    /// @dev Value in asset terms at the oracle's raw prices, as the oracle itself values a position.
    function _rawValue(uint256 amount0, uint256 amount1, uint256 price0X96, uint256 price1X96, uint256 quotePriceX96)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(amount0, price0X96, quotePriceX96) + FullMath.mulDiv(amount1, price1X96, quotePriceX96);
    }

    function _setBothCollateralFactors(uint32 factorX32) internal {
        vault.setTokenConfig(Currency.unwrap(currency0), factorX32, type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), factorX32, type(uint32).max);
    }

    /// @dev Pushes the live pool up to `targetTick` (token1 in) through the borrower's own in-range liquidity.
    function _swapUpTo(int24 targetTick) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(plainKey.toId());
        uint256 amountIn =
            FullMath.mulDiv(LIQUIDITY, TickMath.getSqrtPriceAtTick(targetTick) - sqrtPriceX96, Q96) * 1000 / 997 + 1;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: plainKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
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
