// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionInfoLibrary, PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {console} from "forge-std/console.sol";

import {LiquidityCalculator} from "./LiquidityCalculator.sol";

error Unauthorized();

/// @title RevertHook
/// @notice Hook that allows to add LP Positions via PositionManager and enables auto-compounding, auto-exiting and auto-ranging of positions
contract RevertHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // events for auto actions
    event AutoCompound(uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event AutoExit(uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event AutoRange(uint256 indexed tokenId, uint256 newTokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);

    // events for other actions
    event SetPositionConfig(uint256 indexed tokenId, PositionConfig positionConfig);
    event SendLeftoverTokens(uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event SendFees(uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1, address recipient);

    // special event for swap failures
    event SwapFailed(PoolKey poolKey, SwapParams swapParams, bytes reason);

    IPermit2 public immutable permit2;
    mapping(address => bool) private permit2Approved;

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

    constructor(
        IPositionManager positionManager_,
        IPoolManager _poolManager,
        address protocolFeeRecipient_,
        IPermit2 _permit2
    ) BaseHook(_poolManager) {
        positionManager = positionManager_;
        protocolFeeRecipient = protocolFeeRecipient_;
        permit2 = _permit2;
    }

    mapping(uint256 tokenId => PositionConfig positionConfig) public positionConfigs;

    struct PositionConfig {
        bool doAutoCompound;
        bool doAutoRange;
        bool doAutoExit;
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
        // reference pool key data for swaps (can be the same pool or different pool)
        uint24 swapPoolFee;
        int24 swapPoolTickSpacing;
        IHooks swapPoolHooks;
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
        require(
            positionConfig.autoExitTickLower % poolKey.tickSpacing == 0,
            "autoExitTickLower must be divisible by tickSpacing"
        );
        require(
            positionConfig.autoExitTickUpper % poolKey.tickSpacing == 0,
            "autoExitTickUpper must be divisible by tickSpacing"
        );
        require(
            positionConfig.autoRangeLowerLimit % poolKey.tickSpacing == 0,
            "autoRangeLowerLimit must be divisible by tickSpacing"
        );
        require(
            positionConfig.autoRangeUpperLimit % poolKey.tickSpacing == 0,
            "autoRangeUpperLimit must be divisible by tickSpacing"
        );
        require(
            positionConfig.autoRangeLowerDelta % poolKey.tickSpacing == 0,
            "autoRangeLowerDelta must be divisible by tickSpacing"
        );
        require(
            positionConfig.autoRangeUpperDelta % poolKey.tickSpacing == 0,
            "autoRangeUpperDelta must be divisible by tickSpacing"
        );

        // update tick mappings
        _updatePositionTickMappings(tokenId, posInfo.tickLower(), posInfo.tickUpper(), poolKey, positionConfig);

        // save new config
        positionConfigs[tokenId] = positionConfig;

        // emit event
        emit SetPositionConfig(tokenId, positionConfig);
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

    // anyone can compound - needs to choose tokenids (based on offchain logic)
    // gets fees from compounded positions sent to his address
    function autoCompound(uint256[] calldata tokenIds) external {
        poolManager.unlock(abi.encode(tokenIds));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // disallow arbitrary caller
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }
        uint256[] memory tokenIds = abi.decode(data, (uint256[]));
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _autoCompound(tokenIds[i]);
        }
        return "";
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

        int24 tickEnd = _getTickLower(_getTick(poolId), key.tickSpacing);
        int24 tick = tickLowerLasts[poolId];

        // if tick changed - process all triggers, each processing may change the tick again
        // this must work all until the end - otherwise swap is not allowed and hook will not be executed
        while (tick != tickEnd) {
            uint256[] storage tokenIds = tick < tickEnd ? upperTrigger[poolId][tick] : lowerTrigger[poolId][tick];
            uint256 length = tokenIds.length;
            if (length > 0) {
                uint256 tokenId = tokenIds[length - 1];
                tokenIds.pop();
                _handleTokenId(key, poolId, tokenId, tick < tickEnd, tick);

                // tickEnd may have changed after the processing of the tokenId
                tickEnd = _getTickLower(_getTick(poolId), key.tickSpacing);
            } else {
                // move to next tick
                if (tick < tickEnd) {
                    tick += key.tickSpacing;
                } else {
                    tick -= key.tickSpacing;
                }
            }
        }

        tickLowerLasts[poolId] = tickEnd;
        return (this.afterSwap.selector, 0);
    }

    // handle token id - when detected as triggered by a swap
    function _handleTokenId(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger, int24 baseTick)
        internal
    {
        // check conditions again - there may be leftover triggers which are not valid anymore
        bool executeAutoExitLower = positionConfigs[tokenId].doAutoExit && !isUpperTrigger
            && baseTick == positionConfigs[tokenId].autoExitTickLower;
        bool executeAutoExitUpper = positionConfigs[tokenId].doAutoExit && isUpperTrigger
            && baseTick == positionConfigs[tokenId].autoExitTickUpper;

        // there may only be one action configured for a tokenid/tick - auto exit takes priority over auto range
        if (executeAutoExitLower) {
            _autoExit(poolKey, poolId, tokenId, isUpperTrigger, positionConfigs[tokenId].autoExitSwapLower);
        } else if (executeAutoExitUpper) {
            _autoExit(poolKey, poolId, tokenId, isUpperTrigger, positionConfigs[tokenId].autoExitSwapUpper);
        } else {
            bool executeAutoRange = positionConfigs[tokenId].doAutoRange && !isUpperTrigger;
            if (executeAutoRange) {
                _autoRange(poolKey, poolId, tokenId, baseTick);
            }
        }
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata /* key */, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        // Only allow positions created via PositionManager
        if (sender != address(positionManager)) {
            revert Unauthorized();
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
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
    function _updatePositionTickMappings(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        PoolKey memory key,
        PositionConfig memory newConfig
    ) internal {
        PoolId poolId = key.toId();

        // Calculate positionId to check liquidity
        bytes32 positionId =
            Position.calculatePositionKey(address(positionManager), tickLower, tickUpper, bytes32(tokenId));

        // Check current liquidity after the operation
        (uint128 liquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionId);

        // Get current config - to check if changed
        PositionConfig memory currentConfig = positionConfigs[tokenId];

        // TODO optimize this by checking if changed - remove only when needed
        if (liquidity > 0) {
            if (currentConfig.doAutoRange) {
                _removeFromTickMapping(lowerTrigger[poolId][tickLower - currentConfig.autoRangeLowerLimit], tokenId);
                _removeFromTickMapping(upperTrigger[poolId][tickUpper + currentConfig.autoRangeUpperLimit], tokenId);
            }
            if (newConfig.doAutoRange) {
                _addToTickMapping(lowerTrigger[poolId][tickLower - newConfig.autoRangeLowerLimit], tokenId);
                _addToTickMapping(upperTrigger[poolId][tickUpper + newConfig.autoRangeUpperLimit], tokenId);
            }
            if (currentConfig.doAutoExit) {
                _removeFromTickMapping(lowerTrigger[poolId][currentConfig.autoExitTickLower], tokenId);
                _removeFromTickMapping(upperTrigger[poolId][currentConfig.autoExitTickUpper], tokenId);
            }
            if (newConfig.doAutoExit) {
                _addToTickMapping(lowerTrigger[poolId][newConfig.autoExitTickLower], tokenId);
                _addToTickMapping(upperTrigger[poolId][newConfig.autoExitTickUpper], tokenId);
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

    function _getSwapPoolKey(uint256 tokenId, PoolKey memory poolKey) internal view returns (PoolKey memory) {
        uint24 swapPoolFee = positionConfigs[tokenId].swapPoolFee;
        int24 swapPoolTickSpacing = positionConfigs[tokenId].swapPoolTickSpacing;
        IHooks swapPoolHooks = positionConfigs[tokenId].swapPoolHooks;

        // if the swap pool key is the same as the configured swap pool key, return the pool key
        if (swapPoolHooks == poolKey.hooks && swapPoolFee == poolKey.fee && swapPoolTickSpacing == poolKey.tickSpacing)
        {
            return poolKey;
        }

        // otherwise, return the configured swap pool key
        return PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: positionConfigs[tokenId].swapPoolFee,
            tickSpacing: positionConfigs[tokenId].swapPoolTickSpacing,
            hooks: positionConfigs[tokenId].swapPoolHooks
        });
    }

    function _autoExit(PoolKey memory poolKey, PoolId /* poolId */, uint256 tokenId, bool isUpper, bool doSwap) internal {
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        if (doSwap) {
            uint256 swapAmount = !isUpper ? amount0 : amount1;
            PoolKey memory swapPoolKey = _getSwapPoolKey(tokenId, poolKey);
            BalanceDelta swapDelta = _swap(swapPoolKey, !isUpper, swapAmount);
            (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);
        }

        _sendFees(tokenId, currency0, currency1, amount0, amount1, autoExitProtocolFeeBps, protocolFeeRecipient);
        _sendLeftoverTokens(tokenId, currency0, currency1, _getOwner(tokenId));
        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    function _autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, int24 baseTick) internal {
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        int24 tickLower = baseTick + positionConfigs[tokenId].autoRangeLowerDelta;
        int24 tickUpper = baseTick + positionConfigs[tokenId].autoRangeUpperDelta;

        (amount0, amount1) = _swapToOptimalRange(tokenId, poolKey, poolId, tickLower, tickUpper, amount0, amount1);

        amount0 = uint128(amount0 - autoRangeProtocolFeeBps * amount0 / 10000);
        amount1 = uint128(amount1 - autoRangeProtocolFeeBps * amount1 / 10000);

        address owner = _getOwner(tokenId);

        _handleApproval(currency0, amount0);
        _handleApproval(currency1, amount1);

        uint256 newTokenId;

        (newTokenId, amount0, amount1) =
            _mintNewPosition(poolKey, tickLower, tickUpper, uint128(amount0), uint128(amount1), owner);

        _sendFees(tokenId, currency0, currency1, amount0, amount1, autoRangeProtocolFeeBps, protocolFeeRecipient);
        _sendLeftoverTokens(tokenId, currency0, currency1, owner);

        // configure new position
        positionConfigs[newTokenId] = positionConfigs[tokenId];
        _updatePositionTickMappings(newTokenId, tickLower, tickUpper, poolKey, positionConfigs[newTokenId]);

        emit AutoRange(tokenId, newTokenId, currency0, currency1, amount0, amount1);
    }

    /// @notice Auto-compounds fees from a position
    /// @dev Collects fees, swaps to achieve proportions (offchain optimized calculation), and adds liquidity back via PositionManager
    ///      Fees are based on actual added amounts to incentivize optimal swapping
    /// @param tokenId The token ID
    function _autoCompound(uint256 tokenId) internal {
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

        // Step 3: Swap to optimal range
        (fees0, fees1) =
            _swapToOptimalRange(tokenId, poolKey, poolId, posInfo.tickLower(), posInfo.tickUpper(), fees0, fees1);

        // Step 4: Add liquidity
        uint128 maxAddable0 = uint128(fees0 - (autoCompoundProtocolFeeBps + autoCompoundRewardBps) * fees0 / 10000);
        uint128 maxAddable1 = uint128(fees1 - (autoCompoundProtocolFeeBps + autoCompoundRewardBps) * fees1 / 10000);

        _handleApproval(poolKey.currency0, maxAddable0);
        _handleApproval(poolKey.currency1, maxAddable1);

        (uint256 amount0Added, uint256 amount1Added) =
            _increaseLiquidity(tokenId, poolKey, posInfo, maxAddable0, maxAddable1);

        // Step 5: Send protocol fees and reward based on actual amounts added
        _sendFees(
            tokenId,
            poolKey.currency0,
            poolKey.currency1,
            amount0Added,
            amount1Added,
            autoCompoundProtocolFeeBps,
            protocolFeeRecipient
        );
        _sendFees(tokenId, poolKey.currency0, poolKey.currency1, amount0Added, amount1Added, autoCompoundRewardBps, msg.sender);

        // Step 6: Send leftover tokens to owner
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, _getOwner(tokenId));
    }

    /// @notice Swaps to optimal range using LiquidityCalculator
    function _swapToOptimalRange(
        uint256 tokenId,
        PoolKey memory poolKey,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        LiquidityCalculator.V4PoolInfo memory poolInfo = LiquidityCalculator.V4PoolInfo({
            poolMgr: poolManager,
            poolIdentifier: poolId,
            tickSpacing: poolKey.tickSpacing
        });

        PoolKey memory swapPoolKey = _getSwapPoolKey(tokenId, poolKey);

        uint256 inputAmount;
        bool swapDir0to1;
        if (
            swapPoolKey.hooks == poolKey.hooks && swapPoolKey.fee == poolKey.fee
                && swapPoolKey.tickSpacing == poolKey.tickSpacing
        ) {
            (inputAmount,, swapDir0to1,) =
                LiquidityCalculator.calculateSamePool(poolInfo, tickLower, tickUpper, amount0, amount1);
        } else {
            (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(poolManager, swapPoolKey.toId());
            (inputAmount,, swapDir0to1) =
                LiquidityCalculator.calculateSimple(sqrtPrice, tickLower, tickUpper, amount0, amount1, swapPoolKey.fee);
        }

        if (inputAmount > 0) {
            BalanceDelta swapDelta = _swap(swapPoolKey, swapDir0to1, inputAmount);
            (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);
        }

        return (amount0, amount1);
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
    ) internal returns (uint256 newTokenId, uint128 amount0Added, uint128 amount1Added) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Get the next token ID before minting
        newTokenId = positionManager.nextTokenId();

        // Record balances before minting
        amount0Added = uint128(currency0.balanceOfSelf());
        amount1Added = uint128(currency1.balanceOfSelf());

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
        amount0Added -= uint128(currency0.balanceOfSelf());
        amount1Added -= uint128(currency1.balanceOfSelf());
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
    /// @dev Core swap logic that executes swap, settles owed tokens, and takes received tokens.
    ///      If swap fails, emits SwapFailed event (this may happen for swap pool problems like not enough liquidity)
    /// @param poolKey The pool key
    /// @param zeroForOne True if swapping token0 for token1, false otherwise
    /// @param swapAmount The amount to swap (in the source token)
    /// @return swapDelta The balance delta of the swap
    function _swap(PoolKey memory poolKey, bool zeroForOne, uint256 swapAmount)
        internal
        returns (BalanceDelta swapDelta)
    {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Prepare swap params
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount), // exact in
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Execute swap via poolManager - if the swap fails
        try poolManager.swap(poolKey, swapParams, "") returns (BalanceDelta result) {
            swapDelta = result;

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
            // Handle swap deltas - settle what we owe, take what we receive
        } catch (bytes memory reason) {
            // emit event
            emit SwapFailed(poolKey, swapParams, reason);

            // return the swap delta which is 0, 0
        }
    }

    function _sendFees(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        uint16 feeBps,
        address recipient
    ) internal {
        currency0.transfer(recipient, amount0 * feeBps / 10000);
        currency1.transfer(recipient, amount1 * feeBps / 10000);

        emit SendFees(tokenId, currency0, currency1, amount0, amount1, recipient);
    }

    function _sendLeftoverTokens(uint256 tokenId, Currency currency0, Currency currency1, address recipient) internal {
        uint256 amount0 = currency0.balanceOfSelf();
        uint256 amount1 = currency1.balanceOfSelf();
        if (amount0 != 0) {
            currency0.transfer(recipient, amount0);
        }
        if (amount1 != 0) {
            currency1.transfer(recipient, amount1);
        }

        emit SendLeftoverTokens(tokenId, currency0, currency1, amount0, amount1);
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

    function _handleApproval(Currency token, uint256 amount) internal {
        if (amount != 0 && !token.isAddressZero()) {
            address tokenAddr = Currency.unwrap(token);
            if (!permit2Approved[tokenAddr]) {
                SafeERC20.forceApprove(IERC20(tokenAddr), address(permit2), type(uint256).max);
                permit2Approved[tokenAddr] = true;
            }
            permit2.approve(tokenAddr, address(positionManager), uint160(amount), uint48(block.timestamp));
        }
    }
}
