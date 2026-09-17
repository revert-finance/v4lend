// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IHookAuctionController
/// @notice Hook-facing interface of the arbitrage-auction controller
interface IHookAuctionController {
    /// @notice Called by the hook from beforeSwap. Syncs epochs, drips vested auction
    ///         proceeds to in-range LPs, and returns the LP fee override for this swap.
    /// @param key The pool key
    /// @param sender The address that called PoolManager.swap
    /// @return lpFeeOverride 0 for no override, otherwise fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
    function beforeSwap(PoolKey calldata key, address sender) external returns (uint24 lpFeeOverride);

    /// @notice Called by the hook before liquidity is added or removed so vested auction
    ///         proceeds are dripped to the liquidity that was in range while they vested.
    /// @param key The pool key
    function beforeLiquidityChange(PoolKey calldata key) external;
}
