// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AutoLendLib} from "../../src/lib/AutoLendLib.sol";
import {AutoLeverageLib} from "../../src/lib/AutoLeverageLib.sol";
import {AutoRangeLib} from "../../src/lib/AutoRangeLib.sol";

contract SharedPlanningLibrariesHarness {
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

    function borrowAmountToTarget(uint256 currentDebt, uint256 collateralValue, uint256 targetRatioBps)
        external
        pure
        returns (uint256)
    {
        return AutoLeverageLib.borrowAmountToTarget(currentDebt, collateralValue, targetRatioBps);
    }

    function repayAmountToTarget(uint256 currentDebt, uint256 collateralValue, uint256 targetRatioBps)
        external
        pure
        returns (uint256)
    {
        return AutoLeverageLib.repayAmountToTarget(currentDebt, collateralValue, targetRatioBps);
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
    }

    function testAutoLeverageLibBorrowAmountToTarget() public view {
        assertEq(harness.borrowAmountToTarget(2_000, 10_000, 5_000), 6_000);
        assertEq(harness.borrowAmountToTarget(5_000, 10_000, 5_000), 0);
    }

    function testAutoLeverageLibRepayAmountAndLiquidityToRemove() public view {
        assertEq(harness.repayAmountToTarget(7_000, 10_000, 5_000), 4_000);
        assertEq(harness.liquidityToRemove(1_000, 4_000, 10_000), 400);
        assertEq(harness.liquidityToRemove(1_000, 10_000, 1), 1_000);
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
    }

    function testAutoRangeLibBuildsShiftedRangeFromFlooredTick() public view {
        (int24 newTickLower, int24 newTickUpper) = harness.planRange(-125, 60, -120, 120);
        assertEq(newTickLower, -300);
        assertEq(newTickUpper, -60);
    }
}
