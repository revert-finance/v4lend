// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library AutoRangeLib {
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24 baseTick) {
        // forge-lint: disable-next-line(divide-before-multiply)
        baseTick = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            baseTick -= tickSpacing;
        }
    }

    function isReady(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int24 lowerTickLimit,
        int24 upperTickLimit
    ) internal pure returns (bool) {
        if (
            (lowerTickLimit == 0 || currentTick >= tickLower - lowerTickLimit)
                && (upperTickLimit == 0 || currentTick <= tickUpper + upperTickLimit)
        ) {
            if (lowerTickLimit >= 0 && upperTickLimit >= 0) {
                return false;
            }
            if (lowerTickLimit < 0 && currentTick < tickLower - lowerTickLimit) {
                return true;
            }
            return upperTickLimit < 0 && currentTick > tickUpper + upperTickLimit;
        }

        return true;
    }

    /// @dev Shifts the configured deltas from the floored current tick and clamps the result to the
    ///      pool's usable tick range. Near TickMath's bounds the unclamped range would fall outside
    ///      [MIN_TICK, MAX_TICK], the liquidity planner would reject it and the fired trigger would
    ///      be consumed for nothing (V4LE-74); the clamped range is the nearest mintable one. The
    ///      clamp can collapse the range (both bounds at the same edge): callers check isValidRange.
    function plan(
        int24 currentTick,
        int24 tickSpacing,
        int24 lowerTickDelta,
        int24 upperTickDelta
    ) internal pure returns (int24 newTickLower, int24 newTickUpper) {
        int24 baseTick = floorToSpacing(currentTick, tickSpacing);
        newTickLower = baseTick + lowerTickDelta;
        newTickUpper = baseTick + upperTickDelta;
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (newTickLower < minTick) newTickLower = minTick;
        if (newTickUpper > maxTick) newTickUpper = maxTick;
    }

    function isValidRange(int24 tickLower, int24 tickUpper) internal pure returns (bool) {
        return tickLower < tickUpper;
    }

    function isSameRange(
        int24 currentTickLower,
        int24 currentTickUpper,
        int24 newTickLower,
        int24 newTickUpper
    ) internal pure returns (bool) {
        return currentTickLower == newTickLower && currentTickUpper == newTickUpper;
    }
}
