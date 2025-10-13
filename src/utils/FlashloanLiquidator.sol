// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import "../interfaces/IVault.sol";
import "./Swapper.sol";

/// @title Helper contract which allows atomic liquidation and needed swaps by using UniV3 Flashloan
contract FlashloanLiquidator is Swapper, IUnlockCallback {
    struct FlashCallbackData {
        uint256 tokenId;
        uint256 liquidationCost;
        IVault vault;
        Currency asset;
        RouterSwapParams swap0;
        RouterSwapParams swap1;
        address liquidator;
        uint256 minReward;
        uint256 deadline;
        bytes decreaseLiquidityHookData;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder
    )
        Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder)
    {}

    struct LiquidateParams {
        uint256 tokenId; // loan to liquidate
        IVault vault; // vault where the loan is
        uint256 amount0In; // how much of token0 to swap to asset (0 if no swap should be done)
        bytes swapData0; // swap data for token0 swap
        uint256 amount1In; // how much of token1 to swap to asset (0 if no swap should be done)
        bytes swapData1; // swap data for token1 swap
        uint256 minReward; // min reward amount (works as a global slippage control for complete operation)
        uint256 deadline; // deadline for uniswap operations
        bytes decreaseLiquidityHookData; // hook data for all operations which decrease liquidity (optional)
    }

    /// @notice Liquidates a loan, using a Uniswap Flashloan
    function liquidate(LiquidateParams calldata params) external {
        (,,, uint256 liquidationCost, uint256 liquidationValue) = params.vault.loanInfo(params.tokenId);
        if (liquidationValue == 0) {
            revert NotLiquidatable();
        }

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;

        Currency asset = Currency.wrap(params.vault.asset());

        bytes memory data = abi.encode(
            FlashCallbackData(
                params.tokenId,
                liquidationCost,
                params.vault,
                asset,
                RouterSwapParams(token0, asset, params.amount0In, 0, params.swapData0),
                RouterSwapParams(token1, asset, params.amount1In, 0, params.swapData1),
                msg.sender,
                params.minReward,
                params.deadline,
                params.decreaseLiquidityHookData
            )
        );
        poolManager.unlock(data);
    }

    /// @notice Callback to handle the flashloan.
    /// @param data The encoded token address.
    /// @return retdata Arbitrary data (implicit return).
    function unlockCallback(bytes calldata data) external override returns (bytes memory retdata) {
        
        FlashCallbackData memory flashCallbackData = abi.decode(data, (FlashCallbackData));

        // take the needed amount of assets
        poolManager.take(flashCallbackData.asset, address(this), flashCallbackData.liquidationCost);

        // liquidate the loan
        SafeERC20.forceApprove(IERC20(Currency.unwrap(flashCallbackData.asset)), address(flashCallbackData.vault), flashCallbackData.liquidationCost);
        flashCallbackData.vault.liquidate(
            IVault.LiquidateParams(
                flashCallbackData.tokenId, 
                flashCallbackData.swap0.amountIn, 
                flashCallbackData.swap1.amountIn, 
                address(this), 
                flashCallbackData.deadline,
                flashCallbackData.decreaseLiquidityHookData
            )
        );

        SafeERC20.forceApprove(IERC20(Currency.unwrap(flashCallbackData.asset)), address(flashCallbackData.vault), 0);

        // do swaps
        _routerSwap(flashCallbackData.swap0);
        _routerSwap(flashCallbackData.swap1);

        // sync the balance before repayment with `sync`
        poolManager.sync(flashCallbackData.asset);
        // repay the flashloan
        flashCallbackData.asset.transfer(address(poolManager), flashCallbackData.liquidationCost);
        // settle the balance after repayment with `settle`.
        poolManager.settle();

        uint256 balance;

        // return all leftover tokens to liquidator
        if (!(flashCallbackData.swap0.tokenIn == flashCallbackData.asset)) {
            balance = flashCallbackData.swap0.tokenIn.balanceOf(address(this));
            if (balance != 0) {
                flashCallbackData.swap0.tokenIn.transfer(flashCallbackData.liquidator, balance);
            }
        }
        if (!(flashCallbackData.swap1.tokenIn == flashCallbackData.asset)) {
            balance = flashCallbackData.swap1.tokenIn.balanceOf(address(this));
            if (balance != 0) {
                flashCallbackData.swap1.tokenIn.transfer(flashCallbackData.liquidator, balance);
            }
        }
        {
            balance = flashCallbackData.asset.balanceOf(address(this));
            if (balance < flashCallbackData.minReward) {
                revert NotEnoughReward();
            }
            if (balance != 0) {
                flashCallbackData.asset.transfer(flashCallbackData.liquidator, balance);
            }
        }

        // return empty bytes
        return new bytes(0);
    }
}
