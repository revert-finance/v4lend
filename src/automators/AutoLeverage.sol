// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoLeverageLib} from "../shared/planning/AutoLeverageLib.sol";
import {Automator} from "./Automator.sol";

/// @title AutoLeverage
/// @notice Automatically rebalances leverage ratio when price moves.
/// Operator-triggered, works through vault.transform() for vault-owned positions.
contract AutoLeverage is Automator {
    event AutoLeverageExecuted(uint256 indexed tokenId, bool leverageUp, uint256 debtBefore, uint256 debtAfter);
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        uint16 targetLeverageBps,
        uint16 rebalanceThresholdBps,
        uint16 maxSwapSlippageBps,
        uint64 maxRewardX64
    );

    /// @dev No `onlyFees` flag — AutoLeverage only collects fees (liquidity=0), so fee==total and the flag would have no effect
    struct PositionConfig {
        bool isActive;
        uint16 targetLeverageBps;
        uint16 rebalanceThresholdBps;
        uint16 maxSwapSlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint64 maxRewardX64;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @dev Internal struct to avoid stack-too-deep for fee reuse accounting
    struct ExecuteState {
        uint256 startBalance0;
        uint256 startBalance1;
        uint256 startLendBalance;
        uint256 netFee0;
        uint256 netFee1;
        uint256 protocolFee0;
        uint256 protocolFee1;
    }

    struct ExecuteContext {
        PoolKey poolKey;
        PositionInfo positionInfo;
        Currency token0;
        Currency token1;
        Currency lendToken;
        uint256 currentDebt;
        uint256 collateralValue;
        bool isThirdToken;
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
        uint256 currentRatio = AutoLeverageLib.currentRatio(currentDebt, collateralValue);
        uint256 targetRatio = uint256(config.targetLeverageBps);
        uint256 threshold = uint256(config.rebalanceThresholdBps);

        if (AutoLeverageLib.isWithinThreshold(currentRatio, targetRatio, threshold)) {
            revert NotReady();
        }

        // Validate direction matches current state before collecting fees
        if (params.leverageUp && currentRatio >= targetRatio) {
            revert InvalidConfig();
        }
        if (!params.leverageUp && currentRatio <= targetRatio) {
            revert InvalidConfig();
        }

        ExecuteContext memory ctx;
        (ctx.poolKey, ctx.positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        ctx.token0 = ctx.poolKey.currency0;
        ctx.token1 = ctx.poolKey.currency1;
        ctx.lendToken = Currency.wrap(vault.asset());
        ctx.currentDebt = currentDebt;
        ctx.collateralValue = collateralValue;
        ctx.isThirdToken = !(ctx.lendToken == ctx.token0) && !(ctx.lendToken == ctx.token1);

        ExecuteState memory state;
        state.startBalance0 = ctx.token0.balanceOfSelf();
        state.startBalance1 = ctx.token1.balanceOfSelf();
        if (ctx.isThirdToken) {
            state.startLendBalance = ctx.lendToken.balanceOfSelf();
        }

        // Collect fees first and reserve protocol fees until the end of execution.
        // Note: fee == total since liquidity decrease is 0 (onlyFees is always true effectively).
        (uint256 feeAmount0, uint256 feeAmount1) = _decreaseLiquidity(
            params.tokenId, 0, 0, 0, params.deadline, params.decreaseLiquidityHookData
        );
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }
        (feeAmount0, feeAmount1, state.protocolFee0, state.protocolFee1) =
            _quoteProtocolFees(feeAmount0, feeAmount1, feeAmount0, feeAmount1, true, params.rewardX64);
        state.netFee0 = feeAmount0;
        state.netFee1 = feeAmount1;

        // Adjust collateral: deduct only the protocol fee value because net fees are reused.
        {
            uint256 postCollateral;
            (ctx.currentDebt,, postCollateral,,) = vault.loanInfo(params.tokenId);
            ctx.collateralValue =
                postCollateral + (ctx.collateralValue - postCollateral) * (Q64 - params.rewardX64) / Q64;
        }

        if (params.leverageUp) {
            _leverageUp(params, vault, config, ctx, state);
        } else {
            _leverageDown(params, vault, config, ctx, state);
        }

        // Return residual lend token when it's a third token.
        if (ctx.isThirdToken) {
            uint256 lendBalance = _availableBalance(ctx.lendToken, state.startLendBalance, 0);
            if (lendBalance > 0) {
                _transferToken(vault.ownerOf(params.tokenId), ctx.lendToken, lendBalance);
            }
        }
        _sendProtocolFees(ctx.token0, ctx.token1, state.protocolFee0, state.protocolFee1);

        (uint256 newDebt,,,,) = vault.loanInfo(params.tokenId);
        emit AutoLeverageExecuted(params.tokenId, params.leverageUp, ctx.currentDebt, newDebt);
    }

    function _leverageUp(
        ExecuteParams calldata params,
        IVault vault,
        PositionConfig memory config,
        ExecuteContext memory ctx,
        ExecuteState memory state
    ) internal {
        uint256 amount0;
        uint256 amount1;

        {
            uint256 borrowAmount =
                AutoLeverageLib.borrowAmountToTarget(ctx.currentDebt, ctx.collateralValue, config.targetLeverageBps);
            if (borrowAmount == 0) revert NotReady();

            // Borrow from vault
            vault.borrow(params.tokenId, borrowAmount);

            amount0 = _availableBalance(ctx.token0, state.startBalance0, state.protocolFee0);
            amount1 = _availableBalance(ctx.token1, state.startBalance1, state.protocolFee1);
        }

        // Swap borrowed lend token to position tokens
        if (params.amountIn0 > 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwapWithSlippageCheck(
                RouterSwapParams(ctx.lendToken, ctx.token0, params.amountIn0, params.amountOut0Min, params.swapData0),
                config.maxSwapSlippageBps
            );
            if (ctx.lendToken == ctx.token1) amount1 -= amountIn;
            amount0 += amountOut;
        }
        if (params.amountIn1 > 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwapWithSlippageCheck(
                RouterSwapParams(ctx.lendToken, ctx.token1, params.amountIn1, params.amountOut1Min, params.swapData1),
                config.maxSwapSlippageBps
            );
            if (ctx.lendToken == ctx.token0) amount0 -= amountIn;
            amount1 += amountOut;
        }

        // Increase liquidity
        _handleApproval(permit2, ctx.token0, amount0);
        _handleApproval(permit2, ctx.token1, amount1);

        {
            uint128 liquidity = _calculateLiquidity(
                ctx.positionInfo.tickLower(), ctx.positionInfo.tickUpper(), ctx.poolKey, amount0, amount1
            );

            // Track balances before increase to check minimum amounts added
            uint256 balanceBeforeAdd0 = ctx.token0.balanceOfSelf();
            uint256 balanceBeforeAdd1 = ctx.token1.balanceOfSelf();

            (bytes memory actions, bytes[] memory paramsArray) =
                _buildActionsForIncreasingLiquidity(uint8(Actions.INCREASE_LIQUIDITY), ctx.token0, ctx.token1);
            paramsArray[0] = abi.encode(
                params.tokenId, liquidity, type(uint128).max, type(uint128).max, params.increaseLiquidityHookData
            );

            positionManager.modifyLiquidities{value: _getNativeAmount(ctx.token0, ctx.token1, amount0, amount1)}(
                abi.encode(actions, paramsArray), params.deadline
            );

            // Enforce minimum amounts added
            uint256 added0 = balanceBeforeAdd0 - ctx.token0.balanceOfSelf();
            uint256 added1 = balanceBeforeAdd1 - ctx.token1.balanceOfSelf();
            if (added0 < params.amountAddMin0 || added1 < params.amountAddMin1) {
                revert InsufficientAmountAdded();
            }
        }

        address owner = vault.ownerOf(params.tokenId);
        uint256 leftover0 = _availableBalance(ctx.token0, state.startBalance0, state.protocolFee0);
        uint256 leftover1 = _availableBalance(ctx.token1, state.startBalance1, state.protocolFee1);
        _transferToken(owner, ctx.token0, leftover0);
        _transferToken(owner, ctx.token1, leftover1);
    }

    function _leverageDown(
        ExecuteParams calldata params,
        IVault vault,
        PositionConfig memory config,
        ExecuteContext memory ctx,
        ExecuteState memory state
    ) internal {
        uint128 liquidityToRemove;
        uint256 netFeeLendValue;
        {
            uint256 repayAmount =
                AutoLeverageLib.repayAmountToTarget(ctx.currentDebt, ctx.collateralValue, config.targetLeverageBps);

            // Net fees that can be conservatively converted into the lend token reduce how much liquidity must be removed.
            netFeeLendValue =
                _quoteConservativeLendValue(ctx.token0, ctx.lendToken, state.netFee0, config.maxSwapSlippageBps)
                + _quoteConservativeLendValue(ctx.token1, ctx.lendToken, state.netFee1, config.maxSwapSlippageBps);
            repayAmount = repayAmount > netFeeLendValue ? repayAmount - netFeeLendValue : 0;

            if (repayAmount > 0) {
                uint128 currentLiquidity = positionManager.getPositionLiquidity(params.tokenId);
                if (currentLiquidity == 0) revert NoLiquidity();

                // Calculate proportional liquidity to remove
                // Use collateralValue as proxy for total position value
                liquidityToRemove = AutoLeverageLib.liquidityToRemove(currentLiquidity, repayAmount, ctx.collateralValue);
            }
            if (liquidityToRemove == 0 && netFeeLendValue == 0) revert NotReady();
        }

        uint256 amount0;
        uint256 amount1;
        if (liquidityToRemove > 0) {
            _decreaseLiquidity(
                params.tokenId,
                liquidityToRemove,
                params.amountRemoveMin0,
                params.amountRemoveMin1,
                params.deadline,
                params.decreaseLiquidityHookData
            );
        }
        amount0 = _availableBalance(ctx.token0, state.startBalance0, state.protocolFee0);
        amount1 = _availableBalance(ctx.token1, state.startBalance1, state.protocolFee1);

        // Swap position tokens to lend token
        uint256 lendAmount = ctx.lendToken == ctx.token0 ? amount0 : (ctx.lendToken == ctx.token1 ? amount1 : 0);

        if (params.amountIn0 > 0 && !(ctx.lendToken == ctx.token0)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwapWithSlippageCheck(
                RouterSwapParams(ctx.token0, ctx.lendToken, params.amountIn0, params.amountOut0Min, params.swapData0),
                config.maxSwapSlippageBps
            );
            amount0 -= amountIn;
            lendAmount += amountOut;
        }
        if (params.amountIn1 > 0 && !(ctx.lendToken == ctx.token1)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwapWithSlippageCheck(
                RouterSwapParams(ctx.token1, ctx.lendToken, params.amountIn1, params.amountOut1Min, params.swapData1),
                config.maxSwapSlippageBps
            );
            amount1 -= amountIn;
            lendAmount += amountOut;
        }

        // Repay debt
        if (lendAmount > 0) {
            if (lendAmount > ctx.currentDebt) lendAmount = ctx.currentDebt;
            SafeERC20.forceApprove(IERC20(Currency.unwrap(ctx.lendToken)), address(vault), lendAmount);
            vault.repay(params.tokenId, lendAmount, false);
        }

        address owner = vault.ownerOf(params.tokenId);
        uint256 leftover0 = _availableBalance(ctx.token0, state.startBalance0, state.protocolFee0);
        uint256 leftover1 = _availableBalance(ctx.token1, state.startBalance1, state.protocolFee1);
        _transferToken(owner, ctx.token0, leftover0);
        _transferToken(owner, ctx.token1, leftover1);
    }

    function _quoteConservativeLendValue(
        Currency tokenIn,
        Currency lendToken,
        uint256 amountIn,
        uint16 maxSwapSlippageBps
    ) internal view returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }
        if (tokenIn == lendToken) {
            return amountIn;
        }

        // Without a bounded slippage limit there is no safe lower bound on converted output,
        // so do not credit the swapable fee value when sizing liquidity removal.
        if (maxSwapSlippageBps == 10000) {
            return 0;
        }

        uint160 oracleSqrtPriceX96 = v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(tokenIn), Currency.unwrap(lendToken));
        uint256 oraclePriceX96 = FullMath.mulDiv(uint256(oracleSqrtPriceX96), uint256(oracleSqrtPriceX96), Q96);
        uint256 oracleOut = FullMath.mulDiv(amountIn, oraclePriceX96, Q96);
        amountOut = FullMath.mulDiv(oracleOut, 10000 - uint256(maxSwapSlippageBps), 10000);
    }

    /// @notice Position owner configures auto-leverage
    /// @dev Set maxSwapSlippageBps to 10000 to allow automation for pairs without oracle support.
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        if (config.isActive) {
            if (config.targetLeverageBps > 9900) {
                revert InvalidConfig();
            }
            if (config.rebalanceThresholdBps == 0 || config.rebalanceThresholdBps > config.targetLeverageBps) {
                revert InvalidConfig();
            }
        }
        if (config.maxSwapSlippageBps > 10000) {
            revert InvalidConfig();
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
            config.maxSwapSlippageBps,
            config.maxRewardX64
        );
    }
}
