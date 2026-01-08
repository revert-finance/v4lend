// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {Transformer} from "./transformers/Transformer.sol";

/// @title RevertHookState
/// @notice Abstract contract containing all state variables, enums, structs, and events for RevertHook
/// @dev This contract separates state from logic to improve code organization
abstract contract RevertHookState is Transformer {
    // ==================== Enums ====================

    enum PositionMode {
        NONE,
        AUTO_COMPOUND_ONLY,
        AUTO_RANGE,
        AUTO_EXIT,
        AUTO_EXIT_AND_AUTO_RANGE,
        AUTO_LEND,
        AUTO_LEVERAGE
    }

    enum AutoCompoundMode {
        NONE,
        AUTO_COMPOUND,
        HARVEST_TOKEN_0,
        HARVEST_TOKEN_1
    }

    // ==================== Structs ====================

    struct PositionState {
        uint32 lastCollect;
        uint32 acumulatedActiveTime;
        uint32 lastActivated;
        address autoLendToken;
        uint256 autoLendShares;
        uint256 autoLendAmount;
        address autoLendVault;
        int24 autoLeverageBaseTick; // Base tick for auto-leverage triggers (triggers at baseTick ± 10 * tickSpacing)
    }

    struct GeneralConfig {
        // reference pool key data for swaps (can be the same pool or different pool)
        uint24 swapPoolFee;
        int24 swapPoolTickSpacing;
        IHooks swapPoolHooks;
        // sqrt price multipliers for max price impact (pre-calculated from basis points)
        // For zeroForOne swaps: sqrtPriceLimit = currentSqrtPrice * sqrtPriceMultiplier0 / Q64
        // For oneForZero swaps: sqrtPriceLimit = currentSqrtPrice * sqrtPriceMultiplier1 / Q64
        // Value of 0 means no price limit (uses extreme values)
        // Using uint128 to accommodate multipliers > 1 (for oneForZero, up to sqrt(2) * Q64)
        uint128 sqrtPriceMultiplier0; // for swaps token 0 to token 1 (price decreases)
        uint128 sqrtPriceMultiplier1; // for swaps token 1 to token 0 (price increases)
    }

    struct PositionConfig {
        PositionMode mode;
        AutoCompoundMode autoCompoundMode;
        bool autoExitIsRelative; // if true, the auto exit tick is relative to the position limits, if false, the auto exit tick is absolute
        int24 autoExitTickLower;
        int24 autoExitTickUpper;
        int24 autoRangeLowerLimit;
        int24 autoRangeUpperLimit;
        int24 autoRangeLowerDelta;
        int24 autoRangeUpperDelta;
        int24 autoLendToleranceTick;
        uint16 autoLeverageTargetBps; // target debt/collateral ratio (0-10000 bps, e.g., 5000 = 50%)
    }

    // ==================== Events ====================

    event SetAutoLendVault(address indexed token, IERC4626 vault);
    event SetMaxTicksFromOracle(int24 maxTicksFromOracle);
    event SetMinPositionValueNative(uint256 minPositionValueNative);
    event SetProtocolFeeBps(uint16 protocolFeeBps);
    event SetProtocolFeeRecipient(address protocolFeeRecipient);
    event SetGeneralConfig(uint256 indexed tokenId, GeneralConfig generalConfig);
    event SetPositionConfig(uint256 indexed tokenId, PositionConfig positionConfig);

    // ==================== State Variables ====================

    // Configuration storage
    mapping(uint256 tokenId => PositionConfig positionConfig) public positionConfigs;
    mapping(uint256 tokenId => GeneralConfig generalConfig) public generalConfigs;
    mapping(uint256 tokenId => PositionState positionState) public positionStates;

    // configured vaults for auto lend
    mapping(address token => IERC4626 vault) public autoLendVaults;

    // fees for auto compound execution 1% reward - of fees autocompounded / harvested
    uint16 public constant autoCompoundRewardBps = 100;

    // protocol fees (taken from the fees collected while position is active)
    uint16 public protocolFeeBps = 200;
    address public protocolFeeRecipient;

    // oracle price validation
    int24 public maxTicksFromOracle = 100; // Maximum number of ticks allowed from oracle tick (1%)

    // minimum position value in native token (address(0)) to be configurable
    uint256 public minPositionValueNative = 0.01 ether;

    // Position trigger mappings
    mapping(PoolId => int24) public tickLowerLasts;
    mapping(PoolId poolId => TickLinkedList.List) public lowerTriggerAfterSwap;
    mapping(PoolId poolId => TickLinkedList.List) public upperTriggerAfterSwap;
}
