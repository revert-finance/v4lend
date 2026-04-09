// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {NativeAssetLib} from "../shared/NativeAssetLib.sol";
import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoLendLib} from "../shared/planning/AutoLendLib.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {RevertHookActionBase} from "./RevertHookActionBase.sol";
import {RevertHookSwapActions} from "./RevertHookSwapActions.sol";

/// @title RevertHookAutoLendActions
/// @notice Contains auto-lend functions for RevertHook (called via delegatecall)
contract RevertHookAutoLendActions is RevertHookActionBase {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    IHookFeeController internal immutable hookFeeController;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookFeeController _hookFeeController,
        IHookRouteController _hookRouteController,
        RevertHookSwapActions _swapActions
    ) RevertHookActionBase(_permit2, _v4Oracle, _liquidityCalculator, _hookRouteController, _swapActions) {
        hookFeeController = _hookFeeController;
    }

    /// @notice Forces exit from auto-lend position (called by position owner)
    /// @param tokenId The token ID of the position
    function autoLendForceExit(uint256 tokenId) external {
        address owner = _getOwner(tokenId, true);
        if (msg.sender != owner) revert Unauthorized();

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _removePositionTriggers(tokenId, poolKey);

        PositionState storage state = _positionStates[tokenId];
        uint256 shares = state.autoLendShares;
        address autoLendToken = state.autoLendToken;
        uint256 autoLendAmount = state.autoLendAmount;
        if (shares > 0) {
            Currency lendCurrency = Currency.wrap(autoLendToken);
            uint256 redeemedAmount = IERC4626(state.autoLendVault).redeem(shares, address(this), address(this));
            (, uint256 protocolFee) = _processLendingGain(redeemedAmount, autoLendAmount);
            NativeAssetLib.unwrapIfNative(weth, lendCurrency, redeemedAmount);
            _resetAutoLendState(tokenId);
            _disablePosition(tokenId);
            _sendLendingProtocolFee(tokenId, poolKey, lendCurrency, protocolFee);
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, owner);

            emit AutoLendForceExit(tokenId, lendCurrency, redeemedAmount, shares);
            return;
        }

        _resetAutoLendState(tokenId);
        _disablePosition(tokenId);
    }

    /// @notice Deposits position funds into lending vault when out of range
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick
    function autoLendDeposit(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        address owner = _getOwner(tokenId, false);
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        Currency lendCurrency = isUpperTrigger ? poolKey.currency1 : poolKey.currency0;
        address tokenAddress = Currency.unwrap(lendCurrency);
        IERC4626 lendVault = _autoLendVaults[tokenAddress];
        if (address(lendVault) == address(0) && lendCurrency.isAddressZero()) {
            lendVault = _autoLendVaults[address(weth)];
        }
        if (address(lendVault) == address(0)) {
            emit HookAutoLendFailed(address(0), lendCurrency, abi.encodeWithSignature("InvalidConfig()"));
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
            return;
        }

        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            _decreaseLiquidity(poolKey, tokenId, false);
        uint256 lendAmount = isUpperTrigger ? amount1 : amount0;
        if (amount0 == 0 && amount1 == 0) {
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
            return;
        }

        address depositToken = NativeAssetLib.wrapIfNative(weth, lendCurrency, lendAmount);

        SafeERC20.forceApprove(IERC20(depositToken), address(lendVault), lendAmount);
        try lendVault.deposit(lendAmount, address(this)) returns (uint256 shares) {
            PositionState storage state = _positionStates[tokenId];
            state.autoLendShares = shares;
            state.autoLendToken = tokenAddress;
            state.autoLendAmount = lendAmount;
            state.autoLendVault = address(lendVault);

            _sendLeftoverTokens(tokenId, currency0, currency1, owner);
            _removeAutoLendDepositTrigger(tokenId, poolKey, positionInfo, !isUpperTrigger);
            _addPositionTriggers(tokenId, poolKey);

            emit AutoLendDeposit(tokenId, lendCurrency, lendAmount, shares);
        } catch (bytes memory reason) {
            SafeERC20.forceApprove(IERC20(depositToken), address(lendVault), 0);
            NativeAssetLib.unwrapIfNative(weth, lendCurrency, lendAmount);
            _restoreAutoLendPosition(
                tokenId, poolKey, positionInfo, currency0, currency1, amount0, amount1, owner, isUpperTrigger
            );
            emit HookAutoLendFailed(address(lendVault), lendCurrency, reason);
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
            return;
        }
        SafeERC20.forceApprove(IERC20(depositToken), address(lendVault), 0);
    }

    /// @notice Withdraws from lending vault and adds liquidity back when in range
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param shares The number of shares to redeem
    function autoLendWithdraw(PoolKey calldata poolKey, uint256 tokenId, uint256 shares) external {
        PositionState storage state = _positionStates[tokenId];

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
        address beneficiary = _vaults[owner] ? IVault(owner).ownerOf(tokenId) : owner;
        uint256 shares = _positionStates[tokenId].autoLendShares;
        Currency lendCurrency = Currency.wrap(tokenAddress);

        (uint256 reentryAmount, uint256 protocolFee) = _processLendingGain(redeemedAmount, originalLendAmount);
        NativeAssetLib.unwrapIfNative(weth, lendCurrency, redeemedAmount);

        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _approveToken(lendCurrency, reentryAmount);

        bool isToken0Lent = tokenAddress == Currency.unwrap(poolKey.currency0);
        uint256 newTokenId;
        bool restoredExistingPosition;
        (bool addToExisting, int24 newTickLower, int24 newTickUpper) = AutoLendLib.planOneSidedReentry(
            _getCurrentTick(poolKey.toId()),
            poolKey.tickSpacing,
            positionInfo.tickLower(),
            positionInfo.tickUpper(),
            isToken0Lent
        );

        if (addToExisting) {
            (uint256 restored0, uint256 restored1) = _increaseLiquidity(
                tokenId,
                poolKey,
                positionInfo,
                // forge-lint: disable-next-line(unsafe-typecast)
                isToken0Lent ? uint128(reentryAmount) : 0,
                // forge-lint: disable-next-line(unsafe-typecast)
                isToken0Lent ? 0 : uint128(reentryAmount)
            );
            restoredExistingPosition = restored0 > 0 || restored1 > 0;
        } else {
            (newTokenId,,) = _mintPosition(
                poolKey,
                newTickLower,
                newTickUpper,
                // forge-lint: disable-next-line(unsafe-typecast)
                isToken0Lent ? uint128(reentryAmount) : 0,
                // forge-lint: disable-next-line(unsafe-typecast)
                isToken0Lent ? 0 : uint128(reentryAmount),
                owner
            );
        }

        _resetAutoLendState(tokenId);
        if (newTokenId > 0) {
            _migrateRemintedPosition(tokenId, newTokenId);
        } else if (restoredExistingPosition) {
            _addPositionTriggers(tokenId, poolKey);
        } else {
            _disablePosition(tokenId);
            emit HookActionFailed(tokenId, Mode.AUTO_LEND);
        }
        _sendLendingProtocolFee(tokenId, poolKey, lendCurrency, protocolFee);
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, beneficiary);

        emit AutoLendWithdraw(tokenId, lendCurrency, redeemedAmount, shares);
    }

    /// @notice Processes gain from lending (takes protocol fee on gain)
    function _processLendingGain(uint256 redeemedAmount, uint256 originalAmount)
        internal
        view
        returns (uint256 netRedeemedAmount, uint256 protocolFee)
    {
        netRedeemedAmount = redeemedAmount;
        uint256 gain = redeemedAmount > originalAmount ? redeemedAmount - originalAmount : 0;
        if (gain > 0) {
            protocolFee = gain * hookFeeController.autoLendFeeBps() / 10000;
            if (protocolFee > 0) {
                netRedeemedAmount -= protocolFee;
            }
        }
    }

    function _sendLendingProtocolFee(uint256 tokenId, PoolKey memory poolKey, Currency lendCurrency, uint256 protocolFee)
        internal
    {
        if (protocolFee == 0) return;

        address protocolFeeRecipient = hookFeeController.protocolFeeRecipient();
        lendCurrency.transfer(protocolFeeRecipient, protocolFee);

        bool isToken0 = poolKey.currency0 == lendCurrency;
        emit SendProtocolFee(
            tokenId,
            poolKey.currency0,
            poolKey.currency1,
            isToken0 ? protocolFee : 0,
            isToken0 ? 0 : protocolFee,
            protocolFeeRecipient
        );
    }

    /// @notice Resets the auto-lend state for a position
    function _resetAutoLendState(uint256 tokenId) internal {
        PositionState storage state = _positionStates[tokenId];
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
        (uint256 restored0, uint256 restored1) =
            // forge-lint: disable-next-line(unsafe-typecast)
            _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
        _sendLeftoverTokens(tokenId, currency0, currency1, owner);

        if (restored0 == 0 && restored1 == 0) {
            _disablePosition(tokenId);
        } else {
            _removeAutoLendDepositTrigger(tokenId, poolKey, positionInfo, isUpperTrigger);
        }
    }

    function _removeAutoLendDepositTrigger(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        bool removeUpperTrigger
    ) internal {
        int24 tolerance = _positionConfigs[tokenId].autoLendToleranceTick;
        if (removeUpperTrigger) {
            _upperTriggerAfterSwap[poolKey.toId()].remove(positionInfo.tickUpper() + tolerance * 2, tokenId);
        } else {
            _lowerTriggerAfterSwap[poolKey.toId()].remove(
                positionInfo.tickLower() - tolerance * 2 - poolKey.tickSpacing, tokenId
            );
        }
    }
}
