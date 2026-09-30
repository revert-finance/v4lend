// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC4626Vault} from "../../utils/MockERC4626Vault.sol";

/// @title LimitedRedeemERC4626Vault
/// @notice ERC4626 mock whose `maxRedeem` can be capped below the owner's balance, the standard
///         withdrawal-limit / cooldown behaviour the interface permits (`redeem` above it reverts).
contract LimitedRedeemERC4626Vault is MockERC4626Vault {
    uint256 public redeemLimit = type(uint256).max;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626Vault(asset_, name_, symbol_) {}

    function setRedeemLimit(uint256 limit) external {
        redeemLimit = limit;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 balance = balanceOf(owner);
        return balance < redeemLimit ? balance : redeemLimit;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }
}
