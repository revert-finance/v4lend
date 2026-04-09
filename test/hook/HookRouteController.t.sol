// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {HookRouteController} from "src/hook/HookRouteController.sol";
import {HookOwnedControllerBase} from "src/hook/HookOwnedControllerBase.sol";

contract RouteHookOwnerMock {
    address public owner;

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}

contract HookRouteControllerTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    address internal constant TOKEN2 = address(0x3000);

    RouteHookOwnerMock internal hook;
    HookRouteController internal controller;

    function setUp() public {
        hook = new RouteHookOwnerMock(OWNER);
        controller = new HookRouteController(address(hook));
    }

    function test_OnlyCurrentHookOwnerCanConfigure() public {
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        controller.setRoute(TOKEN0, TOKEN1, 3000, 60, IHooks(address(0xBEEF)));

        vm.prank(OWNER);
        controller.setRoute(TOKEN0, TOKEN1, 3000, 60, IHooks(address(0xBEEF)));
        (bool hasRoute, uint24 fee, int24 tickSpacing, IHooks hooks) = controller.route(TOKEN0, TOKEN1);
        assertTrue(hasRoute, "route should be stored");
        assertEq(fee, 3000, "fee should match route config");
        assertEq(tickSpacing, 60, "tick spacing should match route config");
        assertEq(address(hooks), address(0xBEEF), "hooks should match route config");

        address newOwner = makeAddr("newOwner");
        hook.setOwner(newOwner);

        vm.prank(newOwner);
        controller.clearRoute(TOKEN0, TOKEN1);

        vm.prank(OWNER);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        controller.setRoute(TOKEN0, TOKEN1, 3000, 60, IHooks(address(0xBEEF)));
    }

    function test_OrderedDirectionsAreIndependent() public {
        vm.startPrank(OWNER);
        controller.setRoute(TOKEN0, TOKEN1, 3000, 60, IHooks(address(0x1111)));
        controller.setRoute(TOKEN1, TOKEN0, 0, 120, IHooks(address(0x2222)));
        vm.stopPrank();

        (bool hasForwardRoute, uint24 forwardFee, int24 forwardTickSpacing, IHooks forwardHooks) =
            controller.route(TOKEN0, TOKEN1);
        (bool hasReverseRoute, uint24 reverseFee, int24 reverseTickSpacing, IHooks reverseHooks) =
            controller.route(TOKEN1, TOKEN0);

        assertTrue(hasForwardRoute, "forward route should exist");
        assertEq(forwardFee, 3000, "forward fee should match route config");
        assertEq(forwardTickSpacing, 60, "forward tick spacing should match route config");
        assertEq(address(forwardHooks), address(0x1111), "forward hooks should match route config");

        assertTrue(hasReverseRoute, "reverse route should exist");
        assertEq(reverseFee, 0, "reverse fee should allow explicit zero");
        assertEq(reverseTickSpacing, 120, "reverse tick spacing should match route config");
        assertEq(address(reverseHooks), address(0x2222), "reverse hooks should match route config");
    }

    function test_ClearRestoresFallbackState() public {
        vm.prank(OWNER);
        controller.setRoute(TOKEN0, TOKEN2, 500, 10, IHooks(address(0x3333)));

        vm.prank(OWNER);
        controller.clearRoute(TOKEN0, TOKEN2);

        (bool hasRoute, uint24 fee, int24 tickSpacing, IHooks hooks) = controller.route(TOKEN0, TOKEN2);
        assertFalse(hasRoute, "clear should remove the route");
        assertEq(fee, 0, "cleared fee should be zero");
        assertEq(tickSpacing, 0, "cleared tick spacing should be zero");
        assertEq(address(hooks), address(0), "cleared hooks should be zero");
    }

    function test_RevertOnInvalidConfig() public {
        vm.startPrank(OWNER);

        vm.expectRevert(HookRouteController.InvalidConfig.selector);
        controller.setRoute(TOKEN0, TOKEN0, 3000, 60, IHooks(address(0xBEEF)));

        vm.expectRevert(HookRouteController.InvalidConfig.selector);
        controller.setRoute(TOKEN0, TOKEN1, 3000, 0, IHooks(address(0xBEEF)));

        vm.expectRevert(HookRouteController.InvalidConfig.selector);
        controller.clearRoute(TOKEN1, TOKEN1);

        vm.stopPrank();
    }
}
