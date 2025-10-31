// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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


error Unauthorized();

contract RevertHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    IPositionManager public immutable positionManager;

    // manages ticks where actions are triggered
    mapping(PoolId poolId => mapping(int24 tickLower => uint[] tokenIds)) public lowerTrigger;
    mapping(PoolId poolId => mapping(int24 tickUpper => uint[] tokenIds)) public upperTrigger;

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
        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
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
        _updatePositionTickMappings(key, params, true);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        _updatePositionTickMappings(key, params, false);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }





    /// @notice Updates position tick mappings based on liquidity changes
    /// @dev Adds position to mappings when liquidity is added, removes when fully removed
    /// @param key The pool key
    /// @param params The modify liquidity parameters containing tickLower, tickUpper, and salt
    /// @param isAdding True if adding liquidity, false if removing
    function _updatePositionTickMappings(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bool isAdding
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
        
        if (isAdding && liquidity > 0) {
            // Adding liquidity - add to mappings if not already present
            _addToTickMapping(lowerTickPositions, tokenId);
            _addToTickMapping(upperTickPositions, tokenId);
        } else if (!isAdding && liquidity == 0) {
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
}