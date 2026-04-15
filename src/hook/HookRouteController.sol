// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {HookOwnedControllerBase} from "./HookOwnedControllerBase.sol";

contract HookRouteController is HookOwnedControllerBase, IHookRouteController {
    error InvalidConfig();

    event SetRoute(address indexed tokenIn, address indexed tokenOut, uint24 fee, int24 tickSpacing, IHooks hooks);
    event ClearRoute(address indexed tokenIn, address indexed tokenOut);

    struct Route {
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bool hasRoute;
    }

    mapping(address tokenIn => mapping(address tokenOut => Route routeConfig)) internal _routes;

    constructor(address hook_) HookOwnedControllerBase(hook_) {}

    function route(address tokenIn, address tokenOut)
        external
        view
        returns (bool hasRoute, uint24 fee, int24 tickSpacing, IHooks hooks)
    {
        Route memory routeConfig = _routes[tokenIn][tokenOut];
        return (routeConfig.hasRoute, routeConfig.fee, routeConfig.tickSpacing, routeConfig.hooks);
    }

    function setRoute(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, IHooks hooks) external {
        _checkOwner();
        if (tokenIn == tokenOut || tickSpacing <= 0 || fee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidConfig();
        }

        _routes[tokenIn][tokenOut] = Route({fee: fee, tickSpacing: tickSpacing, hooks: hooks, hasRoute: true});
        emit SetRoute(tokenIn, tokenOut, fee, tickSpacing, hooks);
    }

    function clearRoute(address tokenIn, address tokenOut) external {
        _checkOwner();
        if (tokenIn == tokenOut) {
            revert InvalidConfig();
        }

        delete _routes[tokenIn][tokenOut];
        emit ClearRoute(tokenIn, tokenOut);
    }
}
