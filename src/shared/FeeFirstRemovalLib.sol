// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title FeeFirstRemovalLib
/// @notice Encodes the PositionManager batch every supported liquidity removal uses: a zero-liquidity
///         INCREASE with maximal inputs first, then the DECREASE, then TAKE_PAIR.
/// @dev The PositionManager routes a zero-liquidity increase to the pool hook's remove callbacks and
///      lets the hook settle its whole protocol-fee obligation as a caller delta bounded only by the
///      maximal inputs; the DECREASE that follows then releases principal with nothing owed
///      (V4LE-72). One encoder keeps the vault, the transformers, the automators and the hook on the
///      same batch shape.
library FeeFirstRemovalLib {
    /// @notice Parameters of the fee-settling INCREASE_LIQUIDITY(0) that precedes a removal.
    function collectParams(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encode(tokenId, uint256(0), type(uint128).max, type(uint128).max, bytes(""));
    }

    /// @notice Number of decreases a removal of `liquidity` needs when v4 settles at most `chunk` liquidity per
    ///         decrease (0 or >= liquidity: one).
    function decreaseCount(uint256 liquidity, uint256 chunk) internal pure returns (uint256) {
        if (chunk == 0 || chunk >= liquidity) return 1;
        return (liquidity + chunk - 1) / chunk;
    }

    /// @notice Unlock data for a fee-first removal whose payout exceeds what one v4 decrease (or one take)
    ///         can carry: INCREASE(0), then one DECREASE per chunk, then explicit TAKEs of each chunk's
    ///         payout, then TAKE_PAIR for the residual, all in one unlock. v4 narrows every decrease's
    ///         principal and every take's amount to int128 but accumulates the unlock's credit in int256, so
    ///         the whole removal settles atomically and the hook's obligation, taken in the INCREASE(0)
    ///         callback, is netted by all the principal the unlock releases (V4LE-98 / V4LE-156).
    /// @param parts Liquidity of each chunk (each at most what one decrease can pay out)
    /// @param payout0 Token0 each chunk pays out, computed with v4's own formula at the live price
    /// @param payout1 Same for token1
    /// @param charge0 Token0 the hook's obligation takes beyond the accrued fees; consumed by the first
    ///        explicit takes so the residual TAKE_PAIR is the net fee credit plus rounding room only
    /// @param charge1 Same for token1
    function encodeDecreaseChunked(
        uint256 tokenId,
        uint256[] memory parts,
        uint256[] memory payout0,
        uint256[] memory payout1,
        uint256 charge0,
        uint256 charge1,
        bytes memory decreaseLiquidityHookData,
        Currency currency0,
        Currency currency1,
        address recipient
    ) internal pure returns (bytes memory unlockData) {
        uint256 count = parts.length;
        (uint256[] memory take0, uint256 takes0) = _takePieces(payout0, charge0);
        (uint256[] memory take1, uint256 takes1) = _takePieces(payout1, charge1);
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY));
        bytes[] memory params = new bytes[](2 + count + takes0 + takes1);
        params[0] = collectParams(tokenId);
        uint256 k = 1;
        for (uint256 i = 0; i < count; ++i) {
            actions = abi.encodePacked(actions, uint8(Actions.DECREASE_LIQUIDITY));
            params[k++] = abi.encode(tokenId, parts[i], uint256(0), uint256(0), decreaseLiquidityHookData);
        }
        for (uint256 i = 0; i < count; ++i) {
            if (take0[i] != 0) {
                actions = abi.encodePacked(actions, uint8(Actions.TAKE));
                params[k++] = abi.encode(currency0, recipient, take0[i]);
            }
        }
        for (uint256 i = 0; i < count; ++i) {
            if (take1[i] != 0) {
                actions = abi.encodePacked(actions, uint8(Actions.TAKE));
                params[k++] = abi.encode(currency1, recipient, take1[i]);
            }
        }
        actions = abi.encodePacked(actions, uint8(Actions.TAKE_PAIR));
        params[k] = abi.encode(currency0, currency1, recipient);
        return abi.encode(actions, params);
    }

    /// @dev Explicit take of each chunk's payout less one unit of rounding room, with `charge` (principal
    ///      the hook took beyond the fees) consumed by the first pieces; every piece is below what one
    ///      decrease pays out, hence below the int128 bound.
    function _takePieces(uint256[] memory payouts, uint256 charge)
        private
        pure
        returns (uint256[] memory pieces, uint256 count)
    {
        pieces = new uint256[](payouts.length);
        uint256 remainingCharge = charge;
        for (uint256 i = 0; i < payouts.length; ++i) {
            uint256 piece = payouts[i] > 1 ? payouts[i] - 1 : 0;
            if (remainingCharge >= piece) {
                remainingCharge -= piece;
                continue;
            }
            piece -= remainingCharge;
            remainingCharge = 0;
            pieces[i] = piece;
            count++;
        }
    }

    /// @notice Unlock data for a fee-first removal that takes both currencies to `recipient`.
    /// @dev `amount0Min` / `amount1Min` are encoded as given; the PositionManager reads them as uint128,
    ///      so callers that accept wider minima narrow them first.
    function encodeDecrease(
        uint256 tokenId,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        bytes memory decreaseLiquidityHookData,
        Currency currency0,
        Currency currency1,
        address recipient
    ) internal pure returns (bytes memory unlockData) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = collectParams(tokenId);
        params[1] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, decreaseLiquidityHookData);
        params[2] = abi.encode(currency0, currency1, recipient);
        return abi.encode(actions, params);
    }
}
