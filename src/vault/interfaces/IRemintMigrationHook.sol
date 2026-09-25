// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IRemintMigrationHook
/// @notice Callback a vault issues to an allowlisted pool hook when a transform replaced a
///         position NFT, so token-id keyed hook state can follow the loan to the new token.
interface IRemintMigrationHook {
    /// @notice Reverts when an automation configuration cannot safely serve the vault's asset.
    function validateVaultPosition(uint256 tokenId, address asset) external view;

    /// @notice Moves the hook's token-id keyed state from the retired position to its replacement,
    ///         or retires that state when the replacement is no longer in one of the hook's pools.
    /// @dev Invoked by the vault (msg.sender) on the OLD position's hook while its
    ///      `transformedTokenId` equals `newTokenId`; the new position may live under another hook.
    function migrateVaultPosition(uint256 oldTokenId, uint256 newTokenId) external;
}
