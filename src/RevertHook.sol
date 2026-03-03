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
import {RevertHookLendingActions} from "./RevertHookLendingActions.sol";

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
///   - Uses hookFunctionsPositionActions and hookFunctionsLendingActions via delegatecall to avoid contract size limits
///   - All state is maintained in this contract
contract RevertHook is RevertHookTriggers, BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;
    using CurrencyLibrary for Currency;

    IPermit2 public immutable permit2;

    IPositionManager public immutable positionManager;
    IV4Oracle public immutable v4Oracle;
    ILiquidityCalculator public immutable liquidityCalculator;

    /// @notice The RevertHookPositionActions contract for delegatecall (auto-exit, auto-range, auto-compound)
    RevertHookPositionActions public immutable hookFunctionsPositionActions;

    /// @notice The RevertHookLendingActions contract for delegatecall (auto-leverage, auto-lend)
    RevertHookLendingActions public immutable hookFunctionsLendingActions;

    constructor(
        address owner_,
        address protocolFeeRecipient_,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        RevertHookPositionActions _hookFunctionsPositionActions,
        RevertHookLendingActions _hookFunctionsLendingActions
    ) BaseHook(_v4Oracle.poolManager()) Ownable(owner_) {
        positionManager = _v4Oracle.positionManager();
        protocolFeeRecipient = protocolFeeRecipient_;
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;

        // Use pre-deployed function contracts
        hookFunctionsPositionActions = _hookFunctionsPositionActions;
        hookFunctionsLendingActions = _hookFunctionsLendingActions;
    }

    // ==================== Configuration Setters ====================

    /// @notice Sets the ERC4626 vault to use for auto-lend feature for a specific token (onlyOwner)
    /// @dev When AUTO_LEND mode triggers, idle position value is deposited into this vault
    ///      This is effectively a token-level allowlist for AUTO_LEND target vaults.
    /// @param token The token address (typically stablecoin) that the vault accepts
    /// @param vault The ERC4626 vault contract to deposit into
    function setAutoLendVault(address token, IERC4626 vault) external onlyOwner {
        autoLendVaults[token] = vault;
        emit SetAutoLendVault(token, vault);
    }

    /// @notice Sets the maximum tick deviation allowed from oracle price for automated actions (onlyOwner)
    /// @dev Protects against price manipulation by limiting execution to prices within range of oracle
    /// @param _maxTicksFromOracle Maximum tick difference from oracle-derived tick (e.g., 100 = ~1% price deviation)
    /// @custom:security Lower values provide stronger manipulation protection but may prevent legitimate executions
    function setMaxTicksFromOracle(int24 _maxTicksFromOracle) external onlyOwner {
        maxTicksFromOracle = _maxTicksFromOracle;
        emit SetMaxTicksFromOracle(_maxTicksFromOracle);
    }

    /// @notice Sets the minimum position value (in native token) required to enable automated features (onlyOwner)
    /// @dev Prevents dust positions from triggering gas-expensive automated actions
    /// @param _minPositionValueNative Minimum position value in native token (e.g., 0.01 ether)
    function setMinPositionValueNative(uint256 _minPositionValueNative) external onlyOwner {
        minPositionValueNative = _minPositionValueNative;
        emit SetMinPositionValueNative(_minPositionValueNative);
    }

    /// @notice Sets the protocol fee percentage charged on position fees while active (onlyOwner)
    /// @dev Fee is calculated proportionally based on time position was active vs total time since last collect
    /// @param _protocolFeeBps Protocol fee in basis points (e.g., 100 = 1%, max 10000 = 100%)
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

    /// @notice Sets the general swap configuration for a position
    /// @dev Configures which pool to use for rebalancing swaps and max price impact limits.
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

    /// @notice Sets the automation configuration for a position
    /// @dev Configures the automated behavior mode and parameters for a position.
    ///      Only callable by position owner. Position must meet minimum value requirement.
    ///      Because value checks and trigger bounds use V4Oracle, position tokens must have oracle support.
    /// @param tokenId The position token ID to configure
    /// @param positionConfig Configuration struct containing mode and parameters for automation
    /// @custom:security Validates position meets minPositionValueNative to prevent dust position attacks
    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        if (!PositionModeFlags.isNone(positionConfig.modeFlags)) {
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

        // Validate tick configs are aligned to tick spacing (or are sentinel values)
        int24 ts = poolKey.tickSpacing;
        if (
            !_isValidTickConfig(config.autoExitTickLower, ts, type(int24).min) ||
            !_isValidTickConfig(config.autoExitTickUpper, ts, type(int24).max) ||
            !_isValidTickConfig(config.autoRangeLowerLimit, ts, type(int24).min) ||
            !_isValidTickConfig(config.autoRangeUpperLimit, ts, type(int24).max) ||
            !_isValidTickConfig(config.autoRangeLowerDelta, ts, 0) ||
            !_isValidTickConfig(config.autoRangeUpperDelta, ts, 0) ||
            !_isValidTickConfig(config.autoLendToleranceTick, ts, 0) ||
            config.autoLeverageTargetBps >= 10000
        ) {
            revert InvalidConfig();
        }

        // Validate mode flag combinations
        _validateModeFlags(config.modeFlags, tokenId, poolKey);

        // AUTO_LEVERAGE requires setting base tick
        if (PositionModeFlags.hasAutoLeverage(config.modeFlags)) {
            int24 currentTick = _getCurrentBaseTick(poolKey);
            positionStates[tokenId].autoLeverageBaseTick = (currentTick / poolKey.tickSpacing) * poolKey.tickSpacing;
        }

        _updatePositionTriggers(tokenId, poolKey, config);
        positionConfigs[tokenId] = config;

        if (!PositionModeFlags.isNone(config.modeFlags)) {
            _activatePosition(tokenId);
            if (checkImmediateExecution) {
                _checkAndExecuteImmediate(tokenId, poolKey, config);
            }
        } else {
            _deactivatePosition(tokenId);
        }

        emit SetPositionConfig(tokenId, config);
    }

    // ==================== Mode Validation ====================

    /// @notice Validates mode flag combinations
    /// @dev Reverts if invalid combinations are detected
    function _validateModeFlags(uint8 modeFlags, uint256 tokenId, PoolKey memory poolKey) internal view {
        // AUTO_LEVERAGE only for vault-owned positions with lend asset
        if (PositionModeFlags.hasAutoLeverage(modeFlags)) {
            address owner = _getOwner(tokenId, false);
            if (!vaults[owner]) {
                revert InvalidConfig();
            }
            address lendAsset = IVault(owner).asset();
            if (Currency.unwrap(poolKey.currency0) != lendAsset && Currency.unwrap(poolKey.currency1) != lendAsset) {
                revert InvalidConfig();
            }
        }

        // AUTO_LEND only for non-vault positions
        if (PositionModeFlags.hasAutoLend(modeFlags)) {
            address owner = _getOwner(tokenId, false);
            if (vaults[owner]) {
                revert InvalidConfig();
            }
        }

        // Invalid combinations
        if (PositionModeFlags.hasAutoLend(modeFlags) && PositionModeFlags.hasAutoLeverage(modeFlags)) {
            revert InvalidConfig();
        }
        if (PositionModeFlags.hasAutoLend(modeFlags) && PositionModeFlags.hasAutoExit(modeFlags)) {
            revert InvalidConfig();
        }
        // NOTE: AUTO_LEVERAGE + AUTO_EXIT (+ AUTO_RANGE) is valid for vault positions

        // AUTO_EXIT for vault positions requires lend asset in pool (for debt repayment)
        if (PositionModeFlags.hasAutoExit(modeFlags)) {
            address owner = _getOwner(tokenId, false);
            if (vaults[owner]) {
                address lendAsset = IVault(owner).asset();
                if (Currency.unwrap(poolKey.currency0) != lendAsset && Currency.unwrap(poolKey.currency1) != lendAsset) {
                    revert InvalidConfig();
                }
            }
        }
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
        uint8 modeFlags = config.modeFlags;

        // Priority 1: AUTO_EXIT (check if this is an exit trigger)
        if (PositionModeFlags.hasAutoExit(modeFlags)) {
            bool isAutoExitTriggered = _isExitTrigger(tokenId, config, isUpperTrigger, tick);
            if (isAutoExitTriggered) {
                _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
                return;
            }
        }

        bool hasAutoRange = PositionModeFlags.hasAutoRange(modeFlags);
        bool hasAutoLeverage = PositionModeFlags.hasAutoLeverage(modeFlags);

        // When both AUTO_RANGE and AUTO_LEVERAGE are enabled, determine which action to take
        if (hasAutoRange && hasAutoLeverage) {
            _handleAutoRangeOrLeverage(poolKey, poolId, tokenId, isUpperTrigger);
            return;
        }

        // Priority 2: AUTO_RANGE (when not combined with AUTO_LEVERAGE)
        if (hasAutoRange) {
            _handleAutoRange(poolKey, poolId, tokenId);
            return;
        }

        // Priority 3: AUTO_LEVERAGE (when not combined with AUTO_RANGE)
        if (hasAutoLeverage) {
            _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
            return;
        }

        // Priority 4: AUTO_LEND
        if (PositionModeFlags.hasAutoLend(modeFlags)) {
            _handleAutoLend(poolKey, poolId, tokenId, isUpperTrigger);
            return;
        }
    }

    /// @notice Checks if the triggered tick is an exit trigger
    /// @dev Handles both absolute and relative exit tick configurations
    function _isExitTrigger(
        uint256 tokenId,
        PositionConfig storage config,
        bool isUpperTrigger,
        int24 tick
    ) internal view returns (bool) {
        int24 exitTick = _calculateExitTick(
            tokenId,
            isUpperTrigger,
            config.autoExitIsRelative,
            config.autoExitTickLower,
            config.autoExitTickUpper
        );
        return tick == exitTick;
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

    /// @notice Handles case when both AUTO_RANGE and AUTO_LEVERAGE are enabled
    /// @dev Determines which action to take based on which trigger fires first
    function _handleAutoRangeOrLeverage(
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 tokenId,
        bool isUpperTrigger
    ) internal {
        PositionConfig storage config = positionConfigs[tokenId];
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
            positionStates[tokenId].autoLeverageBaseTick,
            poolKey.tickSpacing
        );

        // Determine which trigger fires first:
        // - Going UP (upper trigger): lower tick value fires first
        // - Going DOWN (lower trigger): higher tick value fires first
        if (isUpperTrigger) {
            if (rangeUpper <= leverageUpper) {
                _handleAutoRange(poolKey, poolId, tokenId);
            } else {
                _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
            }
        } else {
            if (rangeLower >= leverageLower) {
                _handleAutoRange(poolKey, poolId, tokenId);
            } else {
                _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
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

        if (!PositionModeFlags.isNone(positionConfigs[tokenId].modeFlags) && !_isActivated(tokenId)) {
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
        if (!PositionModeFlags.hasTriggers(config.modeFlags)) {
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
            config.modeFlags,
            isUpperTrigger,
            tick,
            config.autoExitIsRelative,
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

    /// @notice Executes auto-exit for a position, removing liquidity and swapping to single token
    /// @dev Called via vault transform for collateralized positions or directly for non-vault positions.
    ///      Delegatecalls to hookFunctionsPositionActions contract.
    /// @param poolKey The pool key for the position's pool
    /// @param poolId The pool ID
    /// @param tokenId The position token ID to auto-exit
    /// @param isUpper True if triggered by upper tick boundary, false for lower
    function autoExit(
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 tokenId,
        bool isUpper
    ) public {
        _delegatecallAutoExit(poolKey, poolId, tokenId, isUpper);
    }

    /// @notice Executes auto-range for a position, adjusting tick range around current price
    /// @dev Creates a new position with adjusted ticks and transfers debt if applicable.
    ///      Delegatecalls to hookFunctionsPositionActions contract.
    /// @param poolKey The pool key for the position's pool
    /// @param poolId The pool ID
    /// @param tokenId The position token ID to auto-range
    function autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) public {
        _delegatecallAutoRange(poolKey, poolId, tokenId);
    }

    /// @notice Executes auto-leverage adjustment for a vault-owned position
    /// @dev Adjusts leverage based on price movement. Only works for vault-owned positions.
    ///      Delegatecalls to hookFunctionsLendingActions contract.
    /// @param poolKey The pool key for the position's pool
    /// @param poolId The pool ID
    /// @param tokenId The position token ID to adjust leverage
    /// @param isUpperTrigger True if triggered by upper tick boundary, false for lower
    function autoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) public {
        _delegatecallAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
    }

    /// @notice Forces exit from auto-lend mode, withdrawing deposited tokens
    /// @dev Can be called to manually exit auto-lend before trigger conditions
    /// @param tokenId The position token ID to force exit
    function autoLendForceExit(uint256 tokenId) external {
        _delegatecall(address(hookFunctionsLendingActions), abi.encodeCall(hookFunctionsLendingActions.autoLendForceExit, (tokenId)));
    }

    /// @notice Manually triggers auto-compound for multiple positions
    /// @dev Collects fees and reinvests them as liquidity. Anyone can call this.
    /// @param tokenIds Array of position token IDs to compound
    function autoCompound(uint256[] memory tokenIds) external {
        _delegatecall(address(hookFunctionsPositionActions), abi.encodeCall(hookFunctionsPositionActions.autoCompound, (tokenIds)));
    }

    /// @notice Triggers auto-compound for a vault-owned position via transform
    /// @dev Used when position is collateral in a vault
    /// @param tokenId The position token ID to compound
    /// @param caller The address initiating the compound (for reward distribution)
    function autoCompoundForVault(uint256 tokenId, address caller) external {
        _delegatecall(address(hookFunctionsPositionActions), abi.encodeCall(hookFunctionsPositionActions.autoCompoundForVault, (tokenId, caller)));
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

        if (data.length > 64) {
            (
                uint256 tokenId,
                PoolKey memory poolKey,
                uint8 modeFlags,
                bool isUpperTrigger,
                int24 tick,
                bool autoExitIsRelative,
                int24 autoExitTickLower,
                int24 autoExitTickUpper
            ) = abi.decode(data, (uint256, PoolKey, uint8, bool, int24, bool, int24, int24));

            _executeImmediateActionUnlocked(poolKey, tokenId, modeFlags, isUpperTrigger, tick, autoExitIsRelative, autoExitTickLower, autoExitTickUpper);
        } else {
            (uint256 tokenId, address caller) = abi.decode(data, (uint256, address));
            _executeAutoCompound(tokenId, caller);
        }
        return bytes("");
    }

    function _executeImmediateActionUnlocked(
        PoolKey memory poolKey,
        uint256 tokenId,
        uint8 modeFlags,
        bool isUpperTrigger,
        int24 tick,
        bool autoExitIsRelative,
        int24 autoExitTickLower,
        int24 autoExitTickUpper
    ) internal {
        PoolId poolId = poolKey.toId();

        // Priority 1: AUTO_EXIT (check if this is an exit trigger)
        if (PositionModeFlags.hasAutoExit(modeFlags)) {
            int24 exitTick = _calculateExitTick(
                tokenId, isUpperTrigger, autoExitIsRelative, autoExitTickLower, autoExitTickUpper
            );
            if (tick == exitTick) {
                _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
                return;
            }
        }

        bool hasAutoRange = PositionModeFlags.hasAutoRange(modeFlags);
        bool hasAutoLeverage = PositionModeFlags.hasAutoLeverage(modeFlags);

        // When both AUTO_RANGE and AUTO_LEVERAGE are enabled, determine which action to take
        if (hasAutoRange && hasAutoLeverage) {
            _handleAutoRangeOrLeverage(poolKey, poolId, tokenId, isUpperTrigger);
            return;
        }

        // Priority 2: AUTO_RANGE
        if (hasAutoRange) {
            _handleAutoRange(poolKey, poolId, tokenId);
            return;
        }

        // Priority 3: AUTO_LEVERAGE
        if (hasAutoLeverage) {
            _handleAutoLeverage(poolKey, poolId, tokenId, isUpperTrigger);
            return;
        }

        // Priority 4: AUTO_LEND
        if (PositionModeFlags.hasAutoLend(modeFlags)) {
            _handleAutoLend(poolKey, poolId, tokenId, isUpperTrigger);
            return;
        }
    }

    function _executeAutoCompound(uint256 tokenId, address caller) internal {
        _delegatecall(address(hookFunctionsPositionActions), abi.encodeCall(hookFunctionsPositionActions.executeAutoCompound, (tokenId, caller)));
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
        _delegatecall(address(hookFunctionsPositionActions), abi.encodeCall(hookFunctionsPositionActions.autoExit, (poolKey, poolId, tokenId, isUpper)));
    }

    function _delegatecallAutoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) internal {
        _delegatecall(address(hookFunctionsPositionActions), abi.encodeCall(hookFunctionsPositionActions.autoRange, (poolKey, poolId, tokenId)));
    }

    function _delegatecallAutoLeverage(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        _delegatecall(address(hookFunctionsLendingActions), abi.encodeCall(hookFunctionsLendingActions.autoLeverage, (poolKey, poolId, tokenId, isUpperTrigger)));
    }

    function _delegatecallAutoLendDeposit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper) internal {
        _delegatecall(address(hookFunctionsLendingActions), abi.encodeCall(hookFunctionsLendingActions.autoLendDeposit, (poolKey, poolId, tokenId, isUpper)));
    }

    function _delegatecallAutoLendWithdraw(PoolKey memory poolKey, uint256 tokenId, uint256 shares) internal {
        _delegatecall(address(hookFunctionsLendingActions), abi.encodeCall(hookFunctionsLendingActions.autoLendWithdraw, (poolKey, tokenId, shares)));
    }
}
