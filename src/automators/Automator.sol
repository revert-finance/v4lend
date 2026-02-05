// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {Swapper} from "../utils/Swapper.sol";
import {Transformer, Ownable} from "../transformers/Transformer.sol";
import {IVault} from "../interfaces/IVault.sol";

/// @title Automator
/// @notice Base contract for V4 position automation. Provides operator access control,
/// reward withdrawal, and shared infrastructure for all automator contracts.
abstract contract Automator is Transformer, Swapper, IERC721Receiver, ReentrancyGuard {
    event OperatorChanged(address newOperator, bool active);
    event WithdrawerChanged(address newWithdrawer);

    /// @notice Permit2 contract for token approvals
    IPermit2 public immutable permit2;

    /// @notice Authorized operators that can execute automations
    mapping(address => bool) public operators;

    /// @notice Address authorized to withdraw accumulated protocol rewards
    address public withdrawer;

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder) Ownable(msg.sender) {
        permit2 = _permit2;
        setOperator(_operator, true);
        setWithdrawer(_withdrawer);
    }

    /// @notice Owner controlled function to activate/deactivate operator address
    /// @param _operator operator address
    /// @param _active active or not
    function setOperator(address _operator, bool _active) public onlyOwner {
        emit OperatorChanged(_operator, _active);
        operators[_operator] = _active;
    }

    /// @notice Owner controlled function to set withdrawer address
    /// @param _withdrawer withdrawer address
    function setWithdrawer(address _withdrawer) public onlyOwner {
        emit WithdrawerChanged(_withdrawer);
        withdrawer = _withdrawer;
    }

    /// @notice Withdraws token balance (accumulated protocol rewards)
    /// @param tokens Addresses of tokens to withdraw
    /// @param to Address to send to
    function withdrawBalances(address[] calldata tokens, address to) external virtual {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            address token = tokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance != 0) {
                _transferToken(to, Currency.wrap(token), balance, true);
            }
        }
    }

    /// @notice Withdraws ETH balance
    /// @param to Address to send to
    function withdrawETH(address to) external {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool sent,) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        }
    }

    /// @notice Transfers token to address, optionally unwrapping WETH to ETH
    /// @param to Recipient address
    /// @param token Token to transfer
    /// @param amount Amount to transfer
    /// @param unwrap If true and token is WETH, unwrap to ETH before sending
    function _transferToken(address to, Currency token, uint256 amount, bool unwrap) internal {
        if (amount == 0) return;
        if (unwrap && Currency.unwrap(token) == address(weth)) {
            weth.withdraw(amount);
            (bool sent,) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            if (token.isAddressZero()) {
                (bool sent,) = to.call{value: amount}("");
                if (!sent) {
                    revert EtherSendFailed();
                }
            } else {
                SafeERC20.safeTransfer(IERC20(Currency.unwrap(token)), to, amount);
            }
        }
    }

    /// @notice Callback for receiving ERC721 tokens
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
