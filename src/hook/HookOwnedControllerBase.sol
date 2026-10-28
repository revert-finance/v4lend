// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

interface IHookOwner {
    function owner() external view returns (address);
}

abstract contract HookOwnedControllerBase {
    error InvalidHook();
    error Unauthorized();

    address public immutable hook;

    constructor(address hook_) {
        if (hook_ == address(0)) {
            revert InvalidHook();
        }
        hook = hook_;
    }

    function _checkOwner() internal view {
        if (msg.sender != IHookOwner(hook).owner()) {
            revert Unauthorized();
        }
    }

    /// @dev Tolerant read of an address-returning, argument-less getter on the hook: address(0)
    ///      when the hook has no code, lacks the getter or returns anything else (a recipient of
    ///      address(0) is rejected before these comparisons, so 0 can never match).
    function _hookAddressGetter(bytes4 selector) internal view returns (address) {
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSelector(selector));
        if (!ok || ret.length != 32) {
            return address(0);
        }
        uint256 word = abi.decode(ret, (uint256));
        return word <= type(uint160).max ? address(uint160(word)) : address(0);
    }
}
