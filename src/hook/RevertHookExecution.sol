// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookConfig} from "./RevertHookConfig.sol";

/// @title RevertHookExecution
/// @notice Hook orchestration, delegatecall entrypoints, and unlocked execution flow
abstract contract RevertHookExecution is RevertHookConfig {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
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
    ) internal override {
        if (PositionModeFlags.hasAutoExit(modeFlags)) {
            int24 exitTick = _calculateExitTick(
                tokenId,
                isUpperTrigger,
                autoExitIsRelative,
                autoExitTickLower,
                autoExitTickUpper
            );
            if (tick == exitTick) {
                _handleAutoExit(poolKey, tokenId, isUpperTrigger);
                return;
            }
        }

        bool hasAutoRange = PositionModeFlags.hasAutoRange(modeFlags);
        bool hasAutoLeverage = PositionModeFlags.hasAutoLeverage(modeFlags);

        if (hasAutoRange && hasAutoLeverage) {
            _handleAutoRangeOrLeverage(poolKey, tokenId, isUpperTrigger);
            return;
        }

        if (hasAutoRange) {
            _handleAutoRange(poolKey, tokenId);
            return;
        }

        if (hasAutoLeverage) {
            _handleAutoLeverage(poolKey, tokenId, isUpperTrigger);
            return;
        }

        if (PositionModeFlags.hasAutoLend(modeFlags)) {
            _handleAutoLend(poolKey, tokenId, isUpperTrigger);
        }
    }

    function _calculateExitTick(
        uint256 tokenId,
        bool isUpperTrigger,
        bool autoExitIsRelative,
        int24 autoExitTickLower,
        int24 autoExitTickUpper
    ) internal view returns (int24 exitTick) {
        if (autoExitIsRelative) {
            (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
            if (isUpperTrigger) {
                exitTick = autoExitTickUpper != type(int24).max
                    ? posInfo.tickUpper() + autoExitTickUpper
                    : type(int24).max;
            } else {
                exitTick = autoExitTickLower != type(int24).min
                    ? posInfo.tickLower() - autoExitTickLower
                    : type(int24).min;
            }
        } else {
            exitTick = isUpperTrigger ? autoExitTickUpper : autoExitTickLower;
        }
    }

    function _handleAutoExit(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        _removePositionTriggersWithConfig(tokenId, poolKey, _positionConfigs[tokenId]);
        address owner = _getOwner(tokenId, false);

        if (
            !_executePositionAction(
                owner,
                tokenId,
                abi.encodeCall(this.autoExit, (poolKey, tokenId, isUpperTrigger)),
                abi.encodeCall(positionActions.autoExit, (poolKey, tokenId, isUpperTrigger))
            )
        ) {
            _emitActionFailed(tokenId, Mode.AUTO_EXIT);
        }
    }

    function _handleAutoLend(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        if (_vaults[_getOwner(tokenId, false)]) {
            return;
        }

        uint256 shares = _positionStates[tokenId].autoLendShares;
        bytes memory data = shares > 0
            ? abi.encodeCall(autoLendActions.autoLendWithdraw, (poolKey, tokenId, shares))
            : abi.encodeCall(autoLendActions.autoLendDeposit, (poolKey, tokenId, isUpperTrigger));
        if (!_tryDelegatecall(address(autoLendActions), data)) {
            _emitActionFailed(tokenId, Mode.AUTO_LEND);
        }
    }

    function _handleAutoRange(PoolKey memory poolKey, uint256 tokenId) internal {
        _removePositionTriggersWithConfig(tokenId, poolKey, _positionConfigs[tokenId]);
        address owner = _getOwner(tokenId, false);

        if (
            !_executePositionAction(
                owner,
                tokenId,
                abi.encodeCall(this.autoRange, (poolKey, tokenId)),
                abi.encodeCall(positionActions.autoRange, (poolKey, tokenId))
            )
        ) {
            _emitActionFailed(tokenId, Mode.AUTO_RANGE);
        }
    }

    function _handleAutoLeverage(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        address owner = _getOwner(tokenId, false);
        if (!_vaults[owner]) {
            return;
        }

        try IVault(owner).transform(
            tokenId,
            address(this),
            abi.encodeCall(this.autoLeverage, (poolKey, tokenId, isUpperTrigger))
        ) {} catch {
            _emitActionFailed(tokenId, Mode.AUTO_LEVERAGE);
        }
    }

    function _handleAutoRangeOrLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        bool isUpperTrigger
    ) internal {
        PositionConfig storage config = _positionConfigs[tokenId];
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        (int24 rangeLower, int24 rangeUpper) = _calculateRangeTriggerTicks(
            posInfo.tickLower(),
            posInfo.tickUpper(),
            config.autoRangeLowerLimit,
            config.autoRangeUpperLimit
        );
        (int24 leverageLower, int24 leverageUpper) = _calculateLeverageTriggerTicks(
            _positionStates[tokenId].autoLeverageBaseTick,
            poolKey.tickSpacing
        );

        if (isUpperTrigger) {
            if (rangeUpper <= leverageUpper) {
                _handleAutoRange(poolKey, tokenId);
            } else {
                _handleAutoLeverage(poolKey, tokenId, isUpperTrigger);
            }
        } else {
            if (rangeLower >= leverageLower) {
                _handleAutoRange(poolKey, tokenId);
            } else {
                _handleAutoLeverage(poolKey, tokenId, isUpperTrigger);
            }
        }
    }

    function autoExit(PoolKey calldata poolKey, uint256 tokenId, bool isUpper) external {
        _delegatecallPositionActions(
            abi.encodeCall(positionActions.autoExit, (poolKey, tokenId, isUpper))
        );
    }

    function autoRange(PoolKey calldata poolKey, uint256 tokenId) external {
        _delegatecallPositionActions(
            abi.encodeCall(positionActions.autoRange, (poolKey, tokenId))
        );
    }

    function autoLeverage(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        _delegatecallAutoLeverageActions(
            abi.encodeCall(autoLeverageActions.autoLeverage, (poolKey, tokenId, isUpperTrigger))
        );
    }

    function autoLendForceExit(uint256 tokenId) external {
        _delegatecall(
            address(autoLendActions),
            abi.encodeCall(autoLendActions.autoLendForceExit, (tokenId))
        );
    }

    function autoCompound(uint256[] calldata tokenIds) external {
        _delegatecallPositionActions(abi.encodeCall(positionActions.autoCompound, (tokenIds)));
    }

    function autoCompoundForVault(uint256 tokenId, address caller) external {
        _delegatecallPositionActions(abi.encodeCall(positionActions.autoCompoundForVault, (tokenId, caller)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }

        if (data.length == 64) {
            (uint256 tokenId, address caller) = abi.decode(data, (uint256, address));
            _executeAutoCompound(tokenId, caller);
        } else {
            (uint256 tokenId, bool isUpperTrigger, int24 tick) = abi.decode(data, (uint256, bool, int24));
            _executeImmediateActionUnlocked(tokenId, isUpperTrigger, tick);
        }
        return bytes("");
    }

    function _executeAutoCompound(uint256 tokenId, address caller) internal {
        if (
            !_tryDelegatecallPositionActions(
                abi.encodeCall(positionActions.executeAutoCompound, (tokenId, caller))
            )
        ) {
            _emitActionFailed(tokenId, Mode.AUTO_COMPOUND);
        }
    }

    function _emitActionFailed(uint256 tokenId, Mode mode) internal {
        emit HookActionFailed(tokenId, mode);
    }

    function _executePositionAction(address owner, uint256 tokenId, bytes memory transformData, bytes memory delegateData)
        internal
        returns (bool)
    {
        if (_vaults[owner]) {
            try IVault(owner).transform(tokenId, address(this), transformData) {
                return true;
            } catch {
                return false;
            }
        }
        return _tryDelegatecallPositionActions(delegateData);
    }

    function _getOracleMaxEndTick(PoolKey memory poolKey, bool up) internal view returns (int24 maxEndTick) {
        uint160 oracleSqrtPriceX96 =
            v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        int24 oracleTick = _getTickLower(TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96), poolKey.tickSpacing);

        if (up) {
            maxEndTick = _getTickLower(oracleTick + _maxTicksFromOracle, poolKey.tickSpacing);
        } else {
            maxEndTick = _getTickLower(oracleTick - _maxTicksFromOracle, poolKey.tickSpacing);
        }
    }

    function _hasDirectionReversed(int24 previousLiveTick, int24 currentLiveTick, bool increasing)
        internal
        pure
        returns (bool)
    {
        return increasing ? currentLiveTick < previousLiveTick : currentLiveTick > previousLiveTick;
    }

    function _requeueTokenIdsAtTick(
        TickLinkedList.List storage list,
        int24 tick,
        uint256[] memory tokenIds,
        uint256 startIndex
    ) internal {
        uint256 length = tokenIds.length;
        for (uint256 i = startIndex; i < length;) {
            list.insert(tick, tokenIds[i]);
            unchecked {
                ++i;
            }
        }
    }
}
