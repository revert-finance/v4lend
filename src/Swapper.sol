// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

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
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) {
        weth = NativeWrapper(payable(address(_positionManager))).WETH9();
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
        Currency tokenIn;
        Currency tokenOut;
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
        if (params.amountIn != 0) {
            uint256 balanceInBefore = params.tokenIn.balanceOfSelf();
            uint256 balanceOutBefore = params.tokenOut.balanceOfSelf();

            // Check for direct WETH/ETH swaps
            bool isDirectWethSwap = _isDirectWethSwap(params.tokenIn, params.tokenOut);
            if (isDirectWethSwap) {
                _handleDirectWethSwap(params.tokenIn, params.tokenOut, params.amountIn);
            } else if (params.swapData.length != 0) {
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
                    (, bytes memory routerData) = abi.decode(params.swapData, (address, bytes));
                    UniversalRouterData memory data = abi.decode(routerData, (UniversalRouterData));
                    if (!params.tokenIn.isAddressZero()) {
                        params.tokenIn.transfer(universalRouter, params.amountIn);
                    }
                    IUniversalRouter(universalRouter).execute{value: params.tokenIn.isAddressZero() ? params.amountIn : 0}(data.commands, data.inputs, data.deadline);
                } else {
                    IERC20 tokenIn = IERC20(Currency.unwrap(params.tokenIn));
                    if (!params.tokenIn.isAddressZero()) {
                        SafeERC20.safeIncreaseAllowance(tokenIn, zeroxAllowanceHolder, params.amountIn);
                    }
                    (bool success,) = zeroxAllowanceHolder.call{value: params.tokenIn.isAddressZero() ? params.amountIn : 0}(params.swapData);
                    if (!success) {
                        revert SwapFailed();
                    }
                    if (!params.tokenIn.isAddressZero()) {
                        SafeERC20.forceApprove(tokenIn, zeroxAllowanceHolder, 0);
                    }
                }
            }

            amountInDelta = balanceInBefore - params.tokenIn.balanceOfSelf();
            amountOutDelta = params.tokenOut.balanceOfSelf() - balanceOutBefore;

            if (amountOutDelta < params.amountOutMin) {
                revert SlippageError();
            }

            emit Swap(Currency.unwrap(params.tokenIn), Currency.unwrap(params.tokenOut), amountInDelta, amountOutDelta);
        }
    }

    /// @notice Check if this is a direct WETH/ETH swap
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @return true if this is a direct WETH/ETH swap
    function _isDirectWethSwap(Currency tokenIn, Currency tokenOut) internal view returns (bool) {
        address wethAddress = address(weth);
        address tokenInAddress = Currency.unwrap(tokenIn);
        address tokenOutAddress = Currency.unwrap(tokenOut);
        
        // Check for WETH -> ETH (WETH to zero address)
        if (tokenInAddress == wethAddress && tokenOutAddress == address(0)) {
            return true;
        }
        
        // Check for ETH -> WETH (zero address to WETH)
        if (tokenInAddress == address(0) && tokenOutAddress == wethAddress) {
            return true;
        }
        
        return false;
    }

    /// @notice Handle direct WETH/ETH swaps using IWETH functions
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amount Amount to swap
    function _handleDirectWethSwap(Currency tokenIn, Currency tokenOut, uint256 amount) internal {
        address wethAddress = address(weth);
        address tokenInAddress = Currency.unwrap(tokenIn);
        address tokenOutAddress = Currency.unwrap(tokenOut);
        
        if (tokenInAddress == wethAddress && tokenOutAddress == address(0)) {
            // WETH -> ETH: withdraw WETH to get ETH
            weth.withdraw(amount);
        } else if (tokenInAddress == address(0) && tokenOutAddress == wethAddress) {
            // ETH -> WETH: deposit ETH to get WETH
            weth.deposit{value: amount}();
        }
    }
}