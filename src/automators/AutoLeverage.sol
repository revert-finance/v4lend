// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../interfaces/IVault.sol";
import {Automator} from "./Automator.sol";

/// @title AutoLeverage
/// @notice Automatically rebalances leverage ratio when price moves.
/// Operator-triggered, works through vault.transform() for vault-owned positions.
contract AutoLeverage is Automator {
    event AutoLeverage(uint256 indexed tokenId, bool leverageUp, uint256 debtBefore, uint256 debtAfter);
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        uint16 targetLeverageBps,
        uint16 rebalanceThresholdBps,
        uint64 maxRewardX64
    );

    /// @dev No `onlyFees` flag — AutoLeverage only collects fees (liquidity=0), so fee==total and the flag would have no effect
    struct PositionConfig {
        bool isActive;
        uint16 targetLeverageBps;
        uint16 rebalanceThresholdBps;
        uint64 maxRewardX64;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @dev Internal struct to avoid stack-too-deep — tracks execution context for leftover calculation
    struct ExecuteState {
        uint256 balance0Start;
        uint256 balance1Start;
        uint256 reward0;
        uint256 reward1;
        uint256 netFee0;
        uint256 netFee1;
    }

    struct ExecuteParams {
        uint256 tokenId;
        address vault;
        bool leverageUp;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 deadline;
        bytes decreaseLiquidityHookData;
        bytes increaseLiquidityHookData;
        uint64 rewardX64;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _operator, _withdrawer) {}

    /// @notice Execute leverage rebalancing (always via vault.transform)
    function execute(ExecuteParams calldata params) external {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }
        if (!vaults[params.vault]) {
            revert Unauthorized();
        }

        IVault(params.vault).transform(
            params.tokenId, address(this), abi.encodeCall(this._execute, (params))
        );
    }

    /// @notice Internal execution called from vault.transform()
    function _execute(ExecuteParams calldata params) external nonReentrant {
        _validateCaller(positionManager, params.tokenId);

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }

        IVault vault = IVault(msg.sender);
        (uint256 currentDebt,, uint256 collateralValue,,) = vault.loanInfo(params.tokenId);

        // Check if rebalancing is needed
        uint256 currentRatio = collateralValue > 0 ? currentDebt * 10000 / collateralValue : 0;
        uint256 targetRatio = uint256(config.targetLeverageBps);
        uint256 threshold = uint256(config.rebalanceThresholdBps);

        if (currentRatio > targetRatio - threshold && currentRatio < targetRatio + threshold) {
            revert NotReady();
        }

        // Validate direction matches current state before collecting fees
        if (params.leverageUp && currentRatio >= targetRatio) {
            revert InvalidConfig();
        }
        if (!params.leverageUp && currentRatio <= targetRatio) {
            revert InvalidConfig();
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;
        Currency lendToken = Currency.wrap(vault.asset());
        bool isThirdToken = !(lendToken == token0) && !(lendToken == token1);

        ExecuteState memory state;
        state.balance0Start = token0.balanceOfSelf();
        state.balance1Start = token1.balanceOfSelf();
        uint256 lendBalanceBefore = isThirdToken ? lendToken.balanceOfSelf() : 0;

        // Collect fees first and deduct protocol reward
        // Note: fee == total since liquidity decrease is 0 (onlyFees is always true effectively)
        (uint256 feeAmount0, uint256 feeAmount1) = _decreaseLiquidity(
            params.tokenId, 0, 0, 0, params.deadline, params.decreaseLiquidityHookData
        );
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }
        state.reward0 = feeAmount0;
        state.reward1 = feeAmount1;
        (feeAmount0, feeAmount1) = _deductReward(feeAmount0, feeAmount1, feeAmount0, feeAmount1, true, params.rewardX64);
        state.reward0 -= feeAmount0;
        state.reward1 -= feeAmount1;
        state.netFee0 = feeAmount0;
        state.netFee1 = feeAmount1;

        // Adjust collateral: deduct only the reward value (net fees are reused)
        {
            uint256 postCollateral;
            (currentDebt,, postCollateral,,) = vault.loanInfo(params.tokenId);
            collateralValue = postCollateral + (collateralValue - postCollateral) * (Q64 - params.rewardX64) / Q64;
        }

        if (params.leverageUp) {
            _leverageUp(params, vault, poolKey, positionInfo, token0, token1, lendToken, currentDebt, collateralValue, config, state);
        } else {
            _leverageDown(params, vault, token0, token1, lendToken, currentDebt, collateralValue, config, state);
        }

        // Return residual lend token when it's a third token (excludes protocol reward and pre-existing balances)
        if (isThirdToken) {
            uint256 lendBalance = lendToken.balanceOfSelf() - lendBalanceBefore;
            if (lendBalance > 0) {
                _transferToken(vault.ownerOf(params.tokenId), lendToken, lendBalance, true);
            }
        }

        (uint256 newDebt,,,,) = vault.loanInfo(params.tokenId);
        emit AutoLeverage(params.tokenId, params.leverageUp, currentDebt, newDebt);
    }

    function _leverageUp(
        ExecuteParams calldata params,
        IVault vault,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        Currency token0,
        Currency token1,
        Currency lendToken,
        uint256 currentDebt,
        uint256 collateralValue,
        PositionConfig memory config,
        ExecuteState memory state
    ) internal {
        uint256 amount0;
        uint256 amount1;

        {
            uint16 targetBps = config.targetLeverageBps;
            if (currentDebt * 10000 >= collateralValue * targetBps) revert NotReady();

            uint256 denominator = 10000 - uint256(targetBps);
            if (denominator == 0) revert NotReady();

            uint256 borrowAmount = (uint256(targetBps) * collateralValue - currentDebt * 10000) / denominator;
            if (borrowAmount == 0) revert NotReady();

            // Snapshot balances before borrow to calculate received amounts
            uint256 balance0Before = token0.balanceOfSelf();
            uint256 balance1Before = token1.balanceOfSelf();

            // Borrow from vault
            vault.borrow(params.tokenId, borrowAmount);

            amount0 = token0.balanceOfSelf() - balance0Before + state.netFee0;
            amount1 = token1.balanceOfSelf() - balance1Before + state.netFee1;
        }

        // Swap borrowed lend token to position tokens
        if (params.amountIn0 != 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(lendToken, token0, params.amountIn0, params.amountOut0Min, params.swapData0)
            );
            if (lendToken == token1) amount1 -= amountIn;
            amount0 += amountOut;
        }
        if (params.amountIn1 != 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(lendToken, token1, params.amountIn1, params.amountOut1Min, params.swapData1)
            );
            if (lendToken == token0) amount0 -= amountIn;
            amount1 += amountOut;
        }

        // Increase liquidity
        _handleApproval(permit2, token0, amount0);
        _handleApproval(permit2, token1, amount1);

        {
            uint128 liquidity = _calculateLiquidity(
                positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1
            );

            // Track balances before increase to check minimum amounts added
            uint256 balanceBeforeAdd0 = token0.balanceOfSelf();
            uint256 balanceBeforeAdd1 = token1.balanceOfSelf();

            (bytes memory actions, bytes[] memory params_array) =
                _buildActionsForIncreasingLiquidity(uint8(Actions.INCREASE_LIQUIDITY), token0, token1);
            params_array[0] = abi.encode(
                params.tokenId, liquidity, type(uint128).max, type(uint128).max, params.increaseLiquidityHookData
            );

            positionManager.modifyLiquidities{value: _getNativeAmount(token0, token1, amount0, amount1)}(
                abi.encode(actions, params_array), params.deadline
            );

            // Enforce minimum amounts added
            uint256 added0 = balanceBeforeAdd0 - token0.balanceOfSelf();
            uint256 added1 = balanceBeforeAdd1 - token1.balanceOfSelf();
            if (added0 < params.amountAddMin0 || added1 < params.amountAddMin1) {
                revert InsufficientAmountAdded();
            }
        }

        // Send leftover to owner (excludes protocol reward and pre-existing balances)
        address owner = vault.ownerOf(params.tokenId);
        uint256 leftover0 = token0.balanceOfSelf() - state.balance0Start - state.reward0;
        uint256 leftover1 = token1.balanceOfSelf() - state.balance1Start - state.reward1;
        if (leftover0 > 0) {
            _transferToken(owner, token0, leftover0, true);
        }
        if (leftover1 > 0) {
            _transferToken(owner, token1, leftover1, true);
        }
    }

    function _leverageDown(
        ExecuteParams calldata params,
        IVault vault,
        Currency token0,
        Currency token1,
        Currency lendToken,
        uint256 currentDebt,
        uint256 collateralValue,
        PositionConfig memory config,
        ExecuteState memory state
    ) internal {
        uint128 liquidityToRemove;
        uint256 netFeeLendValue;
        {
            uint16 targetBps = config.targetLeverageBps;
            if (currentDebt * 10000 <= collateralValue * targetBps) revert NotReady();

            uint256 denominator = 10000 - uint256(targetBps);
            if (denominator == 0) revert NotReady();

            uint256 repayAmount = (currentDebt * 10000 - uint256(targetBps) * collateralValue) / denominator;

            // Net fees in lend token reduce how much liquidity must be removed
            netFeeLendValue = (lendToken == token0) ? state.netFee0 : ((lendToken == token1) ? state.netFee1 : 0);
            repayAmount = repayAmount > netFeeLendValue ? repayAmount - netFeeLendValue : 0;

            if (repayAmount > 0) {
                uint128 currentLiquidity = positionManager.getPositionLiquidity(params.tokenId);
                if (currentLiquidity == 0) revert NoLiquidity();

                // Calculate proportional liquidity to remove
                // Use collateralValue as proxy for total position value
                if (collateralValue > 0) {
                    liquidityToRemove = uint128(uint256(currentLiquidity) * repayAmount / collateralValue);
                }
                if (liquidityToRemove > currentLiquidity) liquidityToRemove = currentLiquidity;
            }
            if (liquidityToRemove == 0 && netFeeLendValue == 0) revert NotReady();
        }

        uint256 amount0;
        uint256 amount1;
        if (liquidityToRemove > 0) {
            (amount0, amount1) = _decreaseLiquidity(
                params.tokenId,
                liquidityToRemove,
                params.amountRemoveMin0,
                params.amountRemoveMin1,
                params.deadline,
                params.decreaseLiquidityHookData
            );
        }
        // Include net fees in available amounts for swap/repay
        amount0 += state.netFee0;
        amount1 += state.netFee1;

        // Swap position tokens to lend token
        uint256 lendAmount = lendToken == token0 ? amount0 : (lendToken == token1 ? amount1 : 0);

        if (params.amountIn0 != 0 && !(lendToken == token0)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(token0, lendToken, params.amountIn0, params.amountOut0Min, params.swapData0)
            );
            amount0 -= amountIn;
            lendAmount += amountOut;
        }
        if (params.amountIn1 != 0 && !(lendToken == token1)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(token1, lendToken, params.amountIn1, params.amountOut1Min, params.swapData1)
            );
            amount1 -= amountIn;
            lendAmount += amountOut;
        }

        // Repay debt
        if (lendAmount > 0) {
            if (lendAmount > currentDebt) lendAmount = currentDebt;
            SafeERC20.forceApprove(IERC20(Currency.unwrap(lendToken)), address(vault), lendAmount);
            vault.repay(params.tokenId, lendAmount, false);
        }

        // Send leftover to owner (excludes protocol reward and pre-existing balances)
        address owner = vault.ownerOf(params.tokenId);
        uint256 leftover0 = token0.balanceOfSelf() - state.balance0Start - state.reward0;
        uint256 leftover1 = token1.balanceOfSelf() - state.balance1Start - state.reward1;
        if (leftover0 > 0) {
            _transferToken(owner, token0, leftover0, true);
        }
        if (leftover1 > 0) {
            _transferToken(owner, token1, leftover1, true);
        }
    }

    /// @notice Position owner configures auto-leverage
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        if (config.isActive) {
            if (config.targetLeverageBps > 9900) {
                revert InvalidConfig();
            }
            if (config.rebalanceThresholdBps == 0 || config.rebalanceThresholdBps > config.targetLeverageBps) {
                revert InvalidConfig();
            }
        }

        // Must be vault-owned position
        address posOwner = IERC721(address(positionManager)).ownerOf(tokenId);
        if (!vaults[posOwner]) {
            revert Unauthorized();
        }
        address realOwner = IVault(posOwner).ownerOf(tokenId);
        if (realOwner != msg.sender) {
            revert Unauthorized();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.targetLeverageBps,
            config.rebalanceThresholdBps,
            config.maxRewardX64
        );
    }
}
