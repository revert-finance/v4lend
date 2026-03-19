// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoLeverageLib} from "../shared/planning/AutoLeverageLib.sol";
import {RevertHookActionBase} from "./RevertHookActionBase.sol";

/// @title RevertHookAutoLeverageActions
/// @notice Contains auto-leverage functions for RevertHook (called via delegatecall)
contract RevertHookAutoLeverageActions is RevertHookActionBase {
    using PoolIdLibrary for PoolKey;

    error RestoreFailed();

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator
    ) RevertHookActionBase(_permit2, _v4Oracle, _liquidityCalculator) {}

    // ==================== Auto Leverage ====================

    /// @notice Adjusts leverage for a vault-owned position based on current vs target debt ratio
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick
    function autoLeverage(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        _requireAuthorization(tokenId);

        IVault vault = IVault(msg.sender);
        (uint256 currentDebt,, uint256 collateralValue,,) = vault.loanInfo(tokenId);

        uint16 targetRatioBps = _positionConfigs[tokenId].autoLeverageTargetBps;
        uint256 currentRatio = AutoLeverageLib.currentRatio(currentDebt, collateralValue);
        bool success = true;

        // Adjust leverage based on current vs target ratio
        if (currentRatio < targetRatioBps) {
            success = _increaseLeverage(poolKey, tokenId, vault, currentDebt, collateralValue, targetRatioBps);
        } else if (currentRatio > targetRatioBps) {
            success = _decreaseLeverage(poolKey, tokenId, vault, currentDebt, collateralValue, targetRatioBps);
        }

        if (!success) {
            emit HookActionFailed(tokenId, Mode.AUTO_LEVERAGE);
            return;
        }

        // Update triggers for new base tick
        _removePositionTriggers(tokenId, poolKey);
        int24 newBaseTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);
        _positionStates[tokenId].autoLeverageBaseTick = newBaseTick;
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
    ) internal returns (bool) {
        uint256 borrowAmount = AutoLeverageLib.borrowAmountToTarget(currentDebt, collateralValue, targetRatioBps);
        if (borrowAmount == 0) return true;

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
        (uint256 used0, uint256 used1) =
            // forge-lint: disable-next-line(unsafe-typecast)
            _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
        if (used0 != 0 || used1 != 0) {
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
            return true;
        }

        if (_rollbackFailedIncrease(tokenId, poolKey, vault, lendToken) > currentDebt) {
            revert RestoreFailed();
        }

        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
        return false;
    }

    /// @notice Decreases leverage by removing liquidity and repaying debt
    function _decreaseLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        IVault vault,
        uint256 currentDebt,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal returns (bool) {
        uint256 repayAmount = AutoLeverageLib.repayAmountToTarget(currentDebt, collateralValue, targetRatioBps);

        address lendAsset = vault.asset();
        Currency lendToken = Currency.wrap(lendAsset);
        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        (uint256 positionValue,,,) = v4Oracle.getValue(tokenId, lendAsset);
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        if (positionValue == 0 || currentLiquidity == 0) return true;

        // Calculate liquidity to remove based on value ratio
        uint128 liquidityToRemove = AutoLeverageLib.liquidityToRemove(currentLiquidity, repayAmount, positionValue);
        if (liquidityToRemove == 0) return true;

        // Remove partial liquidity and swap to lend token
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            _decreaseLiquidityPartial(poolKey, tokenId, liquidityToRemove);
        if (amount0 == 0 && amount1 == 0) {
            return false;
        }

        uint256 lendAmount = _swapToLendToken(tokenId, poolKey, lendToken, currency0, currency1, amount0, amount1);

        // Repay debt
        _repayDebtToVault(tokenId, vault, lendAsset, lendAmount, currentDebt);
        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        if (newDebt < currentDebt) {
            _sendLeftoverTokens(tokenId, currency0, currency1, vault.ownerOf(tokenId));
            return true;
        }

        uint256 balance0 = currency0.balanceOfSelf();
        uint256 balance1 = currency1.balanceOfSelf();
        _approveToken(currency0, balance0);
        _approveToken(currency1, balance1);
        _increaseLiquidity(
            tokenId,
            poolKey,
            positionInfo,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(balance0),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(balance1)
        );
        if (positionManager.getPositionLiquidity(tokenId) < currentLiquidity) {
            revert RestoreFailed();
        }

        _sendLeftoverTokens(tokenId, currency0, currency1, vault.ownerOf(tokenId));
        return false;
    }

    function _rollbackFailedIncrease(
        uint256 tokenId,
        PoolKey memory poolKey,
        IVault vault,
        Currency lendToken
    ) internal returns (uint256 debtAfterRollback) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        uint256 lendAmount =
            _swapToLendToken(
                tokenId,
                poolKey,
                lendToken,
                currency0,
                currency1,
                currency0.balanceOfSelf(),
                currency1.balanceOfSelf()
            );

        (uint256 currentDebt,,,,) = vault.loanInfo(tokenId);
        _repayDebtToVault(tokenId, vault, Currency.unwrap(lendToken), lendAmount, currentDebt);
        (debtAfterRollback,,,,) = vault.loanInfo(tokenId);
    }
}
