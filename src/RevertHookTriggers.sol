// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookState} from "./RevertHookState.sol";

/// @title RevertHookTriggers
/// @notice Abstract contract containing trigger management functions for RevertHook
/// @dev Inherits from RevertHookState and provides trigger add/remove/compute functionality
abstract contract RevertHookTriggers is RevertHookState {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    // ==================== Abstract Functions ====================

    /// @notice Gets position and pool info - must be implemented by child
    function _getPoolAndPositionInfo(uint256 tokenId) internal view virtual returns (PoolKey memory, PositionInfo);

    /// @notice Returns the owner of the position - must be implemented by child
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view virtual returns (address);

    // ==================== Tick Helpers ====================

    /// @notice Calculates the tick lower for a given tick and spacing
    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @notice Validates that a tick config is aligned to tick spacing (unless it's a sentinel value)
    /// @param tick The tick value to validate
    /// @param tickSpacing The pool's tick spacing
    /// @param sentinel The sentinel value that bypasses validation (type(int24).min or type(int24).max)
    /// @return valid True if tick is valid (aligned to spacing or equals sentinel)
    function _isValidTickConfig(int24 tick, int24 tickSpacing, int24 sentinel) internal pure returns (bool valid) {
        return tick == sentinel || tick % tickSpacing == 0;
    }

    /// @notice Calculates AUTO_RANGE trigger ticks based on position range and limits
    /// @param tickLower Position's lower tick
    /// @param tickUpper Position's upper tick
    /// @param autoRangeLowerLimit Lower limit config (type(int24).min means disabled)
    /// @param autoRangeUpperLimit Upper limit config (type(int24).max means disabled)
    /// @return rangeLower Lower trigger tick (type(int24).min if disabled)
    /// @return rangeUpper Upper trigger tick (type(int24).max if disabled)
    function _calculateRangeTriggerTicks(
        int24 tickLower,
        int24 tickUpper,
        int24 autoRangeLowerLimit,
        int24 autoRangeUpperLimit
    ) internal pure returns (int24 rangeLower, int24 rangeUpper) {
        rangeLower = autoRangeLowerLimit != type(int24).min
            ? tickLower - autoRangeLowerLimit
            : type(int24).min;
        rangeUpper = autoRangeUpperLimit != type(int24).max
            ? tickUpper + autoRangeUpperLimit
            : type(int24).max;
    }

    /// @notice Calculates AUTO_LEVERAGE trigger ticks based on base tick
    /// @param baseTick The base tick for leverage triggers
    /// @param tickSpacing The pool's tick spacing
    /// @return leverageLower Lower trigger tick
    /// @return leverageUpper Upper trigger tick
    function _calculateLeverageTriggerTicks(
        int24 baseTick,
        int24 tickSpacing
    ) internal pure returns (int24 leverageLower, int24 leverageUpper) {
        leverageLower = baseTick - LEVERAGE_TICK_OFFSET_MULTIPLIER * tickSpacing;
        leverageUpper = baseTick + LEVERAGE_TICK_OFFSET_MULTIPLIER * tickSpacing;
    }

    // ==================== Position Config Helpers ====================

    /// @notice Disables a position by setting its config to NONE
    function _disablePosition(uint256 tokenId) internal {
        PositionConfig memory emptyConfig = _getEmptyPositionConfig();
        positionConfigs[tokenId] = emptyConfig;
        _deactivatePosition(tokenId);
        emit SetPositionConfig(tokenId, emptyConfig);
    }

    /// @notice Returns an empty position config with default/sentinel values
    function _getEmptyPositionConfig() internal pure returns (PositionConfig memory config) {
        config = PositionConfig({
            modeFlags: PositionModeFlags.MODE_NONE,
            autoCompoundMode: AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
    }

    // ==================== Activation Helpers ====================

    /// @notice Marks position as activated (triggers are now active)
    function _activatePosition(uint256 tokenId) internal {
        if (positionStates[tokenId].lastActivated == 0) {
            positionStates[tokenId].lastActivated = uint32(block.timestamp);
        }
    }

    /// @notice Marks position as deactivated
    function _deactivatePosition(uint256 tokenId) internal {
        uint32 lastActivated = positionStates[tokenId].lastActivated;
        if (lastActivated > 0) {
            positionStates[tokenId].acumulatedActiveTime += uint32(block.timestamp) - lastActivated;
            positionStates[tokenId].lastActivated = 0;
        }
    }

    /// @notice Checks if position is currently activated
    function _isActivated(uint256 tokenId) internal view returns (bool) {
        return positionStates[tokenId].lastActivated > 0;
    }

    // ==================== Trigger Management ====================

    /// @notice Adds position triggers based on the current position configuration
    function _addPositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        PositionConfig storage config = positionConfigs[tokenId];

        if (!PositionModeFlags.hasTriggers(config.modeFlags)) {
            return;
        }

        PoolId poolId = poolKey.toId();
        (, PositionInfo posInfo) = _getPoolAndPositionInfo(tokenId);

        TickLinkedList.List storage lowerList = lowerTriggerAfterSwap[poolId];
        TickLinkedList.List storage upperList = upperTriggerAfterSwap[poolId];

        if (!upperList.increasing) {
            upperList.increasing = true;
        }

        int24[4] memory ticks = _computeTriggerTicks(tokenId, poolKey, config, posInfo.tickLower(), posInfo.tickUpper());

        if (ticks[0] != type(int24).min) lowerList.insert(ticks[0], tokenId);
        if (ticks[1] != type(int24).min) lowerList.insert(ticks[1], tokenId);
        if (ticks[2] != type(int24).max) upperList.insert(ticks[2], tokenId);
        if (ticks[3] != type(int24).max) upperList.insert(ticks[3], tokenId);
    }

    /// @notice Removes position triggers based on the current position configuration
    function _removePositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        PositionConfig storage config = positionConfigs[tokenId];

        if (!PositionModeFlags.hasTriggers(config.modeFlags)) {
            return;
        }

        PoolId poolId = poolKey.toId();
        (, PositionInfo posInfo) = _getPoolAndPositionInfo(tokenId);

        TickLinkedList.List storage lowerList = lowerTriggerAfterSwap[poolId];
        TickLinkedList.List storage upperList = upperTriggerAfterSwap[poolId];

        int24[4] memory ticks = _computeTriggerTicks(tokenId, poolKey, config, posInfo.tickLower(), posInfo.tickUpper());

        if (ticks[0] != type(int24).min) lowerList.remove(ticks[0], tokenId);
        if (ticks[1] != type(int24).min) lowerList.remove(ticks[1], tokenId);
        if (ticks[2] != type(int24).max) upperList.remove(ticks[2], tokenId);
        if (ticks[3] != type(int24).max) upperList.remove(ticks[3], tokenId);
    }

    /// @notice Updates position triggers by computing diff between old and new configs
    function _updatePositionTriggers(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory newConfig) internal {
        _updatePositionTriggersInternal(tokenId, poolKey, newConfig, false);
    }

    /// @notice Updates position triggers with optional force flag
    function _updatePositionTriggersInternal(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory newConfig, bool force) internal {
        PositionConfig storage oldConfig = positionConfigs[tokenId];

        bool oldHasTriggers = !force && PositionModeFlags.hasTriggers(oldConfig.modeFlags);
        bool newHasTriggers = PositionModeFlags.hasTriggers(newConfig.modeFlags);

        if (!oldHasTriggers && !newHasTriggers) {
            return;
        }

        PoolId poolId = poolKey.toId();
        (, PositionInfo posInfo) = _getPoolAndPositionInfo(tokenId);

        TickLinkedList.List storage lowerList = lowerTriggerAfterSwap[poolId];
        TickLinkedList.List storage upperList = upperTriggerAfterSwap[poolId];

        if (!upperList.increasing) {
            upperList.increasing = true;
        }

        int24[4] memory oldTicks;
        if (force) {
            oldTicks[0] = type(int24).min;
            oldTicks[1] = type(int24).min;
            oldTicks[2] = type(int24).max;
            oldTicks[3] = type(int24).max;
        } else {
            oldTicks = _computeTriggerTicks(tokenId, poolKey, oldConfig, posInfo.tickLower(), posInfo.tickUpper());
        }
        int24[4] memory newTicks = _computeTriggerTicksMemory(tokenId, poolKey, newConfig, posInfo.tickLower(), posInfo.tickUpper());

        _updateTriggerList(lowerList, tokenId, oldTicks[0], oldTicks[1], newTicks[0], newTicks[1], type(int24).min);
        _updateTriggerList(upperList, tokenId, oldTicks[2], oldTicks[3], newTicks[2], newTicks[3], type(int24).max);
    }

    /// @notice Updates a single trigger list by removing old and adding new ticks
    function _updateTriggerList(
        TickLinkedList.List storage list,
        uint256 tokenId,
        int24 old1,
        int24 old2,
        int24 new1,
        int24 new2,
        int24 sentinel
    ) internal {
        if (old1 != sentinel && old1 != new1 && old1 != new2) list.remove(old1, tokenId);
        if (old2 != sentinel && old2 != new1 && old2 != new2) list.remove(old2, tokenId);
        if (new1 != sentinel && new1 != old1 && new1 != old2) list.insert(new1, tokenId);
        if (new2 != sentinel && new2 != old1 && new2 != old2) list.insert(new2, tokenId);
    }

    // ==================== Trigger Tick Computation ====================

    /// @notice Computes trigger ticks for a position config (storage version)
    function _computeTriggerTicks(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig storage config,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (int24[4] memory ticks) {
        return _computeTriggerTicksCore(
            tokenId, poolKey, config.modeFlags,
            config.autoRangeLowerLimit, config.autoRangeUpperLimit,
            config.autoExitIsRelative, config.autoExitTickLower, config.autoExitTickUpper,
            config.autoLendToleranceTick, tickLower, tickUpper
        );
    }

    /// @notice Computes trigger ticks for a position config (memory version)
    function _computeTriggerTicksMemory(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (int24[4] memory ticks) {
        return _computeTriggerTicksCore(
            tokenId, poolKey, config.modeFlags,
            config.autoRangeLowerLimit, config.autoRangeUpperLimit,
            config.autoExitIsRelative, config.autoExitTickLower, config.autoExitTickUpper,
            config.autoLendToleranceTick, tickLower, tickUpper
        );
    }

    /// @notice Core trigger tick computation logic
    /// @dev Trigger slots: [0]=range/leverage lower (first trigger going down), [1]=exit lower,
    ///      [2]=range/leverage upper (first trigger going up), [3]=exit upper
    ///      When AUTO_RANGE and AUTO_LEVERAGE are combined, we use the trigger that fires first in each direction.
    function _computeTriggerTicksCore(
        uint256 tokenId,
        PoolKey memory poolKey,
        uint8 modeFlags,
        int24 autoRangeLowerLimit,
        int24 autoRangeUpperLimit,
        bool autoExitIsRelative,
        int24 autoExitTickLower,
        int24 autoExitTickUpper,
        int24 autoLendToleranceTick,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (int24[4] memory ticks) {
        ticks[0] = type(int24).min;
        ticks[1] = type(int24).min;
        ticks[2] = type(int24).max;
        ticks[3] = type(int24).max;

        if (!PositionModeFlags.hasTriggers(modeFlags)) {
            return ticks;
        }

        bool hasAutoRange = PositionModeFlags.hasAutoRange(modeFlags);
        bool hasAutoLeverage = PositionModeFlags.hasAutoLeverage(modeFlags);

        // Compute AUTO_RANGE trigger ticks
        int24 rangeLower = type(int24).min;
        int24 rangeUpper = type(int24).max;
        if (hasAutoRange) {
            (rangeLower, rangeUpper) = _calculateRangeTriggerTicks(
                tickLower, tickUpper, autoRangeLowerLimit, autoRangeUpperLimit
            );
        }

        // Compute AUTO_LEVERAGE trigger ticks
        int24 leverageLower = type(int24).min;
        int24 leverageUpper = type(int24).max;
        if (hasAutoLeverage) {
            int24 baseTick = positionStates[tokenId].autoLeverageBaseTick;
            (leverageLower, leverageUpper) = _calculateLeverageTriggerTicks(baseTick, poolKey.tickSpacing);
        }

        // When both AUTO_RANGE and AUTO_LEVERAGE are set, use the trigger that fires first in each direction:
        // - Going DOWN: first trigger = higher tick value (closer to current price)
        // - Going UP: first trigger = lower tick value (closer to current price)
        if (hasAutoRange && hasAutoLeverage) {
            // For lower triggers (price going down), use the HIGHER tick (fires first)
            ticks[0] = rangeLower > leverageLower ? rangeLower : leverageLower;
            // For upper triggers (price going up), use the LOWER tick (fires first)
            ticks[2] = rangeUpper < leverageUpper ? rangeUpper : leverageUpper;
        } else if (hasAutoRange) {
            ticks[0] = rangeLower;
            ticks[2] = rangeUpper;
        } else if (hasAutoLeverage) {
            ticks[0] = leverageLower;
            ticks[2] = leverageUpper;
        }

        // AUTO_EXIT triggers (ticks[1] and ticks[3], or ticks[0]/ticks[2] if no range/leverage)
        if (PositionModeFlags.hasAutoExit(modeFlags)) {
            int24 exitLower;
            int24 exitUpper;
            if (autoExitIsRelative) {
                exitLower = autoExitTickLower != type(int24).min ? tickLower - autoExitTickLower : type(int24).min;
                exitUpper = autoExitTickUpper != type(int24).max ? tickUpper + autoExitTickUpper : type(int24).max;
            } else {
                exitLower = autoExitTickLower;
                exitUpper = autoExitTickUpper;
            }
            // Place exit triggers in slots [1] and [3] if range/leverage triggers exist, otherwise in [0] and [2]
            if (ticks[0] != type(int24).min) {
                ticks[1] = exitLower;
            } else {
                ticks[0] = exitLower;
            }
            if (ticks[2] != type(int24).max) {
                ticks[3] = exitUpper;
            } else {
                ticks[2] = exitUpper;
            }
        }

        // AUTO_LEND triggers (mutually exclusive with AUTO_EXIT and AUTO_LEVERAGE per validation)
        if (PositionModeFlags.hasAutoLend(modeFlags)) {
            PositionState storage state = positionStates[tokenId];
            if (state.autoLendShares > 0) {
                if (Currency.unwrap(poolKey.currency0) == state.autoLendToken) {
                    ticks[2] = tickLower - autoLendToleranceTick - poolKey.tickSpacing;
                } else {
                    ticks[0] = tickUpper + autoLendToleranceTick;
                }
            } else {
                ticks[0] = tickLower - autoLendToleranceTick * 2 - poolKey.tickSpacing;
                ticks[2] = tickUpper + autoLendToleranceTick * 2;
            }
        }
    }
}
