// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {RevertHookFunctionsBase} from "./RevertHookFunctionsBase.sol";

/// @title RevertHookLendingActions
/// @notice Contains auto-leverage and auto-lend functions for RevertHook (called via delegatecall)
contract RevertHookLendingActions is RevertHookFunctionsBase {
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

    // ==================== Auto Lend ====================

    /// @notice Forces exit from auto-lend position (called by position owner)
    /// @param tokenId The token ID of the position
    function autoLendForceExit(uint256 tokenId) external {
        address owner = _getOwner(tokenId, true);
        if (msg.sender != owner) revert Unauthorized();

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _removePositionTriggers(tokenId, poolKey);

        PositionState storage state = positionStates[tokenId];
        if (state.autoLendShares > 0) {
            // Redeem shares from lending vault
            uint256 redeemedAmount = IERC4626(state.autoLendVault).redeem(
                state.autoLendShares, address(this), address(this)
            );

            // Handle any gains from lending
            _processLendingGain(tokenId, poolKey, Currency.wrap(state.autoLendToken), redeemedAmount, state.autoLendAmount);
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, owner);

            emit AutoLendForceExit(tokenId, Currency.wrap(state.autoLendToken), redeemedAmount, state.autoLendShares);
        }

        _resetAutoLendState(tokenId);
        _disablePosition(tokenId);
    }

    /// @notice Deposits position funds into lending vault when out of range
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick
    function autoLendDeposit(PoolKey calldata poolKey, PoolId, uint256 tokenId, bool isUpperTrigger) external {
        _removePositionTriggers(tokenId, poolKey);

        // Remove all liquidity
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        // Determine which token to lend based on trigger direction
        Currency lendCurrency = isUpperTrigger ? currency1 : currency0;
        address tokenAddress = Currency.unwrap(lendCurrency);
        uint256 lendAmount = isUpperTrigger ? amount1 : amount0;

        IERC4626 lendVault = autoLendVaults[tokenAddress];
        if (address(lendVault) == address(0)) return;

        // Deposit into lending vault
        SafeERC20.forceApprove(IERC20(tokenAddress), address(lendVault), lendAmount);
        try lendVault.deposit(lendAmount, address(this)) returns (uint256 shares) {
            // Store lending state
            PositionState storage state = positionStates[tokenId];
            state.autoLendShares = shares;
            state.autoLendToken = tokenAddress;
            state.autoLendAmount = lendAmount;
            state.autoLendVault = address(lendVault);

            _sendLeftoverTokens(tokenId, currency0, currency1, _getOwner(tokenId, true));
            _addPositionTriggers(tokenId, poolKey);

            emit AutoLendDeposit(tokenId, lendCurrency, lendAmount, shares);
        } catch (bytes memory reason) {
            emit HookAutoLendFailed(address(lendVault), lendCurrency, reason);
        }
        SafeERC20.forceApprove(IERC20(tokenAddress), address(lendVault), 0);
    }

    /// @notice Withdraws from lending vault and adds liquidity back when in range
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param shares The number of shares to redeem
    function autoLendWithdraw(PoolKey calldata poolKey, uint256 tokenId, uint256 shares) external {
        PositionState storage state = positionStates[tokenId];

        try IERC4626(state.autoLendVault).redeem(shares, address(this), address(this)) returns (uint256 amount) {
            _processLendWithdraw(poolKey, tokenId, state.autoLendToken, amount, state.autoLendAmount);
        } catch (bytes memory reason) {
            emit HookAutoLendFailed(state.autoLendVault, Currency.wrap(state.autoLendToken), reason);
        }
    }

    /// @notice Processes lending withdrawal and adds liquidity back
    function _processLendWithdraw(
        PoolKey memory poolKey,
        uint256 tokenId,
        address tokenAddress,
        uint256 redeemedAmount,
        uint256 originalLendAmount
    ) internal {
        address owner = _getOwner(tokenId, false);
        address realOwner = vaults[owner] ? IVault(owner).ownerOf(tokenId) : owner;

        _processLendingGain(tokenId, poolKey, Currency.wrap(tokenAddress), redeemedAmount, originalLendAmount);

        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _approveToken(Currency.wrap(tokenAddress), redeemedAmount);

        uint256 newTokenId;
        int24 baseTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);

        // Add liquidity based on which token was lent
        if (tokenAddress == Currency.unwrap(poolKey.currency0)) {
            if (baseTick < positionInfo.tickLower()) {
                // Current tick below position - can add token0 to existing position
                _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(redeemedAmount), 0);
            } else {
                // Current tick within/above position - mint new position above current tick
                int24 tickWidth = positionInfo.tickUpper() - positionInfo.tickLower();
                (newTokenId,,) = _mintPosition(
                    poolKey,
                    baseTick + poolKey.tickSpacing,
                    baseTick + poolKey.tickSpacing + tickWidth,
                    uint128(redeemedAmount),
                    0,
                    owner
                );
            }
        } else {
            if (baseTick >= positionInfo.tickUpper()) {
                // Current tick above position - can add token1 to existing position
                _increaseLiquidity(tokenId, poolKey, positionInfo, 0, uint128(redeemedAmount));
            } else {
                // Current tick within/below position - mint new position below current tick
                int24 tickWidth = positionInfo.tickUpper() - positionInfo.tickLower();
                (newTokenId,,) = _mintPosition(poolKey, baseTick - tickWidth, baseTick, 0, uint128(redeemedAmount), owner);
            }
        }

        _resetAutoLendState(tokenId);
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, realOwner);

        if (newTokenId > 0) {
            _copyPositionConfig(newTokenId, positionConfigs[tokenId]);
            _disablePosition(tokenId);
        } else {
            _addPositionTriggers(tokenId, poolKey);
        }

        emit AutoLendWithdraw(tokenId, Currency.wrap(tokenAddress), redeemedAmount, positionStates[tokenId].autoLendShares);
    }

    // ==================== Internal Helpers ====================

    /// @notice Processes gain from lending (takes protocol fee on gain)
    function _processLendingGain(
        uint256 tokenId,
        PoolKey memory poolKey,
        Currency lendCurrency,
        uint256 redeemedAmount,
        uint256 originalAmount
    ) internal {
        uint256 gain = redeemedAmount > originalAmount ? redeemedAmount - originalAmount : 0;
        if (gain > 0) {
            bool isToken0 = poolKey.currency0 == lendCurrency;
            uint256 protocolFee = gain * protocolFeeBps / 10000;
            lendCurrency.transfer(protocolFeeRecipient, protocolFee);
            emit SendProtocolFee(
                tokenId,
                poolKey.currency0,
                poolKey.currency1,
                isToken0 ? protocolFee : 0,
                isToken0 ? 0 : protocolFee,
                protocolFeeRecipient
            );
        }
    }

    /// @notice Resets the auto-lend state for a position
    function _resetAutoLendState(uint256 tokenId) internal {
        PositionState storage state = positionStates[tokenId];
        state.autoLendShares = 0;
        state.autoLendToken = address(0);
        state.autoLendAmount = 0;
        state.autoLendVault = address(0);
    }
}
