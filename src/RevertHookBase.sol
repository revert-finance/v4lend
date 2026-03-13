// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {IVault} from "./interfaces/IVault.sol";
import {RevertHookAutoLendActions} from "./RevertHookAutoLendActions.sol";
import {RevertHookAutoLeverageActions} from "./RevertHookAutoLeverageActions.sol";
import {RevertHookPositionActions} from "./RevertHookPositionActions.sol";
import {RevertHookTriggers} from "./RevertHookTriggers.sol";

/// @title RevertHookBase
/// @notice Hook-only shared base for constructor wiring, common lookups, and delegatecall helpers
abstract contract RevertHookBase is RevertHookTriggers, BaseHook, IUnlockCallback {
    IPermit2 internal immutable permit2;
    IPositionManager internal immutable positionManager;
    IV4Oracle internal immutable v4Oracle;
    ILiquidityCalculator internal immutable liquidityCalculator;

    RevertHookPositionActions internal immutable positionActions;
    RevertHookAutoLeverageActions internal immutable autoLeverageActions;
    RevertHookAutoLendActions internal immutable autoLendActions;

    constructor(
        address owner_,
        address protocolFeeRecipient_,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        RevertHookPositionActions _positionActions,
        RevertHookAutoLeverageActions _autoLeverageActions,
        RevertHookAutoLendActions _autoLendActions
    ) BaseHook(_v4Oracle.poolManager()) {
        if (owner_ == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }

        _transferOwnership(owner_);
        _protocolFeeRecipient = protocolFeeRecipient_;

        permit2 = _permit2;
        positionManager = _v4Oracle.positionManager();
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;
        positionActions = _positionActions;
        autoLeverageActions = _autoLeverageActions;
        autoLendActions = _autoLendActions;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function setVault(address vault) external onlyOwner {
        _setVault(vault);
    }

    function _getPoolAndPositionInfo(uint256 tokenId) internal view override returns (PoolKey memory, PositionInfo) {
        return positionManager.getPoolAndPositionInfo(tokenId);
    }

    function _getOwner(uint256 tokenId, bool resolveVaultOwner) internal view override returns (address) {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        return (resolveVaultOwner && _vaults[owner]) ? IVault(owner).ownerOf(tokenId) : owner;
    }

    function _getPositionValueNative(uint256 tokenId) internal view returns (uint256 value) {
        (value,,,) = v4Oracle.getValue(tokenId, address(0));
    }

    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

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
        _delegatecall(address(positionActions), data);
    }

    function _delegatecallAutoLeverageActions(bytes memory data) internal {
        _delegatecall(address(autoLeverageActions), data);
    }

    function _tryDelegatecallPositionActions(bytes memory data) internal returns (bool success) {
        return _tryDelegatecall(address(positionActions), data);
    }
}
