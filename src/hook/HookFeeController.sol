// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RevertHookState} from "./RevertHookState.sol";
import {IHookFeeController} from "./interfaces/IHookFeeController.sol";
import {HookOwnedControllerBase} from "./HookOwnedControllerBase.sol";

/// @dev The hook's PoolManager getter (BaseHook's public immutable), read to reject it as a fee recipient.
interface IHookPoolManagerGetter {
    function poolManager() external view returns (address);
}

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

    /// @notice Cap on lpFeeBps and autoLendFeeBps: both are taken from the position's GAIN (collected
    ///         LP fees, auto-lend interest), so 100% would confiscate the whole yield. 50% leaves the
    ///         owner room for any plausible fee policy while making a total-confiscation
    ///         misconfiguration impossible. Deployments use 100 bps (script/Deploy*.s.sol).
    uint16 public constant MAX_GAIN_FEE_BPS = 5_000;
    /// @notice Cap on per-mode swap fees: these are taken from the swap OUTPUT of hook-executed
    ///         automation swaps, i.e. from principal, so they are held an order of magnitude tighter.
    uint16 public constant MAX_SWAP_FEE_BPS = 1_000;

    address internal _protocolFeeRecipient;
    uint16 internal _lpFeeBps;
    uint16 internal _autoLendFeeBps;
    mapping(uint8 mode => uint16 feeBps) internal _defaultSwapFeeBps;
    mapping(PoolId swapPoolId => mapping(uint8 mode => PoolOverride poolOverride)) internal _poolOverrides;

    constructor(address hook_, address protocolFeeRecipient_, uint16 lpFeeBps_, uint16 autoLendFeeBps_)
        HookOwnedControllerBase(hook_)
    {
        _validateGainFeeBps(lpFeeBps_);
        _validateGainFeeBps(autoLendFeeBps_);
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
        _validateGainFeeBps(newLpFeeBps);
        _lpFeeBps = newLpFeeBps;
        emit SetLpFeeBps(newLpFeeBps);
    }

    function setAutoLendFeeBps(uint16 newAutoLendFeeBps) external {
        _checkOwner();
        _validateGainFeeBps(newAutoLendFeeBps);
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
        if (newFeeBps > MAX_SWAP_FEE_BPS) {
            revert InvalidConfig();
        }
    }

    function _validateSwapMode(uint8 mode) internal pure {
        if (!_isSupportedSwapMode(mode)) {
            revert InvalidConfig();
        }
    }

    function _validateGainFeeBps(uint16 newFeeBps) internal pure {
        if (newFeeBps > MAX_GAIN_FEE_BPS) {
            revert InvalidConfig();
        }
    }

    /// @dev Fees are DIRECT-SEND: the hook `take`s swap fees and `transfer`s auto-lend fees straight
    ///      to this recipient, so it must be an address that can actually hold them. Rejected:
    ///      - address(0);
    ///      - the hook: a `take` to it lands in the hook's own balance, which the next action's
    ///        settlement sweeps to whoever that user is;
    ///      - this controller: it has no withdrawal path, the fees would be stranded;
    ///      - the PoolManager: a `take` to it is a self-transfer that debits the hook's delta while
    ///        the tokens never leave the manager - the fee is destroyed.
    ///      The PoolManager is read from the hook's public immutable. The deploy scripts create this
    ///      controller BEFORE the hook, at the hook's predicted address, so the constructor cannot
    ///      rely on that call: it is a tolerant staticcall (no code / no such getter = skip that
    ///      check) and the PoolManager rejection is guaranteed only on setProtocolFeeRecipient.
    function _validateProtocolFeeRecipient(address newProtocolFeeRecipient) internal view {
        if (
            newProtocolFeeRecipient == address(0) || newProtocolFeeRecipient == hook
                || newProtocolFeeRecipient == address(this)
        ) {
            revert InvalidConfig();
        }
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeCall(IHookPoolManagerGetter.poolManager, ()));
        if (ok && ret.length == 32 && abi.decode(ret, (address)) == newProtocolFeeRecipient) {
            revert InvalidConfig();
        }
    }

    function _isSupportedSwapMode(uint8 mode) internal pure returns (bool) {
        return mode == uint8(RevertHookState.Mode.AUTO_COLLECT) || mode == uint8(RevertHookState.Mode.AUTO_RANGE)
            || mode == uint8(RevertHookState.Mode.AUTO_EXIT) || mode == uint8(RevertHookState.Mode.AUTO_LEVERAGE);
    }
}
