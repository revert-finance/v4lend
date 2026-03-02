// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IVault} from "../interfaces/IVault.sol";
import {IV4Oracle} from "../interfaces/IV4Oracle.sol";
import {Automator} from "./Automator.sol";

/// @title AutoExit
/// @notice Lets a V4 position be automatically removed (limit order) or swapped to the opposite token
/// (stop loss order) when it reaches a certain tick.
/// Positions need to be approved (approve or setApprovalForAll) for the contract and configured with configToken method.
contract AutoExit is Automator {
    event AutoExit(
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
        uint16 token0SlippageBps;
        uint16 token1SlippageBps;
        uint64 maxRewardX64;
        bool onlyFees;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    struct ExecuteParams {
        uint256 tokenId;
        bytes swapData;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 amountOutMin;
        uint256 deadline;
        bytes hookData;
        uint64 rewardX64;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _v4Oracle, _operator, _withdrawer) {}

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

        // Check trigger condition
        if (config.token0TriggerTick <= tick && tick < config.token1TriggerTick) {
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

        uint256 amount0 = feeAmount0 + liquidityAmount0;
        uint256 amount1 = feeAmount1 + liquidityAmount1;

        // Deduct protocol reward (stays in contract for withdrawer)
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }
        (amount0, amount1) = _deductReward(feeAmount0, feeAmount1, amount0, amount1, config.onlyFees, params.rewardX64);

        // Resolve owner; for vault positions, repay debt before swap
        address owner;
        if (isVaultCall) {
            IVault vault = IVault(msg.sender);
            owner = vault.ownerOf(params.tokenId);
            Currency lendToken = Currency.wrap(vault.asset());

            // Vault asset must be one of the pool tokens for debt repayment to work
            if (!(lendToken == token0) && !(lendToken == token1)) {
                revert InvalidConfig();
            }

            // Swap sells (isAbove ? token1 : token0) and buys the other
            // Repay before swap when lend token is on the sell side (or no swap)
            bool repayBeforeSwap = !isSwap || (isAbove ? (lendToken == token1) : (lendToken == token0));
            if (repayBeforeSwap) {
                (amount0, amount1) =
                    _repayVaultDebt(vault, params.tokenId, lendToken, token0, token1, amount0, amount1);
            }
        } else {
            owner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        }

        if (isSwap) {
            if (params.swapData.length == 0) {
                revert MissingSwapData();
            }

            uint256 swapAmount = isAbove ? amount1 : amount0;
            if (swapAmount != 0) {
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

                amount0 = isAbove ? amount0 + amountOutDelta : amount0 - amountInDelta;
                amount1 = isAbove ? amount1 - amountInDelta : amount1 + amountOutDelta;
            }
        }

        // Post-swap repayment: when swap produced the lend token, repay remaining debt
        if (isVaultCall) {
            IVault vault = IVault(msg.sender);
            Currency lendToken = Currency.wrap(vault.asset());
            bool repayAfterSwap = isSwap && (isAbove ? (lendToken == token0) : (lendToken == token1));
            if (repayAfterSwap) {
                (amount0, amount1) =
                    _repayVaultDebt(vault, params.tokenId, lendToken, token0, token1, amount0, amount1);
            }
        }

        // Send remaining tokens to owner
        _transferToken(owner, token0, amount0, true);
        _transferToken(owner, token1, amount1, true);

        // Delete config
        delete positionConfigs[params.tokenId];
        emit PositionConfigured(params.tokenId, false, false, false, 0, 0, 0, 0, 0, false);

        emit AutoExit(
            params.tokenId,
            msg.sender,
            isSwap,
            amount0,
            amount1,
            Currency.unwrap(token0),
            Currency.unwrap(token1)
        );
    }

    function _repayVaultDebt(
        IVault vault,
        uint256 tokenId,
        Currency lendToken,
        Currency token0,
        Currency token1,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        uint256 lendAmount;
        if (lendToken == token0) {
            lendAmount = amount0;
        } else if (lendToken == token1) {
            lendAmount = amount1;
        }

        if (lendAmount > 0) {
            (uint256 debt,,,,) = vault.loanInfo(tokenId);
            if (debt > 0) {
                uint256 repayAmount = lendAmount > debt ? debt : lendAmount;
                SafeERC20.forceApprove(IERC20(Currency.unwrap(lendToken)), address(vault), repayAmount);
                (uint256 repaid,) = vault.repay(tokenId, repayAmount, false);
                if (lendToken == token0) {
                    amount0 -= repaid;
                } else {
                    amount1 -= repaid;
                }
            }
        }

        return (amount0, amount1);
    }

    /// @notice Configure a token for auto-exit
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
