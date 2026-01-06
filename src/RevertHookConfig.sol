// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {Transformer} from "./transformers/Transformer.sol";

/// @title RevertHookConfig
/// @notice Base class containing all configuration-related structures, storage, and functions
/// @dev This class handles position configuration management
abstract contract RevertHookConfig is Transformer {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;
    using CurrencyLibrary for Currency;

    // Configuration storage
    mapping(uint256 tokenId => PositionConfig positionConfig) public positionConfigs;
    mapping(uint256 tokenId => GeneralConfig generalConfig) public generalConfigs;

    mapping(uint256 tokenId => PositionState positionState) public positionStates;

    // configured vaults for auto lend
    mapping(address token => IERC4626 vault) public autoLendVaults;

    // fees for auto compound execution 1% reward - of fees autocompounded / harvested
    uint16 public constant autoCompoundRewardBps = 100;

    // protocol fees (taken from the fees collected while position is active)
    uint16 public protocolFeeBps = 200;
    address public protocolFeeRecipient;

    // oracle price validation
    int24 public maxTicksFromOracle = 100; // Maximum number of ticks allowed from oracle tick (1%)

    // minimum position value in native token (address(0)) to be configurable
    uint256 public minPositionValueNative = 0.01 ether;

    // Position trigger mappings
    mapping(PoolId => int24) public tickLowerLasts;
    mapping(PoolId poolId => TickLinkedList.List) public lowerTriggerAfterSwap;
    mapping(PoolId poolId => TickLinkedList.List) public upperTriggerAfterSwap;

    // Events
    event SetAutoLendVault(address indexed token, IERC4626 vault);
    event SetMaxTicksFromOracle(int24 maxTicksFromOracle);
    event SetMinPositionValueNative(uint256 minPositionValueNative);
    event SetProtocolFeeBps(uint16 protocolFeeBps);
    event SetProtocolFeeRecipient(address protocolFeeRecipient);

    event SetGeneralConfig(uint256 indexed tokenId, GeneralConfig generalConfig);
    event SetPositionConfig(uint256 indexed tokenId, PositionConfig positionConfig);
    
    // Enums
    enum PositionMode {
        NONE,
        AUTO_COMPOUND_ONLY,
        AUTO_RANGE,
        AUTO_EXIT,
        AUTO_EXIT_AND_AUTO_RANGE,
        AUTO_LEND
    }

    enum AutoCompoundMode {
        NONE,
        AUTO_COMPOUND,
        HARVEST_TOKEN_0,
        HARVEST_TOKEN_1
    }

    // Structs
    struct PositionState {
        uint32 lastCollect;
        uint32 acumulatedActiveTime;
        uint32 lastActivated;

        address autoLendToken;
        uint256 autoLendShares;
        uint256 autoLendAmount;
        address autoLendVault;
    }

    struct GeneralConfig {
        // reference pool key data for swaps (can be the same pool or different pool)
        uint24 swapPoolFee;
        int24 swapPoolTickSpacing;
        IHooks swapPoolHooks;

        // max price impact in basis points (bps) for swaps
        uint32 maxPriceImpact0; // swaps token 0 to token 1
        uint32 maxPriceImpact1; // swaps token 1 to token 0
    }

    struct PositionConfig {
        PositionMode mode;
        AutoCompoundMode autoCompoundMode;

        bool autoExitIsRelative; // if true, the auto exit tick is relative to the position limits, if false, the auto exit tick is absolute
        int24 autoExitTickLower;
        int24 autoExitTickUpper;

        int24 autoRangeLowerLimit;
        int24 autoRangeUpperLimit;
        int24 autoRangeLowerDelta;
        int24 autoRangeUpperDelta;

        int24 autoLendToleranceTick;
    }


    /// @notice Sets the ERC4626 vault for a given token address
    /// @dev Can only be called by the owner. This vault will be used for autolend functionality.
    /// @param token The token address to set the vault for
    /// @param vault The ERC4626 vault address (can be address(0) to disable vault lending for this token)
    function setAutoLendVault(address token, IERC4626 vault) onlyOwner external {
        autoLendVaults[token] = vault;
        emit SetAutoLendVault(token, vault);
    }

    /// @notice Sets the maximum ticks from oracle for price validation
    /// @param _maxTicksFromOracle The maximum number of ticks allowed from oracle tick
    function setMaxTicksFromOracle(int24 _maxTicksFromOracle) onlyOwner external {
        maxTicksFromOracle = _maxTicksFromOracle;
        emit SetMaxTicksFromOracle(_maxTicksFromOracle);
    }

    /// @notice Sets the minimum position value in native token required for configuration
    /// @param _minPositionValueNative The minimum value in native token (wei)
    function setMinPositionValueNative(uint256 _minPositionValueNative) onlyOwner external {
        minPositionValueNative = _minPositionValueNative;
        emit SetMinPositionValueNative(_minPositionValueNative);
    }

    /// @notice Sets the protocol fee percentage
    /// @param _protocolFeeBps The protocol fee percentage (0-10000)
    function setProtocolFeeBps(uint16 _protocolFeeBps) onlyOwner external {
        if (_protocolFeeBps > 10000) {
            revert InvalidConfig();
        }
        protocolFeeBps = _protocolFeeBps;
        emit SetProtocolFeeBps(_protocolFeeBps);
    }

    /// @notice Sets the protocol fee recipient
    /// @param _protocolFeeRecipient The address to receive the protocol fees
    function setProtocolFeeRecipient(address _protocolFeeRecipient) onlyOwner external {
        protocolFeeRecipient = _protocolFeeRecipient;
        emit SetProtocolFeeRecipient(_protocolFeeRecipient);
    }

    /// @param tokenId The token ID of the position
    /// @param generalConfig The general configuration to set
    function setGeneralConfig(uint256 tokenId, GeneralConfig calldata generalConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey,) = _getPoolAndPositionInfo(tokenId);
        if (generalConfig.swapPoolTickSpacing % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }
        if (generalConfig.maxPriceImpact0 > 10000) {
            revert InvalidConfig();
        }
        if (generalConfig.maxPriceImpact1 > 10000) {
            revert InvalidConfig();
        }

        generalConfigs[tokenId] = generalConfig;
        emit SetGeneralConfig(tokenId, generalConfig);
    }

    /// @notice Sets the position configuration for a given token ID
    /// @param tokenId The token ID of the position
    /// @param positionConfig The position configuration to set
    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        // validate minimum position value when configuring
        if (positionConfig.mode != PositionMode.NONE) {
            uint256 value = _getPositionValueNative(tokenId);
            if (value < minPositionValueNative) {
                revert PositionValueTooLow();
            }
        }

        // config and check if conditions are already met for immediate execution
        _setPositionConfig(tokenId, positionConfig, true);
    }

    /// @notice Disables a position by setting its config to NONE
    /// @param tokenId The token ID of the position to disable
    function _disablePosition(uint256 tokenId) internal {
        _setPositionConfig(tokenId, PositionConfig({
            mode: PositionMode.NONE,
            autoCompoundMode: AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }), false);
    }

    /// @notice Internal function to set position configuration
    /// @param tokenId The token ID of the position
    /// @param config The position configuration to set
    function _setPositionConfig(uint256 tokenId, PositionConfig memory config, bool checkImmediateExecution) internal {
        (PoolKey memory poolKey,) = _getPoolAndPositionInfo(tokenId);

        // validate config
        if (config.autoExitTickLower % poolKey.tickSpacing != 0 && config.autoExitTickLower != type(int24).min) {
            revert InvalidConfig();
        }
        if (config.autoExitTickUpper % poolKey.tickSpacing != 0 && config.autoExitTickUpper != type(int24).max) {
            revert InvalidConfig();
        }
        if (config.autoRangeLowerLimit % poolKey.tickSpacing != 0 && config.autoRangeLowerLimit != type(int24).min) {
            revert InvalidConfig();
        }
        if (config.autoRangeUpperLimit % poolKey.tickSpacing != 0 && config.autoRangeUpperLimit != type(int24).max) {
            revert InvalidConfig();
        }
        if (config.autoRangeLowerDelta % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }
        if (config.autoRangeUpperDelta % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }
        if (config.autoLendToleranceTick % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }

        _updatePositionTriggers(tokenId, poolKey, config);
        positionConfigs[tokenId] = config;

        // Handle activation/deactivation based on mode
        if (config.mode != PositionMode.NONE) {
            _activatePosition(tokenId);

            // Check if conditions are already met for immediate execution
            if (checkImmediateExecution) {
                _checkAndExecuteImmediate(tokenId, poolKey, config);
            }
        } else {
            _deactivatePosition(tokenId);
        }

        // emit event
        emit SetPositionConfig(tokenId, config);
    }

    // Abstract functions that must be implemented by the child contract
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view virtual returns (address);
    function _getPoolAndPositionInfo(uint256 tokenId) internal view virtual returns (PoolKey memory, PositionInfo);
    function _getPositionValueNative(uint256 tokenId) internal view virtual returns (uint256);
    function _checkAndExecuteImmediate(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory config) internal virtual;

    /// @notice Marks position as activated (triggers are now active)
    /// @dev Sets lastActivated timestamp - used to track active time for protocol fees
    /// @param tokenId The token ID of the position
    function _activatePosition(uint256 tokenId) internal {
        if (positionStates[tokenId].lastActivated == 0) {
            positionStates[tokenId].lastActivated = uint32(block.timestamp);
        }
    }

    /// @notice Marks position as deactivated - no more fee accumulation
    /// @dev Accumulates active time and clears lastActivated
    /// @param tokenId The token ID of the position
    function _deactivatePosition(uint256 tokenId) internal {
        uint32 lastActivated = positionStates[tokenId].lastActivated;
        if (lastActivated > 0) {
            positionStates[tokenId].acumulatedActiveTime += uint32(block.timestamp) - lastActivated;
            positionStates[tokenId].lastActivated = 0;
        }
    }

    /// @notice Checks if position is currently activated (has active triggers)
    /// @param tokenId The token ID of the position
    /// @return True if position is activated
    function _isActivated(uint256 tokenId) internal view returns (bool) {
        return positionStates[tokenId].lastActivated > 0;
    }

    /// @notice Adds position triggers based on the current position configuration
    /// @dev Forces addition by assuming previous config was empty
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    function _addPositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        // Force add by passing true - assumes previous config was empty
        _updatePositionTriggers(tokenId, poolKey, positionConfigs[tokenId], true);
    }

    /// @notice Removes position triggers based on the current position configuration
    /// @dev Removes by updating to an empty config
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    function _removePositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        // Create an empty config that has no triggers (NONE mode with sentinel values)
        PositionConfig memory emptyConfig = PositionConfig({
            mode: PositionMode.NONE,
            autoCompoundMode: AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        });

        // Use _updatePositionTriggers to remove all current triggers by diffing against empty config
        _updatePositionTriggers(tokenId, poolKey, emptyConfig, false);
    }

    /// @notice Updates position triggers by computing the diff between old and new configs
    /// @dev Only removes triggers that changed and only adds new triggers, avoiding redundant operations
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    /// @param newConfig The new position configuration
    function _updatePositionTriggers(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory newConfig) internal {
        _updatePositionTriggers(tokenId, poolKey, newConfig, false);
    }

    /// @notice Updates position triggers by computing the diff between old and new configs
    /// @dev Only removes triggers that changed and only adds new triggers, avoiding redundant operations
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    /// @param newConfig The new position configuration
    /// @param force If true, assumes previous config was empty (for adding triggers without removal)
    function _updatePositionTriggers(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory newConfig, bool force) internal {
        PositionConfig storage oldConfig = positionConfigs[tokenId];

        // If both modes require no triggers, nothing to do
        bool oldHasTriggers = !force && oldConfig.mode != PositionMode.NONE && oldConfig.mode != PositionMode.AUTO_COMPOUND_ONLY;
        bool newHasTriggers = newConfig.mode != PositionMode.NONE && newConfig.mode != PositionMode.AUTO_COMPOUND_ONLY;

        if (!oldHasTriggers && !newHasTriggers) {
            return;
        }

        PoolId poolId = poolKey.toId();
        (, PositionInfo posInfo) = _getPoolAndPositionInfo(tokenId);

        TickLinkedList.List storage lowerList = lowerTriggerAfterSwap[poolId];
        TickLinkedList.List storage upperList = upperTriggerAfterSwap[poolId];

        // Ensure the list is increasing (if not, set it to true - only once in first use)
        if (!upperList.increasing) {
            upperList.increasing = true;
        }

        // Pack old and new ticks into arrays to reduce stack variables
        // When force is true, use sentinel values for old ticks (no triggers to remove)
        int24[4] memory oldTicks;
        if (force) {
            oldTicks[0] = type(int24).min;
            oldTicks[1] = type(int24).min;
            oldTicks[2] = type(int24).max;
            oldTicks[3] = type(int24).max;
        } else {
            oldTicks = _computeTriggerTicksFromStorage(tokenId, poolKey, oldConfig, posInfo.tickLower(), posInfo.tickUpper());
        }
        int24[4] memory newTicks = _computeTriggerTicksFromMemory(tokenId, poolKey, newConfig, posInfo.tickLower(), posInfo.tickUpper());

        // Process lower triggers (indices 0 and 1)
        _updateTriggerList(lowerList, tokenId, oldTicks[0], oldTicks[1], newTicks[0], newTicks[1], type(int24).min);
        // Process upper triggers (indices 2 and 3)
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
        // Remove old triggers that are not in new config
        if (old1 != sentinel && old1 != new1 && old1 != new2) {
            list.remove(old1, tokenId);
        }
        if (old2 != sentinel && old2 != new1 && old2 != new2) {
            list.remove(old2, tokenId);
        }
        // Add new triggers that were not in old config
        if (new1 != sentinel && new1 != old1 && new1 != old2) {
            list.insert(new1, tokenId);
        }
        if (new2 != sentinel && new2 != old1 && new2 != old2) {
            list.insert(new2, tokenId);
        }
    }

    /// @notice Computes trigger ticks for a position config from storage
    /// @return ticks Array of [lower1, lower2, upper1, upper2]
    function _computeTriggerTicksFromStorage(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig storage config,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (int24[4] memory) {
        // Copy storage config to memory and delegate to shared implementation
        return _computeTriggerTicks(
            tokenId,
            poolKey,
            config.mode,
            config.autoRangeLowerLimit,
            config.autoRangeUpperLimit,
            config.autoExitIsRelative,
            config.autoExitTickLower,
            config.autoExitTickUpper,
            config.autoLendToleranceTick,
            tickLower,
            tickUpper
        );
    }

    /// @notice Computes trigger ticks from a config passed in memory
    function _computeTriggerTicksFromMemory(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (int24[4] memory) {
        return _computeTriggerTicks(
            tokenId,
            poolKey,
            config.mode,
            config.autoRangeLowerLimit,
            config.autoRangeUpperLimit,
            config.autoExitIsRelative,
            config.autoExitTickLower,
            config.autoExitTickUpper,
            config.autoLendToleranceTick,
            tickLower,
            tickUpper
        );
    }

    /// @notice Shared implementation for computing trigger ticks
    function _computeTriggerTicks(
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
        ticks[0] = type(int24).min; // lower1
        ticks[1] = type(int24).min; // lower2
        ticks[2] = type(int24).max; // upper1
        ticks[3] = type(int24).max; // upper2

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
    }

}