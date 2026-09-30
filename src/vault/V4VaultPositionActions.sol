// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency,CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {FeeFirstRemovalLib} from "../shared/FeeFirstRemovalLib.sol";

/// @notice Immutable delegatecall helper for the vault's fee-first position withdrawals.
/// @dev No storage writes. Each vault deploys its own helper with its PositionManager fixed.
contract V4VaultPositionActions {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    IPositionManager private immutable positionManager;
    IPoolManager private immutable poolManager;
    address private immutable self = address(this);
    error DirectCallNotAllowed();
    error TooManyDecreaseChunks();
    /// @dev Bound on the decreases one removal is split into (each pays out at most one v4 int128 amount,
    ///      ~1.7e38 raw units); beyond it the position is not liquidatable in one transaction.
    uint256 internal constant MAX_DECREASE_CHUNKS = 64;
    constructor(IPositionManager manager) {
        positionManager = manager;
        poolManager = manager.poolManager();
    }
    /// @param chunk Largest liquidity v4 can pay out in one decrease at the live price (from the oracle);
    ///        0 or >= liquidityRemove means a single decrease
    /// @param charge0 Token0 the hook's obligation takes beyond the accrued fees (from the oracle)
    /// @param charge1 Same for token1
    function decreaseLiquidity(uint256 tokenId,uint128 liquidityRemove,uint128 chunk,uint256 charge0,uint256 charge1,
        uint256 amount0Min,uint256 amount1Min,uint256 deadline,bytes calldata decreaseLiquidityHookData,address recipient)
        external returns (uint256 amount0,uint256 amount1)
    {
        if (address(this) == self) revert DirectCallNotAllowed();
        uint256 count = FeeFirstRemovalLib.decreaseCount(liquidityRemove, chunk);
        if (count > MAX_DECREASE_CHUNKS) revert TooManyDecreaseChunks();
        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Cache currencies to save gas
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // check balance before decreasing liquidity
        amount0 = currency0.balanceOf(recipient);
        amount1 = currency1.balanceOf(recipient);

        if (count == 1) {
            // fee-first removal: INCREASE(0) settles the hook's protocol fee, then DECREASE and TAKE_PAIR
            positionManager.modifyLiquidities(
                FeeFirstRemovalLib.encodeDecrease(
                    tokenId, liquidityRemove, amount0Min, amount1Min, decreaseLiquidityHookData, currency0, currency1, recipient
                ),
                deadline
            );
        } else {
            // v4 narrows every decrease's principal and every take to int128 but accumulates the unlock's
            // credit in int256: the removal is split into `chunk`-sized decreases and its payout into
            // explicit takes, all inside the one fee-first unlock, so the hook's obligation (taken in the
            // INCREASE(0) callback) is netted by the whole released principal and the position settles
            // whole. Each chunk's payout is computed with v4's own formula at the live price.
            positionManager.modifyLiquidities(
                _chunkedUnlockData(tokenId, poolKey, liquidityRemove, chunk, charge0, charge1, decreaseLiquidityHookData, recipient),
                deadline
            );
        }

        // calculate delta
        amount0 = currency0.balanceOf(recipient) - amount0;
        amount1 = currency1.balanceOf(recipient) - amount1;
    }

    function _chunkedUnlockData(
        uint256 tokenId,
        PoolKey memory poolKey,
        uint128 liquidityRemove,
        uint128 chunk,
        uint256 charge0,
        uint256 charge1,
        bytes calldata decreaseLiquidityHookData,
        address recipient
    ) internal view returns (bytes memory) {
        (, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(PositionInfoLibrary.tickLower(info));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(PositionInfoLibrary.tickUpper(info));
        uint256 count = FeeFirstRemovalLib.decreaseCount(liquidityRemove, chunk);
        uint256[] memory parts = new uint256[](count);
        uint256[] memory payout0 = new uint256[](count);
        uint256[] memory payout1 = new uint256[](count);
        uint256 remaining = liquidityRemove;
        for (uint256 i = 0; i < count; ++i) {
            uint256 part = remaining > chunk ? chunk : remaining;
            remaining -= part;
            parts[i] = part;
            // forge-lint: disable-next-line(unsafe-typecast)
            (payout0[i], payout1[i]) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, uint128(part));
        }
        return FeeFirstRemovalLib.encodeDecreaseChunked(
            tokenId, parts, payout0, payout1, charge0, charge1, decreaseLiquidityHookData, poolKey.currency0, poolKey.currency1, recipient
        );
    }

}
