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
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {RevertHookFunctionsBase} from "./RevertHookFunctionsBase.sol";

/// @title RevertHookAutoLendActions
/// @notice Contains auto-lend functions for RevertHook (called via delegatecall)
contract RevertHookAutoLendActions is RevertHookFunctionsBase {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator
    ) RevertHookFunctionsBase(_permit2, _v4Oracle, _liquidityCalculator) {}

    /// @notice Forces exit from auto-lend position (called by position owner)
    /// @param tokenId The token ID of the position
    function autoLendForceExit(uint256 tokenId) external {
        address owner = _getOwner(tokenId, true);
        if (msg.sender != owner) revert Unauthorized();

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _removePositionTriggers(tokenId, poolKey);

        PositionState storage state = positionStates[tokenId];
        if (state.autoLendShares > 0) {
            uint256 redeemedAmount = IERC4626(state.autoLendVault).redeem(
                state.autoLendShares, address(this), address(this)
            );

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
        address owner = _getOwner(tokenId, false);
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        Currency lendCurrency = isUpperTrigger ? poolKey.currency1 : poolKey.currency0;
        address tokenAddress = Currency.unwrap(lendCurrency);
        IERC4626 lendVault = autoLendVaults[tokenAddress];
        if (address(lendVault) == address(0)) {
            emit HookAutoLendFailed(address(0), lendCurrency, abi.encodeWithSignature("InvalidConfig()"));
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
            return;
        }

        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);
        uint256 lendAmount = isUpperTrigger ? amount1 : amount0;
        if (amount0 == 0 && amount1 == 0) {
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
            return;
        }

        SafeERC20.forceApprove(IERC20(tokenAddress), address(lendVault), lendAmount);
        try lendVault.deposit(lendAmount, address(this)) returns (uint256 shares) {
            PositionState storage state = positionStates[tokenId];
            state.autoLendShares = shares;
            state.autoLendToken = tokenAddress;
            state.autoLendAmount = lendAmount;
            state.autoLendVault = address(lendVault);

            _sendLeftoverTokens(tokenId, currency0, currency1, owner);
            _removeOppositeAutoLendDepositTrigger(tokenId, poolKey, positionInfo, isUpperTrigger);
            _addPositionTriggers(tokenId, poolKey);

            emit AutoLendDeposit(tokenId, lendCurrency, lendAmount, shares);
        } catch (bytes memory reason) {
            SafeERC20.forceApprove(IERC20(tokenAddress), address(lendVault), 0);
            _restoreAutoLendPosition(
                tokenId, poolKey, positionInfo, currency0, currency1, amount0, amount1, owner, isUpperTrigger
            );
            emit HookAutoLendFailed(address(lendVault), lendCurrency, reason);
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
            return;
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
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
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
        uint256 shares = positionStates[tokenId].autoLendShares;
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        _processLendingGain(tokenId, poolKey, Currency.wrap(tokenAddress), redeemedAmount, originalLendAmount);

        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _approveToken(Currency.wrap(tokenAddress), redeemedAmount);

        uint256 newTokenId;
        int24 baseTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);

        if (tokenAddress == Currency.unwrap(poolKey.currency0)) {
            if (baseTick < positionInfo.tickLower()) {
                _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(redeemedAmount), 0);
            } else {
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
                _increaseLiquidity(tokenId, poolKey, positionInfo, 0, uint128(redeemedAmount));
            } else {
                int24 tickWidth = positionInfo.tickUpper() - positionInfo.tickLower();
                (newTokenId,,) = _mintPosition(poolKey, baseTick - tickWidth, baseTick, 0, uint128(redeemedAmount), owner);
            }
        }

        _resetAutoLendState(tokenId);
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, realOwner);

        if (newTokenId > 0) {
            generalConfigs[newTokenId] = generalConfigs[tokenId];
            _copyPositionConfig(newTokenId, positionConfigs[tokenId]);
            _disablePosition(tokenId);
        } else if (positionManager.getPositionLiquidity(tokenId) > liquidityBefore) {
            _addPositionTriggers(tokenId, poolKey);
        } else {
            _disablePosition(tokenId);
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
        }

        emit AutoLendWithdraw(tokenId, Currency.wrap(tokenAddress), redeemedAmount, shares);
    }

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

    function _restoreAutoLendPosition(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address owner,
        bool isUpperTrigger
    ) internal {
        _approveToken(currency0, amount0);
        _approveToken(currency1, amount1);
        _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
        _sendLeftoverTokens(tokenId, currency0, currency1, owner);

        if (positionManager.getPositionLiquidity(tokenId) == 0) {
            _disablePosition(tokenId);
        } else {
            _removeTriggeredAutoLendDepositTrigger(tokenId, poolKey, positionInfo, isUpperTrigger);
        }
    }

    function _removeOppositeAutoLendDepositTrigger(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        bool isUpperTrigger
    ) internal {
        int24 tolerance = positionConfigs[tokenId].autoLendToleranceTick;
        if (isUpperTrigger) {
            lowerTriggerAfterSwap[poolKey.toId()].remove(
                positionInfo.tickLower() - tolerance * 2 - poolKey.tickSpacing, tokenId
            );
        } else {
            upperTriggerAfterSwap[poolKey.toId()].remove(positionInfo.tickUpper() + tolerance * 2, tokenId);
        }
    }

    function _removeTriggeredAutoLendDepositTrigger(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        bool isUpperTrigger
    ) internal {
        int24 tolerance = positionConfigs[tokenId].autoLendToleranceTick;
        if (isUpperTrigger) {
            upperTriggerAfterSwap[poolKey.toId()].remove(positionInfo.tickUpper() + tolerance * 2, tokenId);
        } else {
            lowerTriggerAfterSwap[poolKey.toId()].remove(
                positionInfo.tickLower() - tolerance * 2 - poolKey.tickSpacing, tokenId
            );
        }
    }
}
