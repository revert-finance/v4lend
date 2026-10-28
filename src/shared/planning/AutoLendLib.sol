// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library AutoLendLib {
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24 baseTick) {
        // forge-lint: disable-next-line(divide-before-multiply)
        baseTick = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            baseTick -= tickSpacing;
        }
    }

    /// @dev Plans the one-sided re-entry range and clamps it to the pool's usable tick range. Near
    ///      TickMath's bounds the unclamped range would leave [minUsableTick, maxUsableTick], the
    ///      position manager would reject it and the fired automation trigger would be consumed for
    ///      nothing (V4LE-74): the clamped range is the nearest mintable one. A re-entry at the very
    ///      edge of the tick space has no room at all, so the clamp can also collapse the range
    ///      (newTickLower >= newTickUpper); callers check that before minting.
    function planOneSidedReentry(
        int24 currentTick,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        bool isToken0Lent
    ) internal pure returns (bool addToExisting, int24 newTickLower, int24 newTickUpper) {
        int24 baseTick = floorToSpacing(currentTick, tickSpacing);
        int24 tickWidth = tickUpper - tickLower;

        if (isToken0Lent) {
            addToExisting = baseTick < tickLower;
            if (!addToExisting) {
                newTickLower = baseTick + tickSpacing;
                newTickUpper = newTickLower + tickWidth;
            }
        } else {
            addToExisting = baseTick >= tickUpper;
            if (!addToExisting) {
                newTickLower = baseTick - tickWidth;
                newTickUpper = baseTick;
            }
        }

        if (!addToExisting) {
            int24 minTick = TickMath.minUsableTick(tickSpacing);
            int24 maxTick = TickMath.maxUsableTick(tickSpacing);
            if (newTickLower < minTick) newTickLower = minTick;
            if (newTickLower > maxTick) newTickLower = maxTick;
            if (newTickUpper > maxTick) newTickUpper = maxTick;
        }
    }
}
