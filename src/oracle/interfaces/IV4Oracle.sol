// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// V4 Oracle Interface for position valuation
interface IV4Oracle {
    /// @notice Sizes the fee-first removal that realizes `target` quote-token value from a position.
    /// @dev Also returns the raw reference-token prices the sizing used, so the caller can value what the
    ///      removal actually pays out with the same precision (`amount * priceX96 / quotePriceX96` per leg)
    ///      instead of with per-leg prices already rounded to Q96 in quote terms, which are zero for a leg
    ///      whose per-unit quote price is below one Q96 unit although the leg has value.
    /// @return liquidity Liquidity to remove; zero when the uncollected fees alone cover the target
    /// @return price0X96 Price of token0 in reference-token terms (Q96)
    /// @return price1X96 Price of token1 in reference-token terms (Q96)
    /// @return quotePriceX96 Price of the quote token in reference-token terms (Q96)
    function getLiquidityForValue(uint256 tokenId, address quoteToken, uint256 target)
        external
        view
        returns (uint128 liquidity, uint256 price0X96, uint256 price1X96, uint256 quotePriceX96);
    /// @notice Additional source-recovery requirements for increasing loan risk after an L2 restart.
    function getRiskScore(uint256 tokenId, address quoteToken, uint256 debtShares) external view returns (uint256);
    function validateRiskChange(uint256 tokenId, address quoteToken, uint256 debtShares, uint256 previousRisk) external view;
    function validateBorrow(uint256 tokenId, address quoteToken) external view;

    function poolManager() external view returns (IPoolManager);
    function positionManager() external view returns (IPositionManager);
    function getPoolSqrtPriceX96(address token0, address token1) external view returns (uint160);
    function getValue(uint256 tokenId, address token) external view returns (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96);
    function getPositionBreakdown(uint256 tokenId) external view returns (Currency currency0, Currency currency1, uint24 fee, uint128 liquidity, uint256 amount0, uint256 amount1, uint128 fees0, uint128 fees1);
    function getLiquidityAndFees(uint256 tokenId)
        external
        view
        returns (uint128 liquidity, uint128 fees0, uint128 fees1);
}
