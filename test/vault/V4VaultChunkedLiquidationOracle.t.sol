// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {MockUniswapV3Pool} from "test/utils/MockUniswapV3Pool.sol";
import {V4VaultOracleLiquidationBase, LiquidationCapFeed} from "test/vault/support/V4VaultOracleLiquidationBase.sol";
import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";

/// @notice V4LE-98 / V4LE-156 end to end with the REAL oracle and vault. The oracle source and the live pool
///         move above the range after the loan was opened, so the position's payout is several times the v4
///         int128 bound. One liquidation settles it whole: the vault splits the removal into decreases v4
///         can settle inside one batch, the loan is closed and the liquidator receives the entire payout.
contract V4VaultChunkedLiquidationOracleTest is V4VaultOracleLiquidationBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BOUND = 1 << 127;
    // a range at sqrt price ~2^41: 2^91 liquidity pays ~5 * 2^127 of token1 once the whole range is crossed
    int24 internal constant TICK_LOWER = 568440;
    int24 internal constant TICK_UPPER = 570240;
    int24 internal constant DRIFT_TICK = 570300;
    uint128 internal constant LIQUIDITY = 2 ** 91;

    function testV4LE156_OverBoundPositionIsLiquidatedWholeInOneTransaction() public {
        // the oracle prices currency0 at TICK_LOWER (TWAP source); the pool sits there too
        _pointOracleAt(TICK_LOWER);
        PoolKey memory key = PoolKey(currency0, currency1, 500, 60, IHooks(address(0)));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(TICK_LOWER));
        vault.setLimits(0, 1e50, 1e50, 1e50, 1e50);
        deal(asset, address(this), 1e50);
        vault.deposit(1e48, address(this));
        deal(Currency.unwrap(currency0), address(this), type(uint256).max / 2);

        // minted at its lower tick (all token0, a small amount) and borrowed against
        uint256 tokenId = _mint(key, TICK_LOWER, TICK_UPPER, LIQUIDITY);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vault.create(tokenId, borrower);
        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        vm.prank(borrower);
        vault.borrow(tokenId, collateralValue * 70 / 100);

        // source and live pool move above the range: the payout is all token1, several times the bound
        _pointOracleAt(DRIFT_TICK);
        _writePoolTick(key.toId(), DRIFT_TICK);
        (, uint256 payout1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(DRIFT_TICK),
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            LIQUIDITY
        );
        assertGt(payout1, 2 * BOUND, "scenario: the payout is several times the v4 bound");
        // the pool must be able to pay that token1 out (the price was written, not swapped to)
        deal(Currency.unwrap(currency1), address(poolManager), type(uint256).max / 2);
        // made unhealthy by policy while its value still covers debt plus the maximum penalty
        _setCollateralFactor(uint32(Q32 * 5 / 10));
        (uint256 debt,, uint256 collateralNow,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertGt(debt, collateralNow, "scenario: unhealthy");
        assertGt(liquidationValue, BOUND, "scenario: the liquidation pays more than one decrease settles");

        (, uint256 amount1) = _liquidateAs(liquidator, tokenId);
        assertGt(amount1, BOUND, "paid out more than one v4 decrease can settle, in one transaction");
        assertEq(vault.loans(tokenId), 0, "loan closed");
        assertEq(vault.debtSharesTotal(), 0);
        // a normal-branch liquidation removes the liquidation share; the rest stays in the NFT for the owner
        uint128 left = positionManager.getPositionLiquidity(tokenId);
        assertLt(left, LIQUIDITY, "the liquidation share was removed");
        assertGt(left, 0, "the owner keeps the remainder");
    }

    function _pointOracleAt(int24 tick) internal {
        twapPool = new MockUniswapV3Pool(Currency.unwrap(currency0), asset, tick);
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
    }

    /// @dev Writes the pool's slot0 price and tick directly (swapping ~2^130 tokens is not an option).
    function _writePoolTick(PoolId id, int24 tick) internal {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(id);
        uint256 slot0 = uint256(vm.load(address(poolManager), stateSlot));
        uint256 priceAndTickMask = (uint256(1) << 184) - 1;
        slot0 = (slot0 & ~priceAndTickMask) | uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        vm.store(address(poolManager), stateSlot, bytes32(slot0));
        (uint160 liveSqrtPriceX96, int24 liveTick,,) = poolManager.getSlot0(id);
        assertEq(liveSqrtPriceX96, sqrtPriceX96, "pool price written");
        assertEq(liveTick, tick, "pool tick written");
    }
}
