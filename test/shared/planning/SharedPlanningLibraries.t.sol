// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AutoLendLib} from "src/shared/planning/AutoLendLib.sol";
import {AutoLeverageLib} from "src/shared/planning/AutoLeverageLib.sol";
import {AutoRangeLib} from "src/shared/planning/AutoRangeLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract SharedPlanningLibrariesHarness {
    function planOneSidedReentry(
        int24 currentTick,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        bool isToken0Lent
    ) external pure returns (bool addToExisting, int24 newTickLower, int24 newTickUpper) {
        return AutoLendLib.planOneSidedReentry(currentTick, tickSpacing, tickLower, tickUpper, isToken0Lent);
    }

    function currentRatio(uint256 currentDebt, uint256 collateralValue) external pure returns (uint256) {
        return AutoLeverageLib.currentRatio(currentDebt, collateralValue);
    }

    function isWithinThreshold(uint256 currentRatioBps, uint256 targetRatioBps, uint256 thresholdBps)
        external
        pure
        returns (bool)
    {
        return AutoLeverageLib.isWithinThreshold(currentRatioBps, targetRatioBps, thresholdBps);
    }

    function borrowAmountToTarget(
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue,
        uint256 targetRatioBps
    ) external pure returns (uint256) {
        return AutoLeverageLib.borrowAmountToTarget(currentDebt, fullValue, collateralValue, targetRatioBps);
    }

    function repayAmountToTarget(
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue,
        uint256 targetRatioBps
    ) external pure returns (uint256) {
        return AutoLeverageLib.repayAmountToTarget(currentDebt, fullValue, collateralValue, targetRatioBps);
    }

    function improvesTowardTarget(
        uint256 debtBefore,
        uint256 collateralBefore,
        uint256 debtAfter,
        uint256 collateralAfter,
        uint256 targetRatioBps
    ) external pure returns (bool) {
        return AutoLeverageLib.improvesTowardTarget(
            debtBefore, collateralBefore, debtAfter, collateralAfter, targetRatioBps, 100
        );
    }

    function improvesTowardTargetWithTolerance(
        uint256 debtBefore,
        uint256 collateralBefore,
        uint256 debtAfter,
        uint256 collateralAfter,
        uint256 targetRatioBps,
        uint256 toleranceBps
    ) external pure returns (bool) {
        return AutoLeverageLib.improvesTowardTarget(
            debtBefore, collateralBefore, debtAfter, collateralAfter, targetRatioBps, toleranceBps
        );
    }

    function landsWithinTolerance(
        uint256 debtBefore,
        uint256 collateralBefore,
        uint256 debtAfter,
        uint256 collateralAfter,
        uint256 targetRatioBps,
        uint256 toleranceBps
    ) external pure returns (bool) {
        return AutoLeverageLib.landsWithinTolerance(
            debtBefore, collateralBefore, debtAfter, collateralAfter, targetRatioBps, toleranceBps
        );
    }

    function liquidityToRemove(uint128 currentLiquidity, uint256 removeValue, uint256 totalValue)
        external
        pure
        returns (uint128)
    {
        return AutoLeverageLib.liquidityToRemove(currentLiquidity, removeValue, totalValue);
    }

    function isRangeReady(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int24 lowerTickLimit,
        int24 upperTickLimit
    ) external pure returns (bool) {
        return AutoRangeLib.isReady(currentTick, tickLower, tickUpper, lowerTickLimit, upperTickLimit);
    }

    function planRange(int24 currentTick, int24 tickSpacing, int24 lowerTickDelta, int24 upperTickDelta)
        external
        pure
        returns (int24 newTickLower, int24 newTickUpper)
    {
        return AutoRangeLib.plan(currentTick, tickSpacing, lowerTickDelta, upperTickDelta);
    }

    function isValidRange(int24 tickLower, int24 tickUpper) external pure returns (bool) {
        return AutoRangeLib.isValidRange(tickLower, tickUpper);
    }

    function isSameRange(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper)
        external
        pure
        returns (bool)
    {
        return AutoRangeLib.isSameRange(oldTickLower, oldTickUpper, newTickLower, newTickUpper);
    }

    function floorToSpacing(int24 tick, int24 tickSpacing) external pure returns (int24) {
        return AutoRangeLib.floorToSpacing(tick, tickSpacing);
    }

    function floorToSpacingLend(int24 tick, int24 tickSpacing) external pure returns (int24) {
        return AutoLendLib.floorToSpacing(tick, tickSpacing);
    }
}

contract SharedPlanningLibrariesTest is Test {
    SharedPlanningLibrariesHarness internal harness;

    function setUp() public {
        harness = new SharedPlanningLibrariesHarness();
    }

    function testAutoLeverageLibCurrentRatioAndThreshold() public view {
        assertEq(harness.currentRatio(25, 100), 2500);
        assertTrue(harness.isWithinThreshold(5100, 5000, 200));
        assertFalse(harness.isWithinThreshold(5300, 5000, 200));
        assertFalse(harness.isWithinThreshold(4000, 5000, 1000));
        assertFalse(harness.isWithinThreshold(6000, 5000, 1000));
        assertTrue(harness.isWithinThreshold(4001, 5000, 1000));
        assertTrue(harness.isWithinThreshold(5999, 5000, 1000));
    }

    function testAutoLeverageLibBorrowAmountToTarget() public view {
        assertEq(harness.borrowAmountToTarget(2_000, 10_000, 10_000, 5_000), 6_000);
        assertEq(harness.borrowAmountToTarget(5_000, 10_000, 10_000, 5_000), 0);
        // 80% effective collateral factor: borrowing 3,333 grows collateral
        // by about 2,666, landing debt/collateral at the 50% target.
        assertEq(harness.borrowAmountToTarget(2_000, 10_000, 8_000, 5_000), 3_333);
    }

    function testAutoLeverageLibRepayAmountAndLiquidityToRemove() public view {
        assertEq(harness.repayAmountToTarget(7_000, 10_000, 10_000, 5_000), 4_000);
        assertEq(harness.repayAmountToTarget(7_000, 10_000, 8_000, 5_000), 5_000);
        assertEq(harness.liquidityToRemove(1_000, 4_000, 10_000), 400);
        assertEq(harness.liquidityToRemove(1_000, 10_000, 1), 1_000);
    }

    function testAutoLeverageLibRequiresMonotonicImprovement() public view {
        assertTrue(harness.improvesTowardTarget(2_000, 8_000, 4_000, 9_000, 5_000));
        assertTrue(harness.improvesTowardTarget(6_000, 10_000, 5_000, 10_000, 5_000));
        assertTrue(harness.improvesTowardTarget(6_000, 10_000, 100, 10_000, 5_000));
        assertFalse(harness.improvesTowardTarget(2_000, 8_000, 8_000, 9_000, 5_000));
        assertFalse(harness.improvesTowardTarget(6_000, 10_000, 6_100, 10_000, 5_000));
        assertFalse(harness.improvesTowardTarget(2_000, 8_000, 2_000, 8_000, 5_000));
    }

    /// @notice Leverage-up may not cross the target by more than the tolerance: overshoot hands the
    ///         user more leverage than configured, and a closer-but-above landing is not "better".
    function testAutoLeverageLibLeverageUpRejectsOvershoot() public view {
        // target 50%: 30% -> 68% is closer in distance terms but overshoots -> rejected
        assertFalse(harness.improvesTowardTargetWithTolerance(3_000, 10_000, 6_800, 10_000, 5_000, 100));
        // boundary: exactly target + tolerance passes, one bp more fails
        assertTrue(harness.improvesTowardTargetWithTolerance(3_000, 10_000, 5_100, 10_000, 5_000, 100));
        assertFalse(harness.improvesTowardTargetWithTolerance(3_000, 10_000, 5_101, 10_000, 5_000, 100));
        // landing exactly on or below target is fine; not moving is not
        assertTrue(harness.improvesTowardTargetWithTolerance(3_000, 10_000, 5_000, 10_000, 5_000, 0));
        assertTrue(harness.improvesTowardTargetWithTolerance(3_000, 10_000, 4_000, 10_000, 5_000, 0));
        assertFalse(harness.improvesTowardTargetWithTolerance(3_000, 10_000, 3_000, 10_000, 5_000, 0));
        // deleverage keeps its "any reduction" rule regardless of tolerance
        assertTrue(harness.improvesTowardTargetWithTolerance(8_000, 10_000, 1_000, 10_000, 5_000, 0));
    }

    /// @notice Operator-driven adjustments must land inside the band in both directions. A deleverage
    ///         that removes target-sized liquidity but repays only part of the proceeds still lowers the
    ///         ratio, and is exactly what the strict variant has to reject.
    function testAutoLeverageLibLandsWithinToleranceBindsDeleverageToBand() public view {
        // target 30%, band 100bps: 70% -> 57% is a decrease but far above the band -> rejected
        assertFalse(harness.landsWithinTolerance(7_000, 10_000, 2_875, 5_070, 3_000, 100));
        // honest landing on target passes, as does landing below it
        assertTrue(harness.landsWithinTolerance(7_000, 10_000, 1_521, 5_070, 3_000, 100));
        assertTrue(harness.landsWithinTolerance(7_000, 10_000, 1_000, 5_070, 3_000, 100));
        // boundary: exactly target + tolerance passes, one bp more fails
        assertTrue(harness.landsWithinTolerance(7_000, 10_000, 3_100, 10_000, 3_000, 100));
        assertFalse(harness.landsWithinTolerance(7_000, 10_000, 3_101, 10_000, 3_000, 100));
        // the ratio still has to move: starting on the band edge and staying there is rejected
        assertFalse(harness.landsWithinTolerance(3_100, 10_000, 3_100, 10_000, 3_000, 100));
        // leverage-up keeps the overshoot rule and must still increase the ratio
        assertTrue(harness.landsWithinTolerance(1_000, 10_000, 3_050, 10_000, 3_000, 100));
        assertFalse(harness.landsWithinTolerance(1_000, 10_000, 3_101, 10_000, 3_000, 100));
        assertFalse(harness.landsWithinTolerance(1_000, 10_000, 1_000, 10_000, 3_000, 100));
        // degenerate collateral is never an acceptable landing
        assertFalse(harness.landsWithinTolerance(7_000, 10_000, 0, 0, 3_000, 100));
        assertFalse(harness.landsWithinTolerance(7_000, 0, 0, 10_000, 3_000, 100));
    }

    function testAutoLeverageLibDegenerateInputsReturnZero() public view {
        assertEq(harness.currentRatio(1, 0), 0);
        assertEq(harness.borrowAmountToTarget(6_000, 10_000, 10_000, 5_000), 0);
        assertEq(harness.borrowAmountToTarget(1, 1, 1, 10_000), 0);
        assertEq(harness.repayAmountToTarget(4_000, 10_000, 10_000, 5_000), 0);
        assertEq(harness.repayAmountToTarget(1, 1, 1, 10_000), 0);
        assertEq(harness.liquidityToRemove(1_000, 0, 10_000), 0);
        assertEq(harness.liquidityToRemove(1_000, 10_000, 0), 0);
    }

    function testAutoLendLibPlanOneSidedReentryToken0AddToExisting() public view {
        (bool addToExisting, int24 newTickLower, int24 newTickUpper) =
            harness.planOneSidedReentry(-61, 60, -60, 60, true);

        assertTrue(addToExisting);
        assertEq(newTickLower, 0);
        assertEq(newTickUpper, 0);
    }

    function testAutoLendLibPlanOneSidedReentryToken0MintsShiftedRangeAtBoundary() public view {
        (bool addToExisting, int24 newTickLower, int24 newTickUpper) =
            harness.planOneSidedReentry(-60, 60, -60, 60, true);

        assertFalse(addToExisting);
        assertEq(newTickLower, 0);
        assertEq(newTickUpper, 120);
    }

    function testAutoLendLibPlanOneSidedReentryToken1AddsToExistingAtBoundary() public view {
        (bool addToExisting, int24 newTickLower, int24 newTickUpper) =
            harness.planOneSidedReentry(60, 60, -60, 60, false);

        assertTrue(addToExisting);
        assertEq(newTickLower, 0);
        assertEq(newTickUpper, 0);
    }

    function testAutoLendLibPlanOneSidedReentryToken1MintsShiftedRangeBelowBoundary() public view {
        (bool addToExisting, int24 newTickLower, int24 newTickUpper) =
            harness.planOneSidedReentry(59, 60, -60, 60, false);

        assertFalse(addToExisting);
        assertEq(newTickLower, -120);
        assertEq(newTickUpper, 0);
    }

    function testAutoRangeAndLendLibFloorTicks() public view {
        assertEq(harness.floorToSpacing(125, 60), 120);
        assertEq(harness.floorToSpacing(-125, 60), -180);
        assertEq(harness.floorToSpacingLend(-125, 60), -180);
    }

    function testAutoRangeLibReadinessMatchesPositiveAndNegativeLimits() public view {
        assertFalse(harness.isRangeReady(90, 100, 200, 10, 10));
        assertTrue(harness.isRangeReady(89, 100, 200, 10, 10));
        assertTrue(harness.isRangeReady(105, 100, 200, -10, 0));
        assertFalse(harness.isRangeReady(115, 100, 200, -10, 0));
        assertFalse(harness.isRangeReady(210, 100, 200, 10, 10));
        assertTrue(harness.isRangeReady(211, 100, 200, 10, 10));
        assertTrue(harness.isRangeReady(195, 100, 200, 0, -10));
        assertFalse(harness.isRangeReady(185, 100, 200, 0, -10));
        assertFalse(harness.isRangeReady(150, 100, 200, -10, -10));
        assertTrue(harness.isRangeReady(105, 100, 200, -10, -10));
    }

    function testAutoRangeLibBuildsShiftedRangeFromFlooredTick() public view {
        (int24 newTickLower, int24 newTickUpper) = harness.planRange(-125, 60, -120, 120);
        assertEq(newTickLower, -300);
        assertEq(newTickUpper, -60);
    }

    /// @dev V4LE-74: a shift from a bucket at the TickMath edge is clamped to the usable range
    ///      instead of producing ticks the liquidity planner rejects.
    function testAutoRangeLibClampsPlannedRangeToUsableTicks() public view {
        int24 maxUsable = TickMath.maxUsableTick(60); // 887220
        int24 minUsable = TickMath.minUsableTick(60); // -887220
        (int24 newTickLower, int24 newTickUpper) = harness.planRange(TickMath.MAX_TICK - 1, 60, -60, 60);
        assertEq(newTickLower, maxUsable - 60, "lower side untouched");
        assertEq(newTickUpper, maxUsable, "upper side clamped to maxUsableTick");

        (newTickLower, newTickUpper) = harness.planRange(TickMath.MIN_TICK, 60, -60, 60);
        assertEq(newTickLower, minUsable, "lower side clamped to minUsableTick");
        assertEq(newTickUpper, minUsable, "the shift from the sub-usable bucket collapses onto the edge");
        assertFalse(harness.isValidRange(newTickLower, newTickUpper), "callers must reject the collapsed range");

        (newTickLower, newTickUpper) = harness.planRange(minUsable, 60, -60, 120);
        assertEq(newTickLower, minUsable);
        assertEq(newTickUpper, minUsable + 120);
        assertTrue(harness.isValidRange(newTickLower, newTickUpper));
    }

    function testAutoRangeLibValidityAndSameRangeHelpers() public view {
        assertTrue(harness.isValidRange(-120, 120));
        assertFalse(harness.isValidRange(120, 120));
        assertFalse(harness.isValidRange(120, -120));
        assertTrue(harness.isSameRange(-120, 120, -120, 120));
        assertFalse(harness.isSameRange(-120, 120, -60, 120));
    }
}
