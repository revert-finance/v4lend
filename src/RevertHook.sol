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
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookTriggers} from "./RevertHookTriggers.sol";
import {RevertHookPositionActions} from "./RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "./RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "./RevertHookAutoLendActions.sol";

/// @title RevertHook
/// @notice Uniswap V4 hook enabling automated LP position management features
/// @dev Implements hook callbacks to trigger automated actions based on price movements.
///      Positions are owned by users directly or by V4Vault as collateral.
/// @custom:security Hook Permissions:
///   - afterInitialize: Tracks pool tick for trigger calculations
///   - beforeAddLiquidity: Validates sender is position manager or hook itself
///   - afterAddLiquidity: Takes protocol fees, activates position triggers
///   - afterRemoveLiquidity: Takes protocol fees, deactivates empty positions
///   - afterSwap: Executes triggered actions (auto-exit, auto-range, auto-lend, auto-leverage)
/// @custom:security Oracle Protection:
///   - maxTicksFromOracle limits how far from oracle price actions can execute
///   - Prevents manipulation attacks by constraining execution to valid price ranges
/// @custom:security Delegatecall Pattern:
///   - Uses action contracts via delegatecall to avoid contract size limits
///   - All state is maintained in this contract
contract RevertHook is RevertHookTriggers, BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;
    using CurrencyLibrary for Currency;

    IPermit2 internal immutable permit2;

    IPositionManager internal immutable positionManager;
    IV4Oracle internal immutable v4Oracle;
    ILiquidityCalculator internal immutable liquidityCalculator;

    /// @notice The RevertHookPositionActions contract for delegatecall (auto-exit, auto-range, auto-compound)
    RevertHookPositionActions internal immutable hookFunctionsPositionActions;

    /// @notice The RevertHookAutoLeverageActions contract for delegatecall (auto-leverage)
    RevertHookAutoLeverageActions internal immutable hookFunctionsAutoLeverageActions;

    /// @notice The RevertHookAutoLendActions contract for delegatecall (auto-lend)
    RevertHookAutoLendActions internal immutable hookFunctionsAutoLendActions;

    constructor(
        address owner_,
        address protocolFeeRecipient_,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        RevertHookPositionActions _hookFunctionsPositionActions,
        RevertHookAutoLeverageActions _hookFunctionsAutoLeverageActions,
        RevertHookAutoLendActions _hookFunctionsAutoLendActions
    ) BaseHook(_v4Oracle.poolManager()) Ownable(owner_) {
        positionManager = _v4Oracle.positionManager();
        _protocolFeeRecipient = protocolFeeRecipient_;
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;

        // Use pre-deployed function contracts
        hookFunctionsPositionActions = _hookFunctionsPositionActions;
        hookFunctionsAutoLeverageActions = _hookFunctionsAutoLeverageActions;
        hookFunctionsAutoLendActions = _hookFunctionsAutoLendActions;
    }

    function autoCompoundRewardBps() external pure returns (uint16) {
        return _AUTO_COMPOUND_REWARD_BPS;
    }

    function LEVERAGE_TICK_OFFSET_MULTIPLIER() external pure returns (int24) {
        return _LEVERAGE_TICK_OFFSET_MULTIPLIER;
    }

    function MAX_TRIGGER_BATCHES_PER_SWAP() external pure returns (uint256) {
        return _MAX_TRIGGER_BATCHES_PER_SWAP;
    }

    function positionConfigs(uint256 tokenId)
        external
        view
        returns (
            uint8 modeFlags,
            AutoCompoundMode autoCompoundMode,
            bool autoExitIsRelative,
            int24 autoExitTickLower,
            int24 autoExitTickUpper,
            int24 autoRangeLowerLimit,
            int24 autoRangeUpperLimit,
            int24 autoRangeLowerDelta,
            int24 autoRangeUpperDelta,
            int24 autoLendToleranceTick,
            uint16 autoLeverageTargetBps
        )
    {
        PositionConfig storage config = _positionConfigs[tokenId];
        return (
            config.modeFlags,
            config.autoCompoundMode,
            config.autoExitIsRelative,
            config.autoExitTickLower,
            config.autoExitTickUpper,
            config.autoRangeLowerLimit,
            config.autoRangeUpperLimit,
            config.autoRangeLowerDelta,
            config.autoRangeUpperDelta,
            config.autoLendToleranceTick,
            config.autoLeverageTargetBps
        );
    }

    function generalConfigs(uint256 tokenId)
        external
        view
        returns (
            uint24 swapPoolFee,
            int24 swapPoolTickSpacing,
            IHooks swapPoolHooks,
            uint128 sqrtPriceMultiplier0,
            uint128 sqrtPriceMultiplier1
        )
    {
        GeneralConfig storage config = _generalConfigs[tokenId];
        return (
            config.swapPoolFee,
            config.swapPoolTickSpacing,
            config.swapPoolHooks,
            config.sqrtPriceMultiplier0,
            config.sqrtPriceMultiplier1
        );
    }

    function positionStates(uint256 tokenId)
        external
        view
        returns (
            uint32 lastCollect,
            uint32 acumulatedActiveTime,
            uint32 lastActivated,
            address autoLendToken,
            uint256 autoLendShares,
            uint256 autoLendAmount,
            address autoLendVault,
            int24 autoLeverageBaseTick
        )
    {
        PositionState storage state = _positionStates[tokenId];
        return (
            state.lastCollect,
            state.acumulatedActiveTime,
            state.lastActivated,
            state.autoLendToken,
            state.autoLendShares,
            state.autoLendAmount,
            state.autoLendVault,
            state.autoLeverageBaseTick
        );
    }

    function autoLendVaults(address token) external view returns (IERC4626 vault) {
        return _autoLendVaults[token];
    }

    function protocolFeeBps() external view returns (uint16) {
        return _protocolFeeBps;
    }

    function protocolFeeRecipient() external view returns (address) {
        return _protocolFeeRecipient;
    }

    function maxTicksFromOracle() external view returns (int24) {
        return _maxTicksFromOracle;
    }

    function minPositionValueNative() external view returns (uint256) {
        return _minPositionValueNative;
    }

    function tickLowerLasts(PoolId poolId) external view returns (int24) {
        return _tickLowerLasts[poolId];
    }

    function lowerTriggerAfterSwap(PoolId poolId) external view returns (bool increasing, uint32 size, int24 head) {
        TickLinkedList.List storage list = _lowerTriggerAfterSwap[poolId];
        return (list.increasing, list.size, list.head);
    }

    function upperTriggerAfterSwap(PoolId poolId) external view returns (bool increasing, uint32 size, int24 head) {
        TickLinkedList.List storage list = _upperTriggerAfterSwap[poolId];
        return (list.increasing, list.size, list.head);
    }

    // ==================== Configuration Setters ====================

    /// @notice Sets the ERC4626 vault to use for auto-lend feature for a specific token (onlyOwner)
    /// @dev When AUTO_LEND mode triggers, idle position value is deposited into this vault
    ///      This is effectively a token-level allowlist for AUTO_LEND target vaults.
    /// @param token The token address (typically stablecoin) that the vault accepts
    /// @param vault The ERC4626 vault contract to deposit into
    function setAutoLendVault(address token, IERC4626 vault) external {
        _delegatecallPassthrough(
            address(hookFunctionsAutoLendActions),
            abi.encodeCall(hookFunctionsAutoLendActions.setAutoLendVault, (token, vault))
        );
    }

    /// @notice Sets the maximum tick deviation allowed from oracle price for automated actions (onlyOwner)
    /// @dev Protects against price manipulation by limiting execution to prices within range of oracle
    /// @param newMaxTicksFromOracle Maximum tick difference from oracle-derived tick (e.g., 100 = ~1% price deviation)
    /// @custom:security Lower values provide stronger manipulation protection but may prevent legitimate executions
    function setMaxTicksFromOracle(int24 newMaxTicksFromOracle) external onlyOwner {
        _maxTicksFromOracle = newMaxTicksFromOracle;
        emit SetMaxTicksFromOracle(newMaxTicksFromOracle);
    }

    /// @notice Sets the minimum position value (in native token) required to enable automated features (onlyOwner)
    /// @dev Prevents dust positions from triggering gas-expensive automated actions
    /// @param newMinPositionValueNative Minimum position value in native token (e.g., 0.01 ether)
    function setMinPositionValueNative(uint256 newMinPositionValueNative) external onlyOwner {
        _minPositionValueNative = newMinPositionValueNative;
        emit SetMinPositionValueNative(newMinPositionValueNative);
    }

    /// @notice Sets the protocol fee percentage charged on position fees while active (onlyOwner)
    /// @dev Fee is calculated proportionally based on time position was active vs total time since last collect
    /// @param newProtocolFeeBps Protocol fee in basis points (e.g., 100 = 1%, max 10000 = 100%)
    function setProtocolFeeBps(uint16 newProtocolFeeBps) external onlyOwner {
        if (newProtocolFeeBps > 10000) {
            revert InvalidConfig();
        }
        _protocolFeeBps = newProtocolFeeBps;
        emit SetProtocolFeeBps(newProtocolFeeBps);
    }

    /// @notice Sets the protocol fee recipient
    function setProtocolFeeRecipient(address newProtocolFeeRecipient) external onlyOwner {
        _protocolFeeRecipient = newProtocolFeeRecipient;
        emit SetProtocolFeeRecipient(newProtocolFeeRecipient);
    }

    /// @notice Sets the general swap configuration for a position
    /// @dev Configures which pool to use for rebalancing swaps and max price impact limits.
    ///      Hook-initiated swaps may use the same hooked pool or a pool that does not use this hook.
    ///      Another pool using this same hook is rejected to keep afterSwap tick caching scoped to one hooked pool.
    ///      Only callable by position owner (real owner if position is in vault).
    /// @param tokenId The position token ID to configure
    /// @param swapPoolFee Fee tier of the pool to use for swaps
    /// @param swapPoolTickSpacing Tick spacing of the swap pool (must be multiple of position pool's tick spacing)
    /// @param swapPoolHooks Hook address of the swap pool
    /// @param maxPriceImpactBps0 Maximum price impact in basis points when swapping token0
    /// @param maxPriceImpactBps1 Maximum price impact in basis points when swapping token1
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
        if (
            address(swapPoolHooks) == address(this)
                && (swapPoolFee != poolKey.fee || swapPoolTickSpacing != poolKey.tickSpacing)
        ) {
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

    /// @notice Sets the automation configuration for a position
    /// @dev Configures the automated behavior mode and parameters for a position.
    ///      Only callable by position owner. Position must meet minimum value requirement.
    ///      Because value checks and trigger bounds use V4Oracle, position tokens must have oracle support.
    ///      AUTO_LEND additionally requires configured ERC4626 vaults for both pool tokens.
    /// @param tokenId The position token ID to configure
    /// @param positionConfig Configuration struct containing mode and parameters for automation
    /// @custom:security Validates position meets minPositionValueNative to prevent dust position attacks
    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
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

    // ==================== Internal Configuration Helpers ====================

    /// @notice Calculates the sqrt price multiplier from basis points
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

    /// @notice Internal function to set position configuration
    function _setPositionConfig(uint256 tokenId, PositionConfig memory config, bool checkImmediateExecution) internal {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _validateTickAlignedConfig(config, poolKey.tickSpacing);
        _validateModeFlags(config.modeFlags, tokenId, poolKey);
        hookFunctionsPositionActions.validateRangeConfig(
            poolKey.tickSpacing,
            positionInfo.tickLower(),
            positionInfo.tickUpper(),
            config
        );
        PositionConfig memory oldConfig = _positionConfigs[tokenId];
        _removePositionTriggersWithConfig(tokenId, poolKey, oldConfig);

        _positionConfigs[tokenId] = config;
        _delegatecallLendingActions(
            abi.encodeCall(hookFunctionsAutoLeverageActions.syncAutoLeverageBaseTick, (tokenId, poolKey, config.modeFlags))
        );
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

    // ==================== Mode Validation ====================

    /// @notice Validates mode flag combinations
    /// @dev Reverts if invalid combinations are detected
    function _validateModeFlags(uint8 modeFlags, uint256 tokenId, PoolKey memory poolKey) internal {
        // Invalid combinations
        if (PositionModeFlags.hasAutoLend(modeFlags) && PositionModeFlags.hasAutoLeverage(modeFlags)) {
            revert InvalidConfig();
        }
        if (PositionModeFlags.hasAutoLend(modeFlags) && PositionModeFlags.hasAutoExit(modeFlags)) {
            revert InvalidConfig();
        }

        _delegatecallPassthrough(
            address(hookFunctionsAutoLendActions),
            abi.encodeCall(hookFunctionsAutoLendActions.validateAutoLendMode, (tokenId, poolKey, modeFlags))
        );
        _delegatecallPassthrough(
            address(hookFunctionsAutoLeverageActions),
            abi.encodeCall(hookFunctionsAutoLeverageActions.validateAutoLeverageMode, (tokenId, poolKey, modeFlags))
        );
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

            bool exists;
            int24 tick;
            (exists, tick) = list.searchFirstAfter(cursor);
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

        // Persist the last processed cursor even when the batch cap is hit. Unprocessed trigger ticks remain in the
        // linked lists and may be consumed by a later external swap if the subsequent price path makes them eligible.
        _tickLowerLasts[poolId] = cursor;
        return (this.afterSwap.selector, 0);
    }

    function _dispatchAutomationAction(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint8 modeFlags,
        bool isUpperTrigger,
        int24 tick,
        bool autoExitIsRelative,
        int24 autoExitTickLower,
        int24 autoExitTickUpper
    ) internal {
        // Priority 1: AUTO_EXIT
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

        // When both AUTO_RANGE and AUTO_LEVERAGE are enabled, determine which action to take
        if (hasAutoRange && hasAutoLeverage) {
            _handleAutoRangeOrLeverage(poolKey, tokenId, isUpperTrigger);
            return;
        }

        // Priority 2: AUTO_RANGE
        if (hasAutoRange) {
            _handleAutoRange(poolKey, tokenId);
            return;
        }

        // Priority 3: AUTO_LEVERAGE
        if (hasAutoLeverage) {
            _handleAutoLeverage(poolKey, tokenId, isUpperTrigger);
            return;
        }

        // Priority 4: AUTO_LEND
        if (PositionModeFlags.hasAutoLend(modeFlags)) {
            _handleAutoLend(poolKey, tokenId, isUpperTrigger);
        }
    }

    /// @notice Calculates the exit tick based on configuration
    /// @dev Handles both absolute and relative exit tick configurations
    /// @param tokenId The position token ID
    /// @param isUpperTrigger True if upper trigger, false if lower trigger
    /// @param autoExitIsRelative Whether exit ticks are relative to position range
    /// @param autoExitTickLower Lower exit tick (absolute or relative delta)
    /// @param autoExitTickUpper Upper exit tick (absolute or relative delta)
    /// @return exitTick The calculated exit tick
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
                abi.encodeCall(hookFunctionsPositionActions.autoExit, (poolKey, tokenId, isUpperTrigger))
            )
        ) {
            _emitActionFailed(tokenId, Mode.AUTO_EXIT);
        }
    }

    function _handleAutoLend(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        if (vaults[_getOwner(tokenId, false)]) {
            return;
        }

        uint256 shares = _positionStates[tokenId].autoLendShares;
        bytes memory data = shares > 0
            ? abi.encodeCall(hookFunctionsAutoLendActions.autoLendWithdraw, (poolKey, tokenId, shares))
            : abi.encodeCall(hookFunctionsAutoLendActions.autoLendDeposit, (poolKey, tokenId, isUpperTrigger));
        if (!_tryDelegatecall(address(hookFunctionsAutoLendActions), data)) {
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
                abi.encodeCall(hookFunctionsPositionActions.autoRange, (poolKey, tokenId))
            )
        ) {
            _emitActionFailed(tokenId, Mode.AUTO_RANGE);
        }
    }

    function _handleAutoLeverage(PoolKey memory poolKey, uint256 tokenId, bool isUpperTrigger) internal {
        address owner = _getOwner(tokenId, false);
        if (!vaults[owner]) {
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

    /// @notice Handles case when both AUTO_RANGE and AUTO_LEVERAGE are enabled
    /// @dev Determines which action to take based on which trigger fires first
    function _handleAutoRangeOrLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        bool isUpperTrigger
    ) internal {
        PositionConfig storage config = _positionConfigs[tokenId];
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Compute AUTO_RANGE trigger ticks
        (int24 rangeLower, int24 rangeUpper) = _calculateRangeTriggerTicks(
            posInfo.tickLower(),
            posInfo.tickUpper(),
            config.autoRangeLowerLimit,
            config.autoRangeUpperLimit
        );

        // Compute AUTO_LEVERAGE trigger ticks
        (int24 leverageLower, int24 leverageUpper) = _calculateLeverageTriggerTicks(
            _positionStates[tokenId].autoLeverageBaseTick,
            poolKey.tickSpacing
        );

        // Determine which trigger fires first:
        // - Going UP (upper trigger): lower tick value fires first
        // - Going DOWN (lower trigger): higher tick value fires first
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
        address feeRecipient = _protocolFeeRecipient;
        PositionState storage state = _positionStates[tokenId];
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
            int32(accumulatedActiveTime) * feeDelta.amount0() * int16(_protocolFeeBps) / (10000 * int32(feeTime));
        int128 protocolFee1 =
            int32(accumulatedActiveTime) * feeDelta.amount1() * int16(_protocolFeeBps) / (10000 * int32(feeTime));

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
        if (!PositionModeFlags.hasTriggers(config.modeFlags)) {
            return;
        }

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        (bool shouldExecute, bool isUpperTrigger, int24 triggeredTick) = _checkTriggerConditions(
            tokenId, poolKey, config, posInfo.tickLower(), posInfo.tickUpper()
        );

        if (shouldExecute) {
            _executeImmediateAction(tokenId, isUpperTrigger, triggeredTick);
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
        int24 lowerTrigger = _getNearestSatisfiedLowerTrigger(currentTickLower, triggerTicks[0], triggerTicks[1]);
        int24 upperTrigger = _getNearestSatisfiedUpperTrigger(currentTickLower, triggerTicks[2], triggerTicks[3]);

        bool lowerSatisfied = lowerTrigger != type(int24).min;
        bool upperSatisfied = upperTrigger != type(int24).max;

        if (lowerSatisfied && upperSatisfied) {
            uint256 lowerDistance = uint256(int256(lowerTrigger) - int256(currentTickLower));
            uint256 upperDistance = uint256(int256(currentTickLower) - int256(upperTrigger));
            return lowerDistance <= upperDistance ? (true, false, lowerTrigger) : (true, true, upperTrigger);
        }
        if (lowerSatisfied) {
            return (true, false, lowerTrigger);
        }
        if (upperSatisfied) {
            return (true, true, upperTrigger);
        }

        return (false, false, 0);
    }

    function _getNearestSatisfiedLowerTrigger(int24 currentTickLower, int24 first, int24 second)
        internal
        pure
        returns (int24 lowerTrigger)
    {
        lowerTrigger = type(int24).min;

        if (first != type(int24).min && currentTickLower <= first) {
            lowerTrigger = first;
        }
        if (second != type(int24).min && currentTickLower <= second && second > lowerTrigger) {
            lowerTrigger = second;
        }
    }

    function _getNearestSatisfiedUpperTrigger(int24 currentTickLower, int24 first, int24 second)
        internal
        pure
        returns (int24 upperTrigger)
    {
        upperTrigger = type(int24).max;

        if (first != type(int24).max && currentTickLower >= first) {
            upperTrigger = first;
        }
        if (second != type(int24).max && currentTickLower >= second && second < upperTrigger) {
            upperTrigger = second;
        }
    }

    function _executeImmediateAction(uint256 tokenId, bool isUpperTrigger, int24 tick) internal {
        poolManager.unlock(abi.encode(tokenId, isUpperTrigger, tick));
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = _getTickLower(_getTick(poolId), tickSpacing);
        int24 tickLowerLast = _tickLowerLasts[poolId];

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

    /// @notice Executes auto-exit for a position, removing liquidity and swapping to single token
    /// @dev Called via vault transform for collateralized positions or directly for non-vault positions.
    ///      Delegatecalls to hookFunctionsPositionActions contract.
    /// @param poolKey The pool key for the position's pool
    /// @param tokenId The position token ID to auto-exit
    /// @param isUpper True if triggered by upper tick boundary, false for lower
    function autoExit(PoolKey calldata poolKey, uint256 tokenId, bool isUpper) external {
        _delegatecallPositionActions(
            abi.encodeCall(hookFunctionsPositionActions.autoExit, (poolKey, tokenId, isUpper))
        );
    }

    /// @notice Executes auto-range for a position, adjusting tick range around current price
    /// @dev Creates a new position with adjusted ticks and transfers debt if applicable.
    ///      Delegatecalls to hookFunctionsPositionActions contract.
    /// @param poolKey The pool key for the position's pool
    /// @param tokenId The position token ID to auto-range
    function autoRange(PoolKey calldata poolKey, uint256 tokenId) external {
        _delegatecallPositionActions(
            abi.encodeCall(hookFunctionsPositionActions.autoRange, (poolKey, tokenId))
        );
    }

    /// @notice Executes auto-leverage adjustment for a vault-owned position
    /// @dev Adjusts leverage based on price movement. Only works for vault-owned positions.
    ///      Delegatecalls to hookFunctionsAutoLeverageActions contract.
    /// @param poolKey The pool key for the position's pool
    /// @param tokenId The position token ID to adjust leverage
    /// @param isUpperTrigger True if triggered by upper tick boundary, false for lower
    function autoLeverage(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        _delegatecallLendingActions(
            abi.encodeCall(hookFunctionsAutoLeverageActions.autoLeverage, (poolKey, tokenId, isUpperTrigger))
        );
    }

    /// @notice Forces exit from auto-lend mode, withdrawing deposited tokens
    /// @dev Can be called to manually exit auto-lend before trigger conditions
    /// @param tokenId The position token ID to force exit
    function autoLendForceExit(uint256 tokenId) external {
        _delegatecall(
            address(hookFunctionsAutoLendActions),
            abi.encodeCall(hookFunctionsAutoLendActions.autoLendForceExit, (tokenId))
        );
    }

    /// @notice Manually triggers auto-compound for multiple positions
    /// @dev Collects fees and reinvests them as liquidity. Anyone can call this.
    /// @param tokenIds Array of position token IDs to compound
    function autoCompound(uint256[] calldata tokenIds) external {
        _delegatecallPositionActions(abi.encodeCall(hookFunctionsPositionActions.autoCompound, (tokenIds)));
    }

    /// @notice Triggers auto-compound for a vault-owned position via transform
    /// @dev Used when position is collateral in a vault
    /// @param tokenId The position token ID to compound
    /// @param caller The address initiating the compound (for reward distribution)
    function autoCompoundForVault(uint256 tokenId, address caller) external {
        _delegatecallPositionActions(abi.encodeCall(hookFunctionsPositionActions.autoCompoundForVault, (tokenId, caller)));
    }

    /// @notice Callback from pool manager during immediate execution of triggered actions
    /// @dev Called when setPositionConfig triggers immediate execution via poolManager.unlock()
    /// @param data Encoded action parameters or (tokenId, caller) for auto-compound
    /// @return Empty bytes (required by interface)
    /// @custom:security Only callable by pool manager
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

    function _executeImmediateActionUnlocked(uint256 tokenId, bool isUpperTrigger, int24 tick) internal {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        PositionConfig storage config = _positionConfigs[tokenId];
        PoolId poolId = poolKey.toId();
        _consumeImmediateTrigger(tokenId, poolId, isUpperTrigger, tick);
        _dispatchAutomationAction(
            poolKey,
            tokenId,
            config.modeFlags,
            isUpperTrigger,
            tick,
            config.autoExitIsRelative,
            config.autoExitTickLower,
            config.autoExitTickUpper
        );
    }

    function _consumeImmediateTrigger(uint256 tokenId, PoolId poolId, bool isUpperTrigger, int24 tick) internal {
        TickLinkedList.List storage list = isUpperTrigger ? _upperTriggerAfterSwap[poolId] : _lowerTriggerAfterSwap[poolId];
        list.remove(tick, tokenId);
    }

    function _executeAutoCompound(uint256 tokenId, address caller) internal {
        if (
            !_tryDelegatecallPositionActions(
                abi.encodeCall(hookFunctionsPositionActions.executeAutoCompound, (tokenId, caller))
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
        if (vaults[owner]) {
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

    // ==================== Internal Delegatecall Helper ====================

    function _delegatecall(address target, bytes memory data) internal {
        (bool success,) = target.delegatecall(data);
        if (!success) {
            revert TransformFailed();
        }
    }

    function _delegatecallPassthrough(address target, bytes memory data) internal {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    function _tryDelegatecall(address target, bytes memory data) internal returns (bool success) {
        (success,) = target.delegatecall(data);
    }

    function _delegatecallPositionActions(bytes memory data) internal {
        _delegatecall(address(hookFunctionsPositionActions), data);
    }

    function _delegatecallLendingActions(bytes memory data) internal {
        _delegatecall(address(hookFunctionsAutoLeverageActions), data);
    }

    function _tryDelegatecallPositionActions(bytes memory data) internal returns (bool success) {
        return _tryDelegatecall(address(hookFunctionsPositionActions), data);
    }

}
