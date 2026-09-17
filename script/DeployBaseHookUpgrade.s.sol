// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {V4Oracle, AggregatorV3Interface, IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import {LiquidityCalculator, ILiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {RevertHook} from "src/RevertHook.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {HookRouteController} from "src/hook/HookRouteController.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Deploys the corrected RevertHook stack against the existing funded
/// Base vault. The old hook and its positions remain untouched.
/// @dev LIMITATION: the existing vault predates `V4Vault._migrateHookState`, so a range
///      change through V4Utils (`CHANGE_RANGE` via `vault.transform`) on that vault does NOT
///      carry hook automation to the reminted position: the old NFT is drained and deactivated
///      and the new one has no config or triggers until the owner reconfigures it. Only the
///      hook's own auto-range remints self-migrate. Carrying automation across V4Utils remints on
///      Base requires redeploying the vault from this codebase. The old hook also stays in the
///      vault's hookAllowList; remove it once its positions have been unwound. RUNBOOK TRAP: as
///      soon as a vault built from this codebase is live, a transform that remints a position
///      on the OLD hook reverts while that hook is still allowlisted (it does not implement
///      migrateVaultPosition). Decide old-hook handling (unwind its positions, or de-allowlist
///      it) in the same upgrade batch.
contract DeployBaseHookUpgrade is Script {
    address constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    address constant ETH = address(0);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant UNISWAP_V3_USDC_WETH = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    address constant DEFAULT_ORACLE = 0x94C9bDeDB05358A98d95520205879d438419AB41;
    address constant DEFAULT_VAULT = 0xaf98803a1f43afC14335360e089F6B12947924ED;

    uint32 constant USDC_MAX_FEED_AGE = 25 hours;
    uint32 constant ORACLE_TWAP_SECONDS = 30 minutes;
    uint16 constant MAX_ORACLE_SOURCE_DIFFERENCE = 200;
    uint16 constant PROTOCOL_FEE_BPS = 100;
    int24 constant MAX_TICKS_FROM_ORACLE = 100;
    uint256 constant MIN_POSITION_VALUE_NATIVE = 0.01 ether;
    uint24 constant ETH_USDC_ROUTE_FEE = 500;
    int24 constant ETH_USDC_ROUTE_TICK_SPACING = 10;
    // WETH is accepted as collateral too and _resolveSwapPool matches token addresses exactly, so
    // WETH/USDC positions need their own route. Base's hookless WETH/USDC v4 liquidity sits in the
    // 0.3% pool; the 0.05% one is roughly 400x shallower and unusable as a route.
    uint24 constant WETH_USDC_ROUTE_FEE = 3000;
    int24 constant WETH_USDC_ROUTE_TICK_SPACING = 60;
    uint256 constant MAX_LOOP = 500_000;

    function run()
        external
        returns (
            LiquidityCalculator liquidityCalculator,
            HookFeeController feeController,
            HookRouteController routeController,
            RevertHookSwapActions swapActions,
            RevertHookPositionActions positionActions,
            RevertHookAutoLeverageActions autoLeverageActions,
            RevertHookAutoLendActions autoLendActions,
            RevertHook revertHook,
            V4Utils v4Utils
        )
    {
        require(block.chainid == 8453, "DeployBaseHookUpgrade: Base only");

        address deployer = msg.sender;
        V4Oracle oracle = V4Oracle(vm.envOr("EXISTING_V4_ORACLE", DEFAULT_ORACLE));
        V4Vault vault = V4Vault(payable(vm.envOr("EXISTING_V4_VAULT", DEFAULT_VAULT)));
        address zeroXAllowanceHolder = vm.envOr("ZEROX_ALLOWANCE_HOLDER", ZEROX_ALLOWANCE_HOLDER);

        require(address(oracle).code.length > 0, "DeployBaseHookUpgrade: oracle missing");
        require(address(vault).code.length > 0, "DeployBaseHookUpgrade: vault missing");
        require(oracle.owner() == deployer, "DeployBaseHookUpgrade: deployer not oracle owner");
        require(vault.owner() == deployer, "DeployBaseHookUpgrade: deployer not vault owner");
        require(address(oracle.positionManager()) == POSITION_MANAGER, "DeployBaseHookUpgrade: wrong position manager");
        require(vault.asset() == USDC, "DeployBaseHookUpgrade: wrong vault asset");

        vm.startBroadcast();

        liquidityCalculator = new LiquidityCalculator();

        uint64 hookSidecarNonce = vm.getNonce(deployer);
        address predictedFeeController = vm.computeCreateAddress(deployer, hookSidecarNonce);
        address predictedRouteController = vm.computeCreateAddress(deployer, hookSidecarNonce + 1);
        address predictedSwapActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 2);
        address predictedPositionActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 3);
        address predictedAutoLeverageActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 4);
        address predictedAutoLendActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 5);

        bytes memory constructorArgs = abi.encode(
            deployer,
            oracle,
            HookFeeController(predictedFeeController),
            RevertHookPositionActions(predictedPositionActions),
            RevertHookAutoLeverageActions(predictedAutoLeverageActions),
            RevertHookAutoLendActions(predictedAutoLendActions)
        );
        bytes memory creationCodeWithArgs = abi.encodePacked(type(RevertHook).creationCode, constructorArgs);
        (address expectedHookAddress, bytes32 salt) = _findHookSalt(creationCodeWithArgs);

        feeController = new HookFeeController(expectedHookAddress, deployer, PROTOCOL_FEE_BPS, PROTOCOL_FEE_BPS);
        require(address(feeController) == predictedFeeController, "fee controller address mismatch");

        routeController = new HookRouteController(expectedHookAddress);
        require(address(routeController) == predictedRouteController, "route controller address mismatch");

        swapActions = new RevertHookSwapActions(oracle.poolManager(), feeController);
        require(address(swapActions) == predictedSwapActions, "swap actions address mismatch");

        positionActions = new RevertHookPositionActions(
            IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), routeController, swapActions
        );
        require(address(positionActions) == predictedPositionActions, "position actions address mismatch");

        autoLeverageActions = new RevertHookAutoLeverageActions(
            IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), routeController, swapActions
        );
        require(address(autoLeverageActions) == predictedAutoLeverageActions, "auto leverage address mismatch");

        autoLendActions = new RevertHookAutoLendActions(
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator),
            feeController,
            routeController,
            swapActions
        );
        require(address(autoLendActions) == predictedAutoLendActions, "auto lend address mismatch");

        revertHook = new RevertHook{salt: salt}(
            deployer, oracle, feeController, positionActions, autoLeverageActions, autoLendActions
        );
        require(address(revertHook) == expectedHookAddress, "hook address mismatch");

        revertHook.setMaxTicksFromOracle(MAX_TICKS_FROM_ORACLE);
        revertHook.setMinPositionValueNative(MIN_POSITION_VALUE_NATIVE);
        routeController.setRoute(ETH, USDC, ETH_USDC_ROUTE_FEE, ETH_USDC_ROUTE_TICK_SPACING, IHooks(address(0)));
        routeController.setRoute(USDC, ETH, ETH_USDC_ROUTE_FEE, ETH_USDC_ROUTE_TICK_SPACING, IHooks(address(0)));
        routeController.setRoute(WETH, USDC, WETH_USDC_ROUTE_FEE, WETH_USDC_ROUTE_TICK_SPACING, IHooks(address(0)));
        routeController.setRoute(USDC, WETH, WETH_USDC_ROUTE_FEE, WETH_USDC_ROUTE_TICK_SPACING, IHooks(address(0)));

        // Use the candidate's Base USDC feed-age configuration on the oracle
        // shared by the existing vault and the replacement hook.
        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            USDC_MAX_FEED_AGE,
            IUniswapV3Pool(UNISWAP_V3_USDC_WETH),
            USDC,
            ORACLE_TWAP_SECONDS,
            V4Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            MAX_ORACLE_SOURCE_DIFFERENCE
        );

        revertHook.setVault(address(vault));
        revertHook.setAutoLendVault(USDC, vault);
        vault.setTransformer(address(revertHook), true);
        vault.setHookAllowList(address(revertHook), true);

        v4Utils =
            new V4Utils(IPositionManager(POSITION_MANAGER), UNIVERSAL_ROUTER, zeroXAllowanceHolder, IPermit2(PERMIT2));
        v4Utils.setVault(address(vault));
        vault.setTransformer(address(v4Utils), true);

        vm.stopBroadcast();

        console.log("LiquidityCalculator:", address(liquidityCalculator));
        console.log("HookFeeController:", address(feeController));
        console.log("HookRouteController:", address(routeController));
        console.log("RevertHookSwapActions:", address(swapActions));
        console.log("RevertHookPositionActions:", address(positionActions));
        console.log("RevertHookAutoLeverageActions:", address(autoLeverageActions));
        console.log("RevertHookAutoLendActions:", address(autoLendActions));
        console.log("RevertHook:", address(revertHook));
        console.log("NOTE: existing vault has no remint callback; V4Utils range changes do not migrate hook automation");
        console.log("V4Utils:", address(v4Utils));
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

    function _findHookSalt(bytes memory creationCodeWithArgs) private view returns (address hookAddress, bytes32 salt) {
        uint160 flags = _hookFlags() & Hooks.ALL_HOOK_MASK;
        for (uint256 i; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xFF), CREATE2_DEPLOYER, salt, keccak256(creationCodeWithArgs))
                        )
                    )
                )
            );
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }
        revert("DeployBaseHookUpgrade: could not find hook salt");
    }
}
