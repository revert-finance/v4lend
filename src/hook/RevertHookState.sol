// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {RevertHookAccess} from "./RevertHookAccess.sol";

/// @title RevertHookState
/// @notice Abstract contract containing all state variables, enums, structs, and events for RevertHook
/// @dev This contract separates state from logic to improve code organization
abstract contract RevertHookState is RevertHookAccess {
    // ==================== Enums ====================

    enum Mode {
        AUTO_COLLECT,
        AUTO_RANGE,
        AUTO_EXIT,
        AUTO_LEND,
        AUTO_LEVERAGE
    }

    enum AutoCollectMode {
        NONE,
        AUTO_COLLECT,
        HARVEST_TOKEN_0,
        HARVEST_TOKEN_1,
        HARVEST_TOKENS
    }

    enum UnlockAction {
        AUTO_COLLECT,
        IMMEDIATE_ACTION,
        IMMEDIATE_AUTO_LEVERAGE
    }

    // ==================== Structs ====================

    struct PositionState {
        uint32 lastCollect;
        uint32 accumulatedActiveTime;
        uint32 lastActivated;
        address autoLendToken;
        uint256 autoLendShares;
        uint256 autoLendAmount;
        address autoLendVault;
        int24 autoLeverageBaseTick; // Base tick for auto-leverage triggers (triggers at baseTick ± 10 * tickSpacing)
    }

    /// @notice Protocol fee owed by a position that could not be taken inside a liquidity callback.
    /// @dev PositionManager attributes every hook delta to principal, so a fee-only removal cannot
    ///      carry a fee. The shortfall is parked here and settled on a later operation with room.
    struct PendingProtocolFee {
        uint128 amount0;
        uint128 amount1;
    }

    struct SwapProtectionConfig {
        // sqrt price multipliers for max price impact (pre-calculated from basis points)
        // For zeroForOne swaps: sqrtPriceLimit = currentSqrtPrice * sqrtPriceMultiplier0 / Q64
        // For oneForZero swaps: sqrtPriceLimit = currentSqrtPrice * sqrtPriceMultiplier1 / Q64
        // Value of 0 means no price limit (uses extreme values)
        // Using uint128 to accommodate multipliers > 1 (for oneForZero, up to sqrt(2) * Q64)
        uint128 sqrtPriceMultiplier0; // for swaps token 0 to token 1 (price decreases)
        uint128 sqrtPriceMultiplier1; // for swaps token 1 to token 0 (price increases)
    }

    struct PositionConfig {
        uint8 modeFlags; // Combination of PositionModeFlags (e.g., MODE_AUTO_COLLECT | MODE_AUTO_RANGE)
        AutoCollectMode autoCollectMode;
        bool autoExitIsRelative; // if true, the auto exit tick is relative to the position limits, if false, the auto exit tick is absolute
        bool autoExitSwapOnLowerTrigger; // if true, lower-side AUTO_EXIT swaps into a single exit-side token after debt repayment
        bool autoExitSwapOnUpperTrigger; // if true, upper-side AUTO_EXIT swaps into a single exit-side token after debt repayment
        int24 autoExitTickLower;
        int24 autoExitTickUpper;
        int24 autoRangeLowerLimit;
        int24 autoRangeUpperLimit;
        int24 autoRangeLowerDelta;
        int24 autoRangeUpperDelta;
        int24 autoLendToleranceTick;
        uint16 autoLeverageTargetBps; // target debt/collateral ratio (0-10000 bps, e.g., 5000 = 50%)
    }

    // ==================== Errors ====================

    /// @notice A configured, inactive position was re-activated by an external liquidity add while
    ///         one of its triggers is already satisfied at the live tick (V4LE-70).
    error TriggerAlreadySatisfied();

    // ==================== Events ====================

    // Configuration events
    event SetAutoLendVault(address indexed token, IERC4626 vault);
    event SetMaxTicksFromOracle(int24 maxTicksFromOracle);
    event SetMinPositionValueNative(uint256 minPositionValueNative);
    event SetSwapProtectionConfig(uint256 indexed tokenId, SwapProtectionConfig swapProtectionConfig);
    event SetPositionConfig(uint256 indexed tokenId, PositionConfig positionConfig);

    // Auto action events
    event AutoCollect(
        uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1
    );
    event AutoExit(uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event AutoRange(
        uint256 indexed tokenId,
        uint256 newTokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1
    );
    event AutoLendDeposit(uint256 indexed tokenId, Currency currency, uint256 amount, uint256 shares);
    event AutoLendWithdraw(uint256 indexed tokenId, Currency currency, uint256 amount, uint256 shares);
    event AutoLendForceExit(uint256 indexed tokenId, Currency currency, uint256 amount, uint256 shares);
    event AutoLeverage(uint256 indexed tokenId, bool isUpperTrigger, uint256 debtBefore, uint256 debtAfter);

    // Token transfer events
    event SendLeftoverTokens(
        uint256 indexed tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    );
    event SendRewards(
        uint256 indexed tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    );
    event SendProtocolFee(
        uint256 indexed tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    );

    /// @notice Emitted whenever a position's carried (not yet taken) protocol fee changes.
    event ProtocolFeeDeferred(
        uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1
    );

    // Special events for swap failures / modifyLiquidities failures
    event HookActionFailed(uint256 indexed tokenId, Mode mode);
    event HookSwapFailed(PoolKey poolKey, SwapParams swapParams, bytes reason);
    event HookSwapPartial(uint256 indexed tokenId, bool zeroForOne, uint256 requested, uint256 swapped);
    event HookModifyLiquiditiesFailed(bytes actions, bytes[] params, bytes reason);
    event HookAutoLendFailed(address vault, Currency currency, bytes reason);

    // ==================== State Variables ====================

    // Configuration storage
    mapping(uint256 tokenId => PositionConfig positionConfig) internal _positionConfigs;
    mapping(uint256 tokenId => SwapProtectionConfig swapProtectionConfig) internal _swapProtectionConfigs;
    mapping(uint256 tokenId => PositionState positionState) internal _positionStates;

    // configured vaults for auto lend
    mapping(address token => IERC4626 vault) internal _autoLendVaults;

    // fees for auto compound execution 1% reward - of fees autocompounded / harvested
    uint16 internal constant _AUTO_COLLECT_REWARD_BPS = 100;

    // auto-leverage triggers at baseTick ± (LEVERAGE_TICK_OFFSET_MULTIPLIER * tickSpacing)
    int24 internal constant _LEVERAGE_TICK_OFFSET_MULTIPLIER = 10;

    // a hook leverage-up may land at most this far above the configured target ratio; beyond it the
    // action is rolled back as NoImprovement (bad fills must not hand the user more leverage)
    uint256 internal constant _LEVERAGE_OVERSHOOT_TOLERANCE_BPS = 100;

    // oracle price validation
    /// @notice Tag that opens a remint-migration claim in a mint's hookData:
    ///         `abi.encodePacked(REMINT_MIGRATION_TAG, oldTokenId)` (36 bytes). Any other hookData is
    ///         ignored by the add-liquidity callback, so unrelated 32-byte payloads never enter that path.
    ///         Value: bytes4(keccak256("RevertHookRemintMigration(uint256)")).
    bytes4 internal constant REMINT_MIGRATION_TAG = bytes4(keccak256("RevertHookRemintMigration(uint256)"));

    int24 internal _maxTicksFromOracle = 100; // Maximum number of ticks allowed from oracle tick (1%)
    // Bound automation processing for one external swap. If the cap is hit, remaining executions stay registered
    // and can be picked up by a later external swap; they are not guaranteed to run on the immediately following swap.
    uint256 internal constant _MAX_EXECUTIONS_PER_SWAP = 32;

    // minimum position value in native token (address(0)) to be configurable
    uint256 internal _minPositionValueNative = 0.01 ether;

    /// @notice Per-pool afterSwap cursor packed with a "has ever registered a trigger" flag so the
    ///         swap hot path decides whether to walk the trigger lists from the slot it already reads.
    struct TriggerCursor {
        int24 tickLowerLast; // last processed tick bucket
        bool hasTriggers; // set when the first trigger registers; gates the afterSwap list walk
        int24 tickLowerOpposite; // opposite end of a walk left pending by action-induced price movement
    }

    // Position trigger mappings
    mapping(PoolId => TriggerCursor) internal _triggerCursors;
    mapping(PoolId poolId => TickLinkedList.List) internal _lowerTriggerAfterSwap;
    mapping(PoolId poolId => TickLinkedList.List) internal _upperTriggerAfterSwap;

    // Permit2 approval tracking
    mapping(address => bool) internal _permit2Approved;

    // Protocol fee carried per position until a liquidity operation can absorb it
    mapping(uint256 tokenId => PendingProtocolFee pendingProtocolFee) internal _pendingProtocolFees;

    /// @notice ERC4626 shares the hook custodies for auto-lend positions, per share token (the
    ///         lending vault). Hook actions sweep whole self-balances, so every balance read that
    ///         feeds a payout subtracts this (see RevertHookActionBase._sweepableBalance); a pool
    ///         whose currency is a share token can then never pay another position's shares out.
    /// @dev Appended last: the delegatecall sidecars share this layout (docs/hook-hierarchy.md).
    mapping(address shareToken => uint256 shares) internal _custodiedShares;
}
