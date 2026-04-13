// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RevertHookState} from "src/hook/RevertHookState.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {HookOwnedControllerBase} from "src/hook/HookOwnedControllerBase.sol";

contract HookOwnerMock {
    address public owner;

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}

contract HookFeeControllerTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);
    PoolId internal constant DEFAULT_POOL = PoolId.wrap(bytes32(uint256(1)));
    PoolId internal constant OVERRIDE_POOL = PoolId.wrap(bytes32(uint256(2)));

    HookOwnerMock internal hook;
    HookFeeController internal controller;

    function setUp() public {
        hook = new HookOwnerMock(OWNER);
        controller = new HookFeeController(address(hook), RECIPIENT, 200, 300);
    }

    function test_OnlyCurrentHookOwnerCanConfigure() public {
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), 100);

        vm.prank(OWNER);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), 100);
        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT)), 100);

        address newOwner = makeAddr("newOwner");
        hook.setOwner(newOwner);

        vm.prank(newOwner);
        controller.setLpFeeBps(250);
        assertEq(controller.lpFeeBps(), 250);

        vm.prank(OWNER);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        controller.setLpFeeBps(260);
    }

    function test_DefaultPerModeSwapFeeResolves() public {
        vm.prank(OWNER);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_RANGE), 321);

        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_RANGE)), 321);
        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT)), 0);
    }

    function test_PoolOverrideBeatsDefault() public {
        vm.startPrank(OWNER);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_EXIT), 100);
        controller.setPoolOverrideSwapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_EXIT), 777);
        vm.stopPrank();

        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_EXIT)), 100);
        assertEq(controller.swapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_EXIT)), 777);
    }

    function test_ExplicitZeroOverrideDisablesDefault() public {
        vm.startPrank(OWNER);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_LEVERAGE), 555);
        controller.setPoolOverrideSwapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_LEVERAGE), 0);
        vm.stopPrank();

        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_LEVERAGE)), 555);
        assertEq(controller.swapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_LEVERAGE)), 0);

        vm.prank(OWNER);
        controller.clearPoolOverrideSwapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_LEVERAGE));
        assertEq(controller.swapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_LEVERAGE)), 555);
    }

    function test_PoolOverridesAreScopedByPoolAndMode() public {
        vm.startPrank(OWNER);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), 100);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_RANGE), 200);
        controller.setPoolOverrideSwapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT), 777);
        vm.stopPrank();

        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT)), 100);
        assertEq(controller.swapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT)), 777);
        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_RANGE)), 200);
        assertEq(
            controller.swapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_RANGE)),
            200,
            "pool override should not leak across modes"
        );
    }

    function test_UnsupportedModesReturnZeroAndRejectConfig() public {
        uint8 unsupportedMode = uint8(RevertHookState.Mode.AUTO_LEND);
        uint8 unknownMode = type(uint8).max;

        assertEq(controller.swapFeeBps(DEFAULT_POOL, unsupportedMode), 0, "AUTO_LEND should not have swap fees");
        assertEq(controller.swapFeeBps(DEFAULT_POOL, unknownMode), 0, "unknown modes should resolve to zero");

        vm.startPrank(OWNER);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setDefaultSwapFeeBps(unsupportedMode, 100);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setPoolOverrideSwapFeeBps(OVERRIDE_POOL, unsupportedMode, 100);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.clearPoolOverrideSwapFeeBps(OVERRIDE_POOL, unsupportedMode);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setDefaultSwapFeeBps(unknownMode, 100);

        vm.stopPrank();
    }

    function test_FeeRecipientAndBpsUpdate() public {
        address newRecipient = makeAddr("newRecipient");

        vm.startPrank(OWNER);
        controller.setProtocolFeeRecipient(newRecipient);
        controller.setLpFeeBps(123);
        controller.setAutoLendFeeBps(456);
        vm.stopPrank();

        assertEq(controller.protocolFeeRecipient(), newRecipient);
        assertEq(controller.lpFeeBps(), 123);
        assertEq(controller.autoLendFeeBps(), 456);
    }

    function test_RevertWhenProtocolFeeRecipientIsZero() public {
        vm.expectRevert(HookOwnedControllerBase.InvalidHook.selector);
        new HookFeeController(address(0), RECIPIENT, 200, 300);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(hook), address(0), 200, 300);

        vm.prank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setProtocolFeeRecipient(address(0));
    }

    function test_RevertWhenBpsAboveMax() public {
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(hook), RECIPIENT, 10001, 300);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(hook), RECIPIENT, 200, 10001);

        vm.startPrank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setLpFeeBps(10001);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setAutoLendFeeBps(10001);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), 10001);
        vm.stopPrank();
    }
}
