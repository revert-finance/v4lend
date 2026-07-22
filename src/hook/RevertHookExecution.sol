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
                tokenId, isUpperTrigger, autoExitIsRelative, autoExitTickLower, autoExitTickUpper
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
                exitTick =
                    autoExitTickUpper != type(int24).max ? posInfo.tickUpper() + autoExitTickUpper : type(int24).max;
            } else {
                exitTick =
                    autoExitTickLower != type(int24).min ? posInfo.tickLower() - autoExitTickLower : type(int24).min;
            }
        } else {
            exitTick = isUpperTrigger ? autoExitTickUpper : autoExitTickLower;
        }
    }

    function _handleAutoExit(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        // Skip a position whose NFT no longer exists so a dead trigger cannot revert the swap (H-2);
        // the fired node was already popped, so it will not be revisited.
        (address owner, bool exists) = _tryGetOwner(tokenId, false);
        if (!exists) {
            return;
        }
        // @custom:accepted-risk AUDIT-ACCEPTED-HOOK-TRIGGER-CONSUME
        // Triggers are consumed before action execution. Failed actions emit recovery
        // events rather than automatically re-arming the fired trigger.
        _removePositionTriggersWithConfig(tokenId, poolKey, _positionConfigs[tokenId]);

        if (!_executePositionAction(
                owner,
                tokenId,
                abi.encodeCall(this.autoExit, (poolKey, tokenId, isUpperTrigger)),
                abi.encodeCall(positionActions.autoExit, (poolKey, tokenId, isUpperTrigger))
            )) {
            _emitActionFailed(tokenId, Mode.AUTO_EXIT);
        }
    }

    function _handleAutoLend(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        // Skip a position whose NFT no longer exists (e.g. burned while lent). ownerOf would revert
        // and, called from _afterSwap outside any try/catch, would roll back the swap and re-arm the
        // dead node, permanently bricking the pool (H-2). The node has already been popped here.
        (address owner, bool exists) = _tryGetOwner(tokenId, false);
        if (!exists || _vaults[owner]) {
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
        // Skip a position whose NFT no longer exists so a dead trigger cannot revert the swap (H-2);
        // the fired node was already popped, so it will not be revisited.
        (address owner, bool exists) = _tryGetOwner(tokenId, false);
        if (!exists) {
            return;
        }
        // @custom:accepted-risk AUDIT-ACCEPTED-HOOK-TRIGGER-CONSUME
        // Triggers are consumed before action execution. Failed actions emit recovery
        // events rather than automatically re-arming the fired trigger.
        _removePositionTriggersWithConfig(tokenId, poolKey, _positionConfigs[tokenId]);

        if (!_executePositionAction(
                owner,
                tokenId,
                abi.encodeCall(this.autoRange, (poolKey, tokenId)),
                abi.encodeCall(positionActions.autoRange, (poolKey, tokenId))
            )) {
            _emitActionFailed(tokenId, Mode.AUTO_RANGE);
        }
    }

    function _handleAutoLeverage(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal override {
        // Skip a position whose NFT no longer exists so a dead trigger cannot revert the swap (H-2).
        (address owner, bool exists) = _tryGetOwner(tokenId, false);
        if (!exists || !_vaults[owner]) {
            return;
        }

        try IVault(owner)
            .transform(tokenId, address(this), abi.encodeCall(this.autoLeverage, (poolKey, tokenId, isUpperTrigger))) {}
        catch {
            _emitActionFailed(tokenId, Mode.AUTO_LEVERAGE);
        }
    }

    function _handleAutoRangeOrLeverage(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        PositionConfig storage config = _positionConfigs[tokenId];
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        (int24 rangeLower, int24 rangeUpper) = _calculateRangeTriggerTicks(
            posInfo.tickLower(), posInfo.tickUpper(), config.autoRangeLowerLimit, config.autoRangeUpperLimit
        );
        (int24 leverageLower, int24 leverageUpper) =
            _calculateLeverageTriggerTicks(_positionStates[tokenId].autoLeverageBaseTick, poolKey.tickSpacing);

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

    function autoExit(PoolKey calldata poolKey, uint256 tokenId, bool isUpper) external payable {
        _delegatecallPositionActionsPassthrough(abi.encodeCall(positionActions.autoExit, (poolKey, tokenId, isUpper)));
    }

    function autoRange(PoolKey calldata poolKey, uint256 tokenId) external payable {
        _delegatecallPositionActionsPassthrough(abi.encodeCall(positionActions.autoRange, (poolKey, tokenId)));
    }

    function autoLeverage(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external payable {
        _delegatecallAutoLeverageActionsPassthrough(
            abi.encodeCall(autoLeverageActions.autoLeverage, (poolKey, tokenId, isUpperTrigger))
        );
    }

    function autoLendForceExit(uint256 tokenId) external payable {
        _delegatecallPassthrough(address(autoLendActions), abi.encodeCall(autoLendActions.autoLendForceExit, (tokenId)));
    }

    function autoCollect(uint256[] calldata tokenIds) external payable {
        _delegatecallPositionActionsPassthrough(abi.encodeCall(positionActions.autoCollect, (tokenIds)));
    }

    function autoCollectForVault(uint256 tokenId, address caller) external payable {
        _delegatecallPositionActionsPassthrough(abi.encodeCall(positionActions.autoCollectForVault, (tokenId, caller)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }

        uint256 rawAction;
        assembly ("memory-safe") {
            rawAction := calldataload(data.offset)
        }

        if (rawAction > uint8(UnlockAction.IMMEDIATE_AUTO_LEVERAGE)) {
            revert InvalidConfig();
        }

        if (rawAction == uint8(UnlockAction.AUTO_COLLECT)) {
            (, uint256 tokenId, address caller) = abi.decode(data, (UnlockAction, uint256, address));
            _executeAutoCollect(tokenId, caller);
        } else if (rawAction == uint8(UnlockAction.IMMEDIATE_AUTO_LEVERAGE)) {
            (, uint256 tokenId, bool isUpperTrigger) = abi.decode(data, (UnlockAction, uint256, bool));
            _executeImmediateAutoLeverageUnlocked(tokenId, isUpperTrigger);
        } else {
            (, uint256 tokenId, bool isUpperTrigger, int24 tick) =
                abi.decode(data, (UnlockAction, uint256, bool, int24));
            _executeImmediateActionUnlocked(tokenId, isUpperTrigger, tick);
        }
        return bytes("");
    }

    function _executeAutoCollect(uint256 tokenId, address caller) internal {
        if (!_tryDelegatecallPositionActions(abi.encodeCall(positionActions.executeAutoCollect, (tokenId, caller)))) {
            _emitActionFailed(tokenId, Mode.AUTO_COLLECT);
        }
    }

    function _emitActionFailed(uint256 tokenId, Mode mode) internal {
        emit HookActionFailed(tokenId, mode);
    }

    function _executePositionAction(
        address owner,
        uint256 tokenId,
        bytes memory transformData,
        bytes memory delegateData
    ) internal returns (bool) {
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

    function getOracleMaxEndTick(PoolKey calldata poolKey, bool up) external view returns (int24 maxEndTick) {
        return _getOracleMaxEndTick(poolKey, up);
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
