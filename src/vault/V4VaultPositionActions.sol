// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency,CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice Immutable delegatecall helper for the vault's fee-first position withdrawals.
/// @dev No storage writes. Each vault deploys its own helper with its PositionManager fixed.
contract V4VaultPositionActions {
    using CurrencyLibrary for Currency;
    IPositionManager private immutable positionManager;
    address private immutable self = address(this);
    error DirectCallNotAllowed();
    constructor(IPositionManager manager) { positionManager = manager; }
    function decreaseLiquidity(uint256 tokenId,uint128 liquidityRemove,uint256 amount0Min,uint256 amount1Min,
        uint256 deadline,bytes calldata decreaseLiquidityHookData,address recipient)
        external returns (uint256 amount0,uint256 amount1)
    {
        if (address(this) == self) revert DirectCallNotAllowed();
        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Cache currencies to save gas
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // check balance before decreasing liquidity
        amount0 = currency0.balanceOf(recipient);
        amount1 = currency1.balanceOf(recipient);

        // V4 uses different approach - need to use modifyLiquidities with encoded actions
        // Include both DECREASE_LIQUIDITY and TAKE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory paramsArray = new bytes[](3);
        paramsArray[0] = abi.encode(tokenId, 0, type(uint128).max, type(uint128).max, bytes(""));
        paramsArray[1] = abi.encode(tokenId, liquidityRemove, amount0Min, amount1Min, decreaseLiquidityHookData);
        paramsArray[2] = abi.encode(currency0, currency1, recipient);

        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), deadline);

        // calculate delta
        amount0 = currency0.balanceOf(recipient) - amount0;
        amount1 = currency1.balanceOf(recipient) - amount1;
    }

}
