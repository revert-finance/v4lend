// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RevertHookState} from "./RevertHookState.sol";
import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {HookOwnedControllerBase} from "./HookOwnedControllerBase.sol";

contract HookFeeController is HookOwnedControllerBase, IHookFeeController {
    error InvalidConfig();

    event SetProtocolFeeRecipient(address protocolFeeRecipient);
    event SetLpFeeBps(uint16 lpFeeBps);
    event SetAutoLendFeeBps(uint16 autoLendFeeBps);
    event SetDefaultSwapFeeBps(uint8 indexed mode, uint16 newFeeBps);
    event SetPoolOverrideSwapFeeBps(PoolId indexed swapPoolId, uint8 indexed mode, uint16 newFeeBps);
    event ClearPoolOverrideSwapFeeBps(PoolId indexed swapPoolId, uint8 indexed mode);

    struct PoolOverride {
        uint16 feeBps;
        bool hasOverride;
    }

    address internal _protocolFeeRecipient;
    uint16 internal _lpFeeBps;
    uint16 internal _autoLendFeeBps;
    mapping(uint8 mode => uint16 feeBps) internal _defaultSwapFeeBps;
    mapping(PoolId swapPoolId => mapping(uint8 mode => PoolOverride poolOverride)) internal _poolOverrides;

    constructor(address hook_, address protocolFeeRecipient_, uint16 lpFeeBps_, uint16 autoLendFeeBps_)
        HookOwnedControllerBase(hook_)
    {
        _validateBps(lpFeeBps_);
        _validateBps(autoLendFeeBps_);
        _validateProtocolFeeRecipient(protocolFeeRecipient_);
        _protocolFeeRecipient = protocolFeeRecipient_;
        _lpFeeBps = lpFeeBps_;
        _autoLendFeeBps = autoLendFeeBps_;
    }

    function protocolFeeRecipient() external view returns (address) {
        return _protocolFeeRecipient;
    }

    function lpFeeBps() external view returns (uint16) {
        return _lpFeeBps;
    }

    function autoLendFeeBps() external view returns (uint16) {
        return _autoLendFeeBps;
    }

    function swapFeeBps(PoolId swapPoolId, uint8 mode) external view returns (uint16) {
        if (!_isSupportedSwapMode(mode)) {
            return 0;
        }

        PoolOverride memory poolOverride = _poolOverrides[swapPoolId][mode];
        return poolOverride.hasOverride ? poolOverride.feeBps : _defaultSwapFeeBps[mode];
    }

    function setProtocolFeeRecipient(address newProtocolFeeRecipient) external {
        _checkOwner();
        _validateProtocolFeeRecipient(newProtocolFeeRecipient);
        _protocolFeeRecipient = newProtocolFeeRecipient;
        emit SetProtocolFeeRecipient(newProtocolFeeRecipient);
    }

    function setLpFeeBps(uint16 newLpFeeBps) external {
        _checkOwner();
        _validateBps(newLpFeeBps);
        _lpFeeBps = newLpFeeBps;
        emit SetLpFeeBps(newLpFeeBps);
    }

    function setAutoLendFeeBps(uint16 newAutoLendFeeBps) external {
        _checkOwner();
        _validateBps(newAutoLendFeeBps);
        _autoLendFeeBps = newAutoLendFeeBps;
        emit SetAutoLendFeeBps(newAutoLendFeeBps);
    }

    function setDefaultSwapFeeBps(uint8 mode, uint16 newFeeBps) external {
        _checkOwner();
        _validateSwapConfig(mode, newFeeBps);
        _defaultSwapFeeBps[mode] = newFeeBps;
        emit SetDefaultSwapFeeBps(mode, newFeeBps);
    }

    function setPoolOverrideSwapFeeBps(PoolId swapPoolId, uint8 mode, uint16 newFeeBps) external {
        _checkOwner();
        _validateSwapConfig(mode, newFeeBps);
        _poolOverrides[swapPoolId][mode] = PoolOverride({feeBps: newFeeBps, hasOverride: true});
        emit SetPoolOverrideSwapFeeBps(swapPoolId, mode, newFeeBps);
    }

    function clearPoolOverrideSwapFeeBps(PoolId swapPoolId, uint8 mode) external {
        _checkOwner();
        _validateSwapMode(mode);
        delete _poolOverrides[swapPoolId][mode];
        emit ClearPoolOverrideSwapFeeBps(swapPoolId, mode);
    }
    function _validateSwapConfig(uint8 mode, uint16 newFeeBps) internal pure {
        _validateSwapMode(mode);
        _validateBps(newFeeBps);
    }

    function _validateSwapMode(uint8 mode) internal pure {
        if (!_isSupportedSwapMode(mode)) {
            revert InvalidConfig();
        }
    }

    function _validateBps(uint16 newFeeBps) internal pure {
        if (newFeeBps > 10000) {
            revert InvalidConfig();
        }
    }

    function _validateProtocolFeeRecipient(address newProtocolFeeRecipient) internal pure {
        if (newProtocolFeeRecipient == address(0)) {
            revert InvalidConfig();
        }
    }

    function _isSupportedSwapMode(uint8 mode) internal pure returns (bool) {
        return mode == uint8(RevertHookState.Mode.AUTO_COLLECT) || mode == uint8(RevertHookState.Mode.AUTO_RANGE)
            || mode == uint8(RevertHookState.Mode.AUTO_EXIT) || mode == uint8(RevertHookState.Mode.AUTO_LEVERAGE);
    }
}
