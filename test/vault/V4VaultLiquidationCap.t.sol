// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {V4VaultOracleLiquidationBase} from "test/vault/support/V4VaultOracleLiquidationBase.sol";

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
