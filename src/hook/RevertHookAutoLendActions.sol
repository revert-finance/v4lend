// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {NativeAssetLib} from "../shared/NativeAssetLib.sol";
import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoLendLib} from "../shared/planning/AutoLendLib.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
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
    /// @dev Deploy address of this sidecar; differs from address(this) under delegatecall.
    address private immutable _selfAddress;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookFeeController _hookFeeController,
        IHookRouteController _hookRouteController,
        RevertHookSwapActions _swapActions
    ) RevertHookActionBase(_permit2, _v4Oracle, _liquidityCalculator, _hookRouteController, _swapActions) {
        hookFeeController = _hookFeeController;
        _selfAddress = address(this);
    }

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
                // native/WETH canonicalised: a WETH vault serves a native pool (V4LE-49)
                (, bool lendInPool) = _lendCurrency(poolKey, IVault(tokenOwner).asset());
                if (!lendInPool) {
                    revert InvalidConfig();
                }
            }
        }
    }

    error ProtocolFeesUnsettled();

    // ==================== Protocol fee on collected LP fees ====================

    /// @notice Time-weighted protocol fee on the LP fees a position collects. Called by the hook via
    ///         delegatecall from its after-liquidity callbacks (shared storage layout); hosted here
    ///         to keep the hook bytecode under the EIP-170 limit.
    /// @dev PositionManager attributes hook deltas to principal. DECREASE(0) cannot pay a fee;
    /// use INCREASE(0) with max inputs and settle/close the currencies instead. Removals which
    /// cannot pay all obligations revert, so fees cannot become an unsecured receivable.
    /// @dev Delegatecall-only: a direct call (own storage, spoofable events) is rejected.
    /// @param liquidityDelta Signed liquidity change of the operation (0 for fee-only collections)
    /// @param delta Full caller delta (principal + accrued fees) reported by the pool
    /// @param feeDelta Accrued LP fees reported by the pool
    /// @return newFeeDelta Amount taken by the hook, returned to the pool as the hook delta
    function takeProtocolFees(
        uint256 tokenId,
        PoolKey calldata key,
        int256 liquidityDelta,
        BalanceDelta delta,
        BalanceDelta feeDelta
    ) external returns (BalanceDelta newFeeDelta) {
        if (address(this) == _selfAddress) {
            revert Unauthorized();
        }

        (uint256 fee0, uint256 fee1) = _accrueProtocolFee(tokenId, feeDelta);

        PendingProtocolFee storage pending = _pendingProtocolFees[tokenId];
        uint256 pending0 = pending.amount0;
        uint256 pending1 = pending.amount1;
        uint256 owed0 = fee0 + pending0;
        uint256 owed1 = fee1 + pending1;
        if (owed0 == 0 && owed1 == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        (uint256 cap0, uint256 cap1) = _protocolFeeCaps(liquidityDelta, delta, feeDelta, owed0, owed1);
        uint256 take0 = owed0 > cap0 ? cap0 : owed0;
        uint256 take1 = owed1 > cap1 ? cap1 : owed1;
        uint256 newPending0 = owed0 - take0;
        uint256 newPending1 = owed1 - take1;

        // Never release fees or principal in exchange for an unsecured receivable. Callers can
        // prepend INCREASE_LIQUIDITY(0) with adequate max inputs to settle all fees atomically.
        if (newPending0 != 0 || newPending1 != 0) revert ProtocolFeesUnsettled();

        if (newPending0 != pending0 || newPending1 != pending1) {
            pending.amount0 = SafeCast.toUint128(newPending0);
            pending.amount1 = SafeCast.toUint128(newPending1);
            emit ProtocolFeeDeferred(tokenId, key.currency0, key.currency1, newPending0, newPending1);
        }

        if (take0 == 0 && take1 == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        address feeRecipient = hookFeeController.protocolFeeRecipient();
        if (take0 > 0) {
            poolManager.take(key.currency0, feeRecipient, take0);
        }
        if (take1 > 0) {
            poolManager.take(key.currency1, feeRecipient, take1);
        }
        emit SendProtocolFee(tokenId, key.currency0, key.currency1, take0, take1, feeRecipient);

        newFeeDelta = toBalanceDelta(SafeCast.toInt128(int256(take0)), SafeCast.toInt128(int256(take1)));
    }

    /// @dev Consumes the position's active-time accounting and returns this period's protocol fee.
    function _accrueProtocolFee(uint256 tokenId, BalanceDelta feeDelta) internal returns (uint256 fee0, uint256 fee1) {
        PositionState storage state = _positionStates[tokenId];
        uint32 accumulatedActiveTime = state.accumulatedActiveTime;
        uint32 lastActivated = state.lastActivated;
        uint32 currentTime = uint32(block.timestamp);
        if (lastActivated > 0) {
            accumulatedActiveTime += currentTime - lastActivated;
            state.lastActivated = currentTime;
        }

        uint32 lastCollect = state.lastCollect;
        uint32 feeTime = lastCollect == 0 ? 0 : currentTime - lastCollect;
        state.lastCollect = currentTime;
        state.accumulatedActiveTime = 0;

        if (feeTime == 0 || accumulatedActiveTime == 0) {
            return (0, 0);
        }
        if (accumulatedActiveTime > feeTime) {
            accumulatedActiveTime = feeTime;
        }

        uint16 lpFeeBps = hookFeeController.lpFeeBps();
        if (lpFeeBps == 0) {
            return (0, 0);
        }

        // Accrued LP fees are never negative; guard anyway so a hostile delta cannot underflow.
        uint256 fees0 = feeDelta.amount0() > 0 ? uint256(int256(feeDelta.amount0())) : 0;
        uint256 fees1 = feeDelta.amount1() > 0 ? uint256(int256(feeDelta.amount1())) : 0;
        // uint128 * uint32 * uint16 cannot overflow uint256.
        uint256 denominator = 10000 * uint256(feeTime);
        fee0 = fees0 * accumulatedActiveTime * lpFeeBps / denominator;
        fee1 = fees1 * accumulatedActiveTime * lpFeeBps / denominator;
    }

    /// @dev A decrease can pay only from principal (PositionManager validates unsigned min-outs).
    /// An increase, including zero liquidity, can settle the whole obligation via max-inputs.
    function _protocolFeeCaps(
        int256 liquidityDelta,
        BalanceDelta delta,
        BalanceDelta feeDelta,
        uint256 fee0,
        uint256 fee1
    ) internal view returns (uint256 cap0, uint256 cap1) {
        if (liquidityDelta < 0) {
            int256 principal0 = int256(delta.amount0()) - int256(feeDelta.amount0());
            int256 principal1 = int256(delta.amount1()) - int256(feeDelta.amount1());
            cap0 = principal0 > 0 ? uint256(principal0) : 0;
            cap1 = principal1 > 0 ? uint256(principal1) : 0;

        } else {
            cap0 = fee0;
            cap1 = fee1;
        }
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
            if (shares == 0) {
                SafeERC20.forceApprove(IERC20(depositToken), address(lendVault), 0);
                // A zero-share deposit must not have taken the assets. Measure what the running
                // action may treat as its own: the raw balance would also count ERC4626 shares the
                // hook custodies for other auto-lend positions when the pool currency is such a
                // share token, and the restore below would then rebuild this position out of them.
                if (_sweepableBalance(Currency.wrap(depositToken)) < lendAmount) {
                    revert InvalidConfig();
                }
                NativeAssetLib.unwrapIfNative(weth, lendCurrency, lendAmount);
                _restoreAutoLendPosition(
                    tokenId, poolKey, positionInfo, currency0, currency1, amount0, amount1, owner, isUpperTrigger
                );
                emit HookAutoLendFailed(address(lendVault), lendCurrency, abi.encodeWithSignature("InvalidConfig()"));
                emit HookActionFailed(tokenId, Mode.AUTO_LEND);
                return;
            }

            PositionState storage state = _positionStates[tokenId];
            state.autoLendShares = shares;
            _custodiedShares[address(lendVault)] += shares;
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

        // Clear auto-lend state before re-adding liquidity. The increase/mint below triggers
        // _afterAddLiquidity, which re-arms position triggers from the current state; if shares
        // are still recorded here it would arm a stale withdraw trigger (against the pre-withdraw
        // "still lent" state) instead of the correct deposit triggers (M-1).
        _resetAutoLendState(tokenId);

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

    function _sendLendingProtocolFee(
        uint256 tokenId,
        PoolKey memory poolKey,
        Currency lendCurrency,
        uint256 protocolFee
    ) internal {
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
    /// @dev Every caller has already redeemed the recorded shares, so the custody total drops with
    ///      the position's record (see RevertHookState._custodiedShares).
    function _resetAutoLendState(uint256 tokenId) internal {
        PositionState storage state = _positionStates[tokenId];
        uint256 custodied = _custodiedShares[state.autoLendVault];
        uint256 shares = state.autoLendShares;
        _custodiedShares[state.autoLendVault] = custodied > shares ? custodied - shares : 0;
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
        // never fund the restore beyond what the action may spend (custodied shares are reserved)
        uint256 available0 = _sweepableBalance(currency0);
        uint256 available1 = _sweepableBalance(currency1);
        if (amount0 > available0) amount0 = available0;
        if (amount1 > available1) amount1 = available1;
        _approveToken(currency0, amount0);
        _approveToken(currency1, amount1);
        (
            uint256 restored0,
            uint256 restored1
            // forge-lint: disable-next-line(unsafe-typecast)
        ) = _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
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
