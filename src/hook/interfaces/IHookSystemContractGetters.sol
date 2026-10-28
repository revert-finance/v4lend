// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @dev The hook's PoolManager getter (BaseHook's public immutable) and PositionManager getter, read
///      by the controllers to reject both system contracts as a fee recipient.
interface IHookSystemContractGetters {
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
}
