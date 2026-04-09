// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IHookRouteController {
    function route(address tokenIn, address tokenOut)
        external
        view
        returns (bool hasRoute, uint24 fee, int24 tickSpacing, IHooks hooks);
}
