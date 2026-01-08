// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {V4Oracle} from "./V4Oracle.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {RevertHookTriggers} from "./RevertHookTriggers.sol";
import {RevertHookFunctions} from "./RevertHookFunctions.sol";
import {RevertHookFunctions2} from "./RevertHookFunctions2.sol";

/// @title RevertHook
/// @notice Hook that allows to add LP Positions via PositionManager and enables auto-compounding, auto-exiting, auto-ranging and auto-lending of positions
/// @dev Positions are not owned by the hook - they are owned by users directly or the vault with the correct permissions
contract RevertHook is RevertHookTriggers, BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;
    using CurrencyLibrary for Currency;

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

    // ==================== Configuration Setters ====================

    /// @notice Sets the ERC4626 vault for a given token address
    function setAutoLendVault(address token, IERC4626 vault) external onlyOwner {
        autoLendVaults[token] = vault;
        emit SetAutoLendVault(token, vault);
    }

    /// @notice Sets the maximum ticks from oracle for price validation
    function setMaxTicksFromOracle(int24 _maxTicksFromOracle) external onlyOwner {
        maxTicksFromOracle = _maxTicksFromOracle;
        emit SetMaxTicksFromOracle(_maxTicksFromOracle);
    }

    /// @notice Sets the minimum position value in native token required for configuration
    function setMinPositionValueNative(uint256 _minPositionValueNative) external onlyOwner {
        minPositionValueNative = _minPositionValueNative;
        emit SetMinPositionValueNative(_minPositionValueNative);
    }

    /// @notice Sets the protocol fee percentage
    function setProtocolFeeBps(uint16 _protocolFeeBps) external onlyOwner {
        if (_protocolFeeBps > 10000) {
            revert InvalidConfig();
        }
        protocolFeeBps = _protocolFeeBps;
        emit SetProtocolFeeBps(_protocolFeeBps);
    }

    /// @notice Sets the protocol fee recipient
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external onlyOwner {
        protocolFeeRecipient = _protocolFeeRecipient;
        emit SetProtocolFeeRecipient(_protocolFeeRecipient);
    }

    /// @notice Sets the general configuration for a position
    function setGeneralConfig(
        uint256 tokenId,
        uint24 swapPoolFee,
        int24 swapPoolTickSpacing,
        IHooks swapPoolHooks,
        uint32 maxPriceImpactBps0,
        uint32 maxPriceImpactBps1
    ) external {
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

        generalConfigs[tokenId] = generalConfig;
        emit SetGeneralConfig(tokenId, generalConfig);
    }

    /// @notice Sets the position configuration for a given token ID
    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        if (positionConfig.mode != PositionMode.NONE) {
            uint256 value = _getPositionValueNative(tokenId);
            if (value < minPositionValueNative) {
                revert PositionValueTooLow();
            }
        }

        _setPositionConfig(tokenId, positionConfig, true);
    }

    // ==================== Internal Configuration Helpers ====================

    /// @notice Calculates the sqrt price multiplier from basis points
    function _calculateSqrtPriceMultiplier(uint32 maxPriceImpactBps, bool zeroForOne) internal pure returns (uint128 multiplier) {
        if (maxPriceImpactBps == 0) {
            return 0;
        }
        uint256 q64Squared = uint256(Q64) * uint256(Q64);
        uint256 numerator = zeroForOne
            ? (10000 - maxPriceImpactBps) * q64Squared / 10000
            : (10000 + maxPriceImpactBps) * q64Squared / 10000;
        multiplier = uint128(Math.sqrt(numerator));
    }

    /// @notice Internal function to set position configuration
    function _setPositionConfig(uint256 tokenId, PositionConfig memory config, bool checkImmediateExecution) internal {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Validate config
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
        if (config.autoLeverageTargetBps >= 10000) {
            revert InvalidConfig();
        }

        // AUTO_LEVERAGE only works for vault-owned positions where one token is the lend asset
        if (config.mode == PositionMode.AUTO_LEVERAGE) {
            address owner = _getOwner(tokenId, false);
            if (!vaults[owner]) {
                revert InvalidConfig();
            }
            address lendAsset = IVault(owner).asset();
            if (Currency.unwrap(poolKey.currency0) != lendAsset && Currency.unwrap(poolKey.currency1) != lendAsset) {
                revert InvalidConfig();
            }
            int24 currentTick = _getCurrentBaseTick(poolKey);
            positionStates[tokenId].autoLeverageBaseTick = (currentTick / poolKey.tickSpacing) * poolKey.tickSpacing;
        }

        _updatePositionTriggers(tokenId, poolKey, config);
        positionConfigs[tokenId] = config;

        if (config.mode != PositionMode.NONE) {
            _activatePosition(tokenId);
            if (checkImmediateExecution) {
                _checkAndExecuteImmediate(tokenId, poolKey, config);
            }
        } else {
            _deactivatePosition(tokenId);
        }

        emit SetPositionConfig(tokenId, config);
    }

    // ==================== Abstract Function Implementations ====================

    function _getPoolAndPositionInfo(uint256 tokenId) internal view override returns (PoolKey memory, PositionInfo) {
        return positionManager.getPoolAndPositionInfo(tokenId);
    }

    /// @notice Returns the owner of the position
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view override returns (address) {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        return (isRealOwner && vaults[owner]) ? IVault(owner).ownerOf(tokenId) : owner;
    }

    /// @notice Gets the position value in native token
    function _getPositionValueNative(uint256 tokenId) internal view returns (uint256 value) {
        (value,,,) = v4Oracle.getValue(tokenId, address(0));
    }

    /// @notice Gets the current base tick for a pool
    function _getCurrentBaseTick(PoolKey memory poolKey) internal view returns (int24 tick) {
        return _getTickLower(_getTick(poolKey.toId()), poolKey.tickSpacing);
    }

    // ==================== Hook Permissions ====================

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

    // ==================== Hook Callbacks ====================

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

            if (oracleMaxEndTick == type(int24).min) {
                oracleMaxEndTick = _getOracleMaxEndTick(key, list.increasing);
                tickEnd = list.increasing
                    ? (oracleMaxEndTick < tickEnd ? oracleMaxEndTick : tickEnd)
                    : (oracleMaxEndTick > tickEnd ? oracleMaxEndTick : tickEnd);
                if (list.increasing ? tick > tickEnd : tick < tickEnd) {
                    break;
                }
            }

            uint256 length = list.tokenIds[tick].length;
            for (uint256 i; i < length;) {
                _handleTokenIdAfterSwap(key, poolId, list.tokenIds[tick][i], list.increasing, tick);
                unchecked { ++i; }
            }

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
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
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

        if (positionConfigs[tokenId].mode != PositionMode.NONE && !_isActivated(tokenId)) {
            if (_getPositionValueNative(tokenId) >= minPositionValueNative) {
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

        if (feeTime == 0 || accumulatedActiveTime == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        int128 protocolFee0 =
            int32(accumulatedActiveTime) * feeDelta.amount0() * int16(protocolFeeBps) / (10000 * int32(feeTime));
        int128 protocolFee1 =
            int32(accumulatedActiveTime) * feeDelta.amount1() * int16(protocolFeeBps) / (10000 * int32(feeTime));

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

    /// @notice Checks if position config conditions are already met and executes immediately if so
    function _checkAndExecuteImmediate(uint256 tokenId, PoolKey memory poolKey, PositionConfig memory config) internal {
        if (config.mode == PositionMode.NONE || config.mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return;
        }

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) = _checkTriggerConditions(
            tokenId, poolKey, config, posInfo.tickLower(), posInfo.tickUpper()
        );

        if (shouldExecute) {
            _executeImmediateAction(tokenId, poolKey, config, isUpperTrigger, triggeredTick);
        }
    }

    function _checkTriggerConditions(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        int24 posTickLower,
        int24 posTickUpper
    ) internal view returns (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) {
        PoolId poolId = poolKey.toId();
        int24 currentTickLower = _getTickLower(_getTick(poolId), poolKey.tickSpacing);

        int24[4] memory triggerTicks = _computeTriggerTicksMemory(tokenId, poolKey, config, posTickLower, posTickUpper);

        if (triggerTicks[0] != type(int24).min && currentTickLower < triggerTicks[0]) {
            return (true, false, triggerTicks[0]);
        }
        if (triggerTicks[1] != type(int24).min && currentTickLower < triggerTicks[1]) {
            return (true, false, triggerTicks[1]);
        }
        if (triggerTicks[2] != type(int24).max && currentTickLower >= triggerTicks[2]) {
            return (true, true, triggerTicks[2]);
        }
        if (triggerTicks[3] != type(int24).max && currentTickLower >= triggerTicks[3]) {
            return (true, true, triggerTicks[3]);
        }

        return (false, false, 0);
    }

    function _executeImmediateAction(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionConfig memory config,
        bool isUpperTrigger,
        int24 tick
    ) internal {
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

    // ==================== Public Functions (called by vault transform or directly) ====================

    function autoExit(
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 tokenId,
        bool isUpper
    ) public {
        _delegatecallAutoExit(poolKey, poolId, tokenId, isUpper);
    }

    function autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) public {
        _delegatecallAutoRange(poolKey, poolId, tokenId);
    }

    function autoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) public {
        _delegatecallAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
    }

    function autoLendForceExit(uint256 tokenId) external {
        _delegatecall(address(hookFunctions2), abi.encodeCall(hookFunctions2.autoLendForceExit, (tokenId)));
    }

    function autoCompound(uint256[] memory tokenIds) external {
        _delegatecall(address(hookFunctions), abi.encodeCall(hookFunctions.autoCompound, (tokenIds)));
    }

    function autoCompoundForVault(uint256 tokenId, address caller) external {
        _delegatecall(address(hookFunctions), abi.encodeCall(hookFunctions.autoCompoundForVault, (tokenId, caller)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }

        if (data.length > 64) {
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
            (uint256 tokenId, address caller) = abi.decode(data, (uint256, address));
            _executeAutoCompound(tokenId, caller);
        }
        return bytes("");
    }

    function _executeImmediateActionUnlocked(
        PoolKey memory poolKey,
        uint256 tokenId,
        PositionMode mode,
        bool isUpperTrigger,
        int24,
        int24,
        int24
    ) internal {
        PoolId poolId = poolKey.toId();
        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_LEND) {
            _handleAutoLend(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_RANGE) {
            _handleAutoRange(poolKey, poolId, tokenId);
        } else if (mode == PositionMode.AUTO_LEVERAGE) {
            _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
        }
    }

    function _executeAutoCompound(uint256 tokenId, address caller) internal {
        _delegatecall(address(hookFunctions), abi.encodeCall(hookFunctions.executeAutoCompound, (tokenId, caller)));
    }

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

    // ==================== Internal Delegatecall Helper ====================

    function _delegatecall(address target, bytes memory data) internal {
        (bool success,) = target.delegatecall(data);
        if (!success) {
            revert TransformFailed();
        }
    }

    function _delegatecallAutoExit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper) internal {
        _delegatecall(address(hookFunctions), abi.encodeCall(hookFunctions.autoExit, (poolKey, poolId, tokenId, isUpper)));
    }

    function _delegatecallAutoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) internal {
        _delegatecall(address(hookFunctions), abi.encodeCall(hookFunctions.autoRange, (poolKey, poolId, tokenId)));
    }

    function _delegatecallAutoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        _delegatecall(address(hookFunctions2), abi.encodeCall(hookFunctions2.autoLeverage, (poolKey, poolId, tokenId, isUpperTrigger)));
    }

    function _delegatecallAutoLendDeposit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper) internal {
        _delegatecall(address(hookFunctions2), abi.encodeCall(hookFunctions2.autoLendDeposit, (poolKey, poolId, tokenId, isUpper)));
    }

    function _delegatecallAutoLendWithdraw(PoolKey memory poolKey, uint256 tokenId, uint256 shares) internal {
        _delegatecall(address(hookFunctions2), abi.encodeCall(hookFunctions2.autoLendWithdraw, (poolKey, tokenId, shares)));
    }
}
