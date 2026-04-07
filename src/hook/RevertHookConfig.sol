// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookImmediate} from "./RevertHookImmediate.sol";

/// @title RevertHookConfig
/// @notice Hook configuration setters and validation helpers
abstract contract RevertHookConfig is RevertHookImmediate {
    function setAutoLendVault(address token, IERC4626 vault) external payable onlyOwner {
        if (address(vault) != address(0)) {
            address expectedAsset = token == address(0) ? address(weth) : token;
            if (vault.asset() != expectedAsset) {
                revert InvalidConfig();
            }
        }
        _autoLendVaults[token] = vault;
        emit SetAutoLendVault(token, vault);
    }

    function setMaxTicksFromOracle(int24 newMaxTicksFromOracle) external payable onlyOwner {
        _maxTicksFromOracle = newMaxTicksFromOracle;
        emit SetMaxTicksFromOracle(newMaxTicksFromOracle);
    }

    function setMinPositionValueNative(uint256 newMinPositionValueNative) external payable onlyOwner {
        _minPositionValueNative = newMinPositionValueNative;
        emit SetMinPositionValueNative(newMinPositionValueNative);
    }

    function setProtocolFeeBps(uint16 newProtocolFeeBps) external payable onlyOwner {
        if (newProtocolFeeBps > 10000) {
            revert InvalidConfig();
        }
        _protocolFeeBps = newProtocolFeeBps;
        emit SetProtocolFeeBps(newProtocolFeeBps);
    }

    function setProtocolFeeRecipient(address newProtocolFeeRecipient) external payable onlyOwner {
        _protocolFeeRecipient = newProtocolFeeRecipient;
        emit SetProtocolFeeRecipient(newProtocolFeeRecipient);
    }

    function setGeneralConfig(
        uint256 tokenId,
        uint24 swapPoolFee,
        int24 swapPoolTickSpacing,
        IHooks swapPoolHooks,
        uint32 maxPriceImpactBps0,
        uint32 maxPriceImpactBps1
    ) external payable {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (swapPoolTickSpacing % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }
        if (maxPriceImpactBps0 > 10000 || maxPriceImpactBps1 > 10000) {
            revert InvalidConfig();
        }

        GeneralConfig memory generalConfig = GeneralConfig({
            swapPoolFee: swapPoolFee,
            swapPoolTickSpacing: swapPoolTickSpacing,
            swapPoolHooks: swapPoolHooks,
            sqrtPriceMultiplier0: _calculateSqrtPriceMultiplier(maxPriceImpactBps0, true),
            sqrtPriceMultiplier1: _calculateSqrtPriceMultiplier(maxPriceImpactBps1, false)
        });

        _generalConfigs[tokenId] = generalConfig;
        emit SetGeneralConfig(tokenId, generalConfig);
    }

    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external payable {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        if (!PositionModeFlags.isNone(positionConfig.modeFlags)) {
            uint256 value = _getPositionValueNative(tokenId);
            if (value < _minPositionValueNative) {
                revert PositionValueTooLow();
            }
        }

        _setPositionConfig(tokenId, positionConfig, true);
    }

    function _calculateSqrtPriceMultiplier(uint32 maxPriceImpactBps, bool zeroForOne)
        internal
        pure
        returns (uint128 multiplier)
    {
        if (maxPriceImpactBps == 0) {
            return 0;
        }

        uint256 q64Squared = uint256(Q64) * uint256(Q64);
        uint256 numerator = zeroForOne
            ? (10000 - maxPriceImpactBps) * q64Squared / 10000
            : (10000 + maxPriceImpactBps) * q64Squared / 10000;
        multiplier = uint128(Math.sqrt(numerator));
    }

    function _setPositionConfig(uint256 tokenId, PositionConfig memory config, bool checkImmediateExecution) internal {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _validateTickAlignedConfig(config, poolKey.tickSpacing);
        _validateModeFlags(config.modeFlags, tokenId, poolKey);
        _validateRangeConfig(poolKey.tickSpacing, positionInfo.tickLower(), positionInfo.tickUpper(), config);

        PositionConfig memory oldConfig = _positionConfigs[tokenId];
        _removePositionTriggersWithConfig(tokenId, poolKey, oldConfig);

        _positionConfigs[tokenId] = config;
        _syncAutoLeverageBaseTick(tokenId, poolKey, config.modeFlags);
        _addPositionTriggers(tokenId, poolKey);

        _syncActivation(tokenId, poolKey, config, checkImmediateExecution);

        emit SetPositionConfig(tokenId, config);
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

    function _validateRangeConfig(
        int24 tickSpacing,
        int24 positionTickLower,
        int24 positionTickUpper,
        PositionConfig memory config
    ) internal pure {
        if (!PositionModeFlags.hasAutoRange(config.modeFlags)) {
            return;
        }

        if (config.autoRangeLowerDelta >= config.autoRangeUpperDelta) {
            revert InvalidConfig();
        }

        (int24 rangeLower, int24 rangeUpper) = _calculateRangeTriggerTicks(
            positionTickLower,
            positionTickUpper,
            config.autoRangeLowerLimit,
            config.autoRangeUpperLimit
        );

        if (
            _rangeTriggerCanResolveToSamePosition(
                positionTickLower,
                positionTickUpper,
                rangeLower,
                config.autoRangeLowerDelta,
                config.autoRangeUpperDelta,
                tickSpacing,
                false
            )
                || _rangeTriggerCanResolveToSamePosition(
                    positionTickLower,
                    positionTickUpper,
                    rangeUpper,
                    config.autoRangeLowerDelta,
                    config.autoRangeUpperDelta,
                    tickSpacing,
                    true
                )
        ) {
            revert InvalidConfig();
        }
    }

    function _syncActivation(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        bool checkImmediateExecution
    ) internal {
        if (PositionModeFlags.isNone(config.modeFlags)) {
            _deactivatePosition(tokenId);
            return;
        }

        _activatePosition(tokenId);
        if (checkImmediateExecution) {
            _checkAndExecuteImmediate(tokenId, poolKey, config);
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
        if (!_hasAutoLendVault(Currency.unwrap(poolKey.currency0)) || !_hasAutoLendVault(Currency.unwrap(poolKey.currency1))) {
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
                address lendAsset = IVault(tokenOwner).asset();
                if (Currency.unwrap(poolKey.currency0) != lendAsset && Currency.unwrap(poolKey.currency1) != lendAsset) {
                    revert InvalidConfig();
                }
            }
        }
    }

    function _syncAutoLeverageBaseTick(uint256 tokenId, PoolKey memory poolKey, uint8 modeFlags) internal {
        _positionStates[tokenId].autoLeverageBaseTick = PositionModeFlags.hasAutoLeverage(modeFlags)
            ? _getTickLower(_getTick(poolKey.toId()), poolKey.tickSpacing)
            : int24(0);
    }

    function _rangeTriggerCanResolveToSamePosition(
        int24 currentTickLower,
        int24 currentTickUpper,
        int24 triggerTick,
        int24 lowerDelta,
        int24 upperDelta,
        int24 tickSpacing,
        bool isUpperTrigger
    ) internal pure returns (bool) {
        if (triggerTick == type(int24).min || triggerTick == type(int24).max) {
            return false;
        }

        int256 sameRangeBaseTickLower = int256(currentTickLower) - int256(lowerDelta);
        int256 sameRangeBaseTickUpper = int256(currentTickUpper) - int256(upperDelta);
        if (sameRangeBaseTickLower != sameRangeBaseTickUpper) {
            return false;
        }

        int256 sameRangeBaseTick = sameRangeBaseTickLower;
        if (sameRangeBaseTick % int256(tickSpacing) != 0) {
            return false;
        }

        int256 triggerTickInt = int256(triggerTick);
        return isUpperTrigger ? sameRangeBaseTick >= triggerTickInt : sameRangeBaseTick <= triggerTickInt;
    }
}
