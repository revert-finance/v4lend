// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

library AutoLeverageLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function currentRatio(uint256 currentDebt, uint256 collateralValue) internal pure returns (uint256) {
        return collateralValue > 0 ? currentDebt * BPS_DENOMINATOR / collateralValue : 0;
    }

    function isWithinThreshold(
        uint256 currentRatioBps,
        uint256 targetRatioBps,
        uint256 thresholdBps
    ) internal pure returns (bool) {
        uint256 lowerBound = targetRatioBps > thresholdBps ? targetRatioBps - thresholdBps : 0;
        return currentRatioBps > lowerBound && currentRatioBps < targetRatioBps + thresholdBps;
    }

    function borrowAmountToTarget(
        uint256 currentDebt,
        uint256 collateralValue,
        uint256 targetRatioBps
    ) internal pure returns (uint256 borrowAmount) {
        if (currentDebt * BPS_DENOMINATOR >= collateralValue * targetRatioBps) {
            return 0;
        }

        uint256 denominator = BPS_DENOMINATOR - targetRatioBps;
        if (denominator == 0) {
            return 0;
        }

        borrowAmount = (targetRatioBps * collateralValue - currentDebt * BPS_DENOMINATOR) / denominator;
    }

    function repayAmountToTarget(
        uint256 currentDebt,
        uint256 collateralValue,
        uint256 targetRatioBps
    ) internal pure returns (uint256 repayAmount) {
        if (currentDebt * BPS_DENOMINATOR <= collateralValue * targetRatioBps) {
            return 0;
        }

        uint256 denominator = BPS_DENOMINATOR - targetRatioBps;
        if (denominator == 0) {
            return 0;
        }

        repayAmount = (currentDebt * BPS_DENOMINATOR - targetRatioBps * collateralValue) / denominator;
    }

    function liquidityToRemove(
        uint128 currentLiquidity,
        uint256 removeValue,
        uint256 totalValue
    ) internal pure returns (uint128 liquidity) {
        if (currentLiquidity == 0 || removeValue == 0 || totalValue == 0) {
            return 0;
        }

        liquidity = uint128(uint256(currentLiquidity) * removeValue / totalValue);
        if (liquidity > currentLiquidity) {
            liquidity = currentLiquidity;
        }
    }
}
