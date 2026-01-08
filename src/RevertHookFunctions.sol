// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {V4Oracle} from "./V4Oracle.sol";
import {RevertHookFunctionsBase} from "./RevertHookFunctionsBase.sol";

/// @title RevertHookFunctions
/// @notice Contains auto-exit, auto-range, and auto-compound functions for RevertHook (called via delegatecall)
contract RevertHookFunctions is RevertHookFunctionsBase {
    using PoolIdLibrary for PoolKey;

    constructor(
        IPermit2 _permit2,
        V4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator
    ) RevertHookFunctionsBase(_permit2, _v4Oracle, _liquidityCalculator) {}

    // ==================== Auto Exit ====================

    /// @notice Executes auto-exit for a position when trigger conditions are met
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick, false if lower tick
    function autoExit(PoolKey memory poolKey, PoolId, uint256 tokenId, bool isUpperTrigger) public {
        _requireAuthorization(tokenId);

        // Remove all liquidity and collect fees
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        // Swap to the desired token based on trigger direction
        bool swapZeroForOne = !isUpperTrigger;
        uint256 swapAmount = swapZeroForOne ? amount0 : amount1;
        BalanceDelta swapDelta = _executeSwap(_getSwapPoolKey(tokenId, poolKey), swapZeroForOne, swapAmount, tokenId);
        (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);

        // Send tokens to owner and disable position
        _sendLeftoverTokens(tokenId, currency0, currency1, _getPositionOwner(tokenId, true));
        _disablePosition(tokenId);

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    // ==================== Auto Range ====================

    /// @notice Executes auto-range for a position when trigger conditions are met
    /// @param poolKey The pool key for the position
    /// @param poolId The pool ID
    /// @param tokenId The token ID of the position
    function autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) public {
        _requireAuthorization(tokenId);

        // Calculate new tick range based on current tick
        int24 baseTick = _getTickLower(_getCurrentTick(poolId), poolKey.tickSpacing);
        int24 newTickLower = baseTick + positionConfigs[tokenId].autoRangeLowerDelta;
        int24 newTickUpper = baseTick + positionConfigs[tokenId].autoRangeUpperDelta;

        // Remove all liquidity from current position
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        // Swap to optimal ratio for new range
        (amount0, amount1) = _calculateAndSwap(tokenId, poolKey, newTickLower, newTickUpper, amount0, amount1);

        // Approve tokens and mint new position
        _approveToken(currency0, amount0);
        _approveToken(currency1, amount1);
        (uint256 newTokenId,,) = _mintPosition(
            poolKey,
            newTickLower,
            newTickUpper,
            uint128(amount0),
            uint128(amount1),
            _getPositionOwner(tokenId, false)
        );

        // Send leftover tokens and copy config to new position
        _sendLeftoverTokens(tokenId, currency0, currency1, _getPositionOwner(tokenId, true));
        _copyPositionConfig(newTokenId, positionConfigs[tokenId]);
        _disablePosition(tokenId);

        emit AutoRange(tokenId, newTokenId, currency0, currency1, amount0, amount1);
    }

    // ==================== Auto Compound ====================

    /// @notice Auto-compounds fees from multiple positions
    /// @param tokenIds Array of token IDs to compound
    function autoCompound(uint256[] memory tokenIds) external {
        for (uint256 i; i < tokenIds.length;) {
            address owner = _getPositionOwner(tokenIds[i], false);
            if (vaults[owner]) {
                IVault(owner).transform(
                    tokenIds[i],
                    address(this),
                    abi.encodeCall(this.autoCompoundForVault, (tokenIds[i], msg.sender))
                );
            } else {
                poolManager.unlock(abi.encode(tokenIds[i], msg.sender));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Auto-compound callback for vault-owned positions
    /// @param tokenId The token ID to compound
    /// @param caller The original caller (for rewards)
    function autoCompoundForVault(uint256 tokenId, address caller) external {
        if (!vaults[msg.sender]) revert Unauthorized();
        _validateCaller(positionManager, tokenId);
        poolManager.unlock(abi.encode(tokenId, caller));
    }

    /// @notice Executes the auto-compound logic (called from unlockCallback)
    /// @param tokenId The token ID to compound
    /// @param caller The original caller (for rewards)
    function executeAutoCompound(uint256 tokenId, address caller) external {
        PositionConfig storage config = positionConfigs[tokenId];
        AutoCompoundMode compoundMode = config.autoCompoundMode;

        // Skip if compound is disabled or position is not active
        if (compoundMode == AutoCompoundMode.NONE || config.mode == PositionMode.NONE) {
            return;
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Collect fees only (no liquidity removal)
        (,, uint256 fees0, uint256 fees1) = _decreaseLiquidity(tokenId, true);
        if (fees0 == 0 && fees1 == 0) return;

        // Process based on compound mode
        if (compoundMode == AutoCompoundMode.AUTO_COMPOUND) {
            // Swap to optimal ratio and add back as liquidity
            (fees0, fees1) = _calculateAndSwap(
                tokenId, poolKey, positionInfo.tickLower(), positionInfo.tickUpper(), fees0, fees1
            );
        } else if (compoundMode == AutoCompoundMode.HARVEST_TOKEN_0) {
            // Swap token1 to token0
            (fees0, fees1) = _applyBalanceDelta(_executeSwap(poolKey, false, fees1, tokenId), fees0, fees1);
        } else if (compoundMode == AutoCompoundMode.HARVEST_TOKEN_1) {
            // Swap token0 to token1
            (fees0, fees1) = _applyBalanceDelta(_executeSwap(poolKey, true, fees0, tokenId), fees0, fees1);
        }

        // Pay rewards to caller
        (fees0, fees1) = _payCompoundRewards(tokenId, poolKey.currency0, poolKey.currency1, fees0, fees1, caller);

        // Approve and add liquidity for AUTO_COMPOUND mode
        _approveToken(poolKey.currency0, fees0);
        _approveToken(poolKey.currency1, fees1);
        if (compoundMode == AutoCompoundMode.AUTO_COMPOUND) {
            _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(fees0), uint128(fees1));
        }

        // Send remaining tokens to owner
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, _getPositionOwner(tokenId, true));
    }

    // ==================== Internal Helpers ====================

    /// @notice Pays compound rewards to the caller
    function _payCompoundRewards(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal returns (uint256, uint256) {
        uint256 reward0 = amount0 * autoCompoundRewardBps / 10000;
        uint256 reward1 = amount1 * autoCompoundRewardBps / 10000;

        if (reward0 != 0) currency0.transfer(recipient, reward0);
        if (reward1 != 0) currency1.transfer(recipient, reward1);

        emit SendRewards(tokenId, currency0, currency1, reward0, reward1, recipient);
        return (amount0 - reward0, amount1 - reward1);
    }
}
