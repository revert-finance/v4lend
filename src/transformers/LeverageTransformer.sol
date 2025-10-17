// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import "@uniswap/v4-periphery/src/libraries/Actions.sol";
import "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";

import "../utils/Swapper.sol";
import "../interfaces/IVault.sol";
import "./Transformer.sol";

/// @title LeverageTransformer
/// @notice Functionality to leverage / deleverage positions direcly in one tx
contract LeverageTransformer is Transformer, Swapper {

    /// @notice Permit2 contract
    IPermit2 public immutable permit2;

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2
    )
        Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder) Ownable(msg.sender)
    {
        permit2 = _permit2;
    }

    struct LeverageUpParams {
        // which token to leverage
        uint256 tokenId;
        // how much to borrow
        uint256 borrowAmount;
        // how much of borrowed lend token should be swapped to token0
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // how much of borrowed lend token should be swapped to token1
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // recipient for leftover tokens
        address recipient;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // hook data for all operations which decrease liquidity (optional)
        bytes decreaseLiquidityHookData;
        // hook data for all operations which increase liquidity (optional)
        bytes increaseLiquidityHookData;
    }

    // method called from transform() method in Vault
    function leverageUp(LeverageUpParams calldata params) external {
        _validateCaller(positionManager, params.tokenId);

        // collect fees before
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(params.tokenId, 0, 0, 0, params.decreaseLiquidityHookData, params.deadline);

        uint256 amount = params.borrowAmount;
        IVault(msg.sender).borrow(params.tokenId, amount);
        
        Currency token = Currency.wrap(IVault(msg.sender).asset());

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;
 
        amount0 += token == token0 ? amount : 0;
        amount1 += token == token1 ? amount : 0;

        if (params.amountIn0 != 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token, token0, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            if (token == token1) {
                amount1 -= amountIn;
            }
            amount -= amountIn;
            amount0 += amountOut;
        }
        if (params.amountIn1 != 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token, token1, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            if (token == token0) {
                amount0 -= amountIn;
            }
            amount -= amountIn;
            amount1 += amountOut;
        }

        _handleApproval(permit2, token0, amount0);
        _handleApproval(permit2, token1, amount1);

        uint128 liquidity = _calculateLiquidity(positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1);

        (bytes memory actions, bytes[] memory params_array) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.INCREASE_LIQUIDITY),
            token0,
            token1
        );
        params_array[0] = abi.encode(
            params.tokenId,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            params.increaseLiquidityHookData
        );
       
        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params_array), params.deadline);

        uint256 added0 = amount0 - token0.balanceOfSelf();
        uint256 added1 = amount1 - token1.balanceOfSelf();

        if (added0 < params.amountAddMin0) {
            revert InsufficientAmountAdded();
        }
        if (added1 < params.amountAddMin1) {
            revert InsufficientAmountAdded();
        }

        // send leftover tokens
        if (amount0 > added0) {
            token0.transfer(params.recipient, amount0 - added0);
        }
        if (amount1 > added1) {
            token1.transfer(params.recipient, amount1 - added1);
        }
        if (!(token == token0) && !(token == token1) && amount != 0) {
            token.transfer(params.recipient, amount);
        }
    }

    struct LeverageDownParams {
        // which token to leverage
        uint256 tokenId;
        // for removing - remove liquidity amount
        uint128 liquidity;
        uint256 amountRemoveMin0; // this only applies to liquidity
        uint256 amountRemoveMin1; // this only applies to liquidity

        // how much of token0 should be swapped to lend token
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0; // encoded data for swap
        // how much of token1 should be swapped to lend token
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1; // encoded data for swap
        // recipient for leftover tokens
        address recipient;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // hook data for all operations which increase liquidity (optional)
        bytes decreaseLiquidityHookData;
    }

    // method called from transform() method in Vault
    function leverageDown(LeverageDownParams calldata params) external {
        _validateCaller(positionManager, params.tokenId);

        Currency token = Currency.wrap(IVault(msg.sender).asset());

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;

        // V4 uses different approach - need to use modifyLiquidities with encoded actions
        // Include both DECREASE_LIQUIDITY and TAKE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params_array = new bytes[](2);
        params_array[0] = abi.encode(
            params.tokenId,
            uint256(params.liquidity),
            uint128(params.amountRemoveMin0), // amount0Min
            uint128(params.amountRemoveMin1), // amount1Min
            params.decreaseLiquidityHookData
        );
        params_array[1] = abi.encode(token0, token1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params_array), params.deadline);

        // amounts recieved from decreasing liquidity
        uint256 amount0 = token0.balanceOfSelf();
        uint256 amount1 = token1.balanceOfSelf();

        uint256 amount = token == token0 ? amount0 : (token == token1 ? amount1 : 0);

        if (params.amountIn0 != 0 && !(token == token0)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token0, token, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            amount0 -= amountIn;
            amount += amountOut;
        }
        if (params.amountIn1 != 0 && !(token == token1)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token1, token, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            amount1 -= amountIn;
            amount += amountOut;
        }

        SafeERC20.forceApprove(IERC20(Currency.unwrap(token)), msg.sender, amount);
        (uint256 repayedAmount,) = IVault(msg.sender).repay(params.tokenId, amount, false);

        // send leftover tokens
        if (amount > repayedAmount) {
            token.transfer(params.recipient, amount - repayedAmount);
        }
        if (amount0 != 0 && !(token == token0)) {
            token0.transfer(params.recipient, amount0);
        }
        if (amount1 != 0 && !(token == token1)) {
            token1.transfer(params.recipient, amount1);
        }
    }
}
