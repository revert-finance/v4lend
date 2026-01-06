// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Constants} from "../utils/Constants.sol";
import {IVault} from "../interfaces/IVault.sol";

abstract contract Transformer is Ownable2Step, Constants {
    event VaultSet(address newVault);

    // configurable by owner
    mapping(address => bool) public vaults;

    /**
     * @notice Owner controlled function to activate vault address
     * @param _vault vault
     */
    function setVault(address _vault) external onlyOwner {
        emit VaultSet(_vault);
        vaults[_vault] = true;
    }

    // validates if caller is owner (direct or indirect for a given position)
    function _validateOwner(IPositionManager positionManager, uint256 tokenId, address vault) internal {
        // vault can not be owner
        if (vaults[msg.sender]) {
            revert Unauthorized();
        }

        address owner;
        if (vault != address(0)) {
            if (!vaults[vault]) {
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

    // validates if caller is allowed to process position
    function _validateCaller(IPositionManager positionManager, uint256 tokenId) internal view {
        if (vaults[msg.sender]) {
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
