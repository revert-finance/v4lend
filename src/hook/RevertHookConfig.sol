// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

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

    /// @notice Mirrors a baseline fee into a pool's stored dynamic LP fee. The PoolManager
    ///         only accepts dynamic fee updates from the pool's hook, so the auction
    ///         controller (which owns the fee configuration) goes through this passthrough.
    /// @dev Controller-only. The owner changes a pool's baseline via the controller's
    ///      setNormalLpFee, which updates config.normalLpFee and re-mirrors atomically, so the
    ///      stored fee and the winner's _winnerLpFee can never drift apart.
    function updateDynamicLPFee(PoolKey calldata key, uint24 newDynamicLPFee) external payable {
        if (msg.sender != address(hookAuctionController)) {
            revert Unauthorized();
        }
        poolManager.updateDynamicLPFee(key, newDynamicLPFee);
    }

    function setMaxTicksFromOracle(int24 newMaxTicksFromOracle) external payable onlyOwner {
        // (0, MAX_TICK] so oracleTick ± _maxTicksFromOracle can never overflow int24 inside
        // _tryOracleMaxEndTick, whose try/catch isolates only the oracle call itself
        if (newMaxTicksFromOracle <= 0 || newMaxTicksFromOracle > TickMath.MAX_TICK) {
            revert InvalidConfig();
        }
        _maxTicksFromOracle = newMaxTicksFromOracle;
        emit SetMaxTicksFromOracle(newMaxTicksFromOracle);
    }

    function setMinPositionValueNative(uint256 newMinPositionValueNative) external payable onlyOwner {
        _minPositionValueNative = newMinPositionValueNative;
        emit SetMinPositionValueNative(newMinPositionValueNative);
    }

    function setSwapProtectionConfig(uint256 tokenId, uint32 maxPriceImpactBps0, uint32 maxPriceImpactBps1)
        external
        payable
    {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        if (maxPriceImpactBps0 > 10000 || maxPriceImpactBps1 > 10000) {
            revert InvalidConfig();
        }

        SwapProtectionConfig memory swapProtectionConfig = SwapProtectionConfig({
            sqrtPriceMultiplier0: _calculateSqrtPriceMultiplier(maxPriceImpactBps0, true),
            sqrtPriceMultiplier1: _calculateSqrtPriceMultiplier(maxPriceImpactBps1, false)
        });

        _swapProtectionConfigs[tokenId] = swapProtectionConfig;
        emit SetSwapProtectionConfig(tokenId, swapProtectionConfig);
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

    /// @notice Moves token-id keyed automation state from a vault position to the position that
    ///         replaced it inside the vault's current transform (e.g. a V4Utils CHANGE_RANGE).
    /// @dev Called by a registered vault. Implementation lives in RevertHookAutoLendActions
    ///      (delegatecall, shared storage layout) to keep the hook under the EIP-170 limit; the
    ///      authorization and validation rules are documented there. Reverts bubble up and fail
    ///      the vault transform.
    function migrateVaultPosition(uint256 oldTokenId, uint256 newTokenId) external {
        _delegatecallPassthrough(
            address(autoLendActions), abi.encodeCall(autoLendActions.migrateVaultPosition, (oldTokenId, newTokenId))
        );
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
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        // Validation lives in the sidecar (delegatecall, shared storage) to keep the hook's own
        // bytecode under the EIP-170 limit. Reverts bubble up.
        _delegatecallPassthrough(
            address(autoLeverageActions), abi.encodeCall(autoLeverageActions.validatePositionConfig, (tokenId, config))
        );

        PositionConfig memory oldConfig = _positionConfigs[tokenId];
        _removePositionTriggersWithConfig(tokenId, poolKey, oldConfig);

        _positionConfigs[tokenId] = config;
        _syncAutoLeverageBaseTick(tokenId, poolKey, config.modeFlags);
        if (PositionModeFlags.hasTriggers(config.modeFlags)) {
            _requireTriggerCursorFresh(poolKey.toId(), poolKey.tickSpacing);
        }
        _addPositionTriggers(tokenId, poolKey);

        _syncActivation(tokenId, poolKey, config, checkImmediateExecution);

        emit SetPositionConfig(tokenId, config);
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

    function _syncAutoLeverageBaseTick(uint256 tokenId, PoolKey memory poolKey, uint8 modeFlags) internal {
        _positionStates[tokenId].autoLeverageBaseTick = PositionModeFlags.hasAutoLeverage(modeFlags)
            ? _getTickLower(_getTick(poolKey.toId()), poolKey.tickSpacing)
            : int24(0);
    }
}
