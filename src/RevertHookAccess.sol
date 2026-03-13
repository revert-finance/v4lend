// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IVault} from "./interfaces/IVault.sol";
import {Constants} from "./utils/Constants.sol";

/// @title RevertHookAccess
/// @notice Internal-only ownership and vault access helpers for the hook/delegatecall stack
abstract contract RevertHookAccess is Constants {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event VaultSet(address newVault);

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    address internal _owner;
    mapping(address => bool) internal _vaults;

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
