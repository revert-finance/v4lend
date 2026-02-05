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
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../interfaces/IVault.sol";
import {Automator} from "./Automator.sol";

/// @title AutoLeverage
/// @notice Automatically rebalances leverage ratio when price moves.
/// Operator-triggered, works through vault.transform() for vault-owned positions.
contract AutoLeverage is Automator {
    event AutoLeveraged(uint256 indexed tokenId, bool leverageUp, uint256 debtBefore, uint256 debtAfter);
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        uint16 targetLeverageBps,
        uint16 rebalanceThresholdBps,
        bool onlyFees,
        uint64 maxRewardX64
    );

    struct PositionConfig {
        bool isActive;
        uint16 targetLeverageBps;
        uint16 rebalanceThresholdBps;
        bool onlyFees;
        uint64 maxRewardX64;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    struct ExecuteParams {
        uint256 tokenId;
        address vault;
        bool leverageUp;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 deadline;
        uint64 rewardX64;
        bytes decreaseLiquidityHookData;
        bytes increaseLiquidityHookData;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _operator, _withdrawer) {}

    /// @notice Execute leverage rebalancing (always via vault.transform)
    function execute(ExecuteParams calldata params) external {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }
        if (!vaults[params.vault]) {
            revert Unauthorized();
        }

        IVault(params.vault).transform(
            params.tokenId, address(this), abi.encodeCall(AutoLeverage._execute, (params))
        );
    }

    /// @notice Internal execution called from vault.transform()
    function _execute(ExecuteParams calldata params) external nonReentrant {
        _validateCaller(positionManager, params.tokenId);

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        IVault vault = IVault(msg.sender);
        (uint256 currentDebt,, uint256 collateralValue,,) = vault.loanInfo(params.tokenId);

        // Check if rebalancing is needed
        uint256 currentRatio = collateralValue > 0 ? currentDebt * 10000 / collateralValue : 0;
        uint256 targetRatio = uint256(config.targetLeverageBps);
        uint256 threshold = uint256(config.rebalanceThresholdBps);

        if (currentRatio > targetRatio - threshold && currentRatio < targetRatio + threshold) {
            revert NotReady();
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;
        Currency lendToken = Currency.wrap(vault.asset());

        // Collect fees first and track amounts
        (uint256 feeAmount0, uint256 feeAmount1) = _decreaseLiquidity(
            params.tokenId, 0, 0, 0, params.deadline, params.decreaseLiquidityHookData
        );

        if (params.leverageUp) {
            _leverageUp(params, vault, poolKey, positionInfo, token0, token1, lendToken, currentDebt, collateralValue, config, feeAmount0, feeAmount1);
        } else {
            _leverageDown(params, vault, token0, token1, lendToken, currentDebt, collateralValue, config, feeAmount0, feeAmount1);
        }

        (uint256 newDebt,,,,) = vault.loanInfo(params.tokenId);
        emit AutoLeveraged(params.tokenId, params.leverageUp, currentDebt, newDebt);
    }

    function _leverageUp(
        ExecuteParams calldata params,
        IVault vault,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        Currency token0,
        Currency token1,
        Currency lendToken,
        uint256 currentDebt,
        uint256 collateralValue,
        PositionConfig memory config,
        uint256 feeAmount0,
        uint256 feeAmount1
    ) internal {
        uint16 targetBps = config.targetLeverageBps;
        if (currentDebt * 10000 >= collateralValue * targetBps) return;

        uint256 denominator = 10000 - uint256(targetBps);
        if (denominator == 0) return;

        uint256 borrowAmount = (uint256(targetBps) * collateralValue - currentDebt * 10000) / denominator;
        if (borrowAmount == 0) return;

        // Borrow from vault
        vault.borrow(params.tokenId, borrowAmount);

        uint256 amount0 = token0.balanceOfSelf();
        uint256 amount1 = token1.balanceOfSelf();

        // Swap borrowed lend token to position tokens
        if (params.amountIn0 != 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(lendToken, token0, params.amountIn0, params.amountOut0Min, params.swapData0)
            );
            if (lendToken == token1) amount1 -= amountIn;
            amount0 += amountOut;
        }
        if (params.amountIn1 != 0) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(lendToken, token1, params.amountIn1, params.amountOut1Min, params.swapData1)
            );
            if (lendToken == token0) amount0 -= amountIn;
            amount1 += amountOut;
        }

        // Deduct reward before adding liquidity
        if (config.onlyFees) {
            // Reward only from collected fees
            uint256 reward0 = feeAmount0 * params.rewardX64 / Q64;
            uint256 reward1 = feeAmount1 * params.rewardX64 / Q64;
            if (reward0 > amount0) reward0 = amount0;
            if (reward1 > amount1) reward1 = amount1;
            amount0 -= reward0;
            amount1 -= reward1;
        } else {
            // Reward from total amounts
            amount0 = _deductReward(amount0, params.rewardX64);
            amount1 = _deductReward(amount1, params.rewardX64);
        }

        // Increase liquidity
        _handleApproval(permit2, token0, amount0);
        _handleApproval(permit2, token1, amount1);

        uint128 liquidity = _calculateLiquidity(
            positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1
        );

        (bytes memory actions, bytes[] memory params_array) =
            _buildActionsForIncreasingLiquidity(uint8(Actions.INCREASE_LIQUIDITY), token0, token1);
        params_array[0] = abi.encode(
            params.tokenId, liquidity, type(uint128).max, type(uint128).max, params.increaseLiquidityHookData
        );

        positionManager.modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, params_array), params.deadline
        );

        // Send leftover to owner
        address owner = vault.ownerOf(params.tokenId);
        _transferToken(owner, token0, token0.balanceOfSelf(), true);
        _transferToken(owner, token1, token1.balanceOfSelf(), true);
    }

    function _leverageDown(
        ExecuteParams calldata params,
        IVault vault,
        Currency token0,
        Currency token1,
        Currency lendToken,
        uint256 currentDebt,
        uint256 collateralValue,
        PositionConfig memory config,
        uint256 feeAmount0,
        uint256 feeAmount1
    ) internal {
        uint16 targetBps = config.targetLeverageBps;
        if (currentDebt * 10000 <= collateralValue * targetBps) return;

        uint256 denominator = 10000 - uint256(targetBps);
        if (denominator == 0) return;

        uint256 repayAmount = (currentDebt * 10000 - uint256(targetBps) * collateralValue) / denominator;

        uint128 currentLiquidity = positionManager.getPositionLiquidity(params.tokenId);
        if (currentLiquidity == 0) return;

        // Calculate proportional liquidity to remove
        // Use collateralValue as proxy for total position value
        uint128 liquidityToRemove;
        if (collateralValue > 0) {
            liquidityToRemove = uint128(uint256(currentLiquidity) * repayAmount / collateralValue);
        }
        if (liquidityToRemove > currentLiquidity) liquidityToRemove = currentLiquidity;
        if (liquidityToRemove == 0) return;

        // Remove partial liquidity
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            params.tokenId,
            liquidityToRemove,
            params.amountRemoveMin0,
            params.amountRemoveMin1,
            params.deadline,
            params.decreaseLiquidityHookData
        );

        // Swap position tokens to lend token
        uint256 lendAmount = lendToken == token0 ? amount0 : (lendToken == token1 ? amount1 : 0);

        if (params.amountIn0 != 0 && !(lendToken == token0)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(token0, lendToken, params.amountIn0, params.amountOut0Min, params.swapData0)
            );
            amount0 -= amountIn;
            lendAmount += amountOut;
        }
        if (params.amountIn1 != 0 && !(lendToken == token1)) {
            (uint256 amountIn, uint256 amountOut) = _routerSwap(
                RouterSwapParams(token1, lendToken, params.amountIn1, params.amountOut1Min, params.swapData1)
            );
            amount1 -= amountIn;
            lendAmount += amountOut;
        }

        // Deduct reward
        if (config.onlyFees) {
            // Reward only from fee portion in lend token
            uint256 feeReward;
            if (Currency.unwrap(lendToken) == Currency.unwrap(token0)) {
                feeReward = feeAmount0 * params.rewardX64 / Q64;
            } else if (Currency.unwrap(lendToken) == Currency.unwrap(token1)) {
                feeReward = feeAmount1 * params.rewardX64 / Q64;
            }
            if (feeReward > lendAmount) feeReward = lendAmount;
            lendAmount -= feeReward;
        } else {
            lendAmount = _deductReward(lendAmount, params.rewardX64);
        }

        // Repay debt
        if (lendAmount > 0) {
            if (lendAmount > currentDebt) lendAmount = currentDebt;
            SafeERC20.forceApprove(IERC20(Currency.unwrap(lendToken)), address(vault), lendAmount);
            vault.repay(params.tokenId, lendAmount, false);
        }

        // Send leftover to owner
        address owner = vault.ownerOf(params.tokenId);
        _transferToken(owner, token0, token0.balanceOfSelf(), true);
        _transferToken(owner, token1, token1.balanceOfSelf(), true);
    }

    function _deductReward(uint256 amount, uint64 rewardX64) internal pure returns (uint256) {
        if (rewardX64 == 0 || amount == 0) return amount;
        return amount - (amount * rewardX64 / Q64);
    }

    /// @notice Position owner configures auto-leverage
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        if (config.isActive) {
            if (config.targetLeverageBps > 9900) {
                revert InvalidConfig();
            }
            if (config.rebalanceThresholdBps == 0) {
                revert InvalidConfig();
            }
        }

        // Must be vault-owned position
        address posOwner = IERC721(address(positionManager)).ownerOf(tokenId);
        if (!vaults[posOwner]) {
            revert Unauthorized();
        }
        address realOwner = IVault(posOwner).ownerOf(tokenId);
        if (realOwner != msg.sender) {
            revert Unauthorized();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.targetLeverageBps,
            config.rebalanceThresholdBps,
            config.onlyFees,
            config.maxRewardX64
        );
    }
}
