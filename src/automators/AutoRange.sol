// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../interfaces/IVault.sol";
import {Automator} from "./Automator.sol";

/// @title AutoRange
/// @notice Allows operator to change range for configured positions.
/// When executed, a new position is created and automatically configured the same way as the original position.
/// Positions need to be approved (setApprovalForAll) for the contract and configured with configToken method.
contract AutoRange is Automator {
    event AutoRange(uint256 indexed oldTokenId, uint256 indexed newTokenId);
    event PositionConfigured(
        uint256 indexed tokenId,
        int32 lowerTickLimit,
        int32 upperTickLimit,
        int32 lowerTickDelta,
        int32 upperTickDelta,
        bool onlyFees,
        uint64 maxRewardX64
    );

    struct PositionConfig {
        int32 lowerTickLimit;
        int32 upperTickLimit;
        int32 lowerTickDelta;
        int32 upperTickDelta;
        bool onlyFees;
        uint64 maxRewardX64;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    struct ExecuteParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        uint256 deadline;
        uint64 rewardX64;
        bytes decreaseLiquidityHookData;
        bytes mintHookData;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _operator, _withdrawer) {}

    /// @notice Execute range change for a vault-owned position
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(params.tokenId, address(this), abi.encodeCall(this.execute, (params)));
    }

    /// @notice Execute range change
    function execute(ExecuteParams calldata params) external nonReentrant {
        bool isVaultCall = vaults[msg.sender];
        if (!operators[msg.sender] && !isVaultCall) {
            revert Unauthorized();
        }
        if (isVaultCall) {
            _validateCaller(positionManager, params.tokenId);
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (config.lowerTickDelta == 0 && config.upperTickDelta == 0) {
            revert NotConfigured();
        }
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);

        _executeRangeChange(params, config, poolKey, positionInfo);
    }

    function _executeRangeChange(
        ExecuteParams calldata params,
        PositionConfig memory config,
        PoolKey memory poolKey,
        PositionInfo positionInfo
    ) internal {
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;
        int24 tickSpacing = poolKey.tickSpacing;

        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();

        // Check if position is out of range enough
        if (
            (config.lowerTickLimit == 0 || currentTick >= tickLower - int24(config.lowerTickLimit))
                && (config.upperTickLimit == 0 || currentTick <= tickUpper + int24(config.upperTickLimit))
        ) {
            // Check if within negative limits (allows in-range adjustment)
            if (config.lowerTickLimit >= 0 && config.upperTickLimit >= 0) {
                revert NotReady();
            }
            // Negative limits allow in-range re-ranging - check those conditions
            if (
                config.lowerTickLimit < 0 && currentTick < tickLower - int24(config.lowerTickLimit)
            ) {
                // ok - below lower limit
            } else if (
                config.upperTickLimit < 0 && currentTick > tickUpper + int24(config.upperTickLimit)
            ) {
                // ok - above upper limit
            } else {
                revert NotReady();
            }
        }

        // Calculate new range
        int24 baseTick = (currentTick / tickSpacing) * tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            baseTick -= tickSpacing;
        }
        int24 newTickLower = baseTick + int24(config.lowerTickDelta);
        int24 newTickUpper = baseTick + int24(config.upperTickDelta);

        if (newTickLower == tickLower && newTickUpper == tickUpper) {
            revert SameRange();
        }

        // Get full liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(params.tokenId);

        // Step 1: Collect fees only (0 liquidity decrease)
        (uint256 feeAmount0, uint256 feeAmount1) = _decreaseLiquidity(
            params.tokenId, 0, 0, 0, params.deadline, params.decreaseLiquidityHookData
        );

        // Step 2: Remove all liquidity (fees already collected above)
        (uint256 liquidityAmount0, uint256 liquidityAmount1) = _decreaseLiquidity(
            params.tokenId,
            liquidity,
            params.amountRemoveMin0,
            params.amountRemoveMin1,
            params.deadline,
            params.decreaseLiquidityHookData
        );

        uint256 amount0 = feeAmount0 + liquidityAmount0;
        uint256 amount1 = feeAmount1 + liquidityAmount1;

        // Deduct reward — onlyFees takes reward from fees only, otherwise from total
        uint256 protocolReward0;
        uint256 protocolReward1;
        if (config.onlyFees) {
            protocolReward0 = feeAmount0 * params.rewardX64 / Q64;
            protocolReward1 = feeAmount1 * params.rewardX64 / Q64;
        } else {
            protocolReward0 = amount0 * params.rewardX64 / Q64;
            protocolReward1 = amount1 * params.rewardX64 / Q64;
        }
        amount0 -= protocolReward0;
        amount1 -= protocolReward1;

        // Swap to rebalance for new range
        if (params.amountIn != 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                RouterSwapParams(
                    params.swap0To1 ? token0 : token1,
                    params.swap0To1 ? token1 : token0,
                    params.amountIn,
                    params.amountOutMin,
                    params.swapData
                )
            );
            if (params.swap0To1) {
                amount0 -= amountInDelta;
                amount1 += amountOutDelta;
            } else {
                amount1 -= amountInDelta;
                amount0 += amountOutDelta;
            }
        }

        // Mint new position
        uint256 newTokenId = _mintNewPosition(
            params, poolKey, token0, token1, newTickLower, newTickUpper, amount0, amount1
        );

        // Get owner for sending leftover tokens
        address owner;
        if (vaults[msg.sender]) {
            owner = IVault(msg.sender).ownerOf(params.tokenId);
            // Send new NFT to vault (vault's onERC721Received handles position replacement)
            IERC721(address(positionManager)).safeTransferFrom(address(this), msg.sender, newTokenId);
        } else {
            owner = IERC721(address(positionManager)).ownerOf(params.tokenId);
            // Send new NFT to owner (use transferFrom - owner may not implement onERC721Received)
            IERC721(address(positionManager)).transferFrom(address(this), owner, newTokenId);
        }

        // Copy config and delete old
        positionConfigs[newTokenId] = config;
        delete positionConfigs[params.tokenId];

        // Send leftover tokens to owner
        uint256 leftover0 = token0.balanceOfSelf();
        uint256 leftover1 = token1.balanceOfSelf();
        _transferToken(owner, token0, leftover0, true);
        _transferToken(owner, token1, leftover1, true);

        emit AutoRange(params.tokenId, newTokenId);
    }

    function _mintNewPosition(
        ExecuteParams calldata params,
        PoolKey memory poolKey,
        Currency token0,
        Currency token1,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 newTokenId) {
        _handleApproval(permit2, token0, amount0);
        _handleApproval(permit2, token1, amount1);

        uint128 liquidity = _calculateLiquidity(tickLower, tickUpper, poolKey, amount0, amount1);

        // Track balances before mint to calculate actual amounts added
        uint256 balance0Before = token0.balanceOfSelf();
        uint256 balance1Before = token1.balanceOfSelf();

        (bytes memory actions, bytes[] memory params_array) =
            _buildActionsForIncreasingLiquidity(uint8(Actions.MINT_POSITION), token0, token1);
        params_array[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), params.mintHookData
        );

        positionManager.modifyLiquidities{value: _getNativeAmount(token0, token1, amount0, amount1)}(
            abi.encode(actions, params_array), params.deadline
        );

        newTokenId = positionManager.nextTokenId() - 1;

        // Check minimum amounts added (using delta to handle protocol reward in balance)
        uint256 added0 = balance0Before - token0.balanceOfSelf();
        uint256 added1 = balance1Before - token1.balanceOfSelf();
        if (added0 < params.amountAddMin0 || added1 < params.amountAddMin1) {
            revert InsufficientAmountAdded();
        }
    }

    /// @notice Configure a token for auto-range
    function configToken(uint256 tokenId, address vault, PositionConfig calldata config) external {
        _validateOwner(positionManager, tokenId, vault);

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.lowerTickLimit,
            config.upperTickLimit,
            config.lowerTickDelta,
            config.upperTickDelta,
            config.onlyFees,
            config.maxRewardX64
        );
    }
}
