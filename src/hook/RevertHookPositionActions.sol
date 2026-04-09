// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoRangeLib} from "../shared/planning/AutoRangeLib.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {RevertHookActionBase} from "./RevertHookActionBase.sol";
import {RevertHookSwapActions} from "./RevertHookSwapActions.sol";

/// @title RevertHookPositionActions
/// @notice Contains auto-exit, auto-range, and auto-compound functions for RevertHook (called via delegatecall)
contract RevertHookPositionActions is RevertHookActionBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookRouteController _hookRouteController,
        RevertHookSwapActions _swapActions
    ) RevertHookActionBase(_permit2, _v4Oracle, _liquidityCalculator, _hookRouteController, _swapActions) {}

    // ==================== Auto Exit ====================

    /// @notice Executes auto-exit for a position when trigger conditions are met
    /// @dev For vault positions with debt, repays debt before sending remaining tokens to owner
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick, false if lower tick
    function autoExit(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        _requireAuthorization(tokenId);

        // Remove all liquidity and collect fees
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            _decreaseLiquidity(poolKey, tokenId, false);
        if (amount0 == 0 && amount1 == 0) {
            emit HookActionFailed(tokenId, Mode.AUTO_EXIT);
            return;
        }

        address owner = _getOwner(tokenId, false);
        address beneficiary = owner;

        // Check if this is a vault position with debt
        if (_vaults[owner]) {
            beneficiary = IVault(owner).ownerOf(tokenId);
            uint256 debtShares = IVault(owner).loans(tokenId);

            if (debtShares > 0) {
                _autoExitWithDebtRepayment(
                    tokenId, poolKey, IVault(owner), beneficiary, isUpperTrigger, currency0, currency1, amount0, amount1
                );
                return;
            }
        }

        // No debt case: swap based on trigger direction and send to owner
        if (_shouldSwapOnAutoExit(tokenId, isUpperTrigger)) {
            bool swapZeroForOne = !isUpperTrigger;
            uint256 swapAmount = swapZeroForOne ? amount0 : amount1;
            BalanceDelta swapDelta = _executeSwap(poolKey, swapZeroForOne, swapAmount, tokenId, Mode.AUTO_EXIT);
            (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);
        }

        _sendLeftoverTokens(tokenId, currency0, currency1, beneficiary);
        _disablePosition(tokenId);

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    /// @notice Handles auto-exit for vault positions with outstanding debt
    /// @dev Swaps to lend asset and repays debt, respecting the trigger direction for final token
    function _autoExitWithDebtRepayment(
        uint256 tokenId,
        PoolKey memory poolKey,
        IVault vault,
        address beneficiary,
        bool isUpperTrigger,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        address lendAsset = vault.asset();
        Currency lendToken = Currency.wrap(lendAsset);
        bool lendIsToken0 = (lendToken == currency0);
        bool swapOnExit = _shouldSwapOnAutoExit(tokenId, isUpperTrigger);

        // Target token based on trigger direction: upper trigger -> token1, lower trigger -> token0
        bool targetIsToken0 = !isUpperTrigger;
        bool targetIsLendToken = (targetIsToken0 == lendIsToken0);

        (uint256 currentDebt,,,,) = vault.loanInfo(tokenId);

        uint256 lendAmount = lendToken.balanceOfSelf();
        if (lendAmount < currentDebt) {
            lendAmount = _swapToLendToken(tokenId, poolKey, lendToken, currency0, currency1, amount0, amount1, Mode.AUTO_EXIT);
        }
        _repayDebtToVault(tokenId, vault, lendAsset, lendAmount, currentDebt);

        if (swapOnExit && !targetIsLendToken) {
            // Repay against the lend asset first, then rotate any residual value back
            // into the trigger-side token the strategy wants to leave the user with.
            uint256 remainingLend = lendToken.balanceOfSelf();
            if (remainingLend > 0) {
                _executeSwap(poolKey, lendIsToken0, remainingLend, tokenId, Mode.AUTO_EXIT);
            }
        }

        _sendLeftoverTokens(tokenId, currency0, currency1, beneficiary);
        _disablePosition(tokenId);

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    function _shouldSwapOnAutoExit(uint256 tokenId, bool isUpperTrigger) internal view returns (bool) {
        return isUpperTrigger
            ? _positionConfigs[tokenId].autoExitSwapOnUpperTrigger
            : _positionConfigs[tokenId].autoExitSwapOnLowerTrigger;
    }

    // ==================== Auto Range ====================

    /// @notice Executes auto-range for a position when trigger conditions are met
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    function autoRange(PoolKey calldata poolKey, uint256 tokenId) external {
        _requireAuthorization(tokenId);
        (, PositionInfo oldPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Calculate new tick range based on current tick
        (int24 newTickLower, int24 newTickUpper) = AutoRangeLib.plan(
            _getCurrentTick(poolKey.toId()),
            poolKey.tickSpacing,
            _positionConfigs[tokenId].autoRangeLowerDelta,
            _positionConfigs[tokenId].autoRangeUpperDelta
        );

        // This should already be rejected at configuration time.
        if (AutoRangeLib.isSameRange(
                oldPositionInfo.tickLower(), oldPositionInfo.tickUpper(), newTickLower, newTickUpper
            )) {
            revert InvalidConfig();
        }

        // Remove all liquidity from current position
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            _decreaseLiquidity(poolKey, tokenId, false);
        if (amount0 == 0 && amount1 == 0) {
            emit HookActionFailed(tokenId, Mode.AUTO_RANGE);
            return;
        }

        // Swap to optimal ratio for new range
        (amount0, amount1) = _calculateAndSwap(tokenId, poolKey, newTickLower, newTickUpper, amount0, amount1, Mode.AUTO_RANGE);

        address owner = _getOwner(tokenId, false);
        address beneficiary = _vaults[owner] ? IVault(owner).ownerOf(tokenId) : owner;

        // Approve tokens and mint new position
        _approveToken(currency0, amount0);
        _approveToken(currency1, amount1);
        (uint256 newTokenId,,) =
            // forge-lint: disable-next-line(unsafe-typecast)
            _mintPosition(poolKey, newTickLower, newTickUpper, uint128(amount0), uint128(amount1), owner);

        if (newTokenId == 0) {
            // If remint fails, restore liquidity on the original position without re-arming the consumed trigger.
            (amount0, amount1) = _calculateAndSwap(
                tokenId, poolKey, oldPositionInfo.tickLower(), oldPositionInfo.tickUpper(), amount0, amount1, Mode.AUTO_RANGE
            );
            _approveToken(currency0, amount0);
            _approveToken(currency1, amount1);
            (uint256 restored0, uint256 restored1) =
                // forge-lint: disable-next-line(unsafe-typecast)
                _increaseLiquidity(tokenId, poolKey, oldPositionInfo, uint128(amount0), uint128(amount1));
            _sendLeftoverTokens(tokenId, currency0, currency1, beneficiary);
            if (restored0 > 0 || restored1 > 0) {
                _removePositionTriggers(tokenId, poolKey);
                _deactivatePosition(tokenId);
            } else {
                _disablePosition(tokenId);
            }
            emit HookActionFailed(tokenId, Mode.AUTO_RANGE);
            return;
        }

        // Send leftover tokens and copy config to new position
        _sendLeftoverTokens(tokenId, currency0, currency1, beneficiary);
        _migrateRemintedPosition(tokenId, newTokenId);

        emit AutoRange(tokenId, newTokenId, currency0, currency1, amount0, amount1);
    }

    // ==================== Auto Collect ====================

    /// @notice Auto-collects fees from multiple positions
    /// @param tokenIds Array of token IDs to collect from
    function autoCollect(uint256[] calldata tokenIds) external {
        address caller = msg.sender;
        uint256 length = tokenIds.length;
        for (uint256 i; i < length;) {
            uint256 tokenId = tokenIds[i];
            address owner = _getOwner(tokenId, false);
            if (_vaults[owner]) {
                IVault(owner)
                    .transform(tokenId, address(this), abi.encodeCall(this.autoCollectForVault, (tokenId, caller)));
            } else {
                poolManager.unlock(abi.encode(UnlockAction.AUTO_COLLECT, tokenId, caller));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Auto-collect callback for vault-owned positions
    /// @param tokenId The token ID to collect from
    /// @param caller The original caller (for rewards)
    function autoCollectForVault(uint256 tokenId, address caller) external {
        if (!_vaults[msg.sender]) revert Unauthorized();
        _validateCaller(positionManager, tokenId);
        poolManager.unlock(abi.encode(UnlockAction.AUTO_COLLECT, tokenId, caller));
    }

    /// @notice Executes the auto-collect logic (called from unlockCallback)
    /// @param tokenId The token ID to collect from
    /// @param caller The original caller (for rewards)
    function executeAutoCollect(uint256 tokenId, address caller) external {
        PositionConfig storage config = _positionConfigs[tokenId];
        AutoCollectMode collectMode = config.autoCollectMode;

        // Skip if collect is disabled or position is not active
        if (collectMode == AutoCollectMode.NONE || PositionModeFlags.isNone(config.modeFlags)) {
            return;
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Collect fees only (no liquidity removal)
        (,, uint256 fees0, uint256 fees1) = _decreaseLiquidity(poolKey, tokenId, true);
        if (fees0 == 0 && fees1 == 0) return;

        // Process based on collect mode
        if (collectMode == AutoCollectMode.AUTO_COLLECT) {
            // Swap to optimal ratio and add back as liquidity
            (fees0, fees1) =
                _calculateAndSwap(
                    tokenId, poolKey, positionInfo.tickLower(), positionInfo.tickUpper(), fees0, fees1, Mode.AUTO_COLLECT
                );
        } else if (collectMode == AutoCollectMode.HARVEST_TOKEN_0) {
            // Swap token1 to token0
            (fees0, fees1) =
                _applyBalanceDelta(_executeSwap(poolKey, false, fees1, tokenId, Mode.AUTO_COLLECT), fees0, fees1);
        } else if (collectMode == AutoCollectMode.HARVEST_TOKEN_1) {
            // Swap token0 to token1
            (fees0, fees1) =
                _applyBalanceDelta(_executeSwap(poolKey, true, fees0, tokenId, Mode.AUTO_COLLECT), fees0, fees1);
        }
        // HARVEST_TOKENS mode: no swap needed, fees are sent directly to owner

        // Pay rewards to caller
        (fees0, fees1) = _payCollectRewards(tokenId, poolKey.currency0, poolKey.currency1, fees0, fees1, caller);

        if (collectMode == AutoCollectMode.AUTO_COLLECT) {
            _approveToken(poolKey.currency0, fees0);
            _approveToken(poolKey.currency1, fees1);
            // forge-lint: disable-next-line(unsafe-typecast)
            _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(fees0), uint128(fees1));
        }

        // Send remaining tokens to owner
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, _getOwner(tokenId, true));
    }

    // ==================== Internal Helpers ====================

    /// @notice Pays collect rewards to the caller
    function _payCollectRewards(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal returns (uint256, uint256) {
        uint256 reward0 = amount0 * _AUTO_COLLECT_REWARD_BPS / 10000;
        uint256 reward1 = amount1 * _AUTO_COLLECT_REWARD_BPS / 10000;

        if (reward0 > 0) currency0.transfer(recipient, reward0);
        if (reward1 > 0) currency1.transfer(recipient, reward1);

        emit SendRewards(tokenId, currency0, currency1, reward0, reward1, recipient);
        return (amount0 - reward0, amount1 - reward1);
    }
}
