// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Optional callback used by an approved vault transformer when a position is reminted.
interface IRemintMigrationHook {
    /// @notice Moves token-id keyed hook state from a vault's old position to its replacement.
    function migrateVaultPosition(address vault, uint256 oldTokenId, uint256 newTokenId) external;
}
