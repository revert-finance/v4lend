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

/// @dev Mirrors the real hook's public `poolManager` immutable (BaseHook), which the fee
///      controller reads to refuse the PoolManager as a fee recipient.
contract HookOwnerWithPoolManagerMock is HookOwnerMock {
    address public poolManager;

    constructor(address initialOwner, address poolManager_) HookOwnerMock(initialOwner) {
        poolManager = poolManager_;
    }
}

/// @dev A hook exposing both system-contract getters the fee controller consults.
contract HookOwnerWithSystemContractsMock is HookOwnerWithPoolManagerMock {
    address public positionManager;

    constructor(address initialOwner, address poolManager_, address positionManager_)
        HookOwnerWithPoolManagerMock(initialOwner, poolManager_)
    {
        positionManager = positionManager_;
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

    /// @notice L-08: fees are direct-sent (`take` / `transfer`) to the recipient, so the system's
    ///         own addresses - hook, controller, PoolManager - must be refused like address(0).
    function test_RevertWhenProtocolFeeRecipientIsHookOrController() public {
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(hook), address(hook), 200, 300);

        vm.startPrank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setProtocolFeeRecipient(address(hook));

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setProtocolFeeRecipient(address(controller));
        vm.stopPrank();

        assertEq(controller.protocolFeeRecipient(), RECIPIENT, "recipient unchanged after rejected updates");
    }

    function test_RevertWhenProtocolFeeRecipientIsPoolManager() public {
        address poolManager = makeAddr("poolManager");
        HookOwnerWithPoolManagerMock pmHook = new HookOwnerWithPoolManagerMock(OWNER, poolManager);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(pmHook), poolManager, 200, 300);

        HookFeeController pmController = new HookFeeController(address(pmHook), RECIPIENT, 200, 300);
        vm.prank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        pmController.setProtocolFeeRecipient(poolManager);

        // any other recipient still works against a hook that exposes poolManager()
        address other = makeAddr("other");
        vm.prank(OWNER);
        pmController.setProtocolFeeRecipient(other);
        assertEq(pmController.protocolFeeRecipient(), other);
    }

    /// @notice External audit V4LE-27: the v4 PositionManager's SWEEP action is permissionless and
    ///         hands its whole balance of a currency to any caller, so fees direct-sent there belong
    ///         to the first sweeper. It must be refused like the PoolManager; other recipients and a
    ///         hook without the getter (every other test in this file) keep working.
    function test_RevertWhenProtocolFeeRecipientIsPositionManager() public {
        address poolManager = makeAddr("poolManager");
        address posm = makeAddr("positionManager");
        HookOwnerWithSystemContractsMock sysHook = new HookOwnerWithSystemContractsMock(OWNER, poolManager, posm);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(sysHook), posm, 200, 300);

        HookFeeController sysController = new HookFeeController(address(sysHook), RECIPIENT, 200, 300);
        vm.startPrank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        sysController.setProtocolFeeRecipient(posm);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        sysController.setProtocolFeeRecipient(poolManager);

        address other = makeAddr("other");
        sysController.setProtocolFeeRecipient(other);
        vm.stopPrank();
        assertEq(sysController.protocolFeeRecipient(), other, "any other recipient is accepted");
    }

    /// @notice The deploy scripts create the controller BEFORE the hook, at the hook's predicted
    ///         address: the PoolManager lookup must tolerate a hook without code (and, as the base
    ///         mock shows throughout this file, one without the getter).
    function test_ConstructorToleratesUndeployedHook() public {
        address predictedHook = makeAddr("predictedHook");
        assertEq(predictedHook.code.length, 0, "precondition: no code at the predicted hook");
        HookFeeController predeployed = new HookFeeController(predictedHook, RECIPIENT, 200, 300);
        assertEq(predeployed.protocolFeeRecipient(), RECIPIENT);
        assertEq(predeployed.hook(), predictedHook);
    }

    function test_RevertWhenBpsAboveMax() public {
        uint16 gainCap = controller.MAX_GAIN_FEE_BPS();
        uint16 swapCap = controller.MAX_SWAP_FEE_BPS();
        assertEq(gainCap, 5000, "gain-fee cap");
        assertEq(swapCap, 1000, "swap-fee cap");

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(hook), RECIPIENT, gainCap + 1, 300);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        new HookFeeController(address(hook), RECIPIENT, 200, gainCap + 1);

        vm.startPrank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setLpFeeBps(gainCap + 1);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setAutoLendFeeBps(gainCap + 1);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), swapCap + 1);

        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setPoolOverrideSwapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT), swapCap + 1);

        // the caps themselves are accepted
        controller.setLpFeeBps(gainCap);
        controller.setAutoLendFeeBps(gainCap);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_COLLECT), swapCap);
        controller.setPoolOverrideSwapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT), swapCap);
        vm.stopPrank();

        assertEq(controller.lpFeeBps(), gainCap);
        assertEq(controller.autoLendFeeBps(), gainCap);
        assertEq(controller.swapFeeBps(DEFAULT_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT)), swapCap);
        assertEq(controller.swapFeeBps(OVERRIDE_POOL, uint8(RevertHookState.Mode.AUTO_COLLECT)), swapCap);

        // a swap fee is bounded by the tighter swap cap even though it fits the gain cap
        vm.prank(OWNER);
        vm.expectRevert(HookFeeController.InvalidConfig.selector);
        controller.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_RANGE), gainCap);
    }
}
