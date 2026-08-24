// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookAutoLendActions} from "./RevertHookAutoLendActions.sol";
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
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
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

    /// @dev Fail-open auction integration: the controller syncs auction epochs, drips vested
    ///      auction proceeds to in-range LPs and returns the LP fee override for this swap
    ///      (only meaningful on dynamic-fee pools). A reverting or unset controller never
    ///      blocks swaps - the pool then uses its stored (baseline) dynamic fee.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 lpFeeOverride;
        if (address(hookAuctionController) != address(0)) {
            try hookAuctionController.beforeSwap(key, sender) returns (uint24 fee) {
                lpFeeOverride = fee;
            } catch {
                emit AuctionControllerFailed(key.toId());
            }
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /// @dev Fail-open notification so vested auction proceeds are dripped to the liquidity
    ///      that was in range while they vested, before the liquidity set changes.
    function _notifyAuctionLiquidityChange(PoolKey calldata key) internal {
        if (address(hookAuctionController) == address(0)) {
            return;
        }
        try hookAuctionController.beforeLiquidityChange(key) {}
        catch {
            emit AuctionControllerFailed(key.toId());
        }
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
        uint256 executedActions;
        while (executedActions < _MAX_EXECUTIONS_PER_SWAP) {
            liveTick = _getTickLower(_getTick(poolId), key.tickSpacing);
            if (cursor == liveTick) {
                break;
            }

            bool increasing = cursor < liveTick;
            int24 tickEnd = liveTick;
            if (increasing) {
                if (!hasCachedUpperOracleMaxEndTick) {
                    try this.getOracleMaxEndTick(key, true) returns (int24 maxEndTick) {
                        upperOracleMaxEndTick = maxEndTick;
                    } catch {
                        return (this.afterSwap.selector, 0);
                    }
                    hasCachedUpperOracleMaxEndTick = true;
                }
                if (upperOracleMaxEndTick < tickEnd) {
                    tickEnd = upperOracleMaxEndTick;
                }
            } else {
                if (!hasCachedLowerOracleMaxEndTick) {
                    try this.getOracleMaxEndTick(key, false) returns (int24 maxEndTick) {
                        lowerOracleMaxEndTick = maxEndTick;
                    } catch {
                        return (this.afterSwap.selector, 0);
                    }
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

            (uint256[] memory tokenIdsAtTick, bool tickDrained) =
                list.popTokenIds(tick, _MAX_EXECUTIONS_PER_SWAP - executedActions);

            uint256 length = tokenIdsAtTick.length;
            int24 previousLiveTick = liveTick;
            bool directionReversed;
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
                unchecked {
                    ++executedActions;
                    ++i;
                }

                liveTick = _getTickLower(_getTick(poolId), key.tickSpacing);
                if (_hasDirectionReversed(previousLiveTick, liveTick, increasing)) {
                    if (i < length) {
                        _requeueTokenIdsAtTick(list, tick, tokenIdsAtTick, i);
                    }
                    directionReversed = true;
                    break;
                }
                previousLiveTick = liveTick;
            }

            if (directionReversed || tickDrained) {
                cursor = tick;
            } else {
                break;
            }
        }

        _tickLowerLasts[poolId] = cursor;
        return (this.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        // NOTE: in practice sender is always the PositionManager - the hook's own liquidity
        // operations also go through positionManager.modifyLiquidities, so the address(this)
        // alternative here (and the sender == address(this) early-returns below) are defensive
        // and currently unreachable. Do not build new logic on those branches firing.
        if (sender != address(positionManager) && sender != address(this)) {
            revert Unauthorized();
        }
        _notifyAuctionLiquidityChange(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        if (sender != address(positionManager) && sender != address(this)) {
            revert Unauthorized();
        }
        _notifyAuctionLiquidityChange(key);
        return BaseHook.beforeRemoveLiquidity.selector;
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

        // defensive: sender is always the PositionManager today (see _beforeAddLiquidity note);
        // hook-internal operations run the logic below, which is idempotent by design
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

        // defensive: sender is always the PositionManager today (see _beforeAddLiquidity note);
        // hook-internal operations run the logic below, which is idempotent by design
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

    /// @dev Implementation lives in RevertHookAutoLendActions (delegatecall, shared storage
    ///      layout) to keep the hook's own bytecode under the EIP-170 limit.
    function _takeProtocolFees(uint256 tokenId, PoolKey calldata key, BalanceDelta feeDelta)
        internal
        returns (BalanceDelta newFeeDelta)
    {
        (bool success, bytes memory returndata) = address(autoLendActions).delegatecall(
            abi.encodeCall(RevertHookAutoLendActions.takeProtocolFees, (tokenId, key, feeDelta))
        );
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        newFeeDelta = abi.decode(returndata, (BalanceDelta));
    }
}
