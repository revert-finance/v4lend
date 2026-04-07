// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {IUniversalRouter} from "./IUniversalRouter.sol";
import {Constants} from "../Constants.sol";


// base functionality to do swaps with different routing protocols
abstract contract Swapper is Constants {
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Wrapped native token address
    IWETH9 public immutable weth;

    /// @notice Uniswap v4 position manager
    IPositionManager public immutable positionManager;

    /// @notice Uniswap v4 pool manager
    IPoolManager public immutable poolManager;

    /// @notice Uniswap Universal Router
    address public immutable universalRouter;

    /// @notice 0x Protocol AllowanceHolder contract
    address public immutable zeroxAllowanceHolder;

    /// @notice Tracks tokens that have been approved to Permit2
    mapping(address => bool) private permit2Approved;

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
        poolManager = IPoolManager(_positionManager.poolManager());
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
        if (params.amountIn > 0) {
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
                    if (!params.tokenIn.isAddressZero()) {
                        IERC20 tokenIn = IERC20(Currency.unwrap(params.tokenIn));
                        SafeERC20.forceApprove(tokenIn, zeroxAllowanceHolder, params.amountIn);
                        (bool success,) = zeroxAllowanceHolder.call(params.swapData);
                        if (!success) {
                            revert SwapFailed();
                        }
                        SafeERC20.forceApprove(tokenIn, zeroxAllowanceHolder, 0);
                    } else {
                        (bool success,) = zeroxAllowanceHolder.call{value: params.amountIn}(params.swapData);
                        if (!success) {
                            revert SwapFailed();
                        }
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
        Currency wethCurrency = Currency.wrap(address(weth));
        // Check for WETH -> ETH (WETH to zero address) OR ETH -> WETH (zero address to WETH)
        return (tokenIn == wethCurrency && tokenOut.isAddressZero()) ||
               (tokenIn.isAddressZero() && tokenOut == wethCurrency);
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

    function _handleApproval(IPermit2 permit2, Currency token, uint256 amount) internal {
        if (amount > 0 && !token.isAddressZero()) {
            address tokenAddr = Currency.unwrap(token);
            if (!permit2Approved[tokenAddr]) {
                SafeERC20.forceApprove(IERC20(tokenAddr), address(permit2), type(uint256).max);
                permit2.approve(tokenAddr, address(positionManager), type(uint160).max, type(uint48).max);
                permit2Approved[tokenAddr] = true;
            }
        }
    }

    function _buildActionsForIncreasingLiquidity(
        uint8 baseAction,
        Currency token0, 
        Currency token1
    ) internal view returns (bytes memory actions, bytes[] memory paramsArray) {
        if (token0.isAddressZero() || token1.isAddressZero()) {
            // Include SWEEP action for native ETH
            actions = abi.encodePacked(baseAction, uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            paramsArray = new bytes[](3);
            paramsArray[2] = abi.encode(address(0), address(this));
        } else {
            // Standard actions for ERC20 tokens only
            actions = abi.encodePacked(baseAction, uint8(Actions.SETTLE_PAIR));
            paramsArray = new bytes[](2);
        }
        paramsArray[1] = abi.encode(token0, token1);
    }


    /// @dev Returns the ETH value to send for native token settlement
    function _getNativeAmount(Currency token0, Currency token1, uint256 amount0, uint256 amount1)
        internal pure returns (uint256)
    {
        if (token0.isAddressZero()) return amount0;
        if (token1.isAddressZero()) return amount1;
        return 0;
    }

    function _calculateLiquidity(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 maxLiquidity) {
        // Calculate sqrt prices for tick range
        uint160 sqrtPriceAx96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBx96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate max liquidity
        maxLiquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceAx96, sqrtPriceBx96, amount0, amount1);
    }

    function _calculateLiquidity(
        int24 tickLower,
        int24 tickUpper,
        PoolKey memory poolKey,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128 maxLiquidity) {
        // Get current price from pool
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        return _calculateLiquidity(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
    }

    // decreases liquidity from uniswap v4 position
    function _decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidityRemove, 
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        bytes memory decreaseLiquidityHookData
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        
        // Cache currencies to save gas
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        
        // check balance before decreasing liquidity
        amount0 = currency0.balanceOfSelf();
        amount1 = currency1.balanceOfSelf();

        // V4 uses different approach - need to use modifyLiquidities with encoded actions
        // Include both DECREASE_LIQUIDITY and TAKE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            tokenId,
            uint256(liquidityRemove),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(amount0Min),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(amount1Min),
            decreaseLiquidityHookData
        );
        paramsArray[1] = abi.encode(currency0, currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), deadline);
        
        // calculate delta
        amount0 = currency0.balanceOfSelf() - amount0;
        amount1 = currency1.balanceOfSelf() - amount1;
    }

    // recieves ETH from swaps
    receive() external payable {
    }
}
