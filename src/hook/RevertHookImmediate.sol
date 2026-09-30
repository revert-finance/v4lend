// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {AutoLeverageLib} from "../shared/planning/AutoLeverageLib.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookViews} from "./RevertHookViews.sol";

/// @title RevertHookImmediate
/// @notice Config-time immediate trigger evaluation and unlocked execution helpers
abstract contract RevertHookImmediate is RevertHookViews {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    function _dispatchAutomationAction(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint8 modeFlags,
        bool isUpperTrigger,
        int24 tick,
        bool autoExitIsRelative,
        int24 autoExitTickLower,
        int24 autoExitTickUpper
    ) internal virtual;

    function _handleAutoLeverage(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal virtual;

    function _checkAndExecuteImmediate(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory config) internal {
        if (!PositionModeFlags.hasTriggers(config.modeFlags)) {
            return;
        }

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) = _checkTriggerConditions(
            tokenId, poolKey, config, posInfo.tickLower(), posInfo.tickUpper()
        );
        bool leverageDue;
        if (!shouldExecute) {
            (leverageDue, isUpperTrigger) =
                _immediateAutoLeverageDue(tokenId, config.modeFlags, config.autoLeverageTargetBps);
            if (!leverageDue) {
                return;
            }
        }

        // An immediate action runs outside the _afterSwap walk, whose oracle window bounds every
        // triggered dispatch; its same-pool swap is otherwise price-checked by nobody (the vault
        // only enforces its wider oracle deviation limit) (V4LE-154). Refuse rather than skip: an
        // already-satisfied trigger would be armed behind the cursor and lie dormant until a
        // recross (V4LE-70). The owner retries once the pool is back in line, as for
        // TriggerCursorStale. The first registration in a pool is the plain case - it re-baselines
        // the cursor, so _requireTriggerCursorFresh never sees it as stale.
        _requireInsideOracleWindow(poolKey);
        if (leverageDue) {
            _executeImmediateAutoLeverage(tokenId, isUpperTrigger);
        } else {
            _executeImmediateAction(tokenId, isUpperTrigger, triggeredTick);
        }
    }

    function _requireInsideOracleWindow(PoolKey memory poolKey) internal view {
        (bool ok, int24 lowerBound, int24 upperBound) = _tryOracleTickBounds(poolKey.currency0, poolKey.currency1);
        if (!ok || _outsideOracleWindow(poolKey.toId(), lowerBound, upperBound)) {
            revert OutsideOracleWindow();
        }
    }

    /// @dev Isolates the oracle read so a failing oracle aborts trigger processing (never the swap):
    ///      the price call is tried directly and bounds-checked before the tick conversion, instead
    ///      of an external self-call wrapper (saves the call overhead and the extra entrypoint).
    ///      The bounds are exact ticks: `oracleTick +- _maxTicksFromOracle` with no rounding to the
    ///      pool's tick spacing, and they are compared against the exact live tick
    ///      (_outsideOracleWindow). Flooring both sides to the spacing let the effective window grow
    ///      by up to two spacings less two ticks (399 instead of 100 ticks at spacing 200), so
    ///      same-pool actions could dispatch materially off-oracle. Bucket rounding belongs to the
    ///      cursor walk only.
    function _tryOracleTickBounds(Currency currency0, Currency currency1)
        internal
        view
        returns (bool ok, int24 lowerBound, int24 upperBound)
    {
        try v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(currency0), Currency.unwrap(currency1)) returns (
            uint160 oracleSqrtPriceX96
        ) {
            if (oracleSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || oracleSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
                return (false, 0, 0);
            }
            int24 oracleTick = TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96);
            return (true, oracleTick - _maxTicksFromOracle, oracleTick + _maxTicksFromOracle);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Exact live tick against the exact oracle bounds. Re-reads slot0 instead of reusing the
    ///      walk's bucket-rounded `liveTick`: the walk is at its stack limit and the slot is warm.
    function _outsideOracleWindow(PoolId poolId, int24 lowerBound, int24 upperBound) internal view returns (bool) {
        int24 tick = _getTick(poolId);
        return tick > upperBound || tick < lowerBound;
    }

    function _executeImmediateAction(uint256 tokenId, bool isUpperTrigger, int24 tick) internal {
        poolManager.unlock(abi.encode(UnlockAction.IMMEDIATE_ACTION, tokenId, isUpperTrigger, tick));
    }

    function _executeImmediateAutoLeverage(uint256 tokenId, bool isUpperTrigger) internal {
        poolManager.unlock(abi.encode(UnlockAction.IMMEDIATE_AUTO_LEVERAGE, tokenId, isUpperTrigger));
    }

    function _executeImmediateActionUnlocked(uint256 tokenId, bool isUpperTrigger, int24 tick) internal {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        PositionConfig storage config = _positionConfigs[tokenId];
        PoolId poolId = poolKey.toId();
        _consumeImmediateTrigger(tokenId, poolId, isUpperTrigger, tick);
        _dispatchAutomationAction(
            poolKey,
            tokenId,
            config.modeFlags,
            isUpperTrigger,
            tick,
            config.autoExitIsRelative,
            config.autoExitTickLower,
            config.autoExitTickUpper
        );
    }

    function _executeImmediateAutoLeverageUnlocked(uint256 tokenId, bool isUpperTrigger) internal {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _handleAutoLeverage(poolKey, tokenId, isUpperTrigger);
    }

    function _consumeImmediateTrigger(uint256 tokenId, PoolId poolId, bool isUpperTrigger, int24 tick) internal {
        TickLinkedList.List storage list = isUpperTrigger ? _upperTriggerAfterSwap[poolId] : _lowerTriggerAfterSwap[poolId];
        list.remove(tick, tokenId);
    }

    /// @dev Whether a vault-owned AUTO_LEVERAGE position is off its target ratio at configuration
    ///      time, and in which direction (`isUpperTrigger` = leverage up).
    function _immediateAutoLeverageDue(uint256 tokenId, uint8 modeFlags, uint16 targetRatioBps)
        internal
        view
        returns (bool due, bool isUpperTrigger)
    {
        if (!PositionModeFlags.hasAutoLeverage(modeFlags)) {
            return (false, false);
        }

        address owner = _getOwner(tokenId, false);
        if (!_vaults[owner]) {
            return (false, false);
        }

        (uint256 currentDebt,, uint256 collateralValue,,) = IVault(owner).loanInfo(tokenId);
        uint256 currentRatio = AutoLeverageLib.currentRatio(currentDebt, collateralValue);
        if (currentRatio == targetRatioBps) {
            return (false, false);
        }
        return (true, currentRatio < targetRatioBps);
    }
}
