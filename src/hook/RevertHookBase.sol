// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {RevertHookAutoLendActions} from "./RevertHookAutoLendActions.sol";
import {RevertHookAutoLeverageActions} from "./RevertHookAutoLeverageActions.sol";
import {RevertHookPositionActions} from "./RevertHookPositionActions.sol";
import {RevertHookLookupBase} from "./RevertHookLookupBase.sol";

/// @title RevertHookBase
/// @notice Hook-only shared base for constructor wiring, common lookups, and delegatecall helpers
abstract contract RevertHookBase is RevertHookLookupBase, BaseHook, IUnlockCallback {
    IPermit2 internal immutable permit2;
    IPositionManager internal immutable positionManager;
    IWETH9 internal immutable weth;
    IV4Oracle internal immutable v4Oracle;
    ILiquidityCalculator internal immutable liquidityCalculator;
    IHookFeeController internal immutable hookFeeController;

    RevertHookPositionActions internal immutable positionActions;
    RevertHookAutoLeverageActions internal immutable autoLeverageActions;
    RevertHookAutoLendActions internal immutable autoLendActions;

    constructor(
        address owner_,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookFeeController _hookFeeController,
        RevertHookPositionActions _positionActions,
        RevertHookAutoLeverageActions _autoLeverageActions,
        RevertHookAutoLendActions _autoLendActions
    ) BaseHook(_v4Oracle.poolManager()) {
        if (owner_ == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }

        _transferOwnership(owner_);

        permit2 = _permit2;
        IPositionManager positionManager_ = _v4Oracle.positionManager();
        positionManager = positionManager_;
        weth = NativeWrapper(payable(address(positionManager_))).WETH9();
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;
        hookFeeController = _hookFeeController;
        positionActions = _positionActions;
        autoLeverageActions = _autoLeverageActions;
        autoLendActions = _autoLendActions;
    }

    function transferOwnership(address newOwner) external payable onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    function renounceOwnership() external payable onlyOwner {
        _transferOwnership(address(0));
    }

    function setVault(address vault) external payable onlyOwner {
        _setVault(vault);
    }

    receive() external payable {}

    function _positionManagerRef() internal view override returns (IPositionManager) {
        return positionManager;
    }

    function _poolManagerRef() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function _getPositionValueNative(uint256 tokenId) internal view returns (uint256 value) {
        (value,,,) = v4Oracle.getValue(tokenId, address(0));
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

    function _delegatecallPositionActionsPassthrough(bytes memory data) internal {
        _delegatecallPassthrough(address(positionActions), data);
    }

    function _delegatecallAutoLeverageActionsPassthrough(bytes memory data) internal {
        _delegatecallPassthrough(address(autoLeverageActions), data);
    }

    function _tryDelegatecallPositionActions(bytes memory data) internal returns (bool success) {
        return _tryDelegatecall(address(positionActions), data);
    }
}
