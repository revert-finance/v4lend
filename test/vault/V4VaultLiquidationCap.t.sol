// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockUniswapV3Pool} from "test/utils/MockUniswapV3Pool.sol";

import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @dev Minimal Chainlink-compatible feed; only `decimals()` is consulted in TWAP mode.
contract LiquidationCapFeed {
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice External audit V4LE-23: the liquidation quote (fullValue, feeValue, liquidationValue) is priced
///         by the oracle, but the removal settles at the live pool price, which may sit up to
///         maxPoolPriceDifference away. The liquidator received the actual pool delta, worth more than the
///         quote at the oracle's own prices. The payout must be capped at the authorized value.
/// @dev Fork-free: real PoolManager / PositionManager, a real V4Oracle in TWAP mode whose reference pool is a
///      mock with a fixed tick (the oracle price), so the live v4 pool can be moved inside the tolerance.
///      currency1 is both the oracle's reference token and the vault asset, so prices are 1:1 at tick 0.
contract V4VaultLiquidationCapTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q96 = 2 ** 96;
    uint128 internal constant DEEP_LIQUIDITY = 1e24;

    Currency internal currency0;
    Currency internal currency1;
    address internal asset;
    PoolKey internal plainKey;

    V4Oracle internal oracle;
    MockUniswapV3Pool internal twapPool;
    V4Vault internal vault;

    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public virtual {
        vm.warp(30 days);
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        asset = Currency.unwrap(currency1);

        oracle = new V4Oracle(positionManager, asset, address(0xdead));
        oracle.setMaxPoolPriceDifference(200); // the deployed 2%
        twapPool = new MockUniswapV3Pool(Currency.unwrap(currency0), asset, 0);
        oracle.setTokenConfig(
            Currency.unwrap(currency0),
            AggregatorV3Interface(address(new LiquidationCapFeed())),
            1 days,
            twapPool,
            Currency.unwrap(currency0),
            60,
            V4Oracle.Mode.TWAP,
            type(uint16).max
        );

        vault = new V4Vault(
            "Revert Lend Test",
            "rlTEST",
            asset,
            positionManager,
            new InterestRateModel(0, 0, 0, 0),
            oracle,
            IWETH9(address(0))
        );
        _setCollateralFactor(uint32(Q32 * 9 / 10));
        vault.setLimits(0, 1e30, 1e30, 1e30, 1e30);
        vault.setHookAllowList(address(0), true);

        plainKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(plainKey, V4Constants.SQRT_PRICE_1_1);

        IERC20(asset).approve(address(vault), type(uint256).max);
        vault.deposit(1e24, address(this));
    }

    function _setCollateralFactor(uint32 factorX32) internal {
        vault.setTokenConfig(Currency.unwrap(currency0), factorX32, type(uint32).max);
        vault.setTokenConfig(asset, factorX32, type(uint32).max);
    }

    function _mint(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        (tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            V4Constants.ZERO_BYTES
        );
    }

    function _createLoan(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _mint(key, tickLower, tickUpper, liquidity);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vault.create(tokenId, borrower);
    }

    /// @dev Pushes the live pool up to `targetTick` (token1 in), assuming `liquidity` is active on the way.
    function _movePoolUp(PoolKey memory key, int24 targetTick, uint256 liquidity) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(targetTick);
        uint256 amountIn = FullMath.mulDiv(liquidity, target - Q96, Q96) * 1000 / 997 + 1;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _liquidateAs(address who, uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (,,, uint256 cost,) = vault.loanInfo(tokenId);
        IERC20(asset).transfer(who, cost);
        vm.startPrank(who);
        IERC20(asset).approve(address(vault), cost);
        (amount0, amount1) = vault.liquidate(IVault.LiquidateParams(tokenId, 0, 0, who, block.timestamp, ""));
        vm.stopPrank();
    }

    function _oracleValue(uint256 amount0, uint256 amount1, uint256 price0X96, uint256 price1X96)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(amount0, price0X96, Q96) + FullMath.mulDiv(amount1, price1X96, Q96);
    }

    /// @dev Borrower position covering the 1.8% right above the oracle price: entirely token0 at the oracle
    ///      price and (nearly) entirely token1 once the live pool sits at the top of the range. Borrowed
    ///      to 85% of value, then made unhealthy by lowering the collateral factor to 80% while the value
    ///      still covers debt plus the maximum penalty, so the liquidation is partial.
    function _partialLiquidationSetup() internal returns (uint256 tokenId) {
        _mint(plainKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), DEEP_LIQUIDITY);
        tokenId = _createLoan(plainKey, 0, 180, 1e22);
        (, uint256 fullValue,,,) = vault.loanInfo(tokenId);
        vm.prank(borrower);
        vault.borrow(tokenId, fullValue * 85 / 100);
        _setCollateralFactor(uint32(Q32 * 8 / 10));
    }

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
