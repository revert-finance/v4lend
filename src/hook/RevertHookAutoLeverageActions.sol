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

    // ==================== Position config validation ====================

    /// @notice Validates a position configuration against the position's pool, range and owner.
    ///         Hosted here (delegatecall from RevertHookConfig._setPositionConfig, shared storage)
    ///         to keep the hook's own bytecode under the EIP-170 limit. Pure validation: no state
    ///         is written, so a direct call is harmless.
    function validatePositionConfig(uint256 tokenId, PositionConfig calldata config) external view {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _validateTickAlignedConfig(config, poolKey.tickSpacing);
        _validateModeFlags(config.modeFlags, tokenId, poolKey);
        _validateRangeConfig(poolKey.tickSpacing, positionInfo.tickLower(), positionInfo.tickUpper(), config);
    }

    function _validateTickAlignedConfig(PositionConfig memory config, int24 tickSpacing) internal pure {
        if (
            !_isValidTickConfig(config.autoExitTickLower, tickSpacing, type(int24).min)
                || !_isValidTickConfig(config.autoExitTickUpper, tickSpacing, type(int24).max)
                || !_isValidTickConfig(config.autoRangeLowerLimit, tickSpacing, type(int24).min)
                || !_isValidTickConfig(config.autoRangeUpperLimit, tickSpacing, type(int24).max)
                || !_isValidTickConfig(config.autoRangeLowerDelta, tickSpacing, 0)
                || !_isValidTickConfig(config.autoRangeUpperDelta, tickSpacing, 0)
                || !_isValidTickConfig(config.autoLendToleranceTick, tickSpacing, 0)
                || config.autoLeverageTargetBps >= 10000
        ) {
            revert InvalidConfig();
        }
    }

    function _validateModeFlags(uint8 modeFlags, uint256 tokenId, PoolKey memory poolKey) internal view {
        if (PositionModeFlags.hasAutoLend(modeFlags) && PositionModeFlags.hasAutoLeverage(modeFlags)) {
            revert InvalidConfig();
        }
        if (PositionModeFlags.hasAutoLend(modeFlags) && PositionModeFlags.hasAutoExit(modeFlags)) {
            revert InvalidConfig();
        }

        _validateAutoLendMode(tokenId, poolKey, modeFlags);
        _validateAutoLeverageMode(tokenId, poolKey, modeFlags);
    }

    function _validateAutoLendMode(uint256 tokenId, PoolKey memory poolKey, uint8 modeFlags) internal view {
        if (!PositionModeFlags.hasAutoLend(modeFlags)) {
            return;
        }

        address tokenOwner = _getOwner(tokenId, false);
        if (_vaults[tokenOwner]) {
            revert InvalidConfig();
        }
        if (
            !_hasAutoLendVault(Currency.unwrap(poolKey.currency0))
                || !_hasAutoLendVault(Currency.unwrap(poolKey.currency1))
        ) {
            revert InvalidConfig();
        }
    }

    function _hasAutoLendVault(address token) internal view returns (bool) {
        if (address(_autoLendVaults[token]) != address(0)) {
            return true;
        }
        return token == address(0) && address(_autoLendVaults[address(weth)]) != address(0);
    }

    function _validateAutoLeverageMode(uint256 tokenId, PoolKey memory poolKey, uint8 modeFlags) internal view {
        address tokenOwner = _getOwner(tokenId, false);
        bool hasAutoLeverage = PositionModeFlags.hasAutoLeverage(modeFlags);
        bool hasAutoExit = PositionModeFlags.hasAutoExit(modeFlags);

        if (hasAutoLeverage || hasAutoExit) {
            bool isVault = _vaults[tokenOwner];

            if (hasAutoLeverage && !isVault) {
                revert InvalidConfig();
            }

            if (isVault) {
                address lendAsset = IVault(tokenOwner).asset();
                if (Currency.unwrap(poolKey.currency0) != lendAsset && Currency.unwrap(poolKey.currency1) != lendAsset)
                {
                    revert InvalidConfig();
                }
            }
        }
    }

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

        uint256 lendAmount =
            _swapToLendToken(tokenId, poolKey, lendToken, currency0, currency1, amount0, amount1, Mode.AUTO_LEVERAGE);

        // Repay debt
        _repayDebtToVault(tokenId, vault, lendAsset, lendAmount, currentDebt);
        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        if (newDebt < currentDebt) {
            _sendLeftoverTokens(tokenId, currency0, currency1, vault.ownerOf(tokenId));
            return true;
        }

        uint256 balance0 = _sweepableBalance(currency0);
        uint256 balance1 = _sweepableBalance(currency1);
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
        _repayDebtToVault(tokenId, vault, Currency.unwrap(lendToken), lendAmount, currentDebt);
        (debtAfterRollback,,,,) = vault.loanInfo(tokenId);
    }
}
