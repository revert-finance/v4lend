// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoRangeLib} from "../shared/planning/AutoRangeLib.sol";
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
        uint16 token0SlippageBps,
        uint16 token1SlippageBps,
        uint64 maxRewardX64,
        bool onlyFees
    );

    struct PositionConfig {
        int32 lowerTickLimit;
        int32 upperTickLimit;
        int32 lowerTickDelta;
        int32 upperTickDelta;
        uint16 token0SlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint16 token1SlippageBps; // 10000 disables oracle slippage check (uses only amountOutMin)
        uint64 maxRewardX64;
        bool onlyFees;
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
        bytes decreaseLiquidityHookData;
        bytes mintHookData;
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
        } else {
            // Vault-owned positions must use executeWithVault to ensure proper handling
            address posOwner = IERC721(address(positionManager)).ownerOf(params.tokenId);
            if (vaults[posOwner]) {
                revert Unauthorized();
            }
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (config.lowerTickDelta == 0 && config.upperTickDelta == 0) {
            revert NotConfigured();
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

        // Snapshot balances before any operation to isolate this execution's tokens
        uint256 balance0Before = token0.balanceOfSelf();
        uint256 balance1Before = token1.balanceOfSelf();

        // Reuse the current slot0 for both planning and liquidity math.
        (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();

        // Check if position is out of range enough
        if (
            !AutoRangeLib.isReady(
                currentTick,
                tickLower,
                tickUpper,
                int24(config.lowerTickLimit),
                int24(config.upperTickLimit)
            )
        ) {
            revert NotReady();
        }

        // Calculate new range
        (int24 newTickLower, int24 newTickUpper) = AutoRangeLib.plan(
            currentTick,
            poolKey.tickSpacing,
            int24(config.lowerTickDelta),
            int24(config.upperTickDelta)
        );

        if (!AutoRangeLib.isValidRange(newTickLower, newTickUpper)) {
            revert InvalidConfig();
        }
        if (AutoRangeLib.isSameRange(tickLower, tickUpper, newTickLower, newTickUpper)) {
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

        // Deduct protocol reward (stays in contract for withdrawer)
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }
        // Track rewards by updating balance snapshots — adding reward to "before" baseline
        // so the delta (balanceOfSelf - balance0Before) excludes reward
        (amount0, amount1, balance0Before, balance1Before) = _deductRewardAndUpdateBaselines(
            config, params.rewardX64, feeAmount0, feeAmount1, amount0, amount1, balance0Before, balance1Before
        );

        // Swap to rebalance for new range
        if (params.amountIn != 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwapWithSlippageCheck(
                RouterSwapParams(
                    params.swap0To1 ? token0 : token1,
                    params.swap0To1 ? token1 : token0,
                    params.amountIn,
                    params.amountOutMin,
                    params.swapData
                ),
                params.swap0To1 ? config.token0SlippageBps : config.token1SlippageBps
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
            params, poolKey, token0, token1, newTickLower, newTickUpper, amount0, amount1, sqrtPriceX96
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

        // Send leftover tokens to owner (excludes protocol reward and pre-existing balances)
        uint256 leftover0 = token0.balanceOfSelf() - balance0Before;
        uint256 leftover1 = token1.balanceOfSelf() - balance1Before;
        if (leftover0 > 0) {
            _transferToken(owner, token0, leftover0, true);
        }
        if (leftover1 > 0) {
            _transferToken(owner, token1, leftover1, true);
        }

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
        uint256 amount1,
        uint160 sqrtPriceX96
    ) internal returns (uint256 newTokenId) {
        uint128 liquidity = _calculateLiquidity(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        if (liquidity == 0) {
            revert NoLiquidity();
        }

        _handleApproval(permit2, token0, amount0);
        _handleApproval(permit2, token1, amount1);

        // Track balances before mint to calculate actual amounts added
        uint256 balance0Before = token0.balanceOfSelf();
        uint256 balance1Before = token1.balanceOfSelf();

        (bytes memory actions, bytes[] memory paramsArray) =
            _buildActionsForIncreasingLiquidity(uint8(Actions.MINT_POSITION), token0, token1);
        paramsArray[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), params.mintHookData
        );

        positionManager.modifyLiquidities{value: _getNativeAmount(token0, token1, amount0, amount1)}(
            abi.encode(actions, paramsArray), params.deadline
        );

        newTokenId = positionManager.nextTokenId() - 1;

        // Check minimum amounts added
        uint256 added0 = balance0Before - token0.balanceOfSelf();
        uint256 added1 = balance1Before - token1.balanceOfSelf();
        if (added0 < params.amountAddMin0 || added1 < params.amountAddMin1) {
            revert InsufficientAmountAdded();
        }
    }

    function _deductRewardAndUpdateBaselines(
        PositionConfig memory config,
        uint64 rewardX64,
        uint256 feeAmount0,
        uint256 feeAmount1,
        uint256 amount0,
        uint256 amount1,
        uint256 balance0Before,
        uint256 balance1Before
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        uint256 amount0Pre = amount0;
        uint256 amount1Pre = amount1;
        (amount0, amount1) = _deductReward(feeAmount0, feeAmount1, amount0, amount1, config.onlyFees, rewardX64);
        return (
            amount0,
            amount1,
            balance0Before + (amount0Pre - amount0),
            balance1Before + (amount1Pre - amount1)
        );
    }

    /// @notice Configure a token for auto-range
    /// @dev Set token{0,1}SlippageBps to 10000 to allow automation for pairs without oracle support.
    function configToken(uint256 tokenId, address vault, PositionConfig calldata config) external {
        _validateOwner(positionManager, tokenId, vault);

        // Validate int32 values fit within int24 range (execution casts to int24)
        if (
            config.lowerTickLimit > type(int24).max || config.lowerTickLimit < type(int24).min
                || config.upperTickLimit > type(int24).max || config.upperTickLimit < type(int24).min
                || config.lowerTickDelta > type(int24).max || config.lowerTickDelta < type(int24).min
                || config.upperTickDelta > type(int24).max || config.upperTickDelta < type(int24).min
        ) {
            revert InvalidConfig();
        }

        // New range must have lower < upper (execution would revert anyway, but fail early)
        if (config.lowerTickDelta >= config.upperTickDelta) {
            revert InvalidConfig();
        }
        if (config.token0SlippageBps > 10000 || config.token1SlippageBps > 10000) {
            revert InvalidConfig();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.lowerTickLimit,
            config.upperTickLimit,
            config.lowerTickDelta,
            config.upperTickDelta,
            config.token0SlippageBps,
            config.token1SlippageBps,
            config.maxRewardX64,
            config.onlyFees
        );
    }
}
