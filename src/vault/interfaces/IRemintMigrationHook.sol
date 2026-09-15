// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IRemintMigrationHook
/// @notice Callback a vault issues to an allowlisted pool hook when a transform replaced a
///         position NFT, so token-id keyed hook state can follow the loan to the new token.
interface IRemintMigrationHook {
    /// @notice Moves the hook's token-id keyed state from the retired position to its replacement.
    /// @dev Invoked by the vault (msg.sender) while its `transformedTokenId` equals `newTokenId`.
    function migrateVaultPosition(uint256 oldTokenId, uint256 newTokenId) external;
}
