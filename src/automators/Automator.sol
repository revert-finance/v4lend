// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {Swapper} from "../utils/Swapper.sol";
import {Transformer, Ownable} from "../transformers/Transformer.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IV4Oracle} from "../interfaces/IV4Oracle.sol";

/// @title Automator
/// @notice Base contract for V4 position automation. Provides operator access control,
/// emergency withdrawal, and shared infrastructure for all automator contracts.
abstract contract Automator is Transformer, Swapper, IERC721Receiver, ReentrancyGuard {
    event OperatorChanged(address newOperator, bool active);
    event WithdrawerChanged(address newWithdrawer);
    event BalancesWithdrawn(address[] tokens, address to);
    event ETHWithdrawn(address to, uint256 amount);

    /// @notice Permit2 contract for token approvals
    IPermit2 public immutable permit2;

    /// @notice Oracle for chainlink-derived cross-token pricing
    IV4Oracle public immutable v4Oracle;

    /// @notice Authorized operators that can execute automations
    mapping(address => bool) public operators;

    /// @notice Address authorized to withdraw accumulated token balances
    address public withdrawer;

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address _withdrawer
    ) Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder) Ownable(msg.sender) {
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
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

    /// @notice Withdraws token balance
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

        emit BalancesWithdrawn(tokens, to);
    }

    /// @notice Withdraws ETH balance
    /// @param to Address to send to
    function withdrawETH(address to) external virtual {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool sent,) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
            emit ETHWithdrawn(to, balance);
        }
    }

    /// @notice Deducts protocol reward from amounts. Reward stays in contract for withdrawer.
    /// @param feeAmount0 Fee portion of token0
    /// @param feeAmount1 Fee portion of token1
    /// @param totalAmount0 Total token0 (fees + principal)
    /// @param totalAmount1 Total token1 (fees + principal)
    /// @param onlyFees If true, reward is calculated on fees only; otherwise on total
    /// @param rewardX64 Reward rate in Q64 format
    /// @return Remaining amounts after reward deduction (token0, token1)
    function _deductReward(
        uint256 feeAmount0,
        uint256 feeAmount1,
        uint256 totalAmount0,
        uint256 totalAmount1,
        bool onlyFees,
        uint64 rewardX64
    ) internal pure returns (uint256, uint256) {
        uint256 base0 = onlyFees ? feeAmount0 : totalAmount0;
        uint256 base1 = onlyFees ? feeAmount1 : totalAmount1;
        uint256 reward0 = base0 * rewardX64 / Q64;
        uint256 reward1 = base1 * rewardX64 / Q64;
        if (reward0 > totalAmount0) reward0 = totalAmount0;
        if (reward1 > totalAmount1) reward1 = totalAmount1;
        return (totalAmount0 - reward0, totalAmount1 - reward1);
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

    /// @notice Executes router swap and enforces oracle-based slippage floor when enabled.
    /// @dev The effective minimum output is max(user amountOutMin, oracle floor).
    function _routerSwapWithSlippageCheck(RouterSwapParams memory params, uint16 maxSwapSlippageBps)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (params.amountIn != 0) {
            if (maxSwapSlippageBps > 10000) {
                revert InvalidConfig();
            }
            if (maxSwapSlippageBps == 10000) {
                return _routerSwap(params);
            }
            uint160 oracleSqrtPriceX96 =
                v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(params.tokenIn), Currency.unwrap(params.tokenOut));
            uint256 oraclePriceX96 =
                FullMath.mulDiv(uint256(oracleSqrtPriceX96), uint256(oracleSqrtPriceX96), Q96);
            uint256 oracleOut = FullMath.mulDiv(params.amountIn, oraclePriceX96, Q96);
            uint256 oracleMinOut = FullMath.mulDiv(oracleOut, 10000 - uint256(maxSwapSlippageBps), 10000);
            if (oracleMinOut > params.amountOutMin) {
                params.amountOutMin = oracleMinOut;
            }
        }
        return _routerSwap(params);
    }

    /// @notice Callback for receiving ERC721 tokens
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
