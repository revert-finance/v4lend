// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {AutoRangeLib} from "./lib/AutoRangeLib.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookFunctionsBase} from "./RevertHookFunctionsBase.sol";

/// @title RevertHookPositionActions
/// @notice Contains auto-exit, auto-range, and auto-compound functions for RevertHook (called via delegatecall)
contract RevertHookPositionActions is RevertHookFunctionsBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator
    ) RevertHookFunctionsBase(_permit2, _v4Oracle, _liquidityCalculator) {}

    // ==================== Auto Exit ====================

    /// @notice Executes auto-exit for a position when trigger conditions are met
    /// @dev For vault positions with debt, repays debt before sending remaining tokens to owner
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick, false if lower tick
    function autoExit(PoolKey calldata poolKey, PoolId, uint256 tokenId, bool isUpperTrigger) external {
        _requireAuthorization(tokenId);

        // Remove all liquidity and collect fees
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);
        if (amount0 == 0 && amount1 == 0) {
            emit HookActionFailed(tokenId, Mode.AUTO_EXIT);
            return;
        }

        address owner = _getOwner(tokenId, false);
        address realOwner = owner;

        // Check if this is a vault position with debt
        if (vaults[owner]) {
            realOwner = IVault(owner).ownerOf(tokenId);
            uint256 debtShares = IVault(owner).loans(tokenId);

            if (debtShares > 0) {
                _autoExitWithDebtRepayment(
                    tokenId, poolKey, IVault(owner), realOwner, isUpperTrigger, currency0, currency1, amount0, amount1
                );
                return;
            }
        }

        // No debt case: swap based on trigger direction and send to owner
        bool swapZeroForOne = !isUpperTrigger;
        uint256 swapAmount = swapZeroForOne ? amount0 : amount1;
        BalanceDelta swapDelta = _executeSwap(_getSwapPoolKey(tokenId, poolKey), swapZeroForOne, swapAmount, tokenId);
        (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);

        _sendLeftoverTokens(tokenId, currency0, currency1, realOwner);
        _disablePosition(tokenId);

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    /// @notice Handles auto-exit for vault positions with outstanding debt
    /// @dev Swaps to lend asset and repays debt, respecting the trigger direction for final token
    function _autoExitWithDebtRepayment(
        uint256 tokenId,
        PoolKey memory poolKey,
        IVault vault,
        address realOwner,
        bool isUpperTrigger,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        address lendAsset = vault.asset();
        Currency lendToken = Currency.wrap(lendAsset);
        bool lendIsToken0 = (lendToken == currency0);

        // Target token based on trigger direction: upper trigger -> token1, lower trigger -> token0
        bool targetIsToken0 = !isUpperTrigger;
        bool targetIsLendToken = (targetIsToken0 == lendIsToken0);

        (uint256 currentDebt,,,,) = vault.loanInfo(tokenId);

        if (targetIsLendToken) {
            // Target IS lend token: swap all to lend token first, then repay
            uint256 lendAmount = _swapToLendToken(tokenId, poolKey, lendToken, currency0, currency1, amount0, amount1);
            _repayDebtToVault(tokenId, vault, lendAsset, lendAmount, currentDebt);
        } else {
            // Target is NOT lend token: repay first with lend tokens, then swap remaining to target
            uint256 lendAmount = lendIsToken0 ? amount0 : amount1;
            _repayDebtToVault(tokenId, vault, lendAsset, lendAmount, currentDebt);

            // Swap remaining lend tokens (if any) to target token
            uint256 remainingLend = lendToken.balanceOfSelf();
            if (remainingLend > 0) {
                PoolKey memory swapPool = _getSwapPoolKey(tokenId, poolKey);
                _executeSwap(swapPool, lendIsToken0, remainingLend, tokenId);
            }
        }

        _sendLeftoverTokens(tokenId, currency0, currency1, realOwner);
        _disablePosition(tokenId);

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    // ==================== Auto Range ====================

    /// @notice Executes auto-range for a position when trigger conditions are met
    /// @param poolKey The pool key for the position
    /// @param poolId The pool ID
    /// @param tokenId The token ID of the position
    function autoRange(PoolKey calldata poolKey, PoolId poolId, uint256 tokenId) external {
        _requireAuthorization(tokenId);
        (, PositionInfo oldPositionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Calculate new tick range based on current tick
        (int24 newTickLower, int24 newTickUpper) = AutoRangeLib.plan(
            _getCurrentTick(poolId),
            poolKey.tickSpacing,
            positionConfigs[tokenId].autoRangeLowerDelta,
            positionConfigs[tokenId].autoRangeUpperDelta
        );

        // Remove all liquidity from current position
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);
        if (amount0 == 0 && amount1 == 0) {
            emit HookActionFailed(tokenId, Mode.AUTO_RANGE);
            return;
        }

        // Swap to optimal ratio for new range
        (amount0, amount1) = _calculateAndSwap(tokenId, poolKey, newTickLower, newTickUpper, amount0, amount1);

        address owner = _getOwner(tokenId, false);
        address realOwner = vaults[owner] ? IVault(owner).ownerOf(tokenId) : owner;

        // Approve tokens and mint new position
        _approveToken(currency0, amount0);
        _approveToken(currency1, amount1);
        (uint256 newTokenId,,) = _mintPosition(
            poolKey,
            newTickLower,
            newTickUpper,
            uint128(amount0),
            uint128(amount1),
            owner
        );

        if (newTokenId == 0) {
            // If remint fails, restore liquidity on the original position without re-arming the consumed trigger.
            (amount0, amount1) = _calculateAndSwap(
                tokenId,
                poolKey,
                oldPositionInfo.tickLower(),
                oldPositionInfo.tickUpper(),
                amount0,
                amount1
            );
            _approveToken(currency0, amount0);
            _approveToken(currency1, amount1);
            _increaseLiquidity(tokenId, poolKey, oldPositionInfo, uint128(amount0), uint128(amount1));
            _sendLeftoverTokens(tokenId, currency0, currency1, realOwner);
            if (positionManager.getPositionLiquidity(tokenId) > 0) {
                _removePositionTriggers(tokenId, poolKey);
                _deactivatePosition(tokenId);
            } else {
                _disablePosition(tokenId);
            }
            emit HookActionFailed(tokenId, Mode.AUTO_RANGE);
            return;
        }

        // Send leftover tokens and copy config to new position
        _sendLeftoverTokens(tokenId, currency0, currency1, realOwner);
        _migrateRemintedPosition(tokenId, newTokenId);

        emit AutoRange(tokenId, newTokenId, currency0, currency1, amount0, amount1);
    }

    // ==================== Auto Compound ====================

    /// @notice Auto-compounds fees from multiple positions
    /// @param tokenIds Array of token IDs to compound
    function autoCompound(uint256[] calldata tokenIds) external {
        address caller = msg.sender;
        uint256 length = tokenIds.length;
        for (uint256 i; i < length;) {
            uint256 tokenId = tokenIds[i];
            address owner = _getOwner(tokenId, false);
            if (vaults[owner]) {
                IVault(owner).transform(
                    tokenId,
                    address(this),
                    abi.encodeCall(this.autoCompoundForVault, (tokenId, caller))
                );
            } else {
                poolManager.unlock(abi.encode(tokenId, caller));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Auto-compound callback for vault-owned positions
    /// @param tokenId The token ID to compound
    /// @param caller The original caller (for rewards)
    function autoCompoundForVault(uint256 tokenId, address caller) external {
        if (!vaults[msg.sender]) revert Unauthorized();
        _validateCaller(positionManager, tokenId);
        poolManager.unlock(abi.encode(tokenId, caller));
    }

    /// @notice Executes the auto-compound logic (called from unlockCallback)
    /// @param tokenId The token ID to compound
    /// @param caller The original caller (for rewards)
    function executeAutoCompound(uint256 tokenId, address caller) external {
        PositionConfig storage config = positionConfigs[tokenId];
        AutoCompoundMode compoundMode = config.autoCompoundMode;

        // Skip if compound is disabled or position is not active
        if (compoundMode == AutoCompoundMode.NONE || PositionModeFlags.isNone(config.modeFlags)) {
            return;
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Collect fees only (no liquidity removal)
        (,, uint256 fees0, uint256 fees1) = _decreaseLiquidity(tokenId, true);
        if (fees0 == 0 && fees1 == 0) return;

        // Process based on compound mode
        if (compoundMode == AutoCompoundMode.AUTO_COMPOUND) {
            // Swap to optimal ratio and add back as liquidity
            (fees0, fees1) = _calculateAndSwap(
                tokenId, poolKey, positionInfo.tickLower(), positionInfo.tickUpper(), fees0, fees1
            );
        } else if (compoundMode == AutoCompoundMode.HARVEST_TOKEN_0) {
            // Swap token1 to token0
            (fees0, fees1) = _applyBalanceDelta(_executeSwap(poolKey, false, fees1, tokenId), fees0, fees1);
        } else if (compoundMode == AutoCompoundMode.HARVEST_TOKEN_1) {
            // Swap token0 to token1
            (fees0, fees1) = _applyBalanceDelta(_executeSwap(poolKey, true, fees0, tokenId), fees0, fees1);
        }
        // HARVEST_TOKENS mode: no swap needed, fees are sent directly to owner

        // Pay rewards to caller
        (fees0, fees1) = _payCompoundRewards(tokenId, poolKey.currency0, poolKey.currency1, fees0, fees1, caller);

        // Approve and add liquidity for AUTO_COMPOUND mode
        _approveToken(poolKey.currency0, fees0);
        _approveToken(poolKey.currency1, fees1);
        if (compoundMode == AutoCompoundMode.AUTO_COMPOUND) {
            _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(fees0), uint128(fees1));
        }

        // Send remaining tokens to owner
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, _getOwner(tokenId, true));
    }

    // ==================== Internal Helpers ====================

    /// @notice Pays compound rewards to the caller
    function _payCompoundRewards(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal returns (uint256, uint256) {
        uint256 reward0 = amount0 * autoCompoundRewardBps / 10000;
        uint256 reward1 = amount1 * autoCompoundRewardBps / 10000;

        if (reward0 != 0) currency0.transfer(recipient, reward0);
        if (reward1 != 0) currency1.transfer(recipient, reward1);

        emit SendRewards(tokenId, currency0, currency1, reward0, reward1, recipient);
        return (amount0 - reward0, amount1 - reward1);
    }
}
