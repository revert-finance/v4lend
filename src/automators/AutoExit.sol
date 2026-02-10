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
        bool onlyFees,
        uint64 maxRewardX64
    );

    struct PositionConfig {
        bool isActive;
        bool token0Swap;
        bool token1Swap;
        int24 token0TriggerTick;
        int24 token1TriggerTick;
        bool onlyFees;
        uint64 maxRewardX64;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    struct ExecuteParams {
        uint256 tokenId;
        bytes swapData;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 amountOutMin;
        uint256 deadline;
        uint64 rewardX64;
        bytes hookData;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _operator, _withdrawer) {}

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
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
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

        // For vault positions, repay debt before swapping to ensure lend token is available
        address owner;
        if (isVaultCall) {
            IVault vault = IVault(msg.sender);
            owner = vault.ownerOf(params.tokenId);

            Currency lendToken = Currency.wrap(vault.asset());
            uint256 lendAmount;
            if (lendToken == token0) {
                lendAmount = amount0;
            } else if (lendToken == token1) {
                lendAmount = amount1;
            }

            if (lendAmount > 0) {
                (uint256 debt,,,,) = vault.loanInfo(params.tokenId);
                if (debt > 0) {
                    uint256 repayAmount = lendAmount > debt ? debt : lendAmount;
                    SafeERC20.forceApprove(IERC20(Currency.unwrap(lendToken)), msg.sender, repayAmount);
                    (uint256 repaid,) = vault.repay(params.tokenId, repayAmount, false);
                    if (lendToken == token0) {
                        amount0 -= repaid;
                    } else {
                        amount1 -= repaid;
                    }
                }
            }
        } else {
            owner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        }

        if (isSwap) {
            if (params.swapData.length == 0) {
                revert MissingSwapData();
            }

            // If onlyFees, deduct reward before swap (cap to remaining balance after debt repayment)
            if (config.onlyFees) {
                uint256 reward0 = feeAmount0 * params.rewardX64 / Q64;
                uint256 reward1 = feeAmount1 * params.rewardX64 / Q64;
                amount0 -= reward0 > amount0 ? amount0 : reward0;
                amount1 -= reward1 > amount1 ? amount1 : reward1;
            }

            uint256 swapAmount = isAbove ? amount1 : amount0;
            if (swapAmount != 0) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                    RouterSwapParams(
                        isAbove ? token1 : token0,
                        isAbove ? token0 : token1,
                        swapAmount,
                        params.amountOutMin,
                        params.swapData
                    )
                );

                amount0 = isAbove ? amount0 + amountOutDelta : amount0 - amountInDelta;
                amount1 = isAbove ? amount1 - amountInDelta : amount1 + amountOutDelta;
            }

            // When swap and !onlyFees - reward from target token only
            if (!config.onlyFees) {
                if (isAbove) {
                    amount0 -= amount0 * params.rewardX64 / Q64;
                } else {
                    amount1 -= amount1 * params.rewardX64 / Q64;
                }
            }
        } else {
            // No swap - reward from configured source (cap to remaining balance after debt repayment)
            uint256 reward0 = (config.onlyFees ? feeAmount0 : amount0) * params.rewardX64 / Q64;
            uint256 reward1 = (config.onlyFees ? feeAmount1 : amount1) * params.rewardX64 / Q64;
            amount0 -= reward0 > amount0 ? amount0 : reward0;
            amount1 -= reward1 > amount1 ? amount1 : reward1;
        }

        // Send remaining tokens to owner
        _transferToken(owner, token0, amount0, true);
        _transferToken(owner, token1, amount1, true);

        // Delete config
        delete positionConfigs[params.tokenId];
        emit PositionConfigured(params.tokenId, false, false, false, 0, 0, false, 0);

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

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.token0Swap,
            config.token1Swap,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.onlyFees,
            config.maxRewardX64
        );
    }
}
