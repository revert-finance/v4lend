// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {Automator} from "./Automator.sol";

/// @title AutoExit
/// @notice Lets a V4 position be automatically removed (limit order) or swapped to the opposite token
/// (stop loss order) when it reaches a certain tick.
/// Positions need to be approved (approve or setApprovalForAll) for the contract and configured with configToken method.
contract AutoExit is Automator {
    event AutoExitExecuted(
        uint256 indexed tokenId,
        address account,
        bool isSwap,
        uint256 amountReturned0,
        uint256 amountReturned1,
        address token0,
        address token1
    );
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint16 token0SlippageBps,
        uint16 token1SlippageBps,
        uint64 maxRewardX64,
        bool onlyFees
    );

    struct PositionConfig {
        bool isActive;
        bool token0Swap;
        bool token1Swap;
        int24 token0TriggerTick;
        int24 token1TriggerTick;
        uint16 token0SlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint16 token1SlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint64 maxRewardX64;
        bool onlyFees;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    struct ExecuteParams {
        uint256 tokenId;
        // exit-direction swap: sells the triggered side into the other token
        bytes swapData;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 amountOutMin;
        uint256 deadline;
        bytes hookData;
        uint64 rewardX64;
        // vault positions only: route from the non-lend leg into the lend token, used before the exit swap
        // when the lend leg (net proceeds plus its reserved reward) does not cover the debt. Capped to that
        // leg's gross proceeds; its net proceeds are consumed first, its reserved reward only for the rest.
        uint256 repayAmountIn;
        uint256 repayAmountOutMin;
        bytes repaySwapData;
    }

    struct ExecuteState {
        uint256 amount0;
        uint256 amount1;
        uint256 protocolFee0;
        uint256 protocolFee1;
        address owner;
        Currency lendToken;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address protocolFeeRecipient_
    )
        Automator(
            _positionManager,
            _universalRouter,
            _zeroxAllowanceHolder,
            _permit2,
            _v4Oracle,
            _operator,
            protocolFeeRecipient_
        )
    {}

    /// @notice Execute exit for a vault-owned position
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(params.tokenId, address(this), abi.encodeCall(this.execute, (params)));
    }

    /// @notice Handle token exit (must be in correct state)
    function execute(ExecuteParams calldata params) external nonReentrant {
        bool isVaultCall = vaults[msg.sender];
        if (!operators[msg.sender] && !isVaultCall) {
            revert Unauthorized();
        }
        if (isVaultCall) {
            _validateCaller(positionManager, params.tokenId);
        } else {
            // Vault-owned positions must use executeWithVault to ensure debt repayment
            address posOwner = IERC721(address(positionManager)).ownerOf(params.tokenId);
            if (vaults[posOwner]) {
                revert Unauthorized();
            }
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;

        uint128 liquidity = positionManager.getPositionLiquidity(params.tokenId);
        if (liquidity == 0) {
            revert NoLiquidity();
        }

        // Get current tick
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));

        // Check trigger condition: the lower trigger is reached at or below its tick, the upper one
        // at or above, matching the hook's inclusive trigger evaluation on both sides.
        if (config.token0TriggerTick < tick && tick < config.token1TriggerTick) {
            revert NotReady();
        }

        bool isAbove = tick >= config.token1TriggerTick;
        bool isSwap = (!isAbove && config.token0Swap) || (isAbove && config.token1Swap);

        // Collect fees first (decrease by 0), then remove all liquidity
        (uint256 feeAmount0, uint256 feeAmount1) =
            _decreaseLiquidity(params.tokenId, 0, 0, 0, params.deadline, params.hookData);
        (uint256 liquidityAmount0, uint256 liquidityAmount1) = _decreaseLiquidity(
            params.tokenId, liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline, params.hookData
        );

        ExecuteState memory state;
        state.amount0 = feeAmount0 + liquidityAmount0;
        state.amount1 = feeAmount1 + liquidityAmount1;

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }
        (state.amount0, state.amount1, state.protocolFee0, state.protocolFee1) =
            _quoteProtocolFees(feeAmount0, feeAmount1, state.amount0, state.amount1, config.onlyFees, params.rewardX64);
        state.amount0 = _netBalanceAfterReserved(token0, state.protocolFee0);
        state.amount1 = _netBalanceAfterReserved(token1, state.protocolFee1);

        // Resolve owner; for vault positions, settle the debt before the exit swap
        if (isVaultCall) {
            IVault vault = IVault(msg.sender);
            state.owner = vault.ownerOf(params.tokenId);
            state.lendToken = Currency.wrap(vault.asset());

            // The vault asset must be one of the pool tokens only when there is debt to repay: a
            // zero-debt loan in any accepted collateral pair exits with its tokens sent to the owner.
            if (!(state.lendToken == token0) && !(state.lendToken == token1)) {
                (uint256 debt,,,,) = vault.loanInfo(params.tokenId);
                if (debt > 0) {
                    revert InvalidConfig();
                }
            } else {
                _settleVaultDebt(params, config, vault, token0, token1, state);
            }
        } else {
            state.owner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        }

        if (isSwap) {
            if (params.swapData.length == 0) {
                revert MissingSwapData();
            }

            uint256 swapAmount = isAbove ? state.amount1 : state.amount0;
            if (swapAmount > 0) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwapWithSlippageCheck(
                    RouterSwapParams(
                        isAbove ? token1 : token0,
                        isAbove ? token0 : token1,
                        swapAmount,
                        params.amountOutMin,
                        params.swapData
                    ),
                    isAbove ? config.token1SlippageBps : config.token0SlippageBps
                );

                state.amount0 = isAbove ? state.amount0 + amountOutDelta : state.amount0 - amountInDelta;
                state.amount1 = isAbove ? state.amount1 - amountInDelta : state.amount1 + amountOutDelta;
            }
        }

        // Post-swap repayment: when the exit swap produced the lend token, repay any remaining debt
        if (isVaultCall) {
            bool repayAfterSwap =
                isSwap && (isAbove ? (state.lendToken == token0) : (state.lendToken == token1));
            if (repayAfterSwap) {
                _repayVaultDebt(IVault(msg.sender), params.tokenId, token0, token1, state);
            }
        }

        // Delete config
        delete positionConfigs[params.tokenId];
        emit PositionConfigured(params.tokenId, false, false, false, 0, 0, 0, 0, 0, false);

        // Send remaining tokens after state is finalized.
        _sendProtocolFees(token0, token1, state.protocolFee0, state.protocolFee1);
        (state.amount0, state.amount1) = _sendRemainingBalances(state.owner, token0, token1);

        emit AutoExitExecuted(
            params.tokenId,
            msg.sender,
            isSwap,
            state.amount0,
            state.amount1,
            Currency.unwrap(token0),
            Currency.unwrap(token1)
        );
    }

    /// @dev Settles the vault debt before the exit-direction swap, with the same seniority as the hook's
    ///      own auto-exit: the debt comes first, from both legs, ahead of the exit direction and of the
    ///      reward. When the lend leg (net proceeds plus its reserved reward) cannot cover the debt, the
    ///      other leg is converted into the lend token through the operator's repay route (V4LE-134: the
    ///      exit swap runs away from the lend token when it sits on the sold side; V4LE-102/100: the
    ///      reward reserved in the sold leg was never reachable for a lend-side shortfall). That leg's
    ///      net proceeds are consumed first and its reserved reward only for the remainder, reducing the
    ///      reward by exactly what the debt needed. The exit swap then consolidates what is left.
    function _settleVaultDebt(
        ExecuteParams calldata params,
        PositionConfig memory config,
        IVault vault,
        Currency token0,
        Currency token1,
        ExecuteState memory state
    ) internal {
        (uint256 debt,,,,) = vault.loanInfo(params.tokenId);
        if (debt == 0) {
            return;
        }
        bool lendIsToken0 = state.lendToken == token0;
        uint256 lendGross = lendIsToken0 ? state.amount0 + state.protocolFee0 : state.amount1 + state.protocolFee1;

        if (lendGross < debt && params.repayAmountIn > 0) {
            uint256 otherNet = lendIsToken0 ? state.amount1 : state.amount0;
            uint256 otherReserved = lendIsToken0 ? state.protocolFee1 : state.protocolFee0;
            uint256 amountIn = params.repayAmountIn;
            if (amountIn > otherNet + otherReserved) {
                amountIn = otherNet + otherReserved;
            }
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwapWithSlippageCheck(
                RouterSwapParams(
                    lendIsToken0 ? token1 : token0,
                    state.lendToken,
                    amountIn,
                    params.repayAmountOutMin,
                    params.repaySwapData
                ),
                lendIsToken0 ? config.token1SlippageBps : config.token0SlippageBps
            );
            uint256 fromNet = amountInDelta > otherNet ? otherNet : amountInDelta;
            uint256 fromReward = amountInDelta - fromNet;
            if (lendIsToken0) {
                state.amount1 = otherNet - fromNet;
                state.protocolFee1 = otherReserved - fromReward;
                state.amount0 += amountOutDelta;
            } else {
                state.amount0 = otherNet - fromNet;
                state.protocolFee0 = otherReserved - fromReward;
                state.amount1 += amountOutDelta;
            }
        }

        _repayVaultDebt(vault, params.tokenId, token0, token1, state);
    }

    /// @dev Settles the vault debt from the lend-token proceeds. The debt is senior to the automation
    ///      reward: when the proceeds net of the reserved reward do not cover it, the reward reserved in
    ///      the lend token pays the remainder and is reduced by exactly that amount. Without this a
    ///      loan with net proceeds below the debt but gross proceeds above it could not be exited at
    ///      all (the vault's final health check rejects an emptied position with debt left).
    function _repayVaultDebt(
        IVault vault,
        uint256 tokenId,
        Currency token0,
        Currency token1,
        ExecuteState memory state
    ) internal {
        bool lendIsToken0 = state.lendToken == token0;
        if (!lendIsToken0 && !(state.lendToken == token1)) {
            return;
        }
        uint256 lendAmount = lendIsToken0 ? state.amount0 : state.amount1;
        uint256 reserved = lendIsToken0 ? state.protocolFee0 : state.protocolFee1;

        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        if (debt == 0) {
            return;
        }
        uint256 repayAmount = lendAmount > debt ? debt : lendAmount;
        if (repayAmount < debt && reserved > 0) {
            uint256 shortfall = debt - repayAmount;
            repayAmount += shortfall > reserved ? reserved : shortfall;
        }
        if (repayAmount == 0) {
            return;
        }

        SafeERC20.forceApprove(IERC20(Currency.unwrap(state.lendToken)), address(vault), repayAmount);
        (uint256 repaid,) = vault.repay(tokenId, repayAmount, false);
        // reset any residual allowance (repay caps to outstanding debt, so a remainder can linger)
        SafeERC20.forceApprove(IERC20(Currency.unwrap(state.lendToken)), address(vault), 0);

        // the net proceeds pay first, the reserved reward covers the rest
        uint256 fromNet = repaid > lendAmount ? lendAmount : repaid;
        uint256 fromReward = repaid - fromNet;
        if (lendIsToken0) {
            state.amount0 = lendAmount - fromNet;
            state.protocolFee0 = reserved - fromReward;
        } else {
            state.amount1 = lendAmount - fromNet;
            state.protocolFee1 = reserved - fromReward;
        }
    }

    /// @notice Configure a token for auto-exit
    /// @dev Set token{0,1}SlippageBps to 10000 to allow automation for pairs without oracle support.
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        if (config.isActive) {
            if (config.token0TriggerTick >= config.token1TriggerTick) {
                revert InvalidConfig();
            }
        }

        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        if (vaults[owner]) {
            owner = IVault(owner).ownerOf(tokenId);
        }
        if (owner != msg.sender) {
            revert Unauthorized();
        }
        if (config.token0SlippageBps > 10000 || config.token1SlippageBps > 10000) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.token0Swap,
            config.token1Swap,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.token0SlippageBps,
            config.token1SlippageBps,
            config.maxRewardX64,
            config.onlyFees
        );
    }
}
