// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

library AutoLendLib {
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24 baseTick) {
        // forge-lint: disable-next-line(divide-before-multiply)
        baseTick = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            baseTick -= tickSpacing;
        }
    }

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
    }
}
