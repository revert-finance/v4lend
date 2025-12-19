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

    // Position trigger mappings
    mapping(PoolId => int24) public tickLowerLasts;
    mapping(PoolId poolId => TickLinkedList.List) public lowerTriggerAfterSwap;
    mapping(PoolId poolId => TickLinkedList.List) public upperTriggerAfterSwap;

    // Events
    event SetAutoLendVault(address indexed token, IERC4626 vault);
    event SetMaxTicksFromOracle(int24 maxTicksFromOracle);
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

        bool isRelative; // if true, the auto exit tick is relative to the position limits, if false, the auto exit tick is absolute
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

    /// @notice Sets the position configuration for a given token ID
    /// @param tokenId The token ID of the position
    /// @param positionConfig The position configuration to set
    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        _setPositionConfig(tokenId, positionConfig);
    }

    /// @notice Disables a position by setting its config to NONE
    /// @param tokenId The token ID of the position to disable
    function _disablePosition(uint256 tokenId) internal {
        _setPositionConfig(tokenId, PositionConfig({
            mode: PositionMode.NONE,
            autoCompoundMode: AutoCompoundMode.NONE,
            isRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0
        }));
    }

    /// @notice Internal function to set position configuration
    /// @param tokenId The token ID of the position
    /// @param config The position configuration to set
    function _setPositionConfig(uint256 tokenId, PositionConfig memory config) internal {
        // handle activation and deactivation
        PositionMode previousMode = positionConfigs[tokenId].mode;
        bool activated = previousMode == PositionMode.NONE && config.mode != PositionMode.NONE;
        if (activated) {
            positionStates[tokenId].lastActivated = uint32(block.timestamp);
        } else {
            bool deactivated = previousMode != PositionMode.NONE && config.mode == PositionMode.NONE;
            if (deactivated) {
                positionStates[tokenId].acumulatedActiveTime += uint32(block.timestamp) - positionStates[tokenId].lastActivated;
            }
            positionStates[tokenId].lastActivated = 0; // mark as deactivated
        }

        (PoolKey memory poolKey,) = _getPoolAndPositionInfo(tokenId);

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

        _removePositionTriggers(tokenId, poolKey);
        positionConfigs[tokenId] = config;
        _addPositionTriggers(tokenId, poolKey);

        // emit event
        emit SetPositionConfig(tokenId, config);
    }

    // Abstract functions that must be implemented by the child contract
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view virtual returns (address);
    function _getPoolAndPositionInfo(uint256 tokenId) internal view virtual returns (PoolKey memory, PositionInfo);

    /// @notice Adds position triggers based on the position configuration
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    function _addPositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        PositionMode mode = positionConfigs[tokenId].mode;
        if (mode == PositionMode.NONE || mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return;
        }

        PoolId poolId = poolKey.toId();

        (, PositionInfo posInfo) = _getPoolAndPositionInfo(tokenId);
        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        TickLinkedList.List storage lowerList = lowerTriggerAfterSwap[poolId];
        TickLinkedList.List storage upperList = upperTriggerAfterSwap[poolId];

        // ensure the list is increasing (if not, set it to true - only once in first use)
        if (!upperList.increasing) {
            upperList.increasing = true;
        }

        if (mode == PositionMode.AUTO_RANGE || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            _addAutoRangeTriggers(tokenId, tickLower, tickUpper, lowerList, upperList);
        } 
        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            _addAutoExitTriggers(tokenId, tickLower, tickUpper, lowerList, upperList);
        }
        if (mode == PositionMode.AUTO_LEND) {
            _addAutoLendTriggers(tokenId, poolKey, tickLower, tickUpper, lowerList, upperList);
        }
    }

    /// @notice Removes position triggers based on the position configuration
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    function _removePositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        PositionMode mode = positionConfigs[tokenId].mode;

        if (mode == PositionMode.NONE || mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return;
        }

        PoolId poolId = poolKey.toId();
        (, PositionInfo posInfo) = _getPoolAndPositionInfo(tokenId);
        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        if (mode == PositionMode.AUTO_RANGE || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            _removeAutoRangeTriggers(tokenId, poolId, tickLower, tickUpper);
        } 
        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            _removeAutoExitTriggers(tokenId, poolId, tickLower, tickUpper);
        }
        if (mode == PositionMode.AUTO_LEND) {
            _removeAutoLendTriggers(tokenId, poolKey, poolId, tickLower, tickUpper);
        }
    }

    /// @notice Adds auto range triggers for a position
    function _addAutoRangeTriggers(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        TickLinkedList.List storage lowerList,
        TickLinkedList.List storage upperList
    ) internal {
        if (positionConfigs[tokenId].autoRangeLowerLimit != type(int24).min) {
            lowerList.insert(tickLower - positionConfigs[tokenId].autoRangeLowerLimit, tokenId);
        }
        if (positionConfigs[tokenId].autoRangeUpperLimit != type(int24).max) {
            upperList.insert(tickUpper + positionConfigs[tokenId].autoRangeUpperLimit, tokenId);
        }
    }

    /// @notice Adds auto exit triggers for a position
    function _addAutoExitTriggers(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        TickLinkedList.List storage lowerList,
        TickLinkedList.List storage upperList
    ) internal {
        if (positionConfigs[tokenId].isRelative) {
            if (positionConfigs[tokenId].autoExitTickLower != type(int24).min) {
                lowerList.insert(tickLower - positionConfigs[tokenId].autoExitTickLower, tokenId);
            }
            if (positionConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                upperList.insert(tickUpper + positionConfigs[tokenId].autoExitTickUpper, tokenId);
            }
        } else {
            if (positionConfigs[tokenId].autoExitTickLower != type(int24).min) {
                lowerList.insert(positionConfigs[tokenId].autoExitTickLower, tokenId);
            }
            if (positionConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                upperList.insert(positionConfigs[tokenId].autoExitTickUpper, tokenId);
            }
        }
    }

    /// @notice Adds auto lend triggers for a position
    function _addAutoLendTriggers(
        uint256 tokenId,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        TickLinkedList.List storage lowerList,
        TickLinkedList.List storage upperList
    ) internal {
        if (positionStates[tokenId].autoLendShares > 0) {
            if (Currency.unwrap(poolKey.currency0) == positionStates[tokenId].autoLendToken) {
                upperList.insert(
                    tickLower - positionConfigs[tokenId].autoLendToleranceTick - poolKey.tickSpacing, tokenId
                );
            } else {
                lowerList.insert(tickUpper + positionConfigs[tokenId].autoLendToleranceTick, tokenId);
            }
        } else {
            lowerList.insert(
                tickLower - positionConfigs[tokenId].autoLendToleranceTick * 2 - poolKey.tickSpacing, tokenId
            );
            upperList.insert(tickUpper + positionConfigs[tokenId].autoLendToleranceTick * 2, tokenId);
        }
    }

    /// @notice Removes auto range triggers for a position
    function _removeAutoRangeTriggers(
        uint256 tokenId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        if (positionConfigs[tokenId].autoRangeLowerLimit != type(int24).min) {
            lowerTriggerAfterSwap[poolId].remove(tickLower - positionConfigs[tokenId].autoRangeLowerLimit, tokenId);
        }
        if (positionConfigs[tokenId].autoRangeUpperLimit != type(int24).max) {
            upperTriggerAfterSwap[poolId].remove(tickUpper + positionConfigs[tokenId].autoRangeUpperLimit, tokenId);
        }
    }

    /// @notice Removes auto exit triggers for a position
    function _removeAutoExitTriggers(
        uint256 tokenId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        if (positionConfigs[tokenId].isRelative) {
            if (positionConfigs[tokenId].autoExitTickLower != type(int24).min) {
                lowerTriggerAfterSwap[poolId].remove(tickLower - positionConfigs[tokenId].autoExitTickLower, tokenId);
            }
            if (positionConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                upperTriggerAfterSwap[poolId].remove(tickUpper + positionConfigs[tokenId].autoExitTickUpper, tokenId);
            }
        } else {
            if (positionConfigs[tokenId].autoExitTickLower != type(int24).min) {
                lowerTriggerAfterSwap[poolId].remove(positionConfigs[tokenId].autoExitTickLower, tokenId);
            }
            if (positionConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                upperTriggerAfterSwap[poolId].remove(positionConfigs[tokenId].autoExitTickUpper, tokenId);
            }
        }
    }

    /// @notice Removes auto lend triggers for a position
    function _removeAutoLendTriggers(
        uint256 tokenId,
        PoolKey memory poolKey,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        if (positionStates[tokenId].autoLendShares > 0) {
            if (Currency.unwrap(poolKey.currency0) == positionStates[tokenId].autoLendToken) {
                upperTriggerAfterSwap[poolId].remove(
                    tickLower - positionConfigs[tokenId].autoLendToleranceTick - poolKey.tickSpacing, tokenId
                );
            } else {
                lowerTriggerAfterSwap[poolId].remove(
                    tickUpper + positionConfigs[tokenId].autoLendToleranceTick, tokenId
                );
            }
        } else {
            lowerTriggerAfterSwap[poolId].remove(
                tickLower - positionConfigs[tokenId].autoLendToleranceTick * 2 - poolKey.tickSpacing, tokenId
            );
            upperTriggerAfterSwap[poolId].remove(
                tickUpper + positionConfigs[tokenId].autoLendToleranceTick * 2, tokenId
            );
        }
    }
}

