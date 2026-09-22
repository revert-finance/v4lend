// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {Constants} from "../shared/Constants.sol";

/// @title RevertHookAccess
/// @notice Internal-only ownership and vault access helpers for the hook/delegatecall stack
abstract contract RevertHookAccess is Constants {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event VaultSet(address newVault);

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    address internal _owner;
    mapping(address => bool) internal _vaults;

    /// @dev Transient slot (EIP-1153, cleared after every transaction) naming the token whose vault
    ///      transform the hook itself started; 0 outside one. The sidecars' vault-caller
    ///      authorization requires it, so the hook cannot serve as a generic borrower-callable
    ///      transformer (C-01). Not part of the storage layout shared with the sidecars.
    // keccak256("RevertHook.transformTokenId") - inline assembly needs a literal
    bytes32 internal constant _HOOK_TRANSFORM_TOKEN_SLOT =
        0x28657997ef2591c3603c18ba4a0c47cd42fc5d57008b1bc5321aa5a3a894bcc3;

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        if (_owner != msg.sender) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function _setVault(address vault) internal {
        emit VaultSet(vault);
        _vaults[vault] = true;
    }

    function _setHookTransformToken(uint256 tokenId) internal {
        assembly ("memory-safe") {
            tstore(_HOOK_TRANSFORM_TOKEN_SLOT, tokenId)
        }
    }

    function _hookTransformToken() internal view returns (uint256 tokenId) {
        assembly ("memory-safe") {
            tokenId := tload(_HOOK_TRANSFORM_TOKEN_SLOT)
        }
    }

    // validates if caller is owner (direct or indirect for a given position)
    function _validateOwner(IPositionManager positionManager, uint256 tokenId, address vault) internal view {
        // vault can not be owner
        if (_vaults[msg.sender]) {
            revert Unauthorized();
        }

        address owner;
        if (vault != address(0)) {
            if (!_vaults[vault]) {
                revert Unauthorized();
            }
            owner = IVault(vault).ownerOf(tokenId);
        } else {
            owner = IERC721(address(positionManager)).ownerOf(tokenId);
        }

        if (owner != msg.sender) {
            revert Unauthorized();
        }
    }

    // validates if caller is authorized to process a position
    function _validateCaller(IPositionManager positionManager, uint256 tokenId) internal view {
        if (_vaults[msg.sender]) {
            uint256 transformedTokenId = IVault(msg.sender).transformedTokenId();
            if (tokenId != transformedTokenId) {
                revert Unauthorized();
            }
        } else {
            address owner = IERC721(address(positionManager)).ownerOf(tokenId);
            if (owner != msg.sender && owner != address(this)) {
                revert Unauthorized();
            }
        }
    }
}
