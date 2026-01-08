// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {TickLinkedList} from "./lib/TickLinkedList.sol";
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
            mode: PositionMode.NONE,
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

        if (config.mode == PositionMode.NONE || config.mode == PositionMode.AUTO_COMPOUND_ONLY) {
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

        if (config.mode == PositionMode.NONE || config.mode == PositionMode.AUTO_COMPOUND_ONLY) {
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

        bool oldHasTriggers = !force && oldConfig.mode != PositionMode.NONE && oldConfig.mode != PositionMode.AUTO_COMPOUND_ONLY;
        bool newHasTriggers = newConfig.mode != PositionMode.NONE && newConfig.mode != PositionMode.AUTO_COMPOUND_ONLY;

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
            tokenId, poolKey, config.mode,
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
            tokenId, poolKey, config.mode,
            config.autoRangeLowerLimit, config.autoRangeUpperLimit,
            config.autoExitIsRelative, config.autoExitTickLower, config.autoExitTickUpper,
            config.autoLendToleranceTick, tickLower, tickUpper
        );
    }

    /// @notice Core trigger tick computation logic
    function _computeTriggerTicksCore(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionMode mode,
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

        if (mode == PositionMode.NONE || mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return ticks;
        }

        if (mode == PositionMode.AUTO_RANGE || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            if (autoRangeLowerLimit != type(int24).min) {
                ticks[0] = tickLower - autoRangeLowerLimit;
            }
            if (autoRangeUpperLimit != type(int24).max) {
                ticks[2] = tickUpper + autoRangeUpperLimit;
            }
        }

        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            int24 exitLower;
            int24 exitUpper;
            if (autoExitIsRelative) {
                exitLower = autoExitTickLower != type(int24).min ? tickLower - autoExitTickLower : type(int24).min;
                exitUpper = autoExitTickUpper != type(int24).max ? tickUpper + autoExitTickUpper : type(int24).max;
            } else {
                exitLower = autoExitTickLower;
                exitUpper = autoExitTickUpper;
            }
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

        if (mode == PositionMode.AUTO_LEND) {
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

        if (mode == PositionMode.AUTO_LEVERAGE) {
            int24 baseTick = positionStates[tokenId].autoLeverageBaseTick;
            ticks[0] = baseTick - 10 * poolKey.tickSpacing;
            ticks[2] = baseTick + 10 * poolKey.tickSpacing;
        }
    }
}
