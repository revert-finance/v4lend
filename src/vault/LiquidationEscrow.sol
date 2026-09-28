// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Holds liquidation surplus separately from the vault's lendable assets.
contract LiquidationEscrow is Ownable, ReentrancyGuard {
    mapping(address token => mapping(address beneficiary => uint256)) public claimable;
    event Credited(address indexed token, address indexed beneficiary, uint256 amount);
    event Claimed(address indexed token, address indexed beneficiary, address recipient, uint256 amount);

    constructor() Ownable(msg.sender) {}

    /// @dev The vault transfers the tokens before crediting the beneficiary.
    function credit(address token, address beneficiary, uint256 amount) external onlyOwner {
        claimable[token][beneficiary] += amount;
        emit Credited(token, beneficiary, amount);
    }

    /// @notice A beneficiary can choose a recipient that the token permits receiving funds.
    function claim(address token, address recipient) external nonReentrant {
        uint256 amount = claimable[token][msg.sender];
        claimable[token][msg.sender] = 0;
        SafeERC20.safeTransfer(IERC20(token), recipient, amount);
        emit Claimed(token, msg.sender, recipient, amount);
    }
}
