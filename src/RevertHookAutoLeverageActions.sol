// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {RevertHookFunctionsBase} from "./RevertHookFunctionsBase.sol";

/// @title RevertHookAutoLeverageActions
/// @notice Contains auto-leverage functions for RevertHook (called via delegatecall)
contract RevertHookAutoLeverageActions is RevertHookFunctionsBase {
    using PoolIdLibrary for PoolKey;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator
    ) RevertHookFunctionsBase(_permit2, _v4Oracle, _liquidityCalculator) {}

    // ==================== Auto Leverage ====================

    /// @notice Adjusts leverage for a vault-owned position based on current vs target debt ratio
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick
    function autoLeverage(PoolKey calldata poolKey, PoolId, uint256 tokenId, bool isUpperTrigger) external {
        _requireAuthorization(tokenId);

        IVault vault = IVault(msg.sender);
        (uint256 currentDebt,, uint256 collateralValue,,) = vault.loanInfo(tokenId);

        uint16 targetRatioBps = positionConfigs[tokenId].autoLeverageTargetBps;
        uint256 currentRatio = collateralValue > 0 ? currentDebt * 10000 / collateralValue : 0;

        // Adjust leverage based on current vs target ratio
        if (currentRatio < targetRatioBps) {
            _increaseLeverage(poolKey, tokenId, vault, currentDebt, collateralValue, targetRatioBps);
        } else if (currentRatio > targetRatioBps) {
            _decreaseLeverage(poolKey, tokenId, vault, currentDebt, collateralValue, targetRatioBps);
        }

        // Update triggers for new base tick
        _removePositionTriggers(tokenId, poolKey);
        int24 newBaseTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);
        positionStates[tokenId].autoLeverageBaseTick = (newBaseTick / poolKey.tickSpacing) * poolKey.tickSpacing;
        _addPositionTriggers(tokenId, poolKey);

        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        emit AutoLeverage(tokenId, isUpperTrigger, currentDebt, newDebt);
    }

    /// @notice Increases leverage by borrowing and adding liquidity
    function _increaseLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        IVault vault,
        uint256 currentDebt,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal {
        if (currentDebt * 10000 >= collateralValue * targetRatioBps) return;

        uint256 denominator = 10000 - uint256(targetRatioBps);
        if (denominator == 0) return;

        // Calculate amount to borrow to reach target ratio
        uint256 borrowAmount = (uint256(targetRatioBps) * collateralValue - currentDebt * 10000) / denominator;
        if (borrowAmount == 0) return;

        // Borrow from vault
        Currency lendToken = Currency.wrap(vault.asset());
        vault.borrow(tokenId, borrowAmount);

        // Swap to optimal ratio and add liquidity
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        (uint256 amount0, uint256 amount1) = _calculateAndSwap(
            tokenId,
            poolKey,
            positionInfo.tickLower(),
            positionInfo.tickUpper(),
            lendToken == poolKey.currency0 ? borrowAmount : 0,
            lendToken == poolKey.currency1 ? borrowAmount : 0
        );

        _approveToken(poolKey.currency0, amount0);
        _approveToken(poolKey.currency1, amount1);
        _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
    }

    /// @notice Decreases leverage by removing liquidity and repaying debt
    function _decreaseLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        IVault vault,
        uint256 currentDebt,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal {
        if (currentDebt * 10000 <= collateralValue * targetRatioBps) return;

        uint256 denominator = 10000 - uint256(targetRatioBps);
        if (denominator == 0) return;

        // Calculate amount to repay to reach target ratio
        uint256 repayAmount = (currentDebt * 10000 - uint256(targetRatioBps) * collateralValue) / denominator;

        Currency lendToken = Currency.wrap(vault.asset());
        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        (uint256 positionValue,,,) = v4Oracle.getValue(tokenId, vault.asset());

        if (positionValue == 0 || currentLiquidity == 0) return;

        // Calculate liquidity to remove based on value ratio
        uint128 liquidityToRemove = uint128(uint256(currentLiquidity) * repayAmount / positionValue);
        if (liquidityToRemove > currentLiquidity) liquidityToRemove = currentLiquidity;
        if (liquidityToRemove == 0) return;

        // Remove partial liquidity and swap to lend token
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            _decreaseLiquidityPartial(tokenId, liquidityToRemove);

        uint256 lendAmount = _swapToLendToken(tokenId, poolKey, lendToken, currency0, currency1, amount0, amount1);

        // Repay debt
        _repayDebtToVault(tokenId, vault, Currency.unwrap(lendToken), lendAmount, currentDebt);

        _sendLeftoverTokens(tokenId, currency0, currency1, vault.ownerOf(tokenId));
    }
}
