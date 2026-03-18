// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @title PositionModeFlags
/// @notice Library for position mode flag operations
/// @dev Modes can be combined using bitwise OR (e.g., MODE_AUTO_COLLECT | MODE_AUTO_RANGE)
library PositionModeFlags {
    uint8 internal constant MODE_NONE = 0;                    // 0b00000000
    uint8 internal constant MODE_AUTO_COLLECT = 1 << 0;      // 0b00000001 (1)
    uint8 internal constant MODE_AUTO_RANGE = 1 << 1;         // 0b00000010 (2)
    uint8 internal constant MODE_AUTO_EXIT = 1 << 2;          // 0b00000100 (4)
    uint8 internal constant MODE_AUTO_LEND = 1 << 3;          // 0b00001000 (8)
    uint8 internal constant MODE_AUTO_LEVERAGE = 1 << 4;      // 0b00010000 (16)

    /// @notice Check if a specific flag is set
    function hasFlag(uint8 mode, uint8 flag) internal pure returns (bool) {
        return (mode & flag) != 0;
    }

    /// @notice Check if AUTO_COLLECT flag is set
    function hasAutoCollect(uint8 mode) internal pure returns (bool) {
        return hasFlag(mode, MODE_AUTO_COLLECT);
    }

    /// @notice Check if AUTO_RANGE flag is set
    function hasAutoRange(uint8 mode) internal pure returns (bool) {
        return hasFlag(mode, MODE_AUTO_RANGE);
    }

    /// @notice Check if AUTO_EXIT flag is set
    function hasAutoExit(uint8 mode) internal pure returns (bool) {
        return hasFlag(mode, MODE_AUTO_EXIT);
    }

    /// @notice Check if AUTO_LEND flag is set
    function hasAutoLend(uint8 mode) internal pure returns (bool) {
        return hasFlag(mode, MODE_AUTO_LEND);
    }

    /// @notice Check if AUTO_LEVERAGE flag is set
    function hasAutoLeverage(uint8 mode) internal pure returns (bool) {
        return hasFlag(mode, MODE_AUTO_LEVERAGE);
    }

    /// @notice Check if mode has any trigger-based flags (not NONE or AUTO_COLLECT only)
    function hasTriggers(uint8 mode) internal pure returns (bool) {
        // Any mode that sets triggers (not NONE or AUTO_COLLECT only)
        return (mode & ~MODE_AUTO_COLLECT) != 0;
    }

    /// @notice Check if mode is NONE (no automation)
    function isNone(uint8 mode) internal pure returns (bool) {
        return mode == MODE_NONE;
    }

    /// @notice Check if mode is only AUTO_COLLECT (no triggers)
    function isAutoCollectOnly(uint8 mode) internal pure returns (bool) {
        return mode == MODE_AUTO_COLLECT;
    }
}
