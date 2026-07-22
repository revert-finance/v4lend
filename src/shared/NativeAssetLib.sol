// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @title NativeAssetLib
/// @notice Shared ETH/WETH helpers for contracts that need to bridge native and wrapped-native flows
library NativeAssetLib {
    using CurrencyLibrary for Currency;

    function nativeValue(Currency token0, Currency token1, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256)
    {
        if (token0.isAddressZero()) return amount0;
        if (token1.isAddressZero()) return amount1;
        return 0;
    }

    /// @notice Returns the contract's whole native balance when one of the pool tokens is native, 0 otherwise.
    /// @dev Used to attach msg.value to modifyLiquidities calls: whole-balance forwarding is only safe
    /// when the action set includes a native SWEEP back to the caller; for non-native pools no value
    /// must be attached, or stray ETH would be donated to the PoolManager.
    function balanceIfNative(Currency token0, Currency token1) internal view returns (uint256) {
        return (token0.isAddressZero() || token1.isAddressZero()) ? address(this).balance : 0;
    }

    function isDirectWrappedNativeSwap(IWETH9 weth, Currency tokenIn, Currency tokenOut)
        internal
        pure
        returns (bool)
    {
        Currency wethCurrency = Currency.wrap(address(weth));
        return (tokenIn == wethCurrency && tokenOut.isAddressZero())
            || (tokenIn.isAddressZero() && tokenOut == wethCurrency);
    }

    function handleDirectWrappedNativeSwap(IWETH9 weth, Currency tokenIn, Currency tokenOut, uint256 amount)
        internal
    {
        if (amount == 0) return;

        Currency wethCurrency = Currency.wrap(address(weth));

        if (tokenIn == wethCurrency && tokenOut.isAddressZero()) {
            weth.withdraw(amount);
        } else if (tokenIn.isAddressZero() && tokenOut == wethCurrency) {
            weth.deposit{value: amount}();
        }
    }

    function wrapIfNative(IWETH9 weth, Currency token, uint256 amount) internal returns (address tokenAddress) {
        tokenAddress = Currency.unwrap(token);
        if (!token.isAddressZero()) {
            return tokenAddress;
        }

        if (amount > 0) {
            weth.deposit{value: amount}();
        }

        return address(weth);
    }

    function unwrapIfNative(IWETH9 weth, Currency token, uint256 amount) internal {
        if (token.isAddressZero() && amount > 0) {
            weth.withdraw(amount);
        }
    }
}
