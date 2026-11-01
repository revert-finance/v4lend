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
import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {RevertHookActionBase} from "./RevertHookActionBase.sol";
import {RevertHookSwapActions} from "./RevertHookSwapActions.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";

/// @title RevertHookAutoLeverageActions
/// @notice Contains auto-leverage functions for RevertHook (called via delegatecall)
contract RevertHookAutoLeverageActions is RevertHookActionBase {
    using PoolIdLibrary for PoolKey;

    error RestoreFailed();
    error NoImprovement();

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookRouteController _hookRouteController,
        RevertHookSwapActions _swapActions
    ) RevertHookActionBase(_permit2, _v4Oracle, _liquidityCalculator, _hookRouteController, _swapActions) {}

    // ==================== Auto Leverage ====================

    /// @notice Adjusts leverage for a vault-owned position based on current vs target debt ratio
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick
    function autoLeverage(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        _requireAuthorization(poolKey, tokenId);

        IVault vault = IVault(msg.sender);
        (uint256 currentDebt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(tokenId);

        uint16 targetRatioBps = _positionConfigs[tokenId].autoLeverageTargetBps;
        uint256 currentRatio = AutoLeverageLib.currentRatio(currentDebt, collateralValue);
        bool success = true;

        // Adjust leverage based on current vs target ratio
        if (currentRatio < targetRatioBps) {
            success =
                _increaseLeverage(poolKey, tokenId, vault, currentDebt, fullValue, collateralValue, targetRatioBps);
        } else if (currentRatio > targetRatioBps) {
            success =
                _decreaseLeverage(poolKey, tokenId, vault, currentDebt, fullValue, collateralValue, targetRatioBps);
        }

        if (!success) {
            autoLeverageNeedsAttention[tokenId] = true;
            emit HookActionFailed(tokenId, Mode.AUTO_LEVERAGE);
            return;
        }

        (uint256 checkedDebt,, uint256 checkedCollateral,,) = vault.loanInfo(tokenId);
        bool loanUnchanged = checkedDebt == currentDebt && checkedCollateral == collateralValue;
        if (
            !loanUnchanged
                && !AutoLeverageLib.improvesTowardTarget(
                    currentDebt,
                    collateralValue,
                    checkedDebt,
                    checkedCollateral,
                    targetRatioBps,
                    _LEVERAGE_OVERSHOOT_TOLERANCE_BPS
                )
        ) revert NoImprovement();

        delete autoLeverageNeedsAttention[tokenId];

        // Update triggers for new base tick
        _removePositionTriggers(tokenId, poolKey);
        int24 newBaseTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);
        _positionStates[tokenId].autoLeverageBaseTick = newBaseTick;
        // The liquidity callback may deactivate a position that fell below the
        // configured minimum. Preserve that decision instead of rearming a dust
        // position after the callback removed its triggers.
        if (_isActivated(tokenId)) {
            _addPositionTriggers(tokenId, poolKey);
        }

        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        emit AutoLeverage(tokenId, isUpperTrigger, currentDebt, newDebt);
    }

    /// @notice Increases leverage by borrowing and adding liquidity
    function _increaseLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        IVault vault,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal returns (bool) {
        uint256 borrowAmount = AutoLeverageLib.borrowAmountToTarget(
            currentDebt, fullValue, collateralValue, targetRatioBps
        );
        // Sized to nothing while the loan is off target (a valueless position): nothing was done,
        // so this is a failed action, not a success that re-centres the triggers (V4LE-71).
        if (borrowAmount == 0) return false;

        // Borrow from vault; a WETH vault on a native pool is unwrapped into the pool's native side
        (Currency lendToken,) = _lendCurrency(poolKey, vault.asset());
        vault.borrow(tokenId, borrowAmount);
        if (lendToken.isAddressZero()) {
            weth.withdraw(borrowAmount);
        }

        // Swap to optimal ratio and add liquidity
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        (uint256 amount0, uint256 amount1) = _calculateAndSwap(
            tokenId,
            poolKey,
            positionInfo.tickLower(),
            positionInfo.tickUpper(),
            lendToken == poolKey.currency0 ? borrowAmount : 0,
            lendToken == poolKey.currency1 ? borrowAmount : 0,
            Mode.AUTO_LEVERAGE
        );

        _approveToken(poolKey.currency0, amount0);
        _approveToken(poolKey.currency1, amount1);
        (
            uint256 used0,
            uint256 used1
            // forge-lint: disable-next-line(unsafe-typecast)
        ) = _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
        if (used0 > 0 || used1 > 0) {
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
        uint256 fullValue,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal returns (bool) {
        uint256 repayAmount = AutoLeverageLib.repayAmountToTarget(
            currentDebt, fullValue, collateralValue, targetRatioBps
        );

        (Currency lendToken,) = _lendCurrency(poolKey, vault.asset());
        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        (bool shouldProceed, uint128 liquidityToRemove) =
            _planDecreaseRemoval(tokenId, vault.asset(), currentLiquidity, repayAmount);
        if (!shouldProceed) return false;

        // Remove partial liquidity (or collect fees only) and swap to lend token
        (,, uint256 amount0, uint256 amount1) = liquidityToRemove > 0
            ? _decreaseLiquidityPartial(poolKey, tokenId, liquidityToRemove)
            : _decreaseLiquidity(poolKey, tokenId, true);
        if (amount0 == 0 && amount1 == 0) {
            if (positionManager.getPositionLiquidity(tokenId) < currentLiquidity) {
                revert RemovalConsumedByFees();
            }
            return false;
        }

        uint256 lendAmount = _swapToLendToken(
            tokenId, poolKey, lendToken, poolKey.currency0, poolKey.currency1, amount0, amount1, Mode.AUTO_LEVERAGE
        );

        // Repay debt up to the target debt for the post-decrease collateral, avoiding the vault's (0, minLoanSize) dust band
        _repayDebtToVault(
            tokenId,
            vault,
            lendToken,
            vault.asset(),
            lendAmount,
            _maxRepayForTarget(vault, tokenId, currentDebt, targetRatioBps, lendAmount)
        );
        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        if (newDebt < currentDebt) {
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
            return true;
        }

        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        uint256 balance0 = _sweepableBalance(poolKey.currency0);
        uint256 balance1 = _sweepableBalance(poolKey.currency1);
        _approveToken(poolKey.currency0, balance0);
        _approveToken(poolKey.currency1, balance1);
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

        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
        return false;
    }

    function _rollbackFailedIncrease(uint256 tokenId, PoolKey memory poolKey, IVault vault, Currency lendToken)
        internal
        returns (uint256 debtAfterRollback)
    {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        uint256 lendAmount = _swapToLendToken(
            tokenId,
            poolKey,
            lendToken,
            currency0,
            currency1,
            _sweepableBalance(currency0),
            _sweepableBalance(currency1),
            Mode.AUTO_LEVERAGE
        );

        (uint256 currentDebt,,,,) = vault.loanInfo(tokenId);
        _repayDebtToVault(tokenId, vault, lendToken, vault.asset(), lendAmount, currentDebt);
        (debtAfterRollback,,,,) = vault.loanInfo(tokenId);
    }

    function _planDecreaseRemoval(
        uint256 tokenId,
        address lendAsset,
        uint128 currentLiquidity,
        uint256 repayAmount
    ) internal view returns (bool shouldProceed, uint128 liquidityToRemove) {
        (uint256 positionValue, uint256 feeValue,,) = v4Oracle.getValue(tokenId, lendAsset);
        if (positionValue == 0 || currentLiquidity == 0 || repayAmount == 0) return (false, 0);

        uint256 principalValue = positionValue > feeValue ? positionValue - feeValue : 0;
        if (repayAmount > feeValue) {
            if (principalValue == 0) return (false, 0);
            liquidityToRemove =
                AutoLeverageLib.liquidityToRemove(currentLiquidity, repayAmount - feeValue, principalValue);
            if (liquidityToRemove == 0) return (false, 0);
        }
        return (true, liquidityToRemove);
    }

    function _vaultMinLoanSize(IVault vault) internal view returns (uint256 minLoanSize) {
        (bool ok, bytes memory data) = address(vault).staticcall(abi.encodeWithSignature("minLoanSize()"));
        if (ok && data.length >= 32) {
            minLoanSize = abi.decode(data, (uint256));
        }
    }

    function _maxRepayForTarget(
        IVault vault,
        uint256 tokenId,
        uint256 currentDebt,
        uint16 targetRatioBps,
        uint256 lendAmount
    ) internal view returns (uint256) {
        (,, uint256 postCollateral,,) = vault.loanInfo(tokenId);
        uint256 targetDebt = postCollateral * targetRatioBps / 10000;
        uint256 minLoanSize = _vaultMinLoanSize(vault);
        if (targetDebt < minLoanSize && currentDebt >= minLoanSize) {
            targetDebt = lendAmount >= currentDebt ? 0 : minLoanSize;
        }
        return currentDebt > targetDebt ? currentDebt - targetDebt : 0;
    }
}
