// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {Automator} from "./Automator.sol";

/// @title AutoCollect
/// @notice Allows operators to collect fees by compounding them back into liquidity or harvesting them.
/// Positions need to be approved (approve or setApprovalForAll) for the contract when outside vault.
/// When position is inside Vault - owner needs to approve the position to be transformed by the contract.
contract AutoCollect is Automator {
    event AutoCollectExecuted(
        uint256 indexed tokenId,
        address account,
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1,
        bool harvest
    );

    event PositionConfigured(
        uint256 indexed tokenId,
        uint64 maxRewardX64,
        uint16 token0SlippageBps,
        uint16 token1SlippageBps,
        uint128 minCollectAmount0,
        uint128 minCollectAmount1
    );

    struct PositionConfig {
        uint64 maxRewardX64;
        uint16 token0SlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint16 token1SlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint128 minCollectAmount0;
        uint128 minCollectAmount1;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    enum CollectMode {
        AUTO_COLLECT,
        HARVEST_TOKENS,
        HARVEST_TOKEN_0,
        HARVEST_TOKEN_1
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address protocolFeeRecipient_
    )
        Automator(
            _positionManager,
            _universalRouter,
            _zeroxAllowanceHolder,
            _permit2,
            _v4Oracle,
            _operator,
            protocolFeeRecipient_
        )
    {}

    struct ExecuteParams {
        uint256 tokenId;
        CollectMode mode;
        bool swap0To1;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
        uint256 deadline;
        bytes hookData;
        uint64 rewardX64;
    }

    struct ExecuteState {
        uint256 startBalance0;
        uint256 startBalance1;
        uint256 amount0;
        uint256 amount1;
        uint256 protocolFee0;
        uint256 protocolFee1;
    }

    /// @notice Adjust token (which is in a Vault) - via transform method
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(params.tokenId, address(this), abi.encodeCall(this.execute, (params)));
    }

    /// @notice Adjust token directly or via vault transform
    function execute(ExecuteParams calldata params) external nonReentrant {
        _validateExecuteCaller(params.tokenId);

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;
        PositionConfig memory config = positionConfigs[params.tokenId];

        ExecuteState memory state = _collectNetFees(params, config, token0, token1);
        address owner = _positionOwner(params.tokenId);
        (uint256 a0, uint256 a1) = _executeMode(params, config, poolKey, positionInfo, token0, token1, owner, state);

        _sendProtocolFees(token0, token1, state.protocolFee0, state.protocolFee1);

        emit AutoCollectExecuted(
            params.tokenId,
            msg.sender,
            a0, a1,
            Currency.unwrap(token0),
            Currency.unwrap(token1),
            params.mode != CollectMode.AUTO_COLLECT
        );
    }

    function _validateExecuteCaller(uint256 tokenId) internal view {
        if (operators[msg.sender]) {
            return;
        }
        if (!vaults[msg.sender]) {
            revert Unauthorized();
        }
        _validateCaller(positionManager, tokenId);
    }

    function _collectNetFees(
        ExecuteParams calldata params,
        PositionConfig memory config,
        Currency token0,
        Currency token1
    )
        internal
        returns (ExecuteState memory state)
    {
        state.startBalance0 = token0.balanceOfSelf();
        state.startBalance1 = token1.balanceOfSelf();

        (uint256 feeAmount0, uint256 feeAmount1) =
            _decreaseLiquidity(params.tokenId, 0, 0, 0, params.deadline, params.hookData);

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        state.amount0 = feeAmount0;
        state.amount1 = feeAmount1;
        (state.amount0, state.amount1, state.protocolFee0, state.protocolFee1) =
            _quoteProtocolFees(feeAmount0, feeAmount1, feeAmount0, feeAmount1, true, params.rewardX64);
    }

    function _executeMode(
        ExecuteParams calldata params,
        PositionConfig memory config,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        Currency token0,
        Currency token1,
        address owner,
        ExecuteState memory state
    ) internal returns (uint256, uint256) {
        if (params.mode == CollectMode.AUTO_COLLECT) {
            return _executeAutoCollect(
                params,
                config,
                poolKey,
                positionInfo,
                token0,
                token1,
                owner,
                state
            );
        }

        return _executeHarvest(params, config, token0, token1, owner, state.amount0, state.amount1);
    }

    function _executeAutoCollect(
        ExecuteParams calldata params,
        PositionConfig memory config,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        Currency token0,
        Currency token1,
        address owner,
        ExecuteState memory state
    ) internal returns (uint256 compounded0, uint256 compounded1) {
        uint256 amount0 = state.amount0;
        uint256 amount1 = state.amount1;

        // Optional swap to rebalance
        if (params.amountIn > 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwapWithSlippageCheck(
                RouterSwapParams(
                    params.swap0To1 ? token0 : token1,
                    params.swap0To1 ? token1 : token0,
                    params.amountIn,
                    params.amountOutMin,
                    params.swapData
                ),
                params.swap0To1 ? config.token0SlippageBps : config.token1SlippageBps
            );
            if (params.swap0To1) {
                amount0 -= amountInDelta;
                amount1 += amountOutDelta;
            } else {
                amount1 -= amountInDelta;
                amount0 += amountOutDelta;
            }
        }

        if (amount0 > 0 || amount1 > 0) {
            _handleApproval(permit2, token0, amount0);
            _handleApproval(permit2, token1, amount1);

            uint128 liquidity = _calculateLiquidity(
                positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1
            );

            (bytes memory actions, bytes[] memory paramsArray) =
                _buildActionsForIncreasingLiquidity(uint8(Actions.INCREASE_LIQUIDITY), token0, token1);
            paramsArray[0] = abi.encode(params.tokenId, liquidity, amount0, amount1, params.hookData);

            positionManager.modifyLiquidities{value: _getNativeAmount(token0, token1, amount0, amount1)}(
                abi.encode(actions, paramsArray), params.deadline
            );

            uint256 leftover0 = _availableBalance(token0, state.startBalance0, state.protocolFee0);
            uint256 leftover1 = _availableBalance(token1, state.startBalance1, state.protocolFee1);
            compounded0 = amount0 - leftover0;
            compounded1 = amount1 - leftover1;

            if (compounded0 < config.minCollectAmount0 || compounded1 < config.minCollectAmount1) {
                revert AmountError();
            }
        }

        _sendAvailableBalances(owner, token0, token1, state.startBalance0, state.startBalance1, state.protocolFee0, state.protocolFee1);
    }

    function _executeHarvest(
        ExecuteParams calldata params,
        PositionConfig memory config,
        Currency token0,
        Currency token1,
        address owner,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        // Perform swap based on harvest mode
        if (params.mode == CollectMode.HARVEST_TOKEN_0 && amount1 > 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwapWithSlippageCheck(
                RouterSwapParams(token1, token0, params.amountIn, params.amountOutMin, params.swapData),
                config.token1SlippageBps
            );
            amount1 -= amountInDelta;
            amount0 += amountOutDelta;
        } else if (params.mode == CollectMode.HARVEST_TOKEN_1 && amount0 > 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwapWithSlippageCheck(
                RouterSwapParams(token0, token1, params.amountIn, params.amountOutMin, params.swapData),
                config.token0SlippageBps
            );
            amount0 -= amountInDelta;
            amount1 += amountOutDelta;
        }
        // HARVEST_TOKENS: no swap

        if (amount0 < config.minCollectAmount0 || amount1 < config.minCollectAmount1) {
            revert AmountError();
        }

        // Send tokens to owner
        _transferToken(owner, token0, amount0);
        _transferToken(owner, token1, amount1);

        return (amount0, amount1);
    }

    function _sendAvailableBalances(
        address owner,
        Currency token0,
        Currency token1,
        uint256 startBalance0,
        uint256 startBalance1,
        uint256 protocolFee0,
        uint256 protocolFee1
    ) internal {
        _transferToken(owner, token0, _availableBalance(token0, startBalance0, protocolFee0));
        _transferToken(owner, token1, _availableBalance(token1, startBalance1, protocolFee1));
    }

    /// @notice Configure fee parameters for a position
    /// @dev Set token{0,1}SlippageBps to 10000 to allow automation for pairs without oracle support.
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        address owner = _positionOwner(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }
        if (config.token0SlippageBps > 10000 || config.token1SlippageBps > 10000) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;
        emit PositionConfigured(
            tokenId,
            config.maxRewardX64,
            config.token0SlippageBps,
            config.token1SlippageBps,
            config.minCollectAmount0,
            config.minCollectAmount1
        );
    }

    function _positionOwner(uint256 tokenId) internal view returns (address owner) {
        owner = IERC721(address(positionManager)).ownerOf(tokenId);
        if (vaults[owner]) {
            owner = IVault(owner).ownerOf(tokenId);
        }
    }
}
