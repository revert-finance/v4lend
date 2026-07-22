// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {RevertHookTriggers} from "./RevertHookTriggers.sol";

/// @title RevertHookLookupBase
/// @notice Shared lookup helpers used by both the hook and delegate targets
abstract contract RevertHookLookupBase is RevertHookTriggers {
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
}
