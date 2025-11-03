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

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionInfoLibrary, PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {console} from "forge-std/console.sol";
error Unauthorized();

event AutoExit(uint tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);

contract RevertHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    IPositionManager public immutable positionManager;

    // manages ticks where actions are triggered (can be multiple entries per tokenid)
    mapping(PoolId poolId => mapping(int24 tickLower => uint[] tokenIds)) public lowerTrigger;
    mapping(PoolId poolId => mapping(int24 tickUpper => uint[] tokenIds)) public upperTrigger;

    // last tick
    mapping(PoolId => int24) public tickLowerLasts;

    // fees for auto compound 1% protocol fee / 1% reward
    uint128 autoCompoundProtocolFeeBps = 100;
    uint128 autoCompoundRewardBps = 100;    

    constructor(IPositionManager positionManager_, IPoolManager _poolManager) BaseHook(_poolManager) {
        positionManager = positionManager_;
    }

    mapping(uint tokenId => PositionConfig positionConfig) public positionConfigs;

    struct PositionConfig {
       bool doAutoCompound;
       bool doAutoRange;
       bool doAutoExit;

       // lastprocessed timestamp
       // relative liquidity
       // in range status (only these must be compounded)
       // slipagge config / swap config
    }

    function setPositionConfig(uint tokenId, bool doAutoCompound, bool doAutoRange, bool doAutoExit) external {

        if (_getOwner(tokenId) != msg.sender) {
            revert Unauthorized();
        }

        positionConfigs[tokenId].doAutoCompound = doAutoCompound;
        positionConfigs[tokenId].doAutoRange = doAutoRange;
        positionConfigs[tokenId].doAutoExit = doAutoExit;
    }

    // params for auto compound - calculated offchain for performance reasons
    struct AutoCompoundConfig {
        uint tokenId;
        bool zeroForOne;
        uint swapAmount;
    }

    // anyone can compound - needs to choose tokenids (based on offchain logic)
    // gets fees from compounded positions sent to his address
    function autoCompound(AutoCompoundConfig[] calldata params) external {
        for (uint i = 0; i < params.length; i++) {
            _autoCompound(params[i]);
        }
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

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {

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
                uint[] storage tokenIds = upperTrigger[poolId][tick];
                for (uint i = 0; i < tokenIds.length; i++) {    
                    _handleTokenId(key, poolId, tokenIds[i]);
                }
                upperTrigger[poolId][tick] = new uint[](0);
            }
        } else if (tickLower < tickLowerLast){
            for (int24 tick = tickLowerLast; tick > tickLower; tick -= key.tickSpacing) {
                uint[] storage tokenIds = lowerTrigger[poolId][tick];
                for (uint i = 0; i < tokenIds.length; i++) {    
                    _handleTokenId(key, poolId, tokenIds[i]);
                }
                lowerTrigger[poolId][tick] = new uint[](0);
            }
        }

        tickLowerLasts[poolId] = tickLower;
        return (this.afterSwap.selector, 0);
    }

    // handle token id - when detected as triggered by a swap
    function _handleTokenId(PoolKey memory poolKey, PoolId poolId, uint tokenId) internal {
        if (positionConfigs[tokenId].doAutoRange) {
            // TODO do range handling
        }
        if (positionConfigs[tokenId].doAutoExit) {
            (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

            //TODO configure slippage / direcction / etc..
            BalanceDelta swapDelta = _swap(poolKey, poolId, true, amount0, 5000);

            address owner = _getOwner(tokenId);
            if (amount0 > 0) {
                currency0.transfer(owner, amount0);
            }
            if (amount1 > 0) {
                currency1.transfer(owner, amount1);
            }
            emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
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
        _updatePositionTickMappings(key, params);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        _updatePositionTickMappings(key, params);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }


    /// @notice Updates position tick mappings based on liquidity changes
    /// @dev Adds position to mappings when liquidity is added, removes when fully removed
    /// @param key The pool key
    /// @param params The modify liquidity parameters containing tickLower, tickUpper, and salt
    function _updatePositionTickMappings(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params
    ) internal {
        // Extract tokenId from salt (PositionManager uses bytes32(tokenId) as salt)
        uint256 tokenId = uint256(params.salt);
        
        PoolId poolId = key.toId();
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        
        // Calculate positionId to check liquidity
        bytes32 positionId = Position.calculatePositionKey(
            address(positionManager),
            tickLower,
            tickUpper,
            params.salt
        );
        
        // Check current liquidity after the operation
        (uint128 liquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionId);

        // Get references to the arrays
        uint[] storage lowerTickPositions = lowerTrigger[poolId][tickLower];
        uint[] storage upperTickPositions = upperTrigger[poolId][tickUpper];
        
        if (liquidity > 0) {
            // Adding liquidity - add to mappings if not already present
            _addToTickMapping(lowerTickPositions, tokenId);
            _addToTickMapping(upperTickPositions, tokenId);
        } else {
            // Removing liquidity and position is now empty - remove from mappings
            _removeFromTickMapping(lowerTickPositions, tokenId);
            _removeFromTickMapping(upperTickPositions, tokenId);
        }
    }

    /// @notice Adds a tokenId to a tick mapping array if not already present
    /// @param tickPositions The storage array reference
    /// @param tokenId The tokenId to add
    function _addToTickMapping(uint[] storage tickPositions, uint256 tokenId) internal {
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
    function _removeFromTickMapping(uint[] storage tickPositions, uint256 tokenId) internal {
        for (uint256 i = 0; i < tickPositions.length; i++) {
            if (tickPositions[i] == tokenId) {
                // Swap with last element and pop
                tickPositions[i] = tickPositions[tickPositions.length - 1];
                tickPositions.pop();
                return;
            }
        }
    }

    function _getOwner(uint tokenId) internal view returns (address) {
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


    /// @notice Auto-compounds fees from a position by collecting fees, calculating perfect proportions, swapping, and adding liquidity back
    /// @dev Collects fees, calculates perfect token proportions for position range using stub method, swaps to achieve proportions,
    ///      and adds liquidity back via PositionManager
    /// @param config The auto compound configuration
    function _autoCompound(AutoCompoundConfig memory config) internal {

        uint256 tokenId = config.tokenId;

        // Step 0: Check if auto compound is enabled
        if (!positionConfigs[tokenId].doAutoCompound) {
            return;
        }

        // Step 1: Get position info
        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();
        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();
        
        // Step 2: Collect fees only (don't remove liquidity)
        (,,uint256 fees0, uint256 fees1) = _decreaseLiquidity(tokenId, true);
        
        if (fees0 == 0 && fees1 == 0) {
            return; // No fees to compound
        }
        
        // Step: 3
        if (config.swapAmount > 0) {
            BalanceDelta swapDelta = _swap(poolKey, poolId, config.zeroForOne, config.swapAmount, 500);
            fees0 += uint256(int256(swapDelta.amount0()));
            fees1 += uint256(int256(swapDelta.amount1()));
        }
        
        // Step 5: Add max liquidity back using PositionManager
        _addLiquidity(tokenId, poolKey, type(uint128).max, type(uint128).max);
    }
    
    /// @notice Iteratively calculates perfect proportions, executes swaps, and checks price convergence
    /// @dev Repeats the process of calculating ideal proportions, swapping, and checking if pool price
    ///      matches ideal price until convergence is achieved or max iterations reached
    /// @param poolKey The pool key
    /// @param poolId The pool ID
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param initialAmount0 Initial amount of token0 available
    /// @param initialAmount1 Initial amount of token1 available
    function _iterateToPerfectProportions(
        PoolKey memory poolKey,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 initialAmount0,
        uint256 initialAmount1
    ) internal {
        uint256 maxIterations = 5;
        uint256 priceToleranceBps = 50;
        
        uint256 currentAmount0 = initialAmount0;
        uint256 currentAmount1 = initialAmount1;
        
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        for (uint256 i = 0; i < maxIterations; i++) {
            // Calculate perfect proportions
            (uint256 swapAmount, bool zeroForOne) = _calculatePerfectProportions(
                sqrtPriceX96,
                tickLower,
                tickUpper,
                currentAmount0,
                currentAmount1
            );

            // Check if swapAmount is at least priceToleranceBps of total token amount
            uint256 totalTokens = zeroForOne ? currentAmount0 : currentAmount1;
            if (swapAmount * (10000 / priceToleranceBps) < totalTokens) {
                break;
            }
            
            // Execute swap
            BalanceDelta swapDelta = _swap(poolKey, poolId, zeroForOne, swapAmount, 500);
            if (swapDelta.amount0() < 0) {
                // we spent token0
                currentAmount0 -= uint256(int256(-swapDelta.amount0()));
            } else {
                currentAmount0 += uint256(int256(swapDelta.amount0()));
            }
            if (swapDelta.amount1() < 0) {
                // we spent token1
                currentAmount1 -= uint256(int256(-swapDelta.amount1()));
            } else {
                currentAmount1 += uint256(int256(swapDelta.amount1()));
            }
        }
    }
    
    /// @notice Stub method that calculates perfect token proportions for a position range
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
    ) internal pure returns (
        uint256 swapAmount,
        bool zeroForOne
    ) {

        // Calculate perfect proportions for the position range at current price
        uint128 unitLiquidity = 1e18; // Use a large unit to avoid precision issues
        (uint256 perfectAmount0, uint256 perfectAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            unitLiquidity
        );
        
        // Calculate total value in terms of token1
        uint256 totalValue1 = amount1Available;
        if (amount0Available > 0 && sqrtPriceX96 > 0) {
            uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
            totalValue1 += FullMath.mulDiv(amount0Available, priceX96, FixedPoint96.Q96);
        }

        uint256 targetAmount0;
        uint256 targetAmount1;
        
        // Calculate the ratio we need
        if (perfectAmount0 == 0) {
            // Position is entirely token1 (price above range)
            targetAmount0 = 0;
            targetAmount1 = totalValue1;
            swapAmount = amount0Available;
            zeroForOne = true;
        } else if (perfectAmount1 == 0) {
            // Position is entirely token0 (price below range)
            targetAmount0 = totalValue1;
            targetAmount1 = 0;
            swapAmount = amount1Available;
            zeroForOne = false;
        } else {
            // Position uses both tokens (price in range)
            uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
            uint256 ratio1To0X96 = FullMath.mulDiv(perfectAmount1, FixedPoint96.Q96, perfectAmount0);
            uint256 denominator = priceX96 + ratio1To0X96;
            
            targetAmount0 = FullMath.mulDiv(totalValue1, FixedPoint96.Q96, denominator);
            targetAmount1 = FullMath.mulDiv(targetAmount0, ratio1To0X96, FixedPoint96.Q96);
            
            // Calculate swap amount needed
            if (amount0Available < targetAmount0) {
                swapAmount = targetAmount0 - amount0Available;
                zeroForOne = false; // Swap token1 -> token0
            } else if (amount1Available < targetAmount1) {
                swapAmount = amount0Available - targetAmount0;
                zeroForOne = true; // Swap token0 -> token1
            } else {
                swapAmount = 0;
            }
        }
    }
    
    /// @notice Adds liquidity to an existing position using PositionManager
    /// @dev Uses INCREASE_LIQUIDITY action to add liquidity back to position
    /// @param tokenId The position NFT token ID
    /// @param poolKey The pool key
    /// @param available0 Available amount of token0
    /// @param available1 Available amount of token1
    function _addLiquidity(
        uint256 tokenId,
        PoolKey memory poolKey,
        uint128 available0,
        uint128 available1
    ) internal {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        
        // Calculate liquidity from available amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
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
            return;
        }
        
        // Use INCREASE_LIQUIDITY and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE_PAIR)
        );
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
        
        // Execute via PositionManager (uses type(uint256).max for deadline)
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
    function _swap(
        PoolKey memory poolKey,
        PoolId poolId,
        bool zeroForOne,
        uint256 swapAmount,
        uint256 slippageBps
    ) internal returns (BalanceDelta swapDelta) {
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
}