// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

interface IHookOwner {
    function owner() external view returns (address);
}

abstract contract HookOwnedControllerBase {
    error Unauthorized();

    address public immutable hook;

    constructor(address hook_) {
        hook = hook_;
    }

    function _checkOwner() internal view {
        if (msg.sender != IHookOwner(hook).owner()) {
            revert Unauthorized();
        }
    }
}
