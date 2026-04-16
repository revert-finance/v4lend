// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Swapper} from "../../shared/swap/Swapper.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Transformer} from "./Transformer.sol";

/// @title LeverageTransformer
/// @notice Enables atomic leverage/deleverage operations on Uniswap V4 positions used as collateral
/// @dev Provides three main operations:
///   - leverageUp: Borrow and add liquidity to an existing position
///   - leverageDown: Remove liquidity and repay debt
///   - leverageIn: Create a leveraged position from scratch with a single token
/// @custom:security Trust Model:
///   - Must be whitelisted as transformer in V4Vault to call borrow()
///   - Uses external swap routers - swap data should be validated off-chain
/// @custom:security Slippage Protection:
///   - amountRemoveMin0/1: Minimum amounts when decreasing liquidity
///   - amountAddMin0/1: Minimum amounts when adding liquidity
///   - amountOutMin: Minimum output for swaps
/// @custom:security Collateral Health:
///   - V4Vault verifies collateral health after transform completes
///   - Leverage operations fail if resulting position would be undercollateralized
contract LeverageTransformer is Transformer, Swapper, IERC721Receiver {

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

    /// @notice Increases leverage by borrowing and adding liquidity to an existing position
    /// @dev Called via V4Vault.transform(). Collects fees, borrows from vault, swaps if needed,
    ///      then adds all available tokens as liquidity. Leftover tokens sent to recipient.
    /// @param params LeverageUpParams struct containing borrow amount, swap configs, and slippage limits
    /// @custom:security Must be called through vault transform to have borrow access
    function leverageUp(LeverageUpParams calldata params) external {
        _validateCaller(positionManager, params.tokenId);

        // collect fees before
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(params.tokenId, 0, 0, 0, params.deadline, params.decreaseLiquidityHookData);

        IVault(msg.sender).borrow(params.tokenId, params.borrowAmount);

        Currency token = Currency.wrap(IVault(msg.sender).asset());

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;

        amount0 += token == token0 ? params.borrowAmount : 0;
        amount1 += token == token1 ? params.borrowAmount : 0;

        // Perform swaps in separate scope to reduce stack depth
        (amount0, amount1) = _leverageUpSwaps(params, token, token0, token1, amount0, amount1);

        _handleApproval(permit2, token0, amount0);
        _handleApproval(permit2, token1, amount1);

        uint128 liquidity = _calculateLiquidity(positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1);

        (bytes memory actions, bytes[] memory paramsArray) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.INCREASE_LIQUIDITY),
            token0,
            token1
        );
        paramsArray[0] = abi.encode(
            params.tokenId,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            params.increaseLiquidityHookData
        );

        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, paramsArray), params.deadline);

        _leverageUpFinalize(params, token, token0, token1, amount0, amount1);
    }

    /// @dev Helper function for swaps during leverageUp - extracted to reduce stack depth
    function _leverageUpSwaps(
        LeverageUpParams calldata params,
        Currency token,
        Currency token0,
        Currency token1,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        if (params.amountIn0 > 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token, token0, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            if (token == token1) {
                amount1 -= amountIn;
            }
            amount0 += amountOut;
        }
        if (params.amountIn1 > 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token, token1, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            if (token == token0) {
                amount0 -= amountIn;
            }
            amount1 += amountOut;
        }
        return (amount0, amount1);
    }

    /// @dev Helper function for finalizing leverageUp - extracted to reduce stack depth
    function _leverageUpFinalize(
        LeverageUpParams calldata params,
        Currency token,
        Currency token0,
        Currency token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
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
        if (!(token == token0) && !(token == token1)) {
            uint256 leftover = token.balanceOfSelf();
            if (leftover > 0) {
                token.transfer(params.recipient, leftover);
            }
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

    /// @notice Decreases leverage by removing liquidity and repaying debt
    /// @dev Called via V4Vault.transform(). Removes liquidity, swaps to vault asset,
    ///      and repays as much debt as possible. Leftover tokens sent to recipient.
    /// @param params LeverageDownParams struct containing liquidity to remove, swap configs, and slippage limits
    /// @custom:security Must be called through vault transform
    function leverageDown(LeverageDownParams calldata params) external {
        _validateCaller(positionManager, params.tokenId);

        Currency token = Currency.wrap(IVault(msg.sender).asset());

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;

        // V4 uses different approach - need to use modifyLiquidities with encoded actions
        // Include both DECREASE_LIQUIDITY and TAKE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            params.tokenId,
            uint256(params.liquidity),
            uint128(params.amountRemoveMin0), // amount0Min
            uint128(params.amountRemoveMin1), // amount1Min
            params.decreaseLiquidityHookData
        );
        paramsArray[1] = abi.encode(token0, token1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), params.deadline);

        // amounts recieved from decreasing liquidity
        uint256 amount0 = token0.balanceOfSelf();
        uint256 amount1 = token1.balanceOfSelf();

        uint256 amount = token == token0 ? amount0 : (token == token1 ? amount1 : 0);

        if (params.amountIn0 > 0 && !(token == token0)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(
                    token0, token, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            amount0 -= amountIn;
            amount += amountOut;
        }
        if (params.amountIn1 > 0 && !(token == token1)) {
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
        if (amount0 > 0 && !(token == token0)) {
            token0.transfer(params.recipient, amount0);
        }
        if (amount1 > 0 && !(token == token1)) {
            token1.transfer(params.recipient, amount1);
        }
    }

    struct LeverageInParams {
        // vault to create position in
        address vault;
        // pool key parameters (one of token0/token1 must be the vault's lend token)
        Currency token0;
        Currency token1;
        uint24 fee;
        int24 tickSpacing;
        address hook;
        // position ticks for the leveraged position
        int24 tickLower;
        int24 tickUpper;
        // initial token amount provided by user (must be the non-lend token)
        uint256 initialAmount;
        // how much to borrow
        uint256 borrowAmount;
        // how much to swap from lend token to other token (or vice versa if swapDirection is false)
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
        // true = swap lend token to other token, false = swap other token to lend token
        bool swapDirection;
        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // recipient for leftover tokens
        address recipient;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // hook data for minting the dummy position (optional)
        bytes mintHookData;
        // hook data for the final leveraged position (optional)
        bytes mintFinalHookData;
        // hook data for decreasing liquidity from dummy position (optional)
        bytes decreaseLiquidityHookData;
    }

    struct LeverageInTransformParams {
        // which token is being transformed (dummy position)
        uint256 tokenId;
        // pool key parameters for the new position (one of token0/token1 must be the vault's lend token)
        Currency token0;
        Currency token1;
        uint24 fee;
        int24 tickSpacing;
        address hook;
        // position ticks for the final leveraged position
        int24 tickLower;
        int24 tickUpper;
        // how much to borrow
        uint256 borrowAmount;
        // how much to swap from lend token to other token (or vice versa if swapDirection is false)
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
        // true = swap lend token to other token, false = swap other token to lend token
        bool swapDirection;
        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // recipient for leftover tokens
        address recipient;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // hook data for the final leveraged position (optional)
        bytes mintHookData;
        // hook data for decreasing liquidity from dummy position (optional)
        bytes decreaseLiquidityHookData;
    }

    /// @notice Creates a leveraged position from a single token
    /// @dev Creates a one-sided dummy position, adds it to vault as collateral, then transforms it to the desired position
    /// @param params The parameters for creating the leveraged position
    /// @return tokenId The token ID of the final leveraged position
    function leverageIn(LeverageInParams calldata params) external payable returns (uint256 tokenId) {
        if (!vaults[params.vault]) {
            revert Unauthorized();
        }

        // Validate that one token is the lend token
        Currency lendToken = Currency.wrap(IVault(params.vault).asset());
        Currency otherToken;
        if (lendToken == params.token0) {
            otherToken = params.token1;
        } else if (lendToken == params.token1) {
            otherToken = params.token0;
        } else {
            revert InvalidToken();
        }

        // Transfer initial token from user and create dummy position
        tokenId = _createDummyPosition(params, otherToken);

        // Send the dummy position to the vault (creates a loan with 0 debt)
        // The owner is set to this contract (LeverageTransformer) so we can call transform directly
        IERC721(address(positionManager)).safeTransferFrom(address(this), params.vault, tokenId);

        // Call transform on the vault to create the final leveraged position
        tokenId = _callTransform(params, tokenId);

        // Transfer ownership of the loan to the original caller
        IVault(params.vault).transferLoan(tokenId, params.recipient);
    }

    /// @dev Helper function to create the dummy position
    function _createDummyPosition(LeverageInParams calldata params, Currency otherToken) internal returns (uint256 tokenId) {
        // Transfer initial token from user (must be the non-lend token)
        if (!otherToken.isAddressZero()) {
            SafeERC20.safeTransferFrom(
                IERC20(Currency.unwrap(otherToken)),
                msg.sender,
                address(this),
                params.initialAmount
            );
        }

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: params.token0,
            currency1: params.token1,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(params.hook)
        });

        (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));

        // Get dummy tick range based on which token is the other token
        (int24 dummyTickLower, int24 dummyTickUpper) =
            _getDummyTickRange(poolKey, otherToken, params.tickSpacing, currentTick);

        // Handle approval for the initial token
        _handleApproval(permit2, otherToken, params.initialAmount);

        // Calculate liquidity for dummy position
        uint256 amount0 = otherToken == params.token0 ? params.initialAmount : 0;
        uint256 amount1 = otherToken == params.token1 ? params.initialAmount : 0;

        uint128 liquidity = _calculateLiquidity(sqrtPriceX96, dummyTickLower, dummyTickUpper, amount0, amount1);

        // Mint the dummy position
        _mintDummyPosition(poolKey, dummyTickLower, dummyTickUpper, liquidity, params);

        // Get the newly minted token ID
        tokenId = positionManager.nextTokenId() - 1;

        // Return any leftover tokens to the caller (may occur due to rounding)
        uint256 leftover = otherToken.balanceOfSelf();
        if (leftover > 0) {
            otherToken.transfer(msg.sender, leftover);
        }
    }

    /// @dev Helper function to get dummy tick range for one-sided position
    /// @dev Uses a wide tick range to ensure all initial tokens can be deposited
    function _getDummyTickRange(
        PoolKey memory poolKey,
        Currency otherToken,
        int24 tickSpacing,
        int24 currentTick
    ) internal pure returns (int24 dummyTickLower, int24 dummyTickUpper) {
        // Round current tick to tick spacing
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 roundedTick = (currentTick / tickSpacing) * tickSpacing;

        // Use MIN_TICK and MAX_TICK aligned to tick spacing to create a wide range
        // This ensures all tokens can be deposited into the dummy position
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);

        if (otherToken == poolKey.currency0) {
            // Token0 only position: must be above current price
            // Use range from just above current tick to max tick
            dummyTickLower = roundedTick + tickSpacing;
            dummyTickUpper = maxTick;
        } else {
            // Token1 only position: must be below current price
            // Use range from min tick to just below current tick
            dummyTickLower = minTick;
            dummyTickUpper = roundedTick - tickSpacing;
        }
    }

    /// @dev Helper function to mint the dummy position
    function _mintDummyPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        LeverageInParams calldata params
    ) internal {
        (bytes memory actions, bytes[] memory mintParams) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.MINT_POSITION),
            poolKey.currency0,
            poolKey.currency1
        );

        mintParams[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            params.mintHookData
        );

        positionManager.modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, mintParams),
            params.deadline
        );
    }

    /// @dev Helper function to call transform on vault
    function _callTransform(LeverageInParams calldata params, uint256 tokenId) internal returns (uint256) {
        // Build transform params for the leverageInTransform method
        LeverageInTransformParams memory transformParams = _buildTransformParams(params, tokenId);

        // Call transform on the vault to create the final leveraged position
        bytes memory transformData = abi.encodeWithSelector(
            this.leverageInTransform.selector,
            transformParams
        );

        return IVault(params.vault).transform(tokenId, address(this), transformData);
    }

    /// @dev Helper to build LeverageInTransformParams - extracted to reduce stack depth
    function _buildTransformParams(
        LeverageInParams calldata params,
        uint256 tokenId
    ) internal pure returns (LeverageInTransformParams memory transformParams) {
        transformParams.tokenId = tokenId;
        transformParams.token0 = params.token0;
        transformParams.token1 = params.token1;
        transformParams.fee = params.fee;
        transformParams.tickSpacing = params.tickSpacing;
        transformParams.hook = params.hook;
        transformParams.tickLower = params.tickLower;
        transformParams.tickUpper = params.tickUpper;
        transformParams.borrowAmount = params.borrowAmount;
        transformParams.amountIn = params.amountIn;
        transformParams.amountOutMin = params.amountOutMin;
        transformParams.swapData = params.swapData;
        transformParams.swapDirection = params.swapDirection;
        transformParams.amountAddMin0 = params.amountAddMin0;
        transformParams.amountAddMin1 = params.amountAddMin1;
        transformParams.recipient = params.recipient;
        transformParams.deadline = params.deadline;
        transformParams.mintHookData = params.mintFinalHookData;
        transformParams.decreaseLiquidityHookData = params.decreaseLiquidityHookData;
    }

    /// @notice Transform method called from vault to create the final leveraged position
    /// @dev Removes dummy position liquidity, borrows, swaps, and mints new position with desired ticks
    /// @param params The parameters for the transform
    function leverageInTransform(LeverageInTransformParams calldata params) external {
        _validateCaller(positionManager, params.tokenId);

        Currency lendToken = Currency.wrap(IVault(msg.sender).asset());

        // Remove dummy position, borrow and swap - returns amounts available for new position
        (uint256 amount0, uint256 amount1) = _removeBorrowAndSwap(params, lendToken);

        // Create the new position with desired ticks
        uint256 newTokenId = _mintNewPosition(params, amount0, amount1);

        // Verify slippage and send new position to vault
        _finalizeLeverageIn(params, amount0, amount1, newTokenId);
    }

    /// @dev Helper function to remove dummy position, borrow, and swap
    function _removeBorrowAndSwap(
        LeverageInTransformParams calldata params,
        Currency lendToken
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Determine which token is the other (non-lend) token
        Currency otherToken = lendToken == params.token0 ? params.token1 : params.token0;

        // Get current liquidity of the dummy position
        uint128 dummyLiquidity = positionManager.getPositionLiquidity(params.tokenId);

        // Remove all liquidity from the dummy position (and collect any fees)
        _decreaseLiquidity(
            params.tokenId,
            dummyLiquidity,
            0,
            0,
            params.deadline,
            params.decreaseLiquidityHookData
        );

        // Get the current token balances which include:
        // - Leftover tokens from the initial deposit that weren't used by the dummy position
        // - Tokens returned from decreasing the dummy position liquidity
        amount0 = params.token0.balanceOfSelf();
        amount1 = params.token1.balanceOfSelf();

        // Borrow from the vault
        IVault(msg.sender).borrow(params.tokenId, params.borrowAmount);

        // Add borrowed amount to the lend token balance
        if (lendToken == params.token0) {
            amount0 += params.borrowAmount;
        } else {
            amount1 += params.borrowAmount;
        }

        // Perform optional swap if needed
        if (params.amountIn > 0) {
            Currency tokenIn;
            Currency tokenOut;

            if (params.swapDirection) {
                // Swap lend token to other token
                tokenIn = lendToken;
                tokenOut = otherToken;
            } else {
                // Swap other token to lend token
                tokenIn = otherToken;
                tokenOut = lendToken;
            }

            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                Swapper.RouterSwapParams(tokenIn, tokenOut, params.amountIn, params.amountOutMin, params.swapData)
            );

            // Update amounts based on which tokens were swapped
            if (tokenIn == params.token0) {
                amount0 -= amountIn;
            } else {
                amount1 -= amountIn;
            }
            if (tokenOut == params.token0) {
                amount0 += amountOut;
            } else {
                amount1 += amountOut;
            }
        }
    }

    /// @dev Helper function to mint the new position
    function _mintNewPosition(
        LeverageInTransformParams calldata params,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 newTokenId) {
        // Approve tokens for position manager
        _handleApproval(permit2, params.token0, amount0);
        _handleApproval(permit2, params.token1, amount1);

        // Create pool key for the new position
        PoolKey memory poolKey = PoolKey({
            currency0: params.token0,
            currency1: params.token1,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(params.hook)
        });

        // Calculate liquidity for the new position
        uint128 newLiquidity = _calculateLiquidity(params.tickLower, params.tickUpper, poolKey, amount0, amount1);

        // Mint the new position with desired ticks
        (bytes memory actions, bytes[] memory mintParams) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.MINT_POSITION),
            params.token0,
            params.token1
        );

        mintParams[0] = abi.encode(
            poolKey,
            params.tickLower,
            params.tickUpper,
            newLiquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            params.mintHookData
        );

        positionManager.modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, mintParams),
            params.deadline
        );

        // Get the newly minted token ID
        newTokenId = positionManager.nextTokenId() - 1;
    }

    /// @dev Helper function to finalize the leverage in operation
    function _finalizeLeverageIn(
        LeverageInTransformParams calldata params,
        uint256 amount0,
        uint256 amount1,
        uint256 newTokenId
    ) internal {
        // Whole-balance accounting is intentional here: the transformer is expected to finish
        // successful executions without retaining position tokens, so the remaining balances are
        // treated as the full leftovers owed back to the recipient.
        // Calculate amounts added
        uint256 added0 = amount0 - params.token0.balanceOfSelf();
        uint256 added1 = amount1 - params.token1.balanceOfSelf();

        // Check minimum amounts were added
        if (added0 < params.amountAddMin0) {
            revert InsufficientAmountAdded();
        }
        if (added1 < params.amountAddMin1) {
            revert InsufficientAmountAdded();
        }

        // Send the new position to the vault - this will replace the dummy position
        // The vault's onERC721Received will handle replacing the old position with the new one
        IERC721(address(positionManager)).safeTransferFrom(address(this), msg.sender, newTokenId);

        // Send leftover tokens to recipient (lendToken is always one of token0 or token1)
        uint256 leftover0 = params.token0.balanceOfSelf();
        uint256 leftover1 = params.token1.balanceOfSelf();

        if (leftover0 > 0) {
            params.token0.transfer(params.recipient, leftover0);
        }
        if (leftover1 > 0) {
            params.token1.transfer(params.recipient, leftover1);
        }
    }

    /// @notice Callback for receiving ERC721 tokens
    /// @dev Required for receiving NFTs from the position manager
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
