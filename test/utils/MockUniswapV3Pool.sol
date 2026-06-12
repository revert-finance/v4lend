// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUniswapV3Pool} from "src/oracle/V4Oracle.sol";

contract MockUniswapV3Pool is IUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;

    int24 public tick;
    bool public observeShouldRevert;

    constructor(address _token0, address _token1, int24 _tick) {
        token0 = _token0;
        token1 = _token1;
        tick = _tick;
    }

    function setTick(int24 _tick) external {
        tick = _tick;
    }

    function setObserveShouldRevert(bool shouldRevert) external {
        observeShouldRevert = shouldRevert;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtPriceAtTick(tick), tick, 0, 2, 2, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeShouldRevert) {
            revert("OBSERVE_FAILED");
        }

        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        int56 tickValue = int56(tick);
        int56 nowCumulative = tickValue * int56(uint56(block.timestamp));
        for (uint256 i; i < secondsAgos.length; i++) {
            tickCumulatives[i] = nowCumulative - tickValue * int56(uint56(secondsAgos[i]));
        }
    }
}
