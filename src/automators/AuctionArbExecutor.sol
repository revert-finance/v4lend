// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title AuctionArbExecutor
/// @notice Owner-operated arbitrage executor intended to be registered as the winning
///         executor of a HookAuctionController epoch. The auction controller recognizes
///         the winner as the contract that calls PoolManager.swap directly, so routes
///         must be executed through this contract (never through shared routers).
/// @dev v1 supports ERC20 pool currencies only.
contract AuctionArbExecutor is IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    struct V4Route {
        Currency startCurrency;
        uint256 amountIn;
        uint256 minProfit;
        address profitRecipient;
        uint256 deadline; // unix seconds
        V4Hop[] hops;
    }

    struct V4Hop {
        PoolKey key;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
    }

    event V4RouteExecuted(Currency indexed startCurrency, uint256 amountIn, uint256 profit, address indexed recipient);

    error OnlyPoolManager();
    error DeadlineExpired();
    error EmptyRoute();
    error InvalidAmount();
    error InvalidRecipient();
    error AmountTooLarge();
    error RouteCurrencyMismatch();
    error UnexpectedSwapDelta();
    error InsufficientProfit(uint256 actualProfit, uint256 minProfit);
    error NativeCurrencyUnsupported();

    constructor(IPoolManager _poolManager, address initialOwner) Ownable(initialOwner) {
        poolManager = _poolManager;
    }

    /// @notice Executes a cyclic exact-input route across v4 pools and sends the profit
    ///         (in the start currency) to the configured recipient.
    function executeV4Route(V4Route calldata route) external onlyOwner nonReentrant returns (uint256 profit) {
        if (block.timestamp > route.deadline) revert DeadlineExpired();
        if (route.hops.length == 0) revert EmptyRoute();
        if (route.amountIn == 0) revert InvalidAmount();
        if (route.amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        if (route.profitRecipient == address(0)) revert InvalidRecipient();
        if (route.startCurrency.isAddressZero()) revert NativeCurrencyUnsupported();

        profit = abi.decode(poolManager.unlock(abi.encode(route)), (uint256));
        emit V4RouteExecuted(route.startCurrency, route.amountIn, profit, route.profitRecipient);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        V4Route memory route = abi.decode(data, (V4Route));
        Currency currentCurrency = route.startCurrency;
        uint256 amountIn = route.amountIn;
        uint256 initialAmountIn = route.amountIn;

        for (uint256 i = 0; i < route.hops.length; i++) {
            V4Hop memory hop = route.hops[i];
            Currency inputCurrency = hop.zeroForOne ? hop.key.currency0 : hop.key.currency1;
            Currency outputCurrency = hop.zeroForOne ? hop.key.currency1 : hop.key.currency0;
            if (!(inputCurrency == currentCurrency)) revert RouteCurrencyMismatch();
            if (inputCurrency.isAddressZero() || outputCurrency.isAddressZero()) revert NativeCurrencyUnsupported();
            if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();

            BalanceDelta delta = poolManager.swap(
                hop.key,
                SwapParams({
                    zeroForOne: hop.zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: hop.sqrtPriceLimitX96
                }),
                ""
            );

            (uint256 amountOwed, uint256 amountOut) = _amountsForExactInput(delta, hop.zeroForOne);
            if (amountOwed != amountIn) revert UnexpectedSwapDelta();

            currentCurrency = outputCurrency;
            amountIn = amountOut;
        }

        if (!(currentCurrency == route.startCurrency)) revert RouteCurrencyMismatch();
        if (amountIn <= initialAmountIn) revert InsufficientProfit(0, route.minProfit);

        uint256 profit = amountIn - initialAmountIn;
        if (profit < route.minProfit) revert InsufficientProfit(profit, route.minProfit);

        // net out: settle what the route consumed against what it produced; only the
        // profit leaves the PoolManager
        poolManager.take(route.startCurrency, route.profitRecipient, profit);

        return abi.encode(profit);
    }

    function _amountsForExactInput(BalanceDelta delta, bool zeroForOne)
        internal
        pure
        returns (uint256 amountOwed, uint256 amountOut)
    {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        if (zeroForOne) {
            if (delta0 >= 0 || delta1 <= 0) revert UnexpectedSwapDelta();
            return (_absNegative(delta0), uint256(uint128(delta1)));
        }

        if (delta1 >= 0 || delta0 <= 0) revert UnexpectedSwapDelta();
        return (_absNegative(delta1), uint256(uint128(delta0)));
    }

    function _absNegative(int128 value) internal pure returns (uint256) {
        unchecked {
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(uint128(-value));
        }
    }
}
