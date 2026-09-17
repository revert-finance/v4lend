// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Deployers} from "./Deployers.sol";
import {MockV4Oracle} from "./MockV4Oracle.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {HookRouteController} from "src/hook/HookRouteController.sol";
import {HookAuctionController} from "src/hook/HookAuctionController.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";

contract BaseTest is Test, Deployers {
    /// @notice Everything a test needs from a full RevertHook deployment.
    struct RevertHookStack {
        RevertHook hook;
        HookFeeController feeController;
        HookRouteController routeController;
        HookAuctionController auctionController;
        LiquidityCalculator liquidityCalculator;
        RevertHookAutoLendActions autoLendActions;
    }

    function deployArtifactsAndLabel() internal {
        deployArtifacts();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    /// @notice Deploys the complete RevertHook stack (controllers, delegatecall action targets,
    ///         and the hook itself via deployCodeTo) with a freshly created auction controller.
    ///         `flags` must encode the hook's permission bits; the caller becomes the hook owner.
    function deployRevertHookStack(address flags, MockV4Oracle v4Oracle, address protocolFeeRecipient)
        internal
        returns (RevertHookStack memory stack)
    {
        return _deployRevertHookStack(
            flags, v4Oracle, protocolFeeRecipient, address(new HookAuctionController(flags, poolManager))
        );
    }

    /// @notice Variant that wires a caller-supplied auction controller (a mock, or address(0)
    ///         for a hook without auctions).
    function deployRevertHookStackWithController(
        address flags,
        MockV4Oracle v4Oracle,
        address protocolFeeRecipient,
        address auctionController
    ) internal returns (RevertHookStack memory stack) {
        return _deployRevertHookStack(flags, v4Oracle, protocolFeeRecipient, auctionController);
    }

    function _deployRevertHookStack(
        address flags,
        MockV4Oracle v4Oracle,
        address protocolFeeRecipient,
        address auctionController
    ) internal returns (RevertHookStack memory stack) {
        stack.liquidityCalculator = new LiquidityCalculator();
        stack.feeController = new HookFeeController(flags, protocolFeeRecipient, 200, 200);
        stack.routeController = new HookRouteController(flags);
        stack.auctionController = HookAuctionController(auctionController);

        RevertHookSwapActions swapActions = new RevertHookSwapActions(v4Oracle.poolManager(), stack.feeController);
        RevertHookPositionActions positionActions = new RevertHookPositionActions(
            permit2, v4Oracle, stack.liquidityCalculator, stack.routeController, swapActions
        );
        RevertHookAutoLeverageActions autoLeverageActions = new RevertHookAutoLeverageActions(
            permit2, v4Oracle, stack.liquidityCalculator, stack.routeController, swapActions
        );
        stack.autoLendActions = new RevertHookAutoLendActions(
            permit2, v4Oracle, stack.liquidityCalculator, stack.feeController, stack.routeController, swapActions
        );

        bytes memory constructorArgs = abi.encode(
            address(this),
            v4Oracle,
            stack.feeController,
            auctionController,
            positionActions,
            autoLeverageActions,
            stack.autoLendActions
        );
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        stack.hook = RevertHook(payable(flags));
    }

    function deployCurrencyPair() internal virtual override returns (Currency currency0, Currency currency1) {
        (currency0, currency1) = super.deployCurrencyPair();

        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }
}