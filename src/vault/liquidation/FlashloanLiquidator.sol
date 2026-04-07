// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IVault} from "../interfaces/IVault.sol";
import {Swapper} from "../../shared/swap/Swapper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";


// Uniswap V3 interfaces
interface IUniswapV3Pool {
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    function token0() external view returns (address);
}

interface IUniswapV3FlashCallback {
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}

/// @title Helper contract which allows atomic liquidation and needed swaps by using UniV3 Flashloan
contract FlashloanLiquidator is Swapper, IUniswapV3FlashCallback {
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
        bytes decreaseLiquidityHookData; // hook data for all operations which decrease liquidity (optional)
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
        IUniswapV3Pool flashLoanPool; // pool which is used for flashloan - may not be used in the swaps below
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

        bool isAsset0 = params.flashLoanPool.token0() == Currency.unwrap(asset);
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
        params.flashLoanPool.flash(address(this), isAsset0 ? liquidationCost : 0, !isAsset0 ? liquidationCost : 0, data);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata callbackData) external override {
        // no origin check is needed - because the contract doesn't hold any funds - there is no benefit in calling uniswapV3FlashCallback() from another context

        FlashCallbackData memory data = abi.decode(callbackData, (FlashCallbackData));

        // liquidate the loan
        SafeERC20.forceApprove(IERC20(Currency.unwrap(data.asset)), address(data.vault), data.liquidationCost);
        data.vault.liquidate(
            IVault.LiquidateParams(
                data.tokenId, 
                data.swap0.amountIn, 
                data.swap1.amountIn, 
                address(this), 
                data.deadline,
                data.decreaseLiquidityHookData
            )
        );
        SafeERC20.forceApprove(IERC20(Currency.unwrap(data.asset)), address(data.vault), 0);

        // do swaps
        _routerSwap(data.swap0);
        _routerSwap(data.swap1);

        // transfer lent amount + fee (only one token can have fee) - back to pool
        data.asset.transfer(msg.sender, data.liquidationCost + (fee0 + fee1));

        uint256 balance;

        // return all leftover tokens to liquidator
        if (!(data.swap0.tokenIn == data.asset)) {
            balance = data.swap0.tokenIn.balanceOf(address(this));
            if (balance > 0) {
                data.swap0.tokenIn.transfer(data.liquidator, balance);
            }
        }
        if (!(data.swap1.tokenIn == data.asset)) {
            balance = data.swap1.tokenIn.balanceOf(address(this));
            if (balance > 0) {
                data.swap1.tokenIn.transfer(data.liquidator, balance);
            }
        }
        {
            balance = data.asset.balanceOf(address(this));
            if (balance < data.minReward) {
                revert NotEnoughReward();
            }
            if (balance > 0) {
                data.asset.transfer(data.liquidator, balance);
            }
        }
    }
}
