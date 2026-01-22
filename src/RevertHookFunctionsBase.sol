// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {RevertHookTriggers} from "./RevertHookTriggers.sol";

/// @title RevertHookFunctionsBase
/// @notice Base contract with shared helper functions for RevertHookPositionActions and RevertHookLendingActions
/// @dev Inherits from RevertHookTriggers for state access and trigger management
abstract contract RevertHookFunctionsBase is RevertHookTriggers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPermit2 public immutable permit2;
    IPositionManager public immutable positionManager;
    IV4Oracle public immutable v4Oracle;
    ILiquidityCalculator public immutable liquidityCalculator;
    IPoolManager public immutable poolManager;

    constructor(IPermit2 _permit2, IV4Oracle _v4Oracle, ILiquidityCalculator _liquidityCalculator) Ownable(address(1)) {
        positionManager = _v4Oracle.positionManager();
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;
        poolManager = _v4Oracle.poolManager();
    }

    // ==================== Abstract Function Implementation ====================

    /// @notice Implementation of abstract function from RevertHookTriggers
    function _getPoolAndPositionInfo(uint256 tokenId) internal view override returns (PoolKey memory, PositionInfo) {
        return positionManager.getPoolAndPositionInfo(tokenId);
    }

    // ==================== Owner Helper ====================

    /// @notice Returns the owner of the position
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view override returns (address) {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        return (isRealOwner && vaults[owner]) ? IVault(owner).ownerOf(tokenId) : owner;
    }

    // ==================== Auth Helpers ====================

    /// @notice Validates that the caller is authorized to interact with the position
    function _requireAuthorization(uint256 tokenId) internal view {
        if (msg.sender != address(poolManager)) {
            if (vaults[msg.sender]) {
                _validateCaller(positionManager, tokenId);
            } else {
                revert Unauthorized();
            }
        }
    }

    // ==================== Tick Helpers ====================

    /// @notice Gets the current tick for a pool
    function _getCurrentTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    // ==================== Pool Key Helpers ====================

    /// @notice Gets the swap pool key for a position (may differ from position pool)
    function _getSwapPoolKey(uint256 tokenId, PoolKey memory poolKey) internal view returns (PoolKey memory) {
        GeneralConfig storage config = generalConfigs[tokenId];
        if (config.swapPoolFee == 0 || config.swapPoolTickSpacing == 0) {
            return poolKey;
        }
        return PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: config.swapPoolFee,
            tickSpacing: config.swapPoolTickSpacing,
            hooks: config.swapPoolHooks
        });
    }

    // ==================== Position Config Helpers ====================

    /// @notice Copies configuration from one position to a new position
    function _copyPositionConfig(uint256 newTokenId, PositionConfig storage oldConfig) internal {
        positionConfigs[newTokenId] = oldConfig;
        if (positionStates[newTokenId].lastActivated == 0) {
            positionStates[newTokenId].lastActivated = uint32(block.timestamp);
        }
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(newTokenId);
        _addPositionTriggers(newTokenId, poolKey);
        emit SetPositionConfig(newTokenId, positionConfigs[newTokenId]);
    }

    // ==================== Swap Helpers ====================

    /// @notice Calculates optimal swap and executes it for liquidity provision
    function _calculateAndSwap(
        uint256 tokenId,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        PoolKey memory swapPool = _getSwapPoolKey(tokenId, poolKey);
        uint256 swapInput;
        bool zeroForOne;

        if (swapPool.hooks == poolKey.hooks && swapPool.fee == poolKey.fee && swapPool.tickSpacing == poolKey.tickSpacing) {
            (swapInput,, zeroForOne,) = liquidityCalculator.calculateSamePool(
                ILiquidityCalculator.V4PoolInfo({
                    poolMgr: poolManager,
                    poolIdentifier: poolKey.toId(),
                    tickSpacing: poolKey.tickSpacing
                }),
                tickLower,
                tickUpper,
                amount0,
                amount1
            );
        } else {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
            (swapInput,, zeroForOne) = liquidityCalculator.calculateSimple(
                sqrtPriceX96, tickLower, tickUpper, amount0, amount1, swapPool.fee
            );
        }

        if (swapInput > 0) {
            return _applyBalanceDelta(_executeSwap(swapPool, zeroForOne, swapInput, tokenId), amount0, amount1);
        }
        return (amount0, amount1);
    }

    /// @notice Executes a swap on the pool manager
    function _executeSwap(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 amountIn,
        uint256 tokenId
    ) internal returns (BalanceDelta delta) {
        GeneralConfig storage config = generalConfigs[tokenId];
        uint128 priceMultiplier = zeroForOne ? config.sqrtPriceMultiplier0 : config.sqrtPriceMultiplier1;

        uint160 sqrtPriceLimitX96;
        if (priceMultiplier == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
            sqrtPriceLimitX96 = uint160(FullMath.mulDiv(currentSqrtPriceX96, priceMultiplier, Q64));
            if (zeroForOne && sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
            }
            if (!zeroForOne && sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
            }
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        try poolManager.swap(poolKey, params, "") returns (BalanceDelta result) {
            delta = result;
            _settleSwapDeltas(poolKey, delta);
            uint256 actualSwapped = uint256(int256(-(zeroForOne ? result.amount0() : result.amount1())));
            if (actualSwapped < amountIn) {
                emit HookSwapPartial(tokenId, zeroForOne, amountIn, actualSwapped);
            }
        } catch (bytes memory reason) {
            emit HookSwapFailed(poolKey, params, reason);
        }
    }

    /// @notice Settles swap deltas with the pool manager
    function _settleSwapDeltas(PoolKey memory poolKey, BalanceDelta delta) internal {
        _settleCurrencyDelta(poolKey.currency0, delta.amount0());
        _settleCurrencyDelta(poolKey.currency1, delta.amount1());
    }

    /// @notice Settles a single currency delta
    function _settleCurrencyDelta(Currency currency, int256 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-delta);
            poolManager.sync(currency);
            if (currency.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                currency.transfer(address(poolManager), amount);
                poolManager.settle();
            }
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }

    // ==================== Liquidity Helpers ====================

    /// @notice Increases liquidity for a position
    function _increaseLiquidity(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal returns (uint256, uint256) {
        uint256 balance0Before = poolKey.currency0.balanceOfSelf();
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(positionInfo.tickLower()),
            TickMath.getSqrtPriceAtTick(positionInfo.tickUpper()),
            amount0Max,
            amount1Max
        );

        if (liquidity == 0) return (0, 0);

        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params) {
            return (balance0Before - poolKey.currency0.balanceOfSelf(), balance1Before - poolKey.currency1.balanceOfSelf());
        } catch (bytes memory reason) {
            emit HookModifyLiquiditiesFailed(actions, params, reason);
            return (0, 0);
        }
    }

    /// @notice Mints a new position
    function _mintPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) internal returns (uint256 newTokenId, uint256 amount0Used, uint256 amount1Used) {
        newTokenId = positionManager.nextTokenId();
        amount0Used = poolKey.currency0.balanceOfSelf();
        amount1Used = poolKey.currency1.balanceOfSelf();

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params) {
            amount0Used -= poolKey.currency0.balanceOfSelf();
            amount1Used -= poolKey.currency1.balanceOfSelf();
            if (vaults[recipient]) {
                IVault(recipient).notifyERC721Received(newTokenId, recipient);
            }
        } catch (bytes memory reason) {
            emit HookModifyLiquiditiesFailed(actions, params, reason);
            amount0Used = 0;
            amount1Used = 0;
        }
    }

    /// @notice Decreases liquidity from a position (optionally only fees)
    function _decreaseLiquidity(
        uint256 tokenId,
        bool feesOnly
    ) internal returns (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = feesOnly ? 0 : positionManager.getPositionLiquidity(tokenId);
        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;

        bytes memory actions = abi.encodePacked(
            feesOnly ? uint8(Actions.INCREASE_LIQUIDITY) : uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            liquidity,
            feesOnly ? type(uint128).max : 0,
            feesOnly ? type(uint128).max : 0,
            bytes("")
        );
        params[1] = abi.encode(currency0, currency1, address(this));

        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params) {
            amount0 = currency0.balanceOfSelf();
            amount1 = currency1.balanceOfSelf();
        } catch (bytes memory reason) {
            emit HookModifyLiquiditiesFailed(actions, params, reason);
        }
    }

    /// @notice Decreases a partial amount of liquidity from a position
    function _decreaseLiquidityPartial(
        uint256 tokenId,
        uint128 liquidityToRemove
    ) internal returns (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidityToRemove, 0, 0, bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));

        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params) {
            amount0 = currency0.balanceOfSelf();
            amount1 = currency1.balanceOfSelf();
        } catch (bytes memory reason) {
            emit HookModifyLiquiditiesFailed(actions, params, reason);
        }
    }

    // ==================== Token Transfer Helpers ====================

    /// @notice Sends leftover tokens to the recipient
    function _sendLeftoverTokens(uint256 tokenId, Currency currency0, Currency currency1, address recipient) internal {
        uint256 amount0 = currency0.balanceOfSelf();
        uint256 amount1 = currency1.balanceOfSelf();
        if (amount0 != 0) currency0.transfer(recipient, amount0);
        if (amount1 != 0) currency1.transfer(recipient, amount1);
        emit SendLeftoverTokens(tokenId, currency0, currency1, amount0, amount1, recipient);
    }

    /// @notice Approves tokens for the position manager via permit2
    function _approveToken(Currency currency, uint256 amount) internal {
        if (amount != 0 && !currency.isAddressZero()) {
            address tokenAddress = Currency.unwrap(currency);
            if (!permit2Approved[tokenAddress]) {
                SafeERC20.forceApprove(IERC20(tokenAddress), address(permit2), type(uint256).max);
                permit2Approved[tokenAddress] = true;
            }
            permit2.approve(tokenAddress, address(positionManager), uint160(amount), uint48(block.timestamp));
        }
    }

    // ==================== Balance Delta Helpers ====================

    /// @notice Applies a balance delta to amounts
    function _applyBalanceDelta(
        BalanceDelta delta,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256, uint256) {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        return (
            delta0 < 0 ? amount0 - uint256(int256(-delta0)) : amount0 + uint256(int256(delta0)),
            delta1 < 0 ? amount1 - uint256(int256(-delta1)) : amount1 + uint256(int256(delta1))
        );
    }
}
