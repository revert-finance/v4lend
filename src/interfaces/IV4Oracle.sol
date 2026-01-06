// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// V4 Oracle Interface for position valuation
interface IV4Oracle {
    function getPoolSqrtPriceX96(address token0, address token1) external view returns (uint160);
    function getValue(uint256 tokenId, address token) external view returns (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96);
    function getPositionBreakdown(uint256 tokenId) external view returns (Currency currency0, Currency currency1, uint24 fee, uint128 liquidity, uint256 amount0, uint256 amount1, uint128 fees0, uint128 fees1);
    function getLiquidityAndFees(uint256 tokenId)
        external
        view
        returns (uint128 liquidity, uint128 fees0, uint128 fees1);
}
