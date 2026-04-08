// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookExecution} from "./RevertHookExecution.sol";

/// @title RevertHookCallbacks
/// @notice Hook callback and fee-accounting layer
abstract contract RevertHookCallbacks is RevertHookExecution {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        _tickLowerLasts[key.toId()] = tickLower;
        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(address caller, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        if (caller == address(this)) {
            return (this.afterSwap.selector, 0);
        }

        int24 cursor = _tickLowerLasts[poolId];
        int24 liveTick;

        bool hasCachedUpperOracleMaxEndTick;
        bool hasCachedLowerOracleMaxEndTick;
        int24 upperOracleMaxEndTick;
        int24 lowerOracleMaxEndTick;
        uint256 processedTickBatches;
        while (processedTickBatches < _MAX_TRIGGER_BATCHES_PER_SWAP) {
            liveTick = _getTickLower(_getTick(poolId), key.tickSpacing);
            if (cursor == liveTick) {
                break;
            }

            bool increasing = cursor < liveTick;
            int24 tickEnd = liveTick;
            if (increasing) {
                if (!hasCachedUpperOracleMaxEndTick) {
                    upperOracleMaxEndTick = _getOracleMaxEndTick(key, true);
                    hasCachedUpperOracleMaxEndTick = true;
                }
                if (upperOracleMaxEndTick < tickEnd) {
                    tickEnd = upperOracleMaxEndTick;
                }
            } else {
                if (!hasCachedLowerOracleMaxEndTick) {
                    lowerOracleMaxEndTick = _getOracleMaxEndTick(key, false);
                    hasCachedLowerOracleMaxEndTick = true;
                }
                if (lowerOracleMaxEndTick > tickEnd) {
                    tickEnd = lowerOracleMaxEndTick;
                }
            }
            if (tickEnd == cursor) {
                break;
            }

            TickLinkedList.List storage list =
                increasing ? _upperTriggerAfterSwap[poolId] : _lowerTriggerAfterSwap[poolId];

            (bool exists, int24 tick) = list.searchFirstAfter(cursor);
            if (!exists || (increasing ? tick > tickEnd : tick < tickEnd)) {
                cursor = tickEnd;
                continue;
            }

            uint256[] memory tokenIdsAtTick = list.tokenIds[tick];
            list.clearTick(tick);

            uint256 length = tokenIdsAtTick.length;
            int24 previousLiveTick = liveTick;
            for (uint256 i; i < length;) {
                PositionConfig storage config = _positionConfigs[tokenIdsAtTick[i]];
                _dispatchAutomationAction(
                    key,
                    tokenIdsAtTick[i],
                    config.modeFlags,
                    increasing,
                    tick,
                    config.autoExitIsRelative,
                    config.autoExitTickLower,
                    config.autoExitTickUpper
                );

                liveTick = _getTickLower(_getTick(poolId), key.tickSpacing);
                if (_hasDirectionReversed(previousLiveTick, liveTick, increasing)) {
                    if (i + 1 < length) {
                        _requeueTokenIdsAtTick(list, tick, tokenIdsAtTick, i + 1);
                    }
                    break;
                }
                previousLiveTick = liveTick;
                unchecked {
                    ++i;
                }
            }

            cursor = tick;
            unchecked {
                ++processedTickBatches;
            }
        }

        _tickLowerLasts[poolId] = cursor;
        return (this.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != address(positionManager) && sender != address(this)) {
            revert Unauthorized();
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);

        feeDelta = _takeProtocolFees(tokenId, key, feeDelta);

        if (sender == address(this)) {
            return (BaseHook.afterAddLiquidity.selector, feeDelta);
        }

        if (!PositionModeFlags.isNone(_positionConfigs[tokenId].modeFlags) && !_isActivated(tokenId)) {
            if (_getPositionValueNative(tokenId) >= _minPositionValueNative) {
                _addPositionTriggers(tokenId, key);
                _activatePosition(tokenId);
            }
        }

        return (BaseHook.afterAddLiquidity.selector, feeDelta);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);
        feeDelta = _takeProtocolFees(tokenId, key, feeDelta);

        if (sender == address(this)) {
            return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
        }

        if (_isActivated(tokenId)) {
            uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
            if (liquidity == 0 || _getPositionValueNative(tokenId) < _minPositionValueNative) {
                _removePositionTriggers(tokenId, key);
                _deactivatePosition(tokenId);
            }
        }

        return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
    }

    function _takeProtocolFees(uint256 tokenId, PoolKey calldata key, BalanceDelta feeDelta)
        internal
        returns (BalanceDelta newFeeDelta)
    {
        PositionState storage state = _positionStates[tokenId];
        uint32 accumulatedActiveTime = state.accumulatedActiveTime;
        uint32 lastActivated = state.lastActivated;
        uint32 currentTime = uint32(block.timestamp);
        if (lastActivated > 0) {
            accumulatedActiveTime += currentTime - lastActivated;
            state.lastActivated = currentTime;
        }

        uint32 lastCollect = state.lastCollect;
        uint32 feeTime = lastCollect == 0 ? 0 : currentTime - lastCollect;
        state.lastCollect = currentTime;

        if (feeTime == 0 || accumulatedActiveTime == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        uint16 lpFeeBps = hookFeeController.lpFeeBps();
        if (lpFeeBps == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        int128 protocolFee0 =
            // forge-lint: disable-next-line(unsafe-typecast)
            int32(accumulatedActiveTime) * feeDelta.amount0() * int16(lpFeeBps) / (10000 * int32(feeTime));
        int128 protocolFee1 =
            // forge-lint: disable-next-line(unsafe-typecast)
            int32(accumulatedActiveTime) * feeDelta.amount1() * int16(lpFeeBps) / (10000 * int32(feeTime));

        if (protocolFee0 == 0 && protocolFee1 == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        address feeRecipient = hookFeeController.protocolFeeRecipient();

        if (protocolFee0 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(key.currency0, feeRecipient, uint256(int256(protocolFee0)));
        }
        if (protocolFee1 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(key.currency1, feeRecipient, uint256(int256(protocolFee1)));
        }

        emit SendProtocolFee(
            tokenId,
            key.currency0,
            key.currency1,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256(int256(protocolFee0)),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256(int256(protocolFee1)),
            feeRecipient
        );

        newFeeDelta = toBalanceDelta(protocolFee0, protocolFee1);
    }
}
