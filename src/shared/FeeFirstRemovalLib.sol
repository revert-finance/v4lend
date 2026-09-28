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
