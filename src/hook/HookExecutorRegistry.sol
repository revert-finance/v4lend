// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;
import {HookOwnedControllerBase} from "./HookOwnedControllerBase.sol";

/// @notice Governance admits reviewed executors with restricted caller policies.
/// @dev Do not admit public routers or upgradeable executors. A code hash cannot attest to
/// mutable proxy implementations or to the executor's authorization semantics.
abstract contract HookExecutorRegistry is HookOwnedControllerBase {
    mapping(address executor => bytes32 codeHash) public admittedExecutorCodeHash;
    event ExecutorAdmissionSet(address indexed executor, bytes32 codeHash);
    error ExecutorHasNoCode();

    constructor(address hook_) HookOwnedControllerBase(hook_) {}

    function setExecutorAdmission(address executor, bool admitted) external {
        _checkOwner();
        if (admitted && executor.code.length == 0) revert ExecutorHasNoCode();
        bytes32 codeHash = admitted ? executor.codehash : bytes32(0);
        admittedExecutorCodeHash[executor] = codeHash;
        emit ExecutorAdmissionSet(executor, codeHash);
    }

    function _executorAdmitted(address executor) internal view returns (bool) {
        return executor.code.length != 0 && admittedExecutorCodeHash[executor] == executor.codehash;
    }
}
