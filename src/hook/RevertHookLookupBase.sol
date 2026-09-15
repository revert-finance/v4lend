// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {RevertHookTriggers} from "./RevertHookTriggers.sol";

/// @title RevertHookLookupBase
/// @notice Shared lookup helpers used by both the hook and delegate targets
abstract contract RevertHookLookupBase is RevertHookTriggers {
    using PoolIdLibrary for PoolKey;

    function _positionManagerRef() internal view virtual returns (IPositionManager);

    function _poolManagerRef() internal view virtual returns (IPoolManager);

    function _getPoolAndPositionInfo(uint256 tokenId) internal view virtual override returns (PoolKey memory, PositionInfo) {
        return _positionManagerRef().getPoolAndPositionInfo(tokenId);
    }

    function _getOwner(uint256 tokenId, bool resolveVaultOwner) internal view virtual override returns (address) {
        address owner = IERC721(address(_positionManagerRef())).ownerOf(tokenId);
        return (resolveVaultOwner && _vaults[owner]) ? IVault(owner).ownerOf(tokenId) : owner;
    }

    /// @notice Non-reverting owner lookup for swap-time dispatch.
    /// @dev A burned position makes ownerOf revert; used from _afterSwap trigger handling, that revert
    /// would roll back the whole swap and re-arm the dead trigger node, permanently bricking the pool (H-2).
    /// Returns exists=false instead so the caller can skip the dead position and let the swap proceed.
    function _tryGetOwner(uint256 tokenId, bool resolveVaultOwner)
        internal
        view
        returns (address owner, bool exists)
    {
        try IERC721(address(_positionManagerRef())).ownerOf(tokenId) returns (address currentOwner) {
            owner = (resolveVaultOwner && _vaults[currentOwner]) ? IVault(currentOwner).ownerOf(tokenId) : currentOwner;
            exists = true;
        } catch {
            owner = address(0);
            exists = false;
        }
    }

    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(_poolManagerRef(), poolId);
    }

    function _getCurrentTick(PoolId poolId) internal view returns (int24 tick) {
        return _getTick(poolId);
    }

    // ==================== Trigger evaluation (shared with delegate targets) ====================

    /// @dev Which configured trigger, if any, is already satisfied at the current tick. Used by the
    ///      hook at config time (immediate execution) and by the sidecar when a vault remint migrates
    ///      a config onto a position with a new range.
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
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 lowerDistance = uint256(int256(lowerTrigger) - int256(currentTickLower));
            // forge-lint: disable-next-line(unsafe-typecast)
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
}
