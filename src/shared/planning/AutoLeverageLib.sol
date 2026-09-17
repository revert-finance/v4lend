// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
        uint256 fullValue,
        uint256 collateralValue,
        uint256 targetRatioBps
    ) internal pure returns (uint256 borrowAmount) {
        uint256 targetCollateral = collateralValue * targetRatioBps;
        uint256 currentDebtBps = currentDebt * BPS_DENOMINATOR;
        if (fullValue == 0 || currentDebtBps >= targetCollateral) {
            return 0;
        }

        // Borrowed value increases full position value 1:1, but borrowing
        // capacity only increases by the position's effective collateral
        // factor (collateralValue / fullValue). Solve
        //   (D + B) / (C + B*C/F) = target
        // rather than assuming the collateral factor is always 100%.
        uint256 denominator = BPS_DENOMINATOR * fullValue - targetCollateral;
        if (denominator == 0) {
            return 0;
        }

        borrowAmount = Math.mulDiv(targetCollateral - currentDebtBps, fullValue, denominator);
    }

    /// @notice Post-condition for one leverage adjustment.
    /// @dev Deleverage is a risk improvement whenever it lowers the debt ratio, even if execution
    ///      lands below target. Leverage-up must raise the ratio and must not cross the target by
    ///      more than `overshootToleranceBps`: overshoot means more leverage than the user asked
    ///      for, and since hook-managed swaps have no default price floor a bad fill is not bounded
    ///      to rounding dust. The tolerance keeps 1-wei landings above target from reverting.
    function improvesTowardTarget(
        uint256 debtBefore,
        uint256 collateralBefore,
        uint256 debtAfter,
        uint256 collateralAfter,
        uint256 targetRatioBps,
        uint256 overshootToleranceBps
    ) internal pure returns (bool) {
        if (collateralBefore == 0 || collateralAfter == 0) return false;
        uint256 ratioBefore = currentRatio(debtBefore, collateralBefore);
        uint256 ratioAfter = currentRatio(debtAfter, collateralAfter);

        if (ratioBefore > targetRatioBps) {
            return ratioAfter < ratioBefore;
        }
        return ratioAfter > ratioBefore && ratioAfter <= targetRatioBps + overshootToleranceBps;
    }

    function repayAmountToTarget(
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue,
        uint256 targetRatioBps
    ) internal pure returns (uint256 repayAmount) {
        uint256 currentDebtBps = currentDebt * BPS_DENOMINATOR;
        uint256 targetCollateral = collateralValue * targetRatioBps;
        if (fullValue == 0 || currentDebtBps <= targetCollateral) {
            return 0;
        }

        // Removing full-value R reduces borrowing capacity by R*C/F.
        uint256 denominator = BPS_DENOMINATOR * fullValue - targetCollateral;
        if (denominator == 0) {
            return 0;
        }

        repayAmount = Math.mulDiv(currentDebtBps - targetCollateral, fullValue, denominator);
    }

    function liquidityToRemove(
        uint128 currentLiquidity,
        uint256 removeValue,
        uint256 totalValue
    ) internal pure returns (uint128 liquidity) {
        if (currentLiquidity == 0 || removeValue == 0 || totalValue == 0) {
            return 0;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        liquidity = uint128(uint256(currentLiquidity) * removeValue / totalValue);
        if (liquidity > currentLiquidity) {
            liquidity = currentLiquidity;
        }
    }
}
