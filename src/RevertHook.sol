// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionInfoLibrary, PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {console} from "forge-std/console.sol";

error Unauthorized();

/// @title RevertHook
/// @notice Hook that allows to add LP Positions via PositionManager and enables auto-compounding, auto-exiting and auto-ranging of positions
contract RevertHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // events for auto actions
    event AutoCompound(uint256 tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event AutoExit(uint256 tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event AutoRange(uint256 tokenId, uint256 newTokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);

    // events for other actions
    event SetPositionConfig(uint256 tokenId, PositionConfig positionConfig);
    event SendLeftoverTokens(uint256 tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event SendFees(uint256 tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1, address recipient);


    IPositionManager public immutable positionManager;

    // manages ticks where actions are triggered (can be multiple entries per tokenid)
    mapping(PoolId poolId => mapping(int24 tickLower => uint256[] tokenIds)) public lowerTrigger;
    mapping(PoolId poolId => mapping(int24 tickUpper => uint256[] tokenIds)) public upperTrigger;

    // last tick
    mapping(PoolId => int24) public tickLowerLasts;

    // fees for auto compound 1% protocol fee / 1% reward
    uint16 autoCompoundProtocolFeeBps = 100;
    uint16 autoCompoundRewardBps = 100;

    // protocol fees for auto exit and auto range (taken from the final amount)
    uint16 autoExitProtocolFeeBps = 100;
    uint16 autoRangeProtocolFeeBps = 100;

    // recipient for protocol fees
    address public protocolFeeRecipient;

    constructor(IPositionManager positionManager_, IPoolManager _poolManager, address protocolFeeRecipient_)
        BaseHook(_poolManager)
    {
        positionManager = positionManager_;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    mapping(uint256 tokenId => PositionConfig positionConfig) public positionConfigs;

    struct PositionConfig {
        bool doAutoCompound;
        bool doAutoRange;
        bool doAutoExit;

        // general config for swap operations
        uint16 slippageBps;

        // auto exit config
        int24 autoExitTickLower;
        int24 autoExitTickUpper;
        bool autoExitSwapLower;
        bool autoExitSwapUpper;

        // auto range config
        int24 autoRangeLowerLimit;
        int24 autoRangeUpperLimit;
        int24 autoRangeLowerDelta;
        int24 autoRangeUpperDelta;
    }

    // lastprocessed timestamp
    // relative liquidity
    // in range status (only these must be compounded)
    // slipagge config / swap config

    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
        if (_getOwner(tokenId) != msg.sender) {
            revert Unauthorized();
        }
        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (address(poolKey.hooks) != address(this)) {
            revert Unauthorized();
        }

        // basic validation
        require(positionConfig.autoExitTickLower % poolKey.tickSpacing == 0, "autoExitTickLower must be divisible by tickSpacing");
        require(positionConfig.autoExitTickUpper % poolKey.tickSpacing == 0, "autoExitTickUpper must be divisible by tickSpacing");
        require(positionConfig.autoRangeLowerLimit % poolKey.tickSpacing == 0, "autoRangeLowerLimit must be divisible by tickSpacing");
        require(positionConfig.autoRangeUpperLimit % poolKey.tickSpacing == 0, "autoRangeUpperLimit must be divisible by tickSpacing");
        require(positionConfig.autoRangeLowerDelta % poolKey.tickSpacing == 0, "autoRangeLowerDelta must be divisible by tickSpacing");
        require(positionConfig.autoRangeUpperDelta % poolKey.tickSpacing == 0, "autoRangeUpperDelta must be divisible by tickSpacing");

        // update tick mappings
        _updatePositionTickMappings(tokenId, posInfo.tickLower(), posInfo.tickUpper(), poolKey, positionConfig);

        // save new config
        positionConfigs[tokenId] = positionConfig;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // params for auto compound - calculated offchain for performance reasons
    struct AutoCompoundParams {
        uint256 tokenId;
        bool zeroForOne;
        uint256 swapAmount;
    }

    // anyone can compound - needs to choose tokenids (based on offchain logic)
    // gets fees from compounded positions sent to his address
    function autoCompound(AutoCompoundParams[] calldata params) external {
        poolManager.unlock(abi.encode(params));
    }

     function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // disallow arbitrary caller
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }
        (AutoCompoundParams[] memory params) = abi.decode(data, (AutoCompoundParams[]));
        for (uint256 i = 0; i < params.length; i++) {
            _autoCompound(params[i]);
        }
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        tickLowerLasts[key.toId()] = tickLower;

        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(address caller, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // swaps triggered by the hook itself are just executed
        if (caller == address(this)) {
            return (this.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();

        int24 tickLower = _getTickLower(_getTick(poolId), key.tickSpacing);
        int24 tickLowerLast = tickLowerLasts[poolId];

        // handle tokens depending swap direction
        if (tickLower > tickLowerLast) {
            for (int24 tick = tickLowerLast; tick < tickLower; tick += key.tickSpacing) {
                uint256[] storage tokenIds = upperTrigger[poolId][tick];
                for (uint256 i = 0; i < tokenIds.length; i++) {
                    _handleTokenId(key, poolId, tokenIds[i], true, tick);
                }
                upperTrigger[poolId][tick] = new uint256[](0);
            }
        } else if (tickLower < tickLowerLast) {
            for (int24 tick = tickLowerLast; tick > tickLower; tick -= key.tickSpacing) {
                uint256[] storage tokenIds = lowerTrigger[poolId][tick];
                for (uint256 i = 0; i < tokenIds.length; i++) {
                    _handleTokenId(key, poolId, tokenIds[i], false, tick);
                }
                lowerTrigger[poolId][tick] = new uint256[](0);
            }
        }

        tickLowerLasts[poolId] = tickLower;
        return (this.afterSwap.selector, 0);
    }

    // handle token id - when detected as triggered by a swap
    function _handleTokenId(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger, int24 tick) internal {
        
        bool executeAutoExitLower = positionConfigs[tokenId].doAutoExit && !isUpperTrigger && tick == positionConfigs[tokenId].autoExitTickLower;
        bool executeAutoExitUpper = positionConfigs[tokenId].doAutoExit && isUpperTrigger && tick == positionConfigs[tokenId].autoExitTickUpper;
        
        if (executeAutoExitLower) {
            _autoExit(poolKey, poolId, tokenId, isUpperTrigger, positionConfigs[tokenId].autoExitSwapLower);
        } else if (executeAutoExitUpper) {
            _autoExit(poolKey, poolId, tokenId, isUpperTrigger, positionConfigs[tokenId].autoExitSwapUpper);
        } else {
            bool executeAutoRange = positionConfigs[tokenId].doAutoRange; // TODO condition 
            if (executeAutoRange) {
                _autoRange(poolKey, poolId, tokenId);
            }
        }
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        // Only allow positions created via PositionManager
        if (sender != address(positionManager)) {
            revert Unauthorized();
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        uint256 tokenId = uint256(params.salt);
        _updatePositionTickMappings(tokenId, params.tickLower, params.tickUpper, key, positionConfigs[tokenId]);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 tokenId = uint256(params.salt);
        _updatePositionTickMappings(tokenId, params.tickLower, params.tickUpper, key, positionConfigs[tokenId]);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Updates position tick mappings based on liquidity changes / config changes
    /// @param tokenId The tokenId of the position
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param key The pool key
    /// @param newConfig The new position config   
    function _updatePositionTickMappings(uint256 tokenId, int24 tickLower, int24 tickUpper, PoolKey memory key, PositionConfig memory newConfig) internal {

        PoolId poolId = key.toId();

        // Calculate positionId to check liquidity
        bytes32 positionId = Position.calculatePositionKey(address(positionManager), tickLower, tickUpper, bytes32(tokenId));

        // Check current liquidity after the operation
        (uint128 liquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionId);

        // Get current config - to check if changed
        PositionConfig memory currentConfig = positionConfigs[tokenId];

        // TODO optimize this by checking if changed - remove when needed
        if (liquidity > 0) {
            if (newConfig.doAutoRange) {
                _addToTickMapping(lowerTrigger[poolId][tickLower - newConfig.autoRangeLowerLimit], tokenId);
                _addToTickMapping(upperTrigger[poolId][tickUpper + newConfig.autoRangeUpperLimit], tokenId);
            } else if (currentConfig.doAutoRange) {
                _removeFromTickMapping(lowerTrigger[poolId][tickLower - currentConfig.autoRangeLowerLimit], tokenId);
                _removeFromTickMapping(upperTrigger[poolId][tickUpper + currentConfig.autoRangeUpperLimit], tokenId);
            }
            if (newConfig.doAutoExit) {
                _addToTickMapping(lowerTrigger[poolId][newConfig.autoExitTickLower], tokenId);
                _addToTickMapping(upperTrigger[poolId][newConfig.autoExitTickUpper], tokenId);
            } else if (currentConfig.doAutoExit) {
                _removeFromTickMapping(lowerTrigger[poolId][currentConfig.autoExitTickLower], tokenId);
                _removeFromTickMapping(upperTrigger[poolId][currentConfig.autoExitTickUpper], tokenId);
            }
        } else {
            if (currentConfig.doAutoRange) {
                _removeFromTickMapping(lowerTrigger[poolId][tickLower - currentConfig.autoRangeLowerLimit], tokenId);
                _removeFromTickMapping(upperTrigger[poolId][tickUpper + currentConfig.autoRangeUpperLimit], tokenId);
            }
            if (currentConfig.doAutoExit) {
                _removeFromTickMapping(lowerTrigger[poolId][currentConfig.autoExitTickLower], tokenId);
                _removeFromTickMapping(upperTrigger[poolId][currentConfig.autoExitTickUpper], tokenId);
            }
        }
    }

    /// @notice Adds a tokenId to a tick mapping array if not already present
    /// @param tickPositions The storage array reference
    /// @param tokenId The tokenId to add
    function _addToTickMapping(uint256[] storage tickPositions, uint256 tokenId) internal {
        // Check if already in the array
        for (uint256 i = 0; i < tickPositions.length; i++) {
            if (tickPositions[i] == tokenId) {
                return; // Already present
            }
        }
        // Add to array
        tickPositions.push(tokenId);
    }

    /// @notice Removes a tokenId from a tick mapping array
    /// @param tickPositions The storage array reference
    /// @param tokenId The tokenId to remove
    function _removeFromTickMapping(uint256[] storage tickPositions, uint256 tokenId) internal {
        for (uint256 i = 0; i < tickPositions.length; i++) {
            if (tickPositions[i] == tokenId) {
                // Swap with last element and pop
                tickPositions[i] = tickPositions[tickPositions.length - 1];
                tickPositions.pop();
                return;
            }
        }
    }

    function _getOwner(uint256 tokenId) internal view returns (address) {
        return IERC721(address(positionManager)).ownerOf(tokenId);
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = _getTickLower(_getTick(poolId), tickSpacing);
        int24 tickLowerLast = tickLowerLasts[poolId];

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _autoExit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper, bool doSwap) internal {
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        if (doSwap) {
            uint256 swapAmount = !isUpper ? amount0 : amount1;
            BalanceDelta swapDelta = _swap(poolKey, poolId, !isUpper, swapAmount, positionConfigs[tokenId].slippageBps);
            (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);
        }

        _sendFees(currency0, currency1, amount0, amount1, autoExitProtocolFeeBps, protocolFeeRecipient);

        _sendLeftoverTokens(currency0, currency1, _getOwner(tokenId));

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    function _autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) internal {
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 tickBase = _getTickLower(tick, poolKey.tickSpacing);

        int24 tickLower = tickBase + positionConfigs[tokenId].autoRangeLowerDelta;
        int24 tickUpper = tickBase + positionConfigs[tokenId].autoRangeUpperDelta;

        (amount0, amount1) = _iterateSwapToPerfectProportions(poolKey, poolId, tickLower, tickUpper, amount0, amount1);

        amount0 = uint128(amount0 - (autoCompoundProtocolFeeBps + autoCompoundRewardBps) * amount0 / 10000);
        amount1 = uint128(amount1 - (autoCompoundProtocolFeeBps + autoCompoundRewardBps) * amount1 / 10000);

        uint256 newTokenId;

        (newTokenId, amount0, amount1) = _mintNewPosition(poolKey, tickLower, tickUpper, uint128(amount0), uint128(amount1), _getOwner(tokenId));

        _sendFees(currency0, currency1, amount0, amount1, autoRangeProtocolFeeBps, protocolFeeRecipient);

        _sendLeftoverTokens(currency0, currency1, _getOwner(tokenId));

        
        emit AutoRange(tokenId, newTokenId, currency0, currency1, amount0, amount1);
    }

    /// @notice Auto-compounds fees from a position
    /// @dev Collects fees, swaps to achieve proportions (offchain optimized calculation), and adds liquidity back via PositionManager
    ///      Fees are based on actual added amounts to incentivize optimal swapping
    /// @param params The auto compound parameters
    function _autoCompound(AutoCompoundParams memory params) internal {
        uint256 tokenId = params.tokenId;

        // Step 0: Check if auto compound is enabled
        if (!positionConfigs[tokenId].doAutoCompound) {
            return;
        }

        // Step 1: Get position info
        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        // Step 2: Collect fees only (don't remove liquidity)
        (,, uint256 fees0, uint256 fees1) = _decreaseLiquidity(tokenId, true);

        if (fees0 == 0 && fees1 == 0) {
            return; // No fees to compound
        }

        // Step: 3 Swap if specified
        if (params.swapAmount > 0) {
            BalanceDelta swapDelta =
                _swap(poolKey, poolId, params.zeroForOne, params.swapAmount, positionConfigs[tokenId].slippageBps);
            if (params.zeroForOne) {
                fees0 -= uint256(int256(-swapDelta.amount0()));
                fees1 += uint256(int256(swapDelta.amount1()));
            } else {
                fees0 += uint256(int256(swapDelta.amount0()));
                fees1 -= uint256(int256(-swapDelta.amount1()));
            }
        }

        // Step 4: Add liquidity
        uint128 maxAddable0 = uint128(fees0 - (autoCompoundProtocolFeeBps + autoCompoundRewardBps) * fees0 / 10000);
        uint128 maxAddable1 = uint128(fees1 - (autoCompoundProtocolFeeBps + autoCompoundRewardBps) * fees1 / 10000);
        (uint256 amount0Added, uint256 amount1Added) =
            _increaseLiquidity(tokenId, poolKey, posInfo, maxAddable0, maxAddable1);

        // Step 5: Send protocol fees based on actual amounts added
        _sendFees(
            poolKey.currency0,
            poolKey.currency1,
            amount0Added,
            amount1Added,
            autoCompoundProtocolFeeBps,
            protocolFeeRecipient
        );
        _sendFees(poolKey.currency0, poolKey.currency1, amount0Added, amount1Added, autoCompoundRewardBps, msg.sender);

        // Step 6: Send leftover tokens to owner
        _sendLeftoverTokens(poolKey.currency0, poolKey.currency1, _getOwner(tokenId));
    }

    /// @notice Iteratively calculates perfect proportions, executes swaps, and checks price convergence
    /// @dev Repeats the process of calculating ideal proportions, swapping, and checking if pool price
    ///      matches ideal price until convergence is achieved or max iterations reached
    /// @param poolKey The pool key
    /// @param poolId The pool ID
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param currentAmount0 Current amount of token0 available
    /// @param currentAmount1 Current amount of token1 available
    function _iterateSwapToPerfectProportions(
        PoolKey memory poolKey,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 currentAmount0,
        uint256 currentAmount1
    ) internal returns (uint256 newAmount0, uint256 newAmount1) {

        // TODO decide on optimal value
        uint256 maxIterations = 5;
        uint256 priceToleranceBps = 50;

        uint160 sqrtPriceX96;

        console.log("currentAmount0", currentAmount0);
        console.log("currentAmount1", currentAmount1);

        for (uint256 i = 0; i < maxIterations; i++) {
            // Get current price
            (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

            console.log("tick", TickMath.getTickAtSqrtPrice(sqrtPriceX96));

            // Calculate perfect proportions
            (uint256 swapAmount, bool zeroForOne) =
                _calculatePerfectProportions(sqrtPriceX96, tickLower, tickUpper, currentAmount0, currentAmount1);

            console.log("swapAmount", swapAmount);
            console.log("zeroForOne", zeroForOne);

            // Check if swapAmount is at least priceToleranceBps of total token amount
            if (swapAmount * (10000 / priceToleranceBps) < (zeroForOne ? currentAmount0 : currentAmount1)) {
                break;
            }

            // Execute swap (TODO optimize: only do in poolmanager - and settle amounts at the end)
            BalanceDelta swapDelta = _swap(poolKey, poolId, zeroForOne, swapAmount, 500);
            (currentAmount0, currentAmount1) = _applyBalanceDelta(swapDelta, currentAmount0, currentAmount1);

            console.log("currentAmount0", currentAmount0);
            console.log("currentAmount1", currentAmount1);
        }
        return (currentAmount0, currentAmount1);
    }

    /// @notice Method that calculates perfect token proportions for a position range
    /// @dev Calculates the ideal ratio of token0/token1 needed for the position range at current price,
    ///      then determines how much to swap to achieve that ratio
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param amount0Available Amount of token0 available
    /// @param amount1Available Amount of token1 available
    /// @return swapAmount Amount to swap to achieve perfect proportions
    /// @return zeroForOne True if swapping token0 for token1, false otherwise
    function _calculatePerfectProportions(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Available,
        uint256 amount1Available
    ) internal pure returns (uint256 swapAmount, bool zeroForOne) {

        // Calculate perfect proportions for the position range at current price
        uint128 unitLiquidity = 1e18; // Use a large unit to avoid precision issues
        (uint256 perfectAmount0, uint256 perfectAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), unitLiquidity
        );

        // Calculate total value in terms of token1
        uint256 totalValue1 = amount1Available;
        if (amount0Available > 0 && sqrtPriceX96 > 0) {
            uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
            totalValue1 += FullMath.mulDiv(amount0Available, priceX96, FixedPoint96.Q96);
        }

        // Calculate the ratio we need
        if (perfectAmount0 == 0) {
            swapAmount = amount0Available;
            zeroForOne = true;
        } else if (perfectAmount1 == 0) {
            swapAmount = amount1Available;
            zeroForOne = false;
        } else {
            // Position uses both tokens (price in range)
            uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
            uint256 ratio1To0X96 = FullMath.mulDiv(perfectAmount1, FixedPoint96.Q96, perfectAmount0);
            uint256 denominator = priceX96 + ratio1To0X96;

            uint256 targetAmount0 = FullMath.mulDiv(totalValue1, FixedPoint96.Q96, denominator);
            uint256 targetAmount1 = FullMath.mulDiv(targetAmount0, ratio1To0X96, FixedPoint96.Q96);

            // Calculate swap amount needed
            if (amount0Available > targetAmount0) {
                swapAmount = amount0Available - targetAmount0;
                zeroForOne = true; // Swap token0 -> token1
            } else if (amount1Available > targetAmount1) {
                swapAmount = amount1Available - targetAmount1;
                zeroForOne = false; // Swap token1 -> token0
            } else {
                swapAmount = 0;
            }
        }
    }

    /// @notice Adds liquidity to an existing position using PositionManager
    /// @dev Uses INCREASE_LIQUIDITY action to add liquidity back to position
    /// @param tokenId The position NFT token ID
    /// @param poolKey The pool key
    /// @param posInfo The position info
    /// @param available0 Available amount of token0
    /// @param available1 Available amount of token1
    /// @return amount0Added Actual amount of token0 added to the position
    /// @return amount1Added Actual amount of token1 added to the position
    function _increaseLiquidity(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo posInfo,
        uint128 available0,
        uint128 available1
    ) internal returns (uint256 amount0Added, uint256 amount1Added) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Record balances before adding liquidity
        amount0Added = currency0.balanceOfSelf();
        amount1Added = currency1.balanceOfSelf();

        // Calculate liquidity from available amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());

        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        // Calculate liquidity from available amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );

        if (liquidity == 0) {
            return (0, 0);
        }

        // Use INCREASE_LIQUIDITY and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        // INCREASE_LIQUIDITY params: (tokenId, liquidity, amount0Max, amount1Max, hookData)
        params_array[0] = abi.encode(
            tokenId,
            uint256(liquidity),
            available0,
            available1,
            bytes("") // hookData
        );

        // SETTLE_PAIR params: (currency0, currency1, payer)
        params_array[1] = abi.encode(currency0, currency1, address(this));

        // Execute via PositionManager
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params_array);

        // Calculate actual amounts added by comparing balances before and after
        amount0Added -= currency0.balanceOfSelf();
        amount1Added -= currency1.balanceOfSelf();
    }

    /// @notice Mints a new position using PositionManager
    /// @dev Uses MINT_POSITION action to create a new position with specified tick range
    /// @param poolKey The pool key
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param available0 Available amount of token0
    /// @param available1 Available amount of token1
    /// @param recipient The owner of the new position
    /// @return newTokenId The token ID of the   newly minted position
    /// @return amount0Added Actual amount of token0 added to the position
    /// @return amount1Added Actual amount of token1 added to the position
    function _mintNewPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 available0,
        uint128 available1,
        address recipient
    ) internal returns (uint256 newTokenId, uint256 amount0Added, uint256 amount1Added) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Get the next token ID before minting
        newTokenId = positionManager.nextTokenId();

        // Record balances before minting
        amount0Added = currency0.balanceOfSelf();
        amount1Added = currency1.balanceOfSelf();

        // Calculate liquidity from available amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());

        // Calculate liquidity from available amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );

        // Use MINT_POSITION and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        // MINT_POSITION params: (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params_array[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            available0,
            available1,
            recipient,
            bytes("") // hookData
        );

        // SETTLE_PAIR params: (currency0, currency1, payer)
        params_array[1] = abi.encode(currency0, currency1, address(this));

        // Execute via PositionManager
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params_array);

        // Calculate actual amounts added by comparing balances before and after
        amount0Added -= currency0.balanceOfSelf();
        amount1Added -= currency1.balanceOfSelf();
    }

    /// @notice Decreases full liquidity from a position using PositionManager
    /// @dev Gets position liquidity, then uses PositionManager.modifyLiquidities with DECREASE_LIQUIDITY and TAKE_PAIR actions
    ///      to remove all liquidity and collect tokens/fees
    /// @param tokenId The position NFT token ID
    /// @return currency0 The currency of the token0
    /// @return currency1 The currency of the token1
    /// @return amount0 Amount of token0 received
    /// @return amount1 Amount of token1 received
    function _decreaseLiquidity(uint256 tokenId, bool onlyFees)
        internal
        returns (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1)
    {
        // Step 1: Get position info and current liquidity
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = onlyFees ? 0 : positionManager.getPositionLiquidity(tokenId);

        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;

        // If only collecting fees and no liquidity, we still want to collect fees (DECREASE_LIQUIDITY with 0 liquidity collects fees)
        if (!onlyFees && liquidity == 0) {
            return (currency0, currency1, 0, 0);
        }

        // Step 2: Record balances before decreasing liquidity
        amount0 = currency0.balanceOfSelf();
        amount1 = currency1.balanceOfSelf();

        // Step 3: Decrease all liquidity using PositionManager
        // Use DECREASE_LIQUIDITY and TAKE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        // DECREASE_LIQUIDITY params: (tokenId, liquidity, amount0Min, amount1Min, hookData)
        params_array[0] = abi.encode(
            tokenId,
            uint256(liquidity), // Remove all liquidity
            uint128(0), // amount0Min - no slippage protection needed
            uint128(0), // amount1Min
            bytes("") // hookData
        );

        // TAKE_PAIR params: (currency0, currency1, recipient)
        params_array[1] = abi.encode(currency0, currency1, address(this));

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params_array);

        // Step 4: Calculate amounts actually received
        amount0 = currency0.balanceOfSelf() - amount0;
        amount1 = currency1.balanceOfSelf() - amount1;
    }

    /// @notice Executes a swap via poolManager and handles balance deltas
    /// @dev Core swap logic that executes swap, settles owed tokens, and takes received tokens
    /// @param poolKey The pool key
    /// @param poolId The pool ID
    /// @param zeroForOne True if swapping token0 for token1, false otherwise
    /// @param swapAmount The amount to swap (in the source token)
    /// @param slippageBps Slippage tolerance in basis points (100 = 1%, 1000 = 10%)
    /// @return swapDelta The balance delta of the swap
    function _swap(PoolKey memory poolKey, PoolId poolId, bool zeroForOne, uint256 swapAmount, uint256 slippageBps)
        internal
        returns (BalanceDelta swapDelta)
    {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Get current price for swap limits
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Calculate price limit based on slippage
        // For zeroForOne (swap token0 -> token1): price goes down, so limit = current * (1 - slippage)
        // For !zeroForOne (swap token1 -> token0): price goes up, so limit = current * (1 + slippage)
        uint160 sqrtPriceLimitX96;
        if (zeroForOne) {
            // Price goes down: limit = sqrtPriceX96 * (10000 - slippageBps) / 10000
            uint256 limitNumerator = FullMath.mulDiv(sqrtPriceX96, 10000 - slippageBps, 10000);
            sqrtPriceLimitX96 = uint160(limitNumerator);
            // Ensure it doesn't go below minimum
            if (sqrtPriceLimitX96 < TickMath.MIN_SQRT_PRICE + 1) {
                sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
            }
        } else {
            // Price goes up: limit = sqrtPriceX96 * (10000 + slippageBps) / 10000
            uint256 limitNumerator = FullMath.mulDiv(sqrtPriceX96, 10000 + slippageBps, 10000);
            sqrtPriceLimitX96 = uint160(limitNumerator);
            // Ensure it doesn't exceed maximum
            if (sqrtPriceLimitX96 > TickMath.MAX_SQRT_PRICE - 1) {
                sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
            }
        }

        // Prepare swap params
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount), // exact in
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Execute swap via poolManager
        swapDelta = poolManager.swap(poolKey, swapParams, "");

        // Handle swap deltas - settle what we owe, take what we receive
        if (swapDelta.amount0() < 0) {
            // We owe token0 - settle the debt
            uint256 amount0Owed = uint256(int256(-swapDelta.amount0()));
            poolManager.sync(currency0);
            if (currency0.isAddressZero()) {
                poolManager.settle{value: amount0Owed}();
            } else {
                currency0.transfer(address(poolManager), amount0Owed);
                poolManager.settle();
            }
        } else if (swapDelta.amount0() > 0) {
            // We receive token0
            poolManager.take(currency0, address(this), uint256(int256(swapDelta.amount0())));
        }

        if (swapDelta.amount1() < 0) {
            // We owe token1 - settle the debt
            uint256 amount1Owed = uint256(int256(-swapDelta.amount1()));
            poolManager.sync(currency1);
            if (currency1.isAddressZero()) {
                poolManager.settle{value: amount1Owed}();
            } else {
                currency1.transfer(address(poolManager), amount1Owed);
                poolManager.settle();
            }
        } else if (swapDelta.amount1() > 0) {
            // We receive token1
            poolManager.take(currency1, address(this), uint256(int256(swapDelta.amount1())));
        }
    }

    function _sendFees(
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        uint16 feeBps,
        address recipient
    ) internal {
        currency0.transfer(recipient, amount0 * feeBps / 10000);
        currency1.transfer(recipient, amount1 * feeBps / 10000);
    }

    function _sendLeftoverTokens(Currency currency0, Currency currency1, address recipient) internal {
        uint256 amount0 = currency0.balanceOfSelf();
        uint256 amount1 = currency1.balanceOfSelf();
        if (amount0 != 0) {
            currency0.transfer(recipient, amount0);
        }
        if (amount1 != 0) {
            currency1.transfer(recipient, amount1);
        }
    }

    function _applyBalanceDelta(BalanceDelta balanceDelta, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256 newAmount0, uint256 newAmount1)
    {
        if (balanceDelta.amount0() < 0) {
            // we spent token0
            newAmount0 = amount0 - uint256(int256(-balanceDelta.amount0()));
        } else {
            newAmount0 = amount0 + uint256(int256(balanceDelta.amount0()));
        }
        if (balanceDelta.amount1() < 0) {
            // we spent token1
            newAmount1 = amount1 - uint256(int256(-balanceDelta.amount1()));
        } else {
            newAmount1 = amount1 + uint256(int256(balanceDelta.amount1()));
        }
    }
}
