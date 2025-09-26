// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import "@uniswap/v4-periphery/lib/permit2/src/interfaces/ISignatureTransfer.sol";

import "@uniswap/v4-core/src/interfaces/IHooks.sol";

import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import "@uniswap/v4-periphery/src/libraries/Actions.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/Currency.sol";

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "./Swapper.sol";


/// @title V4Utils v1.0
/// @notice Utility functions for Uniswap V4 positions
/// It does not hold any ERC20 or NFTs.
/// It can be simply redeployed when new / better functionality is implemented
contract V4Utils is Swapper, IERC721Receiver {
    using SafeCast for uint256;

    // @notice Permit2 contract
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
        address targetToken;
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
        // hook data for mint in CHANGE_RANGE operations (optional)
        bytes mintHookData;
        // hook data for all operations which decrease liquidity (optional)
        bytes decreaseLiquidityHookData;
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
        bytes permitData; // if permit2 signatures are used - set this
    }

    /// @notice Params for swapAndMint() function
    struct SwapAndMintParams {
        Currency token0;
        Currency token1;
        uint24 fee;
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
        // if permit2 signatures are used - set this
        bytes permitData;
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
        // if permit2 signatures are used - set this
        bytes permitData;
        // hook data for all operations which decrease liquidity (optional)
        bytes decreaseLiquidityHookData;
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
    ) Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder) {
        permit2 = _permit2;
    }

    /// @notice Execute instruction with EIP712 permit
    /// @param tokenId Token to process
    /// @param instructions Instructions to execute
    /// @param v Signature values for EIP712 permit
    /// @param r Signature values for EIP712 permit
    /// @param s Signature values for EIP712 permit
    /// @return newTokenId Id of position (if a new one was created)
    function executeWithPermit(uint256 tokenId, Instructions memory instructions, uint8 v, bytes32 r, bytes32 s)
        public
        returns (uint256 newTokenId)
    {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != msg.sender) {
            revert Unauthorized();
        }

        // V4 uses different permit signature format - need to adapt
        // For now, we'll implement a basic version that works with the V4 permit system
        bytes memory signature = abi.encodePacked(r, s, v);
        positionManager.permit(address(this), tokenId, instructions.deadline, 0, signature);
        return execute(tokenId, instructions);

        // NOTE: previous operator can not be reset as operator set by permit can not change operator - so this operator will stay until reset
    }

    /// @notice Execute instruction by pulling approved NFT instead of direct safeTransferFrom call from owner
    /// @param tokenId Token to process
    /// @param instructions Instructions to execute
    /// @return newTokenId Id of position (if a new one was created)
    function execute(uint256 tokenId, Instructions memory instructions) public returns (uint256 newTokenId) {

        // Get position info from V4 PositionManager
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        
        // Get addresses for comparison
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        uint256 amount0;
        uint256 amount1;
        (amount0, amount1) = _decreaseLiquidity(
            tokenId,
            instructions.liquidity,
            instructions.deadline,
            instructions.amountRemoveMin0,
            instructions.amountRemoveMin1,
            instructions.decreaseLiquidityHookData
        );

        // check if enough tokens are available for swaps
        if (amount0 < instructions.amountIn0 || amount1 < instructions.amountIn1) {
            revert AmountError();
        }

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            if (instructions.targetToken == token0) {
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
                        ""
                    ),
                    poolKey.currency0,
                    poolKey.currency1
                );
            } else if (instructions.targetToken == token1) {
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
                        ""
                    ),
                    poolKey.currency0,
                    poolKey.currency1
                );
            } else {
                // no swap is done here
                (liquidity, amount0, amount1) = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        tokenId,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.deadline,
                        Currency.wrap(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        "",
                        ""
                    ),
                    poolKey.currency0,
                    poolKey.currency1
                );
            }
            emit CompoundFees(tokenId, liquidity, amount0, amount1);
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            if (instructions.targetToken == token0) {
                (newTokenId,,,) = _swapAndMint(
                    SwapAndMintParams(
                        poolKey.currency0,
                        poolKey.currency1,
                        instructions.fee,
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
                        "",
                        instructions.hook,
                        instructions.mintHookData
                    )
                );
            } else if (instructions.targetToken == token1) {
                (newTokenId,,,) = _swapAndMint(
                    SwapAndMintParams(
                        poolKey.currency0,
                        poolKey.currency1,
                        instructions.fee,
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
                        "",
                        instructions.hook,
                        instructions.mintHookData
                    )
                );
            } else {
                // no swap is done here
                (newTokenId,,,) = _swapAndMint(
                    SwapAndMintParams(
                        poolKey.currency0,
                        poolKey.currency1,
                        instructions.fee,
                        instructions.tickLower,
                        instructions.tickUpper,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.recipientNFT,
                        instructions.deadline,
                        Currency.wrap(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        instructions.swapAndMintReturnData,
                        "",
                        instructions.hook,
                        instructions.mintHookData
                    )
                );
            }
            emit ChangeRange(tokenId, newTokenId);
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP) {
            uint256 targetAmount;
            if (token0 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        poolKey.currency0,
                        Currency.wrap(instructions.targetToken),
                        instructions.amountIn0,
                        instructions.amountOut0Min,
                        instructions.swapData0
                    )
                );
                if (amountInDelta < amount0) {
                    _transferToken(instructions.recipient, poolKey.currency0, amount0 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount0;
            }
            if (token1 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        poolKey.currency1,
                        Currency.wrap(instructions.targetToken),
                        instructions.amountIn1,
                        instructions.amountOut1Min,
                        instructions.swapData1
                    )
                );
                if (amountInDelta < amount1) {
                    _transferToken(instructions.recipient, poolKey.currency1, amount1 - amountInDelta);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount1;
            }

            // send complete target amount
            if (targetAmount != 0) {
                Currency.wrap(instructions.targetToken).transfer(instructions.recipient, targetAmount);
            }

            emit WithdrawAndCollectAndSwap(tokenId, instructions.targetToken, targetAmount);
        } else {
            revert NotSupportedWhatToDo();
        }
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

        // For now, just return the token using transferFrom
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

        if (params.permitData.length != 0) {
            (ISignatureTransfer.PermitBatchTransferFrom memory pbtf, bytes memory signature) =
                abi.decode(params.permitData, (ISignatureTransfer.PermitBatchTransferFrom, bytes));
            _prepareAddPermit2(
                params.tokenIn, Currency.wrap(address(0)), Currency.wrap(address(0)), params.amountIn, 0, 0, pbtf, signature
            );
        } else {
            _prepareAddApproved(params.tokenIn, Currency.wrap(address(0)), Currency.wrap(address(0)), params.amountIn, 0, 0);
        }

        uint256 amountInDelta;
        (amountInDelta, amountOut) = _routerSwap(
            Swapper.RouterSwapParams(
                params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.swapData
            )
        );

        // send swapped amount of tokenOut
        if (amountOut != 0) {
            _transferToken(params.recipient, params.tokenOut, amountOut);
        }

        // if not all was swapped - return leftovers of tokenIn
        uint256 leftOver = params.amountIn - amountInDelta;
        if (leftOver != 0) {
            _transferToken(params.recipient, params.tokenIn, leftOver);
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

        if (params.permitData.length != 0) {
            (ISignatureTransfer.PermitBatchTransferFrom memory pbtf, bytes memory signature) =
                abi.decode(params.permitData, (ISignatureTransfer.PermitBatchTransferFrom, bytes));
            _prepareAddPermit2(
                params.token0,
                params.token1,
                params.swapSourceToken,
                params.amount0,
                params.amount1,
                params.amountIn0 + params.amountIn1,
                pbtf,
                signature
            );
        } else {
            _prepareAddApproved(
                params.token0,
                params.token1,
                params.swapSourceToken,
                params.amount0,
                params.amount1,
                params.amountIn0 + params.amountIn1
            );
        }

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
        
        if (params.permitData.length != 0) {
            (ISignatureTransfer.PermitBatchTransferFrom memory pbtf, bytes memory signature) =
                abi.decode(params.permitData, (ISignatureTransfer.PermitBatchTransferFrom, bytes));
            _prepareAddPermit2(
                poolKey.currency0,
                poolKey.currency1,
                params.swapSourceToken,
                params.amount0,
                params.amount1,
                params.amountIn0 + params.amountIn1,
                pbtf,
                signature
            );
        } else {
            _prepareAddApproved(
                poolKey.currency0,
                poolKey.currency1,
                params.swapSourceToken,
                params.amount0,
                params.amount1,
                params.amountIn0 + params.amountIn1
            );
        }

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

    struct PrepareAddPermit2State {
        uint256 i;
        uint256 balanceBefore0;
        uint256 balanceBefore1;
        uint256 balanceBeforeOther;
    }

    function _prepareAddPermit2(
        Currency token0,
        Currency token1,
        Currency otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther,
        IPermit2.PermitBatchTransferFrom memory permit,
        bytes memory signature
    ) internal {
        PrepareAddPermit2State memory state;

        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails =
            new ISignatureTransfer.SignatureTransferDetails[](permit.permitted.length);

        // permitted tokens must be in this same order
        if (amount0 != 0 && !token0.isAddressZero()) {
            state.balanceBefore0 = token0.balanceOfSelf();
            transferDetails[state.i++] = ISignatureTransfer.SignatureTransferDetails(address(this), amount0);
        }
        if (amount1 != 0 && !token1.isAddressZero()) {
            state.balanceBefore1 = token1.balanceOfSelf();
            transferDetails[state.i++] = ISignatureTransfer.SignatureTransferDetails(address(this), amount1);
        }
        if (amountOther != 0 && !otherToken.isAddressZero()) {
            state.balanceBeforeOther = otherToken.balanceOfSelf();
            transferDetails[state.i++] = ISignatureTransfer.SignatureTransferDetails(address(this), amountOther);
        }

        // execute batch transfer
        permit2.permitTransferFrom(permit, transferDetails, msg.sender, signature);

        // check if recieved correct amount of tokens
        if (amount0 != 0 && !token0.isAddressZero()) {
            if (token0.balanceOfSelf() - state.balanceBefore0 != amount0) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (amount1 != 0 && !token1.isAddressZero()) {
            if (token1.balanceOfSelf() - state.balanceBefore1 != amount1) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (amountOther != 0 && !otherToken.isAddressZero()) {
            if (otherToken.balanceOfSelf() - state.balanceBeforeOther != amountOther) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
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
            tickSpacing: 60, // Default tick spacing for V4
            hooks: IHooks(params.hook) // Use hook from params
        });
        
        // For V4, we need to use modifyLiquidities with encoded actions
        // Include MINT_POSITION, SETTLE_PAIR, and optionally SWEEP for native ETH
        bytes memory actions;
        bytes[] memory params_array;
        
        if (params.token0.isAddressZero() || params.token1.isAddressZero()) {
            // Include SWEEP action for native ETH
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params_array = new bytes[](3);
            
            // SWEEP parameters: sweep native ETH to this contract
            params_array[2] = abi.encode(Currency.wrap(address(0)), address(this));
        } else {
            // Standard actions for ERC20 tokens only
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params_array = new bytes[](2);
        }
        
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
        params_array[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        
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
    
    function _calculateLiquidity(
        int24 tickLower,
        int24 tickUpper,
        PoolKey memory poolKey,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128 maxLiquidity) {

        // Get poolManager from positionManager
        IPoolManager poolManager = IPoolManager(positionManager.poolManager());
        
        // Get current price from pool
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        
        // Calculate sqrt prices for tick range
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
    
        // Calculate max liquidity
        maxLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            amount0,
            amount1
        );
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
                params.permitData,
                address(0), // No hook for increase liquidity
                ""
            )
        );

        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(params.tokenId);

        // V4 uses different approach - need to use modifyLiquidities with encoded actions
        // Include INCREASE_LIQUIDITY, SETTLE_PAIR, and optionally SWEEP for native ETH
        bytes memory actions;
        bytes[] memory params_array;
        
        // If native ETH is involved
        if (Currency.unwrap(poolKey.currency0) == address(0) || Currency.unwrap(poolKey.currency1) == address(0)) {
            // Include SWEEP action for native ETH
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params_array = new bytes[](3);
            
            // SWEEP parameters: sweep native ETH to this contract
            params_array[2] = abi.encode(Currency.wrap(address(0)), address(this));
        } else {
            // Standard actions for ERC20 tokens only
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            params_array = new bytes[](2);
        }

        // Calculate liquidity from amounts
        // For simplicity, use the minimum of the two amounts as liquidity
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
            uint128(total0), // amount0Max
            uint128(total1), // amount1Max
            false
        );
        params_array[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
       
        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params_array), params.deadline);

        // Calculate consumption and return leftovers
        {
            uint256 finalBalance0 = poolKey.currency0.balanceOfSelf();
            uint256 finalBalance1 = poolKey.currency1.balanceOfSelf();
            
            added0 = total0 - finalBalance0;
            added1 = total1 - finalBalance1;

            emit SwapAndIncreaseLiquidity(params.tokenId, liquidity, added0, added1);

            // Return leftover tokens
            if (finalBalance0 != 0) {
                _transferToken(params.recipient, token0, finalBalance0);
            }
            if (finalBalance1 != 0) {
                _transferToken(params.recipient, token1, finalBalance1);
            }
        }
    }

    // swaps available tokens and prepares max amounts to be added to positionManager
    function _swapAndPrepareAmounts(SwapAndMintParams memory params)
        internal
        returns (uint256 total0, uint256 total1)
    {
        if (params.swapSourceToken == params.token0) {
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
        } else if (params.swapSourceToken == params.token1) {
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
                    params.swapSourceToken, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            (uint256 amountInDelta1, uint256 amountOutDelta1) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.swapSourceToken, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            total0 = params.amount0 + amountOutDelta0;
            total1 = params.amount1 + amountOutDelta1;

            // return third token leftover if any
            uint256 leftOver = params.amountIn0 + params.amountIn1 - amountInDelta0 - amountInDelta1;

            if (leftOver != 0) {
                _transferToken(params.recipient, params.swapSourceToken, leftOver);
            }
        }

        // approve tokens for positionManager
        if (total0 != 0 && !params.token0.isAddressZero()) {
            SafeERC20.forceApprove(IERC20(Currency.unwrap(params.token0)), address(permit2), type(uint256).max);
            permit2.approve(
                Currency.unwrap(params.token0),
                address(positionManager),
                uint160(total0),
                uint48(block.timestamp)
            );
        }
        if (total1 != 0 && !params.token1.isAddressZero()) {
            SafeERC20.forceApprove(IERC20(Currency.unwrap(params.token1)), address(permit2), type(uint256).max);
            permit2.approve(
                Currency.unwrap(params.token1),
                address(positionManager),
                uint160(total1),
                uint48(block.timestamp)
            );
        }
    }

    // returns leftover token balances
    function _returnLeftoverTokens(
        address to,
        Currency token0,
        Currency token1,
        uint256 total0,
        uint256 total1,
        uint256 added0,
        uint256 added1
    ) internal {
        uint256 left0 = total0 - added0;
        uint256 left1 = total1 - added1;

        // return leftovers
        if (left0 != 0) {
            _transferToken(to, token0, left0);
        }
        if (left1 != 0) {
            _transferToken(to, token1, left1);
        }
    }

    // transfers token or ETH
    function _transferToken(address to, Currency token, uint256 amount) internal {
        if (token.isAddressZero()) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            token.transfer(to, amount);
        }
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
        
        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        params_array[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        
        // check balance before decreasing liquidity
        amount0 = poolKey.currency0.balanceOfSelf();
        amount1 = poolKey.currency1.balanceOfSelf();

        positionManager.modifyLiquidities(abi.encode(actions, params_array), deadline);
        
        // calculate delta
        amount0 = poolKey.currency0.balanceOfSelf() - amount0;
        amount1 = poolKey.currency1.balanceOfSelf() - amount1;
    }

    // recieves ETH from swaps, decreasing liquidity
    receive() external payable {
    }
}