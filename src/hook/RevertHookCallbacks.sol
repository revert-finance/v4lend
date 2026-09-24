// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookAutoLendActions} from "./RevertHookAutoLendActions.sol";
import {RevertHookMigrationActions} from "./RevertHookMigrationActions.sol";
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
        _triggerCursors[key.toId()].tickLowerLast = tickLower;
        _triggerCursors[key.toId()].tickLowerOpposite = tickLower;
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Auction integration: on dynamic-fee pools the controller syncs auction epochs,
    ///      drips vested proceeds to in-range LPs, and returns the LP fee override for this swap.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // The auction controller is immutable and audited, and its hook-facing entry points are
        // non-reverting by construction: the only externally-dependent step (donating to LPs in
        // the config-chosen auction currency, which could blacklist / fee-on-transfer) is isolated
        // inside the controller's own donate try/catch. So it is called directly here - a wholesale
        // fail-open wrapper is unnecessary and would only mask a genuine controller regression.
        uint24 lpFeeOverride;
        // auctions require the dynamic fee flag (enforced by configurePool), so static-fee pools
        // skip the controller round trip entirely - a pure calldata check
        if (key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && address(hookAuctionController) != address(0)) {
            lpFeeOverride = hookAuctionController.beforeSwap(key, sender);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /// @dev Isolates the oracle read so a failing oracle aborts trigger processing (never the swap):
    ///      the price call is tried directly and bounds-checked before the tick conversion, instead
    ///      of an external self-call wrapper (saves the call overhead and the extra entrypoint).
    function _tryOracleTickBounds(PoolKey calldata key)
        internal
        view
        returns (bool ok, int24 lowerBound, int24 upperBound)
    {
        try v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)) returns (
            uint160 oracleSqrtPriceX96
        ) {
            if (oracleSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || oracleSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
                return (false, 0, 0);
            }
            int24 oracleTick = _getTickLower(TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96), key.tickSpacing);
            lowerBound = _getTickLower(oracleTick - _maxTicksFromOracle, key.tickSpacing);
            upperBound = _getTickLower(oracleTick + _maxTicksFromOracle, key.tickSpacing);
            return (true, lowerBound, upperBound);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Fail-open value gate for the remove callback: an oracle that reverts (stale feed,
    ///      sequencer grace, pool deviation) must not block withdrawing liquidity from an automated
    ///      position or a vault liquidation of it, so the position simply stays activated (L-01).
    function _isBelowMinimumValue(uint256 tokenId) internal view returns (bool) {
        try v4Oracle.getValue(tokenId, address(0)) returns (uint256 value, uint256, uint256, uint256) {
            return value < _minPositionValueNative;
        } catch {
            return false;
        }
    }

    /// @dev Fail-open notification so vested auction proceeds are dripped to the liquidity
    ///      that was in range while they vested, before the liquidity set changes.
    function _notifyAuctionLiquidityChange(PoolKey calldata key) internal {
        // static-fee pools can never carry an auction (see _beforeSwap)
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || address(hookAuctionController) == address(0)) {
            return;
        }
        // Direct call - see _beforeSwap: the controller is trusted and non-reverting by construction.
        hookAuctionController.beforeLiquidityChange(key);
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

        TriggerCursor storage triggerCursor = _triggerCursors[poolId];
        int24 cursor = triggerCursor.tickLowerLast;
        int24 oppositeCursor = triggerCursor.tickLowerOpposite;
        // No trigger has ever registered: skip the oracle bound, the list walks, and the cursor
        // write entirely (the dominant per-swap costs), from the slot already loaded. The cursor
        // is left stale on purpose - _addPositionTriggers re-baselines it when the first trigger
        // registers, so pre-registration price movement can never fire a trigger.
        if (!triggerCursor.hasTriggers) {
            return (this.afterSwap.selector, 0);
        }
        int24 liveTick = _getTickLower(_getTick(poolId), key.tickSpacing);
        if (cursor == liveTick && oppositeCursor == liveTick) {
            return (this.afterSwap.selector, 0);
        }

        (bool oracleOk, int24 lowerOracleBound, int24 upperOracleBound) = _tryOracleTickBounds(key);
        if (!oracleOk) {
            return (this.afterSwap.selector, 0);
        }
        uint256 executedActions;
        while (executedActions < _MAX_EXECUTIONS_PER_SWAP) {
            liveTick = _getTickLower(_getTick(poolId), key.tickSpacing);
            if (cursor == liveTick && oppositeCursor == liveTick) {
                break;
            }

            // The lower endpoint resumes upper triggers; the higher endpoint resumes lower
            // triggers. Drain the current direction first, then any pending return walk.
            // An action can rearm between these endpoints before the old walk has caught up.
            if (
                cursor == liveTick || (cursor < liveTick && oppositeCursor < cursor)
                    || (cursor > liveTick && oppositeCursor > cursor)
            ) {
                (cursor, oppositeCursor) = (oppositeCursor, cursor);
            }
            bool increasing = cursor < liveTick;
            int24 tickEnd = liveTick;
            // Both bounds apply even when a pending return walk starts beyond the live bucket.
            // Keep the oracle window fixed across the action's own swaps and direction changes.
            if (liveTick > upperOracleBound || liveTick < lowerOracleBound) {
                break;
            }

            TickLinkedList.List storage list =
                increasing ? _upperTriggerAfterSwap[poolId] : _lowerTriggerAfterSwap[poolId];

            (bool exists, int24 tick) = list.searchFirstAfter(cursor);
            if (!exists || (increasing ? tick > tickEnd : tick < tickEnd)) {
                cursor = tickEnd;
                if (increasing ? oppositeCursor < tickEnd : oppositeCursor > tickEnd) {
                    oppositeCursor = tickEnd;
                }
                continue;
            }

            (uint256[] memory tokenIdsAtTick, bool tickDrained) =
                list.popTokenIds(tick, _MAX_EXECUTIONS_PER_SWAP - executedActions);

            uint256 length = tokenIdsAtTick.length;
            int24 previousLiveTick = liveTick;
            if (increasing ? oppositeCursor < liveTick : oppositeCursor > liveTick) {
                oppositeCursor = liveTick;
            }
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
                // Preserve the action's final bucket for the opposite traversal before stopping
                // for an oracle overshoot or the action cap. Advancing only the original cursor
                // would lose queued positions; retaining only it would miss rearmed return triggers.
                if (increasing ? oppositeCursor < liveTick : oppositeCursor > liveTick) {
                    oppositeCursor = liveTick;
                }
                directionReversed = _hasDirectionReversed(previousLiveTick, liveTick, increasing);
                // The action's own swap may also have carried the pool past the oracle bound in
                // the traversal direction; the positions still queued at this tick would execute
                // at that price. Either way put them back. A reversal continues the walk from this
                // tick; leaving the window stops it with the cursor before the tick, so the next
                // in-window swap finds them again (same bookkeeping as the per-swap cap).
                bool leftWindow = liveTick > upperOracleBound || liveTick < lowerOracleBound;
                if (directionReversed || leftWindow) {
                    if (i < length) {
                        _requeueTokenIdsAtTick(list, tick, tokenIdsAtTick, i);
                        tickDrained = false;
                    }
                    if (leftWindow) {
                        tickDrained = false;
                    }
                    break;
                }
                previousLiveTick = liveTick;
            }

            if (directionReversed || tickDrained) {
                cursor = tick;
                // A reversal that leaves entries at `tick` (put back above, or never popped under
                // the per-swap cap) must keep them reachable. The next search in this direction is
                // strictly past the cursor, so parking it on the fired tick would strand them until
                // a full recross; rest one bucket short instead, and the continued walk consumes
                // them now if the price is still past the tick.
                if (!tickDrained) {
                    cursor = increasing ? tick - key.tickSpacing : tick + key.tickSpacing;
                }
            }
            // A reversal may pass the original cursor as well. Retain that final bucket so
            // triggers rearmed there are reachable on the next move in the original direction.
            if (increasing ? liveTick < cursor : liveTick > cursor) {
                cursor = liveTick;
            }
            if (!directionReversed && !tickDrained) {
                break;
            }
        }

        triggerCursor.tickLowerLast = cursor;
        triggerCursor.tickLowerOpposite = oppositeCursor;
        return (this.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        // NOTE: in practice sender is always the PositionManager - the hook's own liquidity
        // operations also go through positionManager.modifyLiquidities, so the address(this)
        // alternative here (and the sender == address(this) early-returns below) are defensive
        // and currently unreachable. Do not build new logic on those branches firing.
        _checkLiquiditySender(sender);
        _notifyAuctionLiquidityChange(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _checkLiquiditySender(address sender) internal view {
        if (sender != address(positionManager) && sender != address(this)) {
            revert Unauthorized();
        }
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        _checkLiquiditySender(sender);
        _notifyAuctionLiquidityChange(key);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feeDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);

        feeDelta = _takeProtocolFees(tokenId, key, params.liquidityDelta, delta, feeDelta);

        // defensive: sender is always the PositionManager today (see _beforeAddLiquidity note);
        // hook-internal operations run the logic below, which is idempotent by design
        if (sender == address(this)) {
            return (BaseHook.afterAddLiquidity.selector, feeDelta);
        }

        // Activation of a configured position and the remint migration a tagged mint may name are
        // handled in the migration sidecar (EIP-170); a plain deposit to an unconfigured position
        // stops here. See RevertHookMigrationActions.afterAddLiquidity.
        if (hookData.length == 36 || !PositionModeFlags.isNone(_positionConfigs[tokenId].modeFlags)) {
            _delegatecallPassthrough(
                address(migrationActions),
                abi.encodeCall(
                    RevertHookMigrationActions.afterAddLiquidity, (key, tokenId, params.liquidityDelta, hookData)
                )
            );
        }

        return (BaseHook.afterAddLiquidity.selector, feeDelta);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);
        feeDelta = _takeProtocolFees(tokenId, key, params.liquidityDelta, delta, feeDelta);

        // defensive: sender is always the PositionManager today (see _beforeAddLiquidity note);
        // hook-internal operations run the logic below, which is idempotent by design
        if (sender == address(this)) {
            return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
        }

        if (_isActivated(tokenId)) {
            uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
            if (liquidity == 0 || _isBelowMinimumValue(tokenId)) {
                _removePositionTriggers(tokenId, key);
                _deactivatePosition(tokenId);
            }
        }

        return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
    }

    /// @dev Implementation lives in RevertHookAutoLendActions (delegatecall, shared storage
    ///      layout) to keep the hook's own bytecode under the EIP-170 limit. Reverts bubble up.
    function _takeProtocolFees(
        uint256 tokenId,
        PoolKey calldata key,
        int256 liquidityDelta,
        BalanceDelta delta,
        BalanceDelta feeDelta
    ) internal returns (BalanceDelta newFeeDelta) {
        bytes memory data = abi.encodeCall(
            RevertHookAutoLendActions.takeProtocolFees, (tokenId, key, liquidityDelta, delta, feeDelta)
        );
        newFeeDelta = abi.decode(_delegatecallPassthrough(address(autoLendActions), data), (BalanceDelta));
    }
}
