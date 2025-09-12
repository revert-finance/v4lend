// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import "./lib/IWETH9.sol";
import "./lib/IUniversalRouter.sol";
import "./Constants.sol";

// base functionality to do swaps with different routing protocols
abstract contract Swapper is Constants {
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Wrapped native token address
    IWETH9 public immutable weth;

    /// @notice Uniswap v4 position manager
    IPositionManager public immutable positionManager;

    /// @notice Uniswap Universal Router
    address public immutable universalRouter;

    /// @notice 0x Protocol AllowanceHolder contract
    address public immutable zeroxAllowanceHolder;

    /// @notice Constructor
    /// @param _positionManager Uniswap v4 position manager
    /// @param _universalRouter Uniswap Universal Router
    /// @param _zeroxAllowanceHolder 0x Protocol AllowanceHolder contract
    constructor(
        IWETH9 _weth,
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) {
        weth = _weth;
        positionManager = _positionManager;
        universalRouter = _universalRouter;
        zeroxAllowanceHolder = _zeroxAllowanceHolder;
    }


    // swap data for uni - must include sweep for input token
    struct UniversalRouterData {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    struct RouterSwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns token amounts deltas after swap
    function _routerSwap(RouterSwapParams memory params)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (params.amountIn != 0 && params.swapData.length != 0 && address(params.tokenOut) != address(0) && address(params.tokenIn) != address(0)) {
            uint256 balanceInBefore = params.tokenIn.balanceOf(address(this));
            uint256 balanceOutBefore = params.tokenOut.balanceOf(address(this));

            // Check if this is Universal Router data by looking at first 32 bytes
            bool isUniversalRouter;
            bytes memory swapData = params.swapData;
            address uniRouter = universalRouter;
            assembly {
                let firstWord := mload(add(swapData, 32))
                isUniversalRouter := eq(firstWord, uniRouter)
            }

            if (isUniversalRouter) {
                // Handle Universal Router case
                (address target, bytes memory routerData) = abi.decode(params.swapData, (address, bytes));
                UniversalRouterData memory data = abi.decode(routerData, (UniversalRouterData));
                SafeERC20.safeTransfer(params.tokenIn, universalRouter, params.amountIn);
                IUniversalRouter(universalRouter).execute(data.commands, data.inputs, data.deadline);
            } else {
                // For 0x v2, use raw data
                SafeERC20.safeIncreaseAllowance(params.tokenIn, zeroxAllowanceHolder, params.amountIn);
                (bool success,) = zeroxAllowanceHolder.call(params.swapData);
                if (!success) {
                    revert SwapFailed();
                }
                SafeERC20.forceApprove(params.tokenIn, zeroxAllowanceHolder, 0);
            }

            amountInDelta = balanceInBefore - params.tokenIn.balanceOf(address(this));
            amountOutDelta = params.tokenOut.balanceOf(address(this)) - balanceOutBefore;

            if (amountOutDelta < params.amountOutMin) {
                revert SlippageError();
            }

            emit Swap(address(params.tokenIn), address(params.tokenOut), amountInDelta, amountOutDelta);
        }
    }
}