// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import "@uniswap/v4-core/src/interfaces/IHooks.sol";

import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import "@uniswap/v4-periphery/src/libraries/Actions.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";

import "../utils/Swapper.sol";
import "../interfaces/IVault.sol";
import "./Transformer.sol";

/// @title V4Utils v1.0
/// @notice Utility functions for Uniswap V4 positions
/// It does not hold any ERC20 or NFTs.
/// It can be simply redeployed when new / better functionality is implemented
contract V4Utils is Transformer, Swapper, IERC721Receiver {
    using SafeCast for uint256;

    /// @notice Permit2 contract
    IPermit2 public immutable permit2;

    // events
    event CompoundFees(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event ChangeRange(uint256 indexed tokenId, uint256 newTokenId);
    event WithdrawAndCollectAndSwap(uint256 indexed tokenId, address token, uint256 amount);
    event SwapAndMint(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event SwapAndIncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Action which should be executed on provided NFT
    enum WhatToDo {
        CHANGE_RANGE,
        WITHDRAW_AND_COLLECT_AND_SWAP,
        COMPOUND_FEES
    }

    /// @notice Complete description of what should be executed on provided NFT - different fields are used depending on specified WhatToDo
    struct Instructions {
        // what action to perform on provided Uniswap v4 position
        WhatToDo whatToDo;
        // target token for swaps (address(0) for native ETH)
        Currency targetToken;
        // for removing liquidity slippage
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        // amountIn0 is used for swap and also as minAmount0 for decreased liquidity + collected fees
        uint256 amountIn0;
        // if token0 needs to be swapped to targetToken - set values
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data
        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if token1 needs to be swapped to targetToken - set values
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data
        // for creating new positions with CHANGE_RANGE
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        // remove liquidity amount for COMPOUND_FEES (in this case should be probably 0) / CHANGE_RANGE / WITHDRAW_AND_COLLECT_AND_SWAP
        uint128 liquidity;
        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // left over tokens will be sent to this address
        address recipient;
        // recipient of newly minted nft (the incoming NFT will ALWAYS be returned to from)
        address recipientNFT;
        // data sent with returned token to IERC721Receiver (optional)
        bytes returnData;
        // data sent with minted token to IERC721Receiver (optional)
        bytes swapAndMintReturnData;
        // hook address for CHANGE_RANGE operations (optional)
        address hook;
        // hook data for all operations which decrease liquidity (optional)
        bytes decreaseLiquidityHookData;
        // hook data for all operations which mint / increase liquidity (optional)
        bytes increaseLiquidityHookData;
    }

    /// @notice Params for swap() function
    /// Renamed because of conflict with SwapParams in PoolOperation.sol
    struct SwapParamsV4 {
        Currency tokenIn;
        Currency tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient; // recipient of tokenOut and leftover tokenIn (if any leftover)
        bytes swapData;
    }

    /// @notice Params for swapAndMint() function
    struct SwapAndMintParams {
        Currency token0;
        Currency token1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        address recipientNFT; // recipient of nft
        uint256 deadline;
        // source token for swaps (maybe either address(0) for native ETH, token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        Currency swapSourceToken;
        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // data to be sent along newly created NFT when transfered to recipientNFT (sent to IERC721Receiver callback)
        bytes returnData;
        // hook address for the pool (optional)
        address hook;
        // hook data (optional)
        bytes mintHookData;
    }

    /// @notice Params for swapAndIncreaseLiquidity() function
    struct SwapAndIncreaseLiquidityParams {
        uint256 tokenId;
        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        uint256 deadline;
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        Currency swapSourceToken;
        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // hook data for all operations which decrease liquidity (optional)
        bytes decreaseLiquidityHookData;
        // hook data for all operations which increase liquidity (optional)
        bytes increaseLiquidityHookData;
    }

    /// @notice Constructor
    /// @param _positionManager Uniswap v4 position manager
    /// @param _universalRouter Uniswap Universal Router (for v3/v2 swaps)
    /// @param _zeroxAllowanceHolder 0x Protocol AllowanceHolder contract
    /// @param _permit2 Permit2 contract
    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2
    ) Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder) Ownable(msg.sender) {
        permit2 = _permit2;
    }

    /// @notice Execute instruction accessing approved NFT instead of direct safeTransferFrom call from owner
    /// @param tokenId Token to process
    /// @param instructions Instructions to execute
    /// @return newTokenId Id of position (if a new one was created)
    function execute(uint256 tokenId, Instructions memory instructions) public returns (uint256 newTokenId) {
        
        _validateCaller(positionManager, tokenId);

        // Get position info from V4 PositionManager
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        
        // Decrease liquidity and collect fees/tokens
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            tokenId,
            instructions.liquidity,
            instructions.deadline,
            instructions.amountRemoveMin0,
            instructions.amountRemoveMin1,
            instructions.decreaseLiquidityHookData
        );

        // Validate sufficient tokens for swaps
        if (amount0 < instructions.amountIn0 || amount1 < instructions.amountIn1) {
            revert AmountError();
        }

        // Execute the requested action
        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            _executeCompoundFees(tokenId, poolKey, amount0, amount1, instructions);
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            newTokenId = _executeChangeRange(tokenId, poolKey, amount0, amount1, instructions);
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP) {
            _executeWithdrawAndSwap(tokenId, poolKey, amount0, amount1, instructions);
        } else {
            revert NotSupportedWhatToDo();
        }
    }

    /// @notice Execute compound fees operation - swap tokens and increase liquidity
    function _executeCompoundFees(
        uint256 tokenId,
        PoolKey memory poolKey,
        uint256 amount0,
        uint256 amount1,
        Instructions memory instructions
    ) internal {
        uint128 liquidity;
Currency targetToken = instructions.targetToken;
        if (targetToken == poolKey.currency0) {
            // Swap token1 to token0 and increase liquidity
            (liquidity, amount0, amount1) = _swapAndIncrease(
                SwapAndIncreaseLiquidityParams(
                    tokenId,
                    amount0,
                    amount1,
                    instructions.recipient,
                    instructions.deadline,
                    poolKey.currency1,
                    instructions.amountIn1,
                    instructions.amountOut1Min,
                    instructions.swapData1,
                    0,
                    0,
                    "",
                    instructions.amountAddMin0,
                    instructions.amountAddMin1,
                    "",
                    instructions.increaseLiquidityHookData
                ),
                poolKey.currency0,
                poolKey.currency1
            );
        } else if (targetToken == poolKey.currency1) {
            // Swap token0 to token1 and increase liquidity
            (liquidity, amount0, amount1) = _swapAndIncrease(
                SwapAndIncreaseLiquidityParams(
                    tokenId,
                    amount0,
                    amount1,
                    instructions.recipient,
                    instructions.deadline,
                    poolKey.currency0,
                    0,
                    0,
                    "",
                    instructions.amountIn0,
                    instructions.amountOut0Min,
                    instructions.swapData0,
                    instructions.amountAddMin0,
                    instructions.amountAddMin1,
                    "",
                    instructions.increaseLiquidityHookData
                ),
                poolKey.currency0,
                poolKey.currency1
            );
        } else {
            // No swap - increase liquidity with both tokens
            (liquidity, amount0, amount1) = _swapAndIncrease(
                SwapAndIncreaseLiquidityParams(
                    tokenId,
                    amount0,
                    amount1,
                    instructions.recipient,
                    instructions.deadline,
                    CurrencyLibrary.ADDRESS_ZERO,
                    0,
                    0,
                    "",
                    0,
                    0,
                    "",
                    instructions.amountAddMin0,
                    instructions.amountAddMin1,
                    "",
                    instructions.increaseLiquidityHookData
                ),
                poolKey.currency0,
                poolKey.currency1
            );
        }
        
        emit CompoundFees(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Execute change range operation - swap tokens and mint new position
    function _executeChangeRange(
        uint256 tokenId,
        PoolKey memory poolKey,
        uint256 amount0,
        uint256 amount1,
        Instructions memory instructions
    ) internal returns (uint256 newTokenId) {
        Currency targetToken = instructions.targetToken;

        if (targetToken == poolKey.currency0) {
            // Swap token1 to token0 and mint new position
            (newTokenId,,,) = _swapAndMint(
                SwapAndMintParams(
                    poolKey.currency0,
                    poolKey.currency1,
                    instructions.fee,
                    instructions.tickSpacing,
                    instructions.tickLower,
                    instructions.tickUpper,
                    amount0,
                    amount1,
                    instructions.recipient,
                    instructions.recipientNFT,
                    instructions.deadline,
                    poolKey.currency1,
                    instructions.amountIn1,
                    instructions.amountOut1Min,
                    instructions.swapData1,
                    0,
                    0,
                    "",
                    instructions.amountAddMin0,
                    instructions.amountAddMin1,
                    instructions.swapAndMintReturnData,
                    instructions.hook,
                    instructions.increaseLiquidityHookData
                )
            );
        } else if (targetToken == poolKey.currency1) {
            // Swap token0 to token1 and mint new position
            (newTokenId,,,) = _swapAndMint(
                SwapAndMintParams(
                    poolKey.currency0,
                    poolKey.currency1,
                    instructions.fee,
                    instructions.tickSpacing,
                    instructions.tickLower,
                    instructions.tickUpper,
                    amount0,
                    amount1,
                    instructions.recipient,
                    instructions.recipientNFT,
                    instructions.deadline,
                    poolKey.currency0,
                    0,
                    0,
                    "",
                    instructions.amountIn0,
                    instructions.amountOut0Min,
                    instructions.swapData0,
                    instructions.amountAddMin0,
                    instructions.amountAddMin1,
                    instructions.swapAndMintReturnData,
                    instructions.hook,
                    instructions.increaseLiquidityHookData
                )
            );
        } else {
            // No swap - mint new position with both tokens
            (newTokenId,,,) = _swapAndMint(
                SwapAndMintParams(
                    poolKey.currency0,
                    poolKey.currency1,
                    instructions.fee,
                    instructions.tickSpacing,
                    instructions.tickLower,
                    instructions.tickUpper,
                    amount0,
                    amount1,
                    instructions.recipient,
                    instructions.recipientNFT,
                    instructions.deadline,
                    CurrencyLibrary.ADDRESS_ZERO,
                    0,
                    0,
                    "",
                    0,
                    0,
                    "",
                    instructions.amountAddMin0,
                    instructions.amountAddMin1,
                    instructions.swapAndMintReturnData,
                    instructions.hook,
                    instructions.increaseLiquidityHookData
                )
            );
        }
        
        emit ChangeRange(tokenId, newTokenId);
    }

    /// @notice Execute withdraw, collect and swap operation
    function _executeWithdrawAndSwap(
        uint256 tokenId,
        PoolKey memory poolKey,
        uint256 amount0,
        uint256 amount1,
        Instructions memory instructions
    ) internal {
        uint256 targetAmount;
        Currency targetToken = instructions.targetToken;

        // Swap token0 to target if needed
        if (!(poolKey.currency0 == targetToken)) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    poolKey.currency0,
                    targetToken,
                    instructions.amountIn0,
                    instructions.amountOut0Min,
                    instructions.swapData0
                )
            );
            // Return any leftover token0
            if (amountInDelta < amount0) {
                poolKey.currency0.transfer(instructions.recipient, amount0 - amountInDelta);
            }
            targetAmount += amountOutDelta;
        } else {
            targetAmount += amount0;
        }

        // Swap token1 to target if needed
        if (!(poolKey.currency1 == targetToken)) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    poolKey.currency1,
                    targetToken,
                    instructions.amountIn1,
                    instructions.amountOut1Min,
                    instructions.swapData1
                )
            );
            // Return any leftover token1
            if (amountInDelta < amount1) {
                poolKey.currency1.transfer(instructions.recipient, amount1 - amountInDelta);
            }
            targetAmount += amountOutDelta;
        } else {
            targetAmount += amount1;
        }

        // Transfer complete target amount to recipient
        if (targetAmount != 0) {
            targetToken.transfer(instructions.recipient, targetAmount);
        }

        emit WithdrawAndCollectAndSwap(tokenId, Currency.unwrap(targetToken), targetAmount);
    }

    /// @notice ERC721 callback function. Called on safeTransferFrom and does manipulation as configured in encoded Instructions parameter.
    /// At the end the NFT (and any newly minted NFT) is returned to sender. The leftover tokens are sent to instructions.recipient.
    function onERC721Received(address, /*operator*/ address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        // only Uniswap v4 NFTs allowed
        if (msg.sender != address(positionManager)) {
            revert WrongContract();
        }

        // not allowed to send to itself
        if (from == address(this)) {
            revert SelfSend();
        }

        Instructions memory instructions = abi.decode(data, (Instructions));

        execute(tokenId, instructions);

        IERC721(address(positionManager)).safeTransferFrom(address(this), from, tokenId, instructions.returnData);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Swaps amountIn of tokenIn for tokenOut - returning at least minAmountOut
    /// @param params Swap configuration
    /// @return amountOut Output amount of tokenOut
    /// If tokenIn is wrapped native token - both the token or the wrapped token can be sent (the sum of both must be equal to amountIn)
    /// Optionally unwraps any wrapped native token and returns native token instead
    function swap(SwapParamsV4 calldata params) external payable returns (uint256 amountOut) {
        if (params.tokenIn == params.tokenOut) {
            revert SameToken();
        }

         _prepareAddApproved(params.tokenIn, CurrencyLibrary.ADDRESS_ZERO, CurrencyLibrary.ADDRESS_ZERO, params.amountIn, 0, 0);

        uint256 amountInDelta;
        (amountInDelta, amountOut) = _routerSwap(
            Swapper.RouterSwapParams(
                params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.swapData
            )
        );

        // send swapped amount of tokenOut
        if (amountOut != 0) {
            params.tokenOut.transfer(params.recipient, amountOut);
        }

        // if not all was swapped - return leftovers of tokenIn
        uint256 leftOver = params.amountIn - amountInDelta;
        if (leftOver != 0) {
            params.tokenIn.transfer(params.recipient, leftOver);
        }
    }

    /// @notice Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to a newly minted position. Newly minted NFT and leftover tokens are returned to recipient.
    /// @param params Swap and mint configuration
    /// @return tokenId The ID of the token that represents the minted position
    /// @return liquidity The amount of liquidity for this position
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function swapAndMint(SwapAndMintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.token0 == params.token1) {
            revert SameToken();
        }

        _prepareAddApproved(
            params.token0,
            params.token1,
            params.swapSourceToken,
            params.amount0,
            params.amount1,
            params.amountIn0 + params.amountIn1
        );

        (tokenId, liquidity, amount0, amount1) = _swapAndMint(params);
    }

    /// @notice Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to any existing position (no need to be position owner). Sends any leftover tokens to recipient.
    /// @param params Swap and increase liquidity configuration
    /// @return liquidity The amount of liquidity added
    /// @return amount0 The amount of token0 added
    /// @return amount1 The amount of token1 added
    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams memory params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {

        // first fees must be removed
        (uint256 fees0, uint256 fees1) = _decreaseLiquidity(params.tokenId, 0, params.deadline, 0, 0, params.decreaseLiquidityHookData);
        
        // Get position info from V4 PositionManager
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        
        _prepareAddApproved(
                poolKey.currency0,
                poolKey.currency1,
                params.swapSourceToken,
                params.amount0,
                params.amount1,
                params.amountIn0 + params.amountIn1
            );

        // if native token special handling - see _decreaseLiquidity()
        params.amount0 = params.amount0 + fees0;
        params.amount1 = params.amount1 + fees1;

        (liquidity, amount0, amount1) = _swapAndIncrease(params, poolKey.currency0, poolKey.currency1);
    }

    // Internal helper functions
    function _prepareAddApproved(
        Currency token0,
        Currency token1,
        Currency otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) internal {
        // Process each token
        _prepareAddApprovedToken(token0, amount0);
        _prepareAddApprovedToken(token1, amount1);
        if (Currency.unwrap(otherToken) != Currency.unwrap(token0) && Currency.unwrap(otherToken) != Currency.unwrap(token1)) {
            _prepareAddApprovedToken(otherToken, amountOther);
        }
    }

    function _prepareAddApprovedToken(Currency token, uint256 amount) internal {
        if (amount == 0) return;
        
        if (!token.isAddressZero()) {
            SafeERC20.safeTransferFrom(IERC20(Currency.unwrap(token)), msg.sender, address(this), amount);
        }
    }

    /// @notice Add SWEEP params if native ETH is involved
    /// @param params_array The params array to modify
    /// @param hasNativeETH Whether native ETH is involved
    function _addSweepParamsIfNeeded(bytes[] memory params_array, bool hasNativeETH) internal view {
        if (hasNativeETH) {
            params_array[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));
        }
    }

    // swap and mint logic
    function _swapAndMint(SwapAndMintParams memory params)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 added0, uint256 added1)
    {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(params);

        // V4 uses different approach - need to create PoolKey and use modifyLiquidities
        PoolKey memory poolKey = PoolKey({
            currency0: params.token0,
            currency1: params.token1,
            fee: params.fee,
            tickSpacing: params.tickSpacing, // Use dynamic tickSpacing from params
            hooks: IHooks(params.hook) // Use hook from params
        });

        (bytes memory actions, bytes[] memory params_array) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.MINT_POSITION),
            params.token0, 
            params.token1
        );

        liquidity = _calculateLiquidity(
            params.tickLower,
            params.tickUpper,
            poolKey,
            total0,
            total1
        );

        params_array[0] = abi.encode(
            poolKey, 
            params.tickLower, 
            params.tickUpper, 
            liquidity, // liquidity
            total0, // amount0Max
            total1, // amount1Max
            address(this), // recipient
            bytes("") // hookData
        );

        // Mint position and handle transfers
        tokenId = _mintPositionAndTransfer(
            actions,
            params_array,
            params.deadline,
            params.recipientNFT,
            params.returnData
        );
        
        // Calculate consumption and return leftovers
        {
            uint256 finalBalance0 = poolKey.currency0.balanceOfSelf();
            uint256 finalBalance1 = poolKey.currency1.balanceOfSelf();

            // Calculate amounts actually added (prevent underflow if balance bigger)
            added0 = total0 >= finalBalance0 ? total0 - finalBalance0 : 0;
            added1 = total1 >= finalBalance1 ? total1 - finalBalance1 : 0;

            // Check minimum amounts were added
            if (added0 < params.amountAddMin0) {
                revert InsufficientAmountAdded();
            }
            if (added1 < params.amountAddMin1) {
                revert InsufficientAmountAdded();
            }

            emit SwapAndMint(tokenId, liquidity, added0, added1);

            // Return leftover tokens
            if (finalBalance0 != 0) {
                params.token0.transfer(params.recipient, finalBalance0);
            }
            if (finalBalance1 != 0) {
                params.token1.transfer(params.recipient, finalBalance1);
            }
        }
    }

    // Helper function to mint position and transfer NFT
    function _mintPositionAndTransfer(
        bytes memory actions,
        bytes[] memory params_array, 
        uint256 deadline,
        address recipientNFT,
        bytes memory returnData
    ) private returns (uint256 tokenId) {
        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params_array), deadline);
        
        // Get the newly minted token ID
        tokenId = positionManager.nextTokenId() - 1;
        
        // Transfer NFT to recipient
        IERC721(address(positionManager)).safeTransferFrom(address(this), recipientNFT, tokenId, returnData);
    }

    // swap and increase logic
    function _swapAndIncrease(SwapAndIncreaseLiquidityParams memory params, Currency token0, Currency token1)
        internal
        returns (uint128 liquidity, uint256 added0, uint256 added1)
    {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(
            SwapAndMintParams(
                token0,
                token1,
                0,
                0,
                0,
                0,
                params.amount0,
                params.amount1,
                params.recipient,
                params.recipient,
                params.deadline,
                params.swapSourceToken,
                params.amountIn0,
                params.amountOut0Min,
                params.swapData0,
                params.amountIn1,
                params.amountOut1Min,
                params.swapData1,
                params.amountAddMin0,
                params.amountAddMin1,
                "",
                address(0), // No hook for increase liquidity
                ""
            )
        );

        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(params.tokenId);

        // Build actions for native ETH if needed
        (bytes memory actions, bytes[] memory params_array) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.INCREASE_LIQUIDITY),
            poolKey.currency0,
            poolKey.currency1
        );

        // Calculate liquidity from amounts
        liquidity = _calculateLiquidity(
            info.tickLower(),
            info.tickUpper(),
            poolKey,
            total0,
            total1
        );
        
        params_array[0] = abi.encode(
            params.tokenId,
            liquidity,
            uint128(total0),
            uint128(total1),
            params.increaseLiquidityHookData
        );
        params_array[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
       
        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params_array), params.deadline);

        // Calculate consumption and return leftovers
        {
            uint256 finalBalance0 = poolKey.currency0.balanceOfSelf();
            uint256 finalBalance1 = poolKey.currency1.balanceOfSelf();
            
            added0 = total0 - finalBalance0;
            added1 = total1 - finalBalance1;

            // Check minimum amounts were added
            if (added0 < params.amountAddMin0) {
                revert InsufficientAmountAdded();
            }
            if (added1 < params.amountAddMin1) {
                revert InsufficientAmountAdded();
            }

            emit SwapAndIncreaseLiquidity(params.tokenId, liquidity, added0, added1);

            // Return leftover tokens
            if (finalBalance0 != 0) {
                token0.transfer(params.recipient, finalBalance0);
            }
            if (finalBalance1 != 0) {
                token1.transfer(params.recipient, finalBalance1);
            }
        }
    }

    // swaps available tokens and prepares max amounts to be added to positionManager
    function _swapAndPrepareAmounts(SwapAndMintParams memory params)
        internal
        returns (uint256 total0, uint256 total1)
    {

        Currency swapSource = params.swapSourceToken;
        if (swapSource == params.token0) {
            if (params.amount0 < params.amountIn1) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.token0, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            total0 = params.amount0 - amountInDelta;
            total1 = params.amount1 + amountOutDelta;
        } else if (swapSource == params.token1) {
            if (params.amount1 < params.amountIn0) {
                revert AmountError();
            }

            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.token1, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            total1 = params.amount1 - amountInDelta;
            total0 = params.amount0 + amountOutDelta;
        } else {
            (uint256 amountInDelta0, uint256 amountOutDelta0) = _routerSwap(
                Swapper.RouterSwapParams(
                    swapSource, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            (uint256 amountInDelta1, uint256 amountOutDelta1) = _routerSwap(
                Swapper.RouterSwapParams(
                    swapSource, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            total0 = params.amount0 + amountOutDelta0;
            total1 = params.amount1 + amountOutDelta1;

            // return third token leftover if any
            uint256 leftOver = params.amountIn0 + params.amountIn1 - amountInDelta0 - amountInDelta1;

            if (leftOver != 0) {
                swapSource.transfer(params.recipient, leftOver);
            }
        }

        _handleApproval(permit2, params.token0, total0);
        _handleApproval(permit2, params.token1, total1);
    }


    // decreases liquidity from uniswap v4 position
    function _decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 deadline,
        uint256 token0Min,
        uint256 token1Min,
        bytes memory hookData
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
        bytes[] memory params_array = new bytes[](2);
        params_array[0] = abi.encode(
            tokenId,
            uint256(liquidity),
            uint128(token0Min), // amount0Min
            uint128(token1Min), // amount1Min
            hookData
        );
        params_array[1] = abi.encode(currency0, currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params_array), deadline);
        
        // calculate delta
        amount0 = currency0.balanceOfSelf() - amount0;
        amount1 = currency1.balanceOfSelf() - amount1;
    }
}