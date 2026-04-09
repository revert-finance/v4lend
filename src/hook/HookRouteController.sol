// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IHookRouteController} from "./interfaces/IHookRouteController.sol";

interface IRouteHookOwner {
    function owner() external view returns (address);
}

contract HookRouteController is IHookRouteController {
    error Unauthorized();
    error InvalidConfig();

    event SetRoute(address indexed tokenIn, address indexed tokenOut, uint24 fee, int24 tickSpacing, IHooks hooks);
    event ClearRoute(address indexed tokenIn, address indexed tokenOut);

    struct Route {
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bool hasRoute;
    }

    address public immutable hook;

    mapping(address tokenIn => mapping(address tokenOut => Route routeConfig)) internal _routes;

    constructor(address hook_) {
        hook = hook_;
    }

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
        if (tokenIn == tokenOut || tickSpacing == 0) {
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

    function _checkOwner() internal view {
        if (msg.sender != IRouteHookOwner(hook).owner()) {
            revert Unauthorized();
        }
    }
}
