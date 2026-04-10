// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {Swapper} from "../shared/swap/Swapper.sol";
import {Transformer} from "../vault/transformers/Transformer.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";

/// @title Automator
/// @notice Base contract for V4 position automation. Provides operator access control,
/// protocol fee routing, and shared infrastructure for all automator contracts.
abstract contract Automator is Transformer, Swapper, IERC721Receiver, ReentrancyGuard {
    event OperatorChanged(address newOperator, bool active);
    event ProtocolFeeRecipientChanged(address newProtocolFeeRecipient);

    /// @notice Permit2 contract for token approvals
    IPermit2 public immutable permit2;

    /// @notice Oracle for chainlink-derived cross-token pricing
    IV4Oracle public immutable v4Oracle;

    /// @notice Authorized operators that can execute automations
    mapping(address => bool) public operators;

    /// @notice Protocol fee recipient for automator fees
    address internal _protocolFeeRecipient;

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address protocolFeeRecipient_
    ) Swapper(_positionManager, _universalRouter, _zeroxAllowanceHolder) Ownable(msg.sender) {
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        setOperator(_operator, true);
        setProtocolFeeRecipient(protocolFeeRecipient_);
    }

    /// @notice Owner controlled function to activate/deactivate operator address
    /// @param _operator operator address
    /// @param _active active or not
    function setOperator(address _operator, bool _active) public onlyOwner {
        emit OperatorChanged(_operator, _active);
        operators[_operator] = _active;
    }

    /// @notice Owner controlled function to set protocol fee recipient
    function setProtocolFeeRecipient(address newProtocolFeeRecipient) public onlyOwner {
        if (newProtocolFeeRecipient == address(0)) {
            revert InvalidConfig();
        }
        emit ProtocolFeeRecipientChanged(newProtocolFeeRecipient);
        _protocolFeeRecipient = newProtocolFeeRecipient;
    }

    function protocolFeeRecipient() external view returns (address) {
        return _protocolFeeRecipient;
    }

    /// @notice Quotes protocol fees from two token amounts without transferring them.
    /// @dev When `onlyFees` is true, fees are charged from the fee portion only; otherwise from total proceeds.
    function _quoteProtocolFees(
        uint256 feeAmount0,
        uint256 feeAmount1,
        uint256 totalAmount0,
        uint256 totalAmount1,
        bool onlyFees,
        uint64 rewardX64
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        uint256 base0 = onlyFees ? feeAmount0 : totalAmount0;
        uint256 base1 = onlyFees ? feeAmount1 : totalAmount1;
        (uint256 netAmount0, uint256 protocolFee0) = _calculateProtocolFee(totalAmount0, base0, rewardX64);
        (uint256 netAmount1, uint256 protocolFee1) = _calculateProtocolFee(totalAmount1, base1, rewardX64);

        return (netAmount0, netAmount1, protocolFee0, protocolFee1);
    }

    function _availableBalance(Currency token, uint256 reservedAmount) internal view returns (uint256) {
        uint256 balance = token.balanceOfSelf();
        return balance > reservedAmount ? balance - reservedAmount : 0;
    }

    function _sendProtocolFee(Currency token, uint256 protocolFee) internal {
        _transferToken(_protocolFeeRecipient, token, protocolFee);
    }

    function _sendProtocolFees(Currency token0, Currency token1, uint256 protocolFee0, uint256 protocolFee1) internal {
        _sendProtocolFee(token0, protocolFee0);
        _sendProtocolFee(token1, protocolFee1);
    }

    function _calculateProtocolFee(uint256 totalAmount, uint256 feeBase, uint64 rewardX64)
        internal
        pure
        returns (uint256 netAmount, uint256 protocolFee)
    {
        protocolFee = feeBase * rewardX64 / Q64;
        if (protocolFee > totalAmount) {
            protocolFee = totalAmount;
        }

        netAmount = totalAmount - protocolFee;
    }

    /// @notice Transfers the position token to the recipient without changing its representation.
    /// @param to Recipient address
    /// @param token Token to transfer
    /// @param amount Amount to transfer
    function _transferToken(address to, Currency token, uint256 amount) internal {
        if (amount == 0) return;
        if (token.isAddressZero()) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            SafeERC20.safeTransfer(IERC20(Currency.unwrap(token)), to, amount);
        }
    }

    /// @notice Executes router swap and enforces oracle-based slippage floor when enabled.
    /// @dev The effective minimum output is max(user amountOutMin, oracle floor).
    ///      maxSwapSlippageBps == 10000 disables oracle slippage checks and relies only on amountOutMin.
    ///      This mode is intended for long-tail tokens/pairs that are not configured in V4Oracle.
    function _routerSwapWithSlippageCheck(RouterSwapParams memory params, uint16 maxSwapSlippageBps)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (params.amountIn > 0) {
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
