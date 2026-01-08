// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {V4Oracle} from "./V4Oracle.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {RevertHookConfig} from "./RevertHookConfig.sol";
import {RevertHookFunctions} from "./RevertHookFunctions.sol";
import {RevertHookFunctions2} from "./RevertHookFunctions2.sol";

/// @title RevertHook
/// @notice Hook that allows to add LP Positions via PositionManager and enables auto-compounding, auto-exiting, auto-ranging and auto-lending of positions
/// @dev Positions are not owned by the hook - they are owned by users directly or the vault with the correct permissions
contract RevertHook is RevertHookConfig, BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    IPermit2 public immutable permit2;

    IPositionManager public immutable positionManager;
    V4Oracle public immutable v4Oracle;
    ILiquidityCalculator public immutable liquidityCalculator;

    /// @notice The RevertHookFunctions contract for delegatecall (auto-exit, auto-range, auto-compound)
    RevertHookFunctions public immutable hookFunctions;

    /// @notice The RevertHookFunctions2 contract for delegatecall (auto-leverage, auto-lend)
    RevertHookFunctions2 public immutable hookFunctions2;

    constructor(address protocolFeeRecipient_, IPermit2 _permit2, V4Oracle _v4Oracle, ILiquidityCalculator _liquidityCalculator)
        BaseHook(_v4Oracle.poolManager())
        Ownable(msg.sender)
    {
        positionManager = _v4Oracle.positionManager();
        protocolFeeRecipient = protocolFeeRecipient_;
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;

        // Deploy the functions contracts with the same immutable parameters
        hookFunctions = new RevertHookFunctions(_permit2, _v4Oracle, _liquidityCalculator);
        hookFunctions2 = new RevertHookFunctions2(_permit2, _v4Oracle, _liquidityCalculator);
    }

    function _getPoolAndPositionInfo(uint256 tokenId) internal view override returns (PoolKey memory, PositionInfo) {
        return positionManager.getPoolAndPositionInfo(tokenId);
    }

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
        tickLowerLasts[key.toId()] = tickLower;
        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(address caller, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // swaps triggered by the hook itself are just executed
        if (caller == address(this)) {
            return (this.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();
        int24 tick = tickLowerLasts[poolId];
        int24 tickEnd = _getTickLower(_getTick(poolId), key.tickSpacing);

        if (tick == tickEnd) {
            return (this.afterSwap.selector, 0);
        }

        TickLinkedList.List storage list =
            tick < tickEnd ? upperTriggerAfterSwap[poolId] : lowerTriggerAfterSwap[poolId];

        int24 oracleMaxEndTick = type(int24).min;

        bool exists;
        (exists, tick) = list.searchFirstAfter(tick);

        while (true) {
            if (!exists || (list.increasing ? tick > tickEnd : tick < tickEnd)) {
                break;
            }

            // if not yet calculated maxEndTick
            if (oracleMaxEndTick == type(int24).min) {
                // only do processing until oracle validated end tick
                oracleMaxEndTick = _getOracleMaxEndTick(key, list.increasing);
                tickEnd = list.increasing
                    ? (oracleMaxEndTick < tickEnd ? oracleMaxEndTick : tickEnd)
                    : (oracleMaxEndTick > tickEnd ? oracleMaxEndTick : tickEnd);
                if (list.increasing ? tick > tickEnd : tick < tickEnd) {
                    break;
                }
            }

            // execute all triggers at this tick
            uint256 length = list.tokenIds[tick].length;
            for (uint256 i; i < length;) {
                _handleTokenIdAfterSwap(key, poolId, list.tokenIds[tick][i], list.increasing, tick);
                unchecked { ++i; }
            }

            // tickEnd may have increased into list direction after the processing of the tokenId (because of swaps - autorange / autoexit will only do swaps in the same direcction)
            tickEnd = _getTickLower(_getTick(poolId), key.tickSpacing);
            tickEnd = list.increasing
                ? (oracleMaxEndTick < tickEnd ? oracleMaxEndTick : tickEnd)
                : (oracleMaxEndTick > tickEnd ? oracleMaxEndTick : tickEnd);

            int24 nextTick;
            (exists, nextTick) = list.getNext(tick);
            list.remove(tick, 0);
            tick = nextTick;
        }

        tickLowerLasts[poolId] = tickEnd;
        return (this.afterSwap.selector, 0);
    }

    // handle token id - when detected as triggered by a swap
    function _handleTokenIdAfterSwap(
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 tokenId,
        bool isUpperTrigger,
        int24 tick
    ) internal {
        PositionConfig storage config = positionConfigs[tokenId];
        PositionMode mode = config.mode;
        if (mode == PositionMode.AUTO_EXIT) {
            _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            // only works with absolute auto exit ticks
            bool isAutoExitTriggered = (isUpperTrigger && tick == config.autoExitTickUpper)
                || (!isUpperTrigger && tick == config.autoExitTickLower);
            if (isAutoExitTriggered) {
                _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
            } else {
                _handleAutoRange(poolKey, poolId, tokenId);
            }
        } else if (mode == PositionMode.AUTO_LEND) {
            _handleAutoLend(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_RANGE) {
            _handleAutoRange(poolKey, poolId, tokenId);
        } else if (mode == PositionMode.AUTO_LEVERAGE) {
            _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
        }
    }

    function _handleAutoExit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        address owner = _getOwner(tokenId, false);

        if (vaults[owner]) {
            IVault(owner).transform(
                tokenId,
                address(this),
                abi.encodeCall(this.autoExit, (poolKey, poolId, tokenId, isUpperTrigger))
            );
        } else {
            _delegatecallAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
        }

        _removePositionTriggers(tokenId, poolKey);
    }

    function _handleAutoLend(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        // no auto lend for collateral positions
        bool ownedByVault = vaults[_getOwner(tokenId, false)];
        if (ownedByVault) {
            return;
        }

        uint256 shares = positionStates[tokenId].autoLendShares;
        if (shares > 0) {
            _delegatecallAutoLendWithdraw(poolKey, tokenId, shares);
        } else {
            _delegatecallAutoLendDeposit(poolKey, poolId, tokenId, isUpperTrigger);
        }
    }

    function _handleAutoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) internal {
        address owner = _getOwner(tokenId, false);

        if (vaults[owner]) {
            IVault(owner).transform(tokenId, address(this), abi.encodeCall(this.autoRange, (poolKey, poolId, tokenId)));
        } else {
            _delegatecallAutoRange(poolKey, poolId, tokenId);
        }
    }

    function _handleAutoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        // AUTO_LEVERAGE only works for vault-owned positions (opposite of AUTO_LEND)
        address owner = _getOwner(tokenId, false);
        if (!vaults[owner]) {
            return;
        }

        IVault(owner).transform(
            tokenId,
            address(this),
            abi.encodeCall(this.autoLeverage, (poolKey, poolId, tokenId, isUpperTrigger))
        );
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // only allow positions created via PositionManager or the hook itself
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

        // if the hook itself is adding liquidity, dont configure anything
        if (sender == address(this)) {
            return (BaseHook.afterAddLiquidity.selector, feeDelta);
        }

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        // Check if position has config and is not yet activated (triggers not added)
        if (positionConfigs[tokenId].mode != PositionMode.NONE && !_isActivated(tokenId)) {
            // Check if position value is now above minimum to add triggers
            if (_getPositionValueNative(tokenId) >= minPositionValueNative) {
                _addPositionTriggers(tokenId, key);
                _activatePosition(tokenId);
            }
        }

        return (BaseHook.afterAddLiquidity.selector, feeDelta);
    }

    /// @notice When liquidity is removed, the hook will take a percentage of the fees
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

        // if the hook itself is removing liquidity, dont configure anything
        if (sender == address(this)) {
            return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
        }

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        // Only check if position is currently activated (has triggers)
        if (_isActivated(tokenId)) {
            // Remove triggers if no liquidity left or value dropped below minimum
            if (liquidity == 0 || _getPositionValueNative(tokenId) < minPositionValueNative) {
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
        address feeRecipient = protocolFeeRecipient;
        PositionState storage state = positionStates[tokenId];
        uint32 accumulatedActiveTime = state.acumulatedActiveTime;
        uint32 lastActivated = state.lastActivated;
        uint32 currentTime = uint32(block.timestamp);
        if (lastActivated > 0) {
            accumulatedActiveTime += currentTime - lastActivated;
            state.lastActivated = currentTime;
        }
        uint32 lastCollect = state.lastCollect;
        uint32 feeTime = lastCollect == 0 ? 0 : currentTime - lastCollect;

        state.lastCollect = currentTime;

        // if no time has passed, or no active time has been accumulated, return 0 fees
        if (feeTime == 0 || accumulatedActiveTime == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        PoolId poolId = key.toId();

        int128 protocolFee0 =
            int32(accumulatedActiveTime) * feeDelta.amount0() * int16(protocolFeeBps) / (10000 * int32(feeTime));
        int128 protocolFee1 =
            int32(accumulatedActiveTime) * feeDelta.amount1() * int16(protocolFeeBps) / (10000 * int32(feeTime));

        // take protocol fees
        if (protocolFee0 > 0) {
            poolManager.take(key.currency0, feeRecipient, uint256(int256(protocolFee0)));
        }
        if (protocolFee1 > 0) {
            poolManager.take(key.currency1, feeRecipient, uint256(int256(protocolFee1)));
        }

        emit SendProtocolFee(
            tokenId,
            key.currency0,
            key.currency1,
            uint256(int256(protocolFee0)),
            uint256(int256(protocolFee1)),
            feeRecipient
        );

        newFeeDelta = toBalanceDelta(protocolFee0, protocolFee1);
    }

    /// @notice Returns the owner of the position
    /// @param tokenId The token ID of the position
    /// @param isRealOwner If true, the real owner is returned, if false, the direct owner of the token is returned (maybe a vault)
    /// @return The owner of the position
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view override returns (address) {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);

        if (isRealOwner && vaults[owner]) {
            return IVault(owner).ownerOf(tokenId);
        } else {
            return owner;
        }
    }

    /// @notice Gets the position value in native token
    /// @param tokenId The token ID of the position
    /// @return value The position value in native token (wei)
    function _getPositionValueNative(uint256 tokenId) internal view override returns (uint256 value) {
        (value,,,) = v4Oracle.getValue(tokenId, address(0));
    }

    /// @notice Gets the current base tick for a pool
    /// @param poolKey The pool key
    /// @return tick The current base tick
    function _getCurrentBaseTick(PoolKey memory poolKey) internal view override returns (int24 tick) {
        return _getTickLower(_getTick(poolKey.toId()), poolKey.tickSpacing);
    }

    /// @notice Checks if position config conditions are already met and executes immediately if so
    /// @dev Called after setPositionConfig to handle cases where current tick already triggers the action
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    /// @param config The position configuration
    function _checkAndExecuteImmediate(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory config) internal override {
        // Skip for modes that don't have immediate triggers
        if (config.mode == PositionMode.NONE || config.mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return;
        }

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Check trigger conditions and get result
        (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) = _checkTriggerConditions(
            tokenId, poolKey, config, posInfo.tickLower(), posInfo.tickUpper()
        );

        if (shouldExecute) {
            _executeImmediateAction(tokenId, poolKey, config, isUpperTrigger, triggeredTick);
        }
    }

    /// @notice Checks if any trigger condition is met for immediate execution
    /// @return shouldExecute True if a trigger condition is met
    /// @return isUpperTrigger True if the upper trigger was hit, false for lower
    /// @return triggeredTick The tick value that triggered the action
    function _checkTriggerConditions(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        int24 posTickLower,
        int24 posTickUpper
    ) internal view returns (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) {
        PoolId poolId = poolKey.toId();
        int24 currentTickLower = _getTickLower(_getTick(poolId), poolKey.tickSpacing);

        // Compute trigger ticks for the config
        int24[4] memory triggerTicks = _computeTriggerTicksFromMemory(tokenId, poolKey, config, posTickLower, posTickUpper);

        // Check lower triggers (fire when current tick falls below them)
        if (triggerTicks[0] != type(int24).min && currentTickLower < triggerTicks[0]) {
            return (true, false, triggerTicks[0]);
        }
        if (triggerTicks[1] != type(int24).min && currentTickLower < triggerTicks[1]) {
            return (true, false, triggerTicks[1]);
        }

        // Check upper triggers (fire when current tick rises above them)
        if (triggerTicks[2] != type(int24).max && currentTickLower >= triggerTicks[2]) {
            return (true, true, triggerTicks[2]);
        }
        if (triggerTicks[3] != type(int24).max && currentTickLower >= triggerTicks[3]) {
            return (true, true, triggerTicks[3]);
        }

        return (false, false, 0);
    }

    /// @notice Executes the appropriate action immediately based on config mode
    function _executeImmediateAction(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        bool isUpperTrigger,
        int24 tick
    ) internal {
        // Need to unlock poolManager for execution
        poolManager.unlock(abi.encode(
            tokenId,
            poolKey,
            config.mode,
            isUpperTrigger,
            tick,
            config.autoExitTickLower,
            config.autoExitTickUpper
        ));
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = _getTickLower(_getTick(poolId), tickSpacing);
        int24 tickLowerLast = tickLowerLasts[poolId];

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    // ==================== Public Functions (called by vault transform or directly) ====================

    /// @notice Auto-exit function - can be called directly or via vault transform
    function autoExit(
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 tokenId,
        bool isUpper
    ) public {
        _delegatecallAutoExit(poolKey, poolId, tokenId, isUpper);
    }

    /// @notice Auto-range function - can be called directly or via vault transform
    function autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) public {
        _delegatecallAutoRange(poolKey, poolId, tokenId);
    }

    /// @notice Adjusts leverage for a vault-owned position based on current vs target debt
    function autoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) public {
        _delegatecallAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
    }

    /// @notice Forces the auto-lend position to exit
    function autoLendForceExit(uint256 tokenId) external {
        (bool success,) = address(hookFunctions2).delegatecall(
            abi.encodeCall(hookFunctions2.autoLendForceExit, (tokenId))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    /// @notice Auto-compounds fees from positions (this can be called by anyone)
    function autoCompound(uint256[] memory tokenIds) external {
        (bool success,) = address(hookFunctions).delegatecall(
            abi.encodeCall(hookFunctions.autoCompound, (tokenIds))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    /// @notice Auto-compounds callback function which is called during transform
    function autoCompoundForVault(uint256 tokenId, address caller) external {
        (bool success,) = address(hookFunctions).delegatecall(
            abi.encodeCall(hookFunctions.autoCompoundForVault, (tokenId, caller))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // disallow arbitrary caller
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }

        // Differentiate action types by data length:
        // - Auto-compound: abi.encode(uint256 tokenId, address caller) = 64 bytes
        // - Immediate execution: abi.encode(uint256, PoolKey, ...) = much larger
        if (data.length > 64) {
            // Immediate execution action
            (
                uint256 tokenId,
                PoolKey memory poolKey,
                PositionMode mode,
                bool isUpperTrigger,
                int24 tick,
                int24 autoExitTickLower,
                int24 autoExitTickUpper
            ) = abi.decode(data, (uint256, PoolKey, PositionMode, bool, int24, int24, int24));

            _executeImmediateActionUnlocked(poolKey, tokenId, mode, isUpperTrigger, tick, autoExitTickLower, autoExitTickUpper);
        } else {
            // Default: auto-compound action (64 bytes exactly)
            (uint256 tokenId, address caller) = abi.decode(data, (uint256, address));
            _executeAutoCompound(tokenId, caller);
        }
        return bytes("");
    }

    /// @notice Executes immediate action when poolManager is unlocked
    /// @dev Called from unlockCallback to handle immediate auto-exit, auto-range, auto-lend, or auto-leverage
    function _executeImmediateActionUnlocked(
        PoolKey memory poolKey,
        uint256 tokenId,
        PositionMode mode,
        bool isUpperTrigger,
        int24, /* tick */
        int24, /* autoExitTickLower */
        int24 /* autoExitTickUpper */
    ) internal {
        PoolId poolId = poolKey.toId();
        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            // For combined mode triggered immediately, treat as auto-exit
            // (the trigger tick determination was already done in _checkTriggerConditions)
            _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_LEND) {
            _handleAutoLend(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_RANGE) {
            _handleAutoRange(poolKey, poolId, tokenId);
        } else if (mode == PositionMode.AUTO_LEVERAGE) {
            _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
        }
    }

    /// @notice Internal function that executes the auto-compound logic via delegatecall
    function _executeAutoCompound(uint256 tokenId, address caller) internal {
        (bool success,) = address(hookFunctions).delegatecall(
            abi.encodeCall(hookFunctions.executeAutoCompound, (tokenId, caller))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    /// @notice Validates and caps the end tick based on oracle price
    /// @param poolKey The pool key
    /// @param up True if swap moves price up (tick increasing), false if swap moves price down (tick decreasing)
    /// @return maxEndTick The maximum end tick allowed based on maxTicksFromOracle
    function _getOracleMaxEndTick(PoolKey memory poolKey, bool up) internal view returns (int24 maxEndTick) {
        uint160 oracleSqrtPriceX96 =
            v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        int24 oracleTick = _getTickLower(TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96), poolKey.tickSpacing);

        if (up) {
            maxEndTick = _getTickLower(oracleTick + maxTicksFromOracle, poolKey.tickSpacing);
        } else {
            maxEndTick = _getTickLower(oracleTick - maxTicksFromOracle, poolKey.tickSpacing);
        }
    }

    // ==================== Internal Delegatecall Wrappers ====================

    function _delegatecallAutoExit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper) internal {
        (bool success,) = address(hookFunctions).delegatecall(
            abi.encodeCall(hookFunctions.autoExit, (poolKey, poolId, tokenId, isUpper))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    function _delegatecallAutoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) internal {
        (bool success,) = address(hookFunctions).delegatecall(
            abi.encodeCall(hookFunctions.autoRange, (poolKey, poolId, tokenId))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    function _delegatecallAutoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        (bool success,) = address(hookFunctions2).delegatecall(
            abi.encodeCall(hookFunctions2.autoLeverage, (poolKey, poolId, tokenId, isUpperTrigger))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    function _delegatecallAutoLendDeposit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper) internal {
        (bool success,) = address(hookFunctions2).delegatecall(
            abi.encodeCall(hookFunctions2.autoLendDeposit, (poolKey, poolId, tokenId, isUpper))
        );
        if (!success) {
            revert TransformFailed();
        }
    }

    function _delegatecallAutoLendWithdraw(PoolKey memory poolKey, uint256 tokenId, uint256 shares) internal {
        (bool success,) = address(hookFunctions2).delegatecall(
            abi.encodeCall(hookFunctions2.autoLendWithdraw, (poolKey, tokenId, shares))
        );
        if (!success) {
            revert TransformFailed();
        }
    }
}
