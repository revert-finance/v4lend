// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

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

        if (shouldExecute) {
            _executeImmediateAction(tokenId, isUpperTrigger, triggeredTick);
            return;
        }

        _checkAndExecuteImmediateAutoLeverage(tokenId, config.modeFlags, config.autoLeverageTargetBps);
    }

    function _checkTriggerConditions(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        int24 posTickLower,
        int24 posTickUpper
    ) internal view returns (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) {
        PoolId poolId = poolKey.toId();
        int24 currentTickLower = _getTickLower(_getTick(poolId), poolKey.tickSpacing);

        int24[4] memory triggerTicks = _computeTriggerTicksMemory(tokenId, poolKey, config, posTickLower, posTickUpper);
        int24 lowerTrigger = _getNearestSatisfiedLowerTrigger(currentTickLower, triggerTicks[0], triggerTicks[1]);
        int24 upperTrigger = _getNearestSatisfiedUpperTrigger(currentTickLower, triggerTicks[2], triggerTicks[3]);

        bool lowerSatisfied = lowerTrigger != type(int24).min;
        bool upperSatisfied = upperTrigger != type(int24).max;

        if (lowerSatisfied && upperSatisfied) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 lowerDistance = uint256(int256(lowerTrigger) - int256(currentTickLower));
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 upperDistance = uint256(int256(currentTickLower) - int256(upperTrigger));
            return lowerDistance <= upperDistance ? (true, false, lowerTrigger) : (true, true, upperTrigger);
        }
        if (lowerSatisfied) {
            return (true, false, lowerTrigger);
        }
        if (upperSatisfied) {
            return (true, true, upperTrigger);
        }

        return (false, false, 0);
    }

    function _getNearestSatisfiedLowerTrigger(int24 currentTickLower, int24 first, int24 second)
        internal
        pure
        returns (int24 lowerTrigger)
    {
        lowerTrigger = type(int24).min;

        if (first != type(int24).min && currentTickLower <= first) {
            lowerTrigger = first;
        }
        if (second != type(int24).min && currentTickLower <= second && second > lowerTrigger) {
            lowerTrigger = second;
        }
    }

    function _getNearestSatisfiedUpperTrigger(int24 currentTickLower, int24 first, int24 second)
        internal
        pure
        returns (int24 upperTrigger)
    {
        upperTrigger = type(int24).max;

        if (first != type(int24).max && currentTickLower >= first) {
            upperTrigger = first;
        }
        if (second != type(int24).max && currentTickLower >= second && second < upperTrigger) {
            upperTrigger = second;
        }
    }

    function _executeImmediateAction(uint256 tokenId, bool isUpperTrigger, int24 tick) internal {
        poolManager.unlock(abi.encode(tokenId, isUpperTrigger, tick));
    }

    function _executeImmediateAutoLeverage(uint256 tokenId, bool isUpperTrigger) internal {
        poolManager.unlock(abi.encode(tokenId, isUpperTrigger, uint256(0), uint256(0)));
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

    function _checkAndExecuteImmediateAutoLeverage(
        uint256 tokenId,
        uint8 modeFlags,
        uint16 targetRatioBps
    ) internal {
        if (!PositionModeFlags.hasAutoLeverage(modeFlags)) {
            return;
        }

        address owner = _getOwner(tokenId, false);
        if (!_vaults[owner]) {
            return;
        }

        (uint256 currentDebt,, uint256 collateralValue,,) = IVault(owner).loanInfo(tokenId);
        uint256 currentRatio = AutoLeverageLib.currentRatio(currentDebt, collateralValue);
        if (currentRatio == targetRatioBps) {
            return;
        }

        _executeImmediateAutoLeverage(tokenId, currentRatio < targetRatioBps);
    }
}
