// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {TickLinkedList} from "./lib/TickLinkedList.sol";
import {RevertHookBase} from "./RevertHookBase.sol";

/// @title RevertHookViews
/// @notice Hook read API grouped away from callbacks and execution flow
abstract contract RevertHookViews is RevertHookBase {
    function autoCollectRewardBps() external pure returns (uint16) {
        return _AUTO_COLLECT_REWARD_BPS;
    }

    function LEVERAGE_TICK_OFFSET_MULTIPLIER() external pure returns (int24) {
        return _LEVERAGE_TICK_OFFSET_MULTIPLIER;
    }

    function MAX_TRIGGER_BATCHES_PER_SWAP() external pure returns (uint256) {
        return _MAX_TRIGGER_BATCHES_PER_SWAP;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function vaults(address vault) external view returns (bool) {
        return _vaults[vault];
    }

    function positionConfigs(uint256 tokenId)
        external
        view
        returns (
            uint8 modeFlags,
            AutoCollectMode autoCollectMode,
            bool autoExitIsRelative,
            bool autoExitSwapOnLowerTrigger,
            bool autoExitSwapOnUpperTrigger,
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
            config.autoCollectMode,
            config.autoExitIsRelative,
            config.autoExitSwapOnLowerTrigger,
            config.autoExitSwapOnUpperTrigger,
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

    function swapProtectionConfigs(uint256 tokenId)
        external
        view
        returns (uint128 sqrtPriceMultiplier0, uint128 sqrtPriceMultiplier1)
    {
        SwapProtectionConfig storage config = _swapProtectionConfigs[tokenId];
        return (config.sqrtPriceMultiplier0, config.sqrtPriceMultiplier1);
    }

    function positionStates(uint256 tokenId)
        external
        view
        returns (
            uint32 lastCollect,
            uint32 accumulatedActiveTime,
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
            state.accumulatedActiveTime,
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
}
