// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {FlashloanLiquidator} from "src/vault/liquidation/FlashloanLiquidator.sol";
import {LeverageTransformer} from "src/vault/transformers/LeverageTransformer.sol";
import {LiquidityCalculator, ILiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {RevertHook} from "src/RevertHook.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title DeployBase
/// @notice Deployment script for RevertHook and all related contracts on Base
/// @dev Run with: forge script script/DeployBase.s.sol:DeployBase --chain-id 8453 --rpc-url <rpc> --broadcast --verify
contract DeployBase is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // ==================== Base Network Contract Addresses ====================
    // Source: https://docs.uniswap.org/contracts/v4/deployments

    IPositionManager constant POSITION_MANAGER = IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // CREATE2 Deployer Proxy used by Forge for CREATE2 deployments
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // 0x Protocol AllowanceHolder - overridable via env if needed
    address constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // ==================== Base Token Addresses ====================
    // Standard OP Stack WETH and native USDC on Base

    address constant WETH = 0x4200000000000000000000000000000000000006; // OP Stack standard WETH
    address constant ETH = address(0);
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Native USDC on Base

    // ==================== Chainlink Oracle Feed Addresses on Base ====================
    // Source: https://docs.chain.link/data-feeds/price-feeds/addresses?network=base

    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    // L2 Sequencer Uptime Feed for Base (Optimism-based L2)
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // ==================== Configuration Constants ====================

    uint32 constant MAX_FEED_AGE = 86400; // 24 hours max feed age
    uint16 constant MAX_POOL_PRICE_DIFFERENCE = 200; // 2% max difference between pool and oracle price

    // Interest rate model parameters (similar to Compound V2)
    uint256 constant BASE_RATE_PER_YEAR = 0; // 0% base rate
    uint256 constant MULTIPLIER_PER_YEAR = Q64 * 5 / 100; // 5% at kink
    uint256 constant JUMP_MULTIPLIER_PER_YEAR = Q64 * 109 / 100; // 109% above kink
    uint256 constant KINK = Q64 * 80 / 100; // 80% utilization kink

    // Collateral factors (in Q32 format)
    uint32 constant CF_STABLECOIN = uint32(Q32 * 850 / 1000); // 85% for stablecoins
    uint32 constant CF_ETH = uint32(Q32 * 775 / 1000); // 77.5% for ETH

    // RevertHook configuration
    uint16 constant PROTOCOL_FEE_BPS = 100; // 1% protocol fee
    int24 constant MAX_TICKS_FROM_ORACLE = 100; // Max tick deviation from oracle price
    uint256 constant MIN_POSITION_VALUE_NATIVE = 0.01 ether; // Minimum position value

    // Vault configuration
    uint256 constant MIN_LOAN_SIZE = 100000; // 0.1 USDC (6 decimals)
    uint256 constant GLOBAL_LEND_LIMIT = 1000000000000; // 1M USDC
    uint256 constant GLOBAL_DEBT_LIMIT = 399000000000000; // 399M USDC
    uint256 constant DAILY_LEND_INCREASE_LIMIT_MIN = 100000000000; // 100K USDC
    uint256 constant DAILY_DEBT_INCREASE_LIMIT_MIN = 75000000000; // 75K USDC

    // Maximum iterations for hook address mining
    uint256 constant MAX_LOOP = 500_000;

    /// @notice RevertHook required flags based on getHookPermissions()
    /// afterInitialize, beforeAddLiquidity, afterAddLiquidity, afterRemoveLiquidity, afterSwap,
    /// afterAddLiquidityReturnDelta, afterRemoveLiquidityReturnDelta
    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

    /// @notice Find a salt that produces a hook address with the correct flags
    /// @dev Uses CREATE2 address computation to mine for valid hook addresses
    /// @param deployer The address that will deploy the hook (msg.sender in broadcast context)
    /// @param creationCodeWithArgs The creation code with constructor args appended
    function findHookSalt(address deployer, bytes memory creationCodeWithArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        uint160 flags = getHookFlags();
        uint160 flagMask = Hooks.ALL_HOOK_MASK;
        flags = flags & flagMask;

        for (uint256 i; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeCreate2Address(deployer, salt, creationCodeWithArgs);

            if (uint160(hookAddress) & flagMask == flags && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }
        revert("DeployBase: could not find valid hook salt");
    }

    /// @notice Compute CREATE2 address
    /// @param deployer The address deploying the contract
    /// @param salt The CREATE2 salt
    /// @param creationCodeWithArgs The creation code with constructor args
    function computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs))))
            )
        );
    }

    function run() external {
        // Get deployer address for protocol fee recipient
        address deployer = msg.sender;
        address zeroXAllowanceHolder = vm.envOr("ZEROX_ALLOWANCE_HOLDER", ZEROX_ALLOWANCE_HOLDER);
        address sequencerUptimeFeed = vm.envOr("SEQUENCER_UPTIME_FEED", SEQUENCER_UPTIME_FEED);

        vm.startBroadcast();

        console.log("===========================================");
        console.log("Deploying Revert V4Utils on Base Network...");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("0x AllowanceHolder:", zeroXAllowanceHolder);
        console.log("Sequencer Uptime Feed:", sequencerUptimeFeed);
        console.log("");

        // ==================== Step 1: Deploy Core Infrastructure ====================

        console.log("Step 1: Deploying Core Infrastructure...");

        // Deploy InterestRateModel (Compound V2-style rates)
        InterestRateModel interestRateModel =
            new InterestRateModel(BASE_RATE_PER_YEAR, MULTIPLIER_PER_YEAR, JUMP_MULTIPLIER_PER_YEAR, KINK);
        console.log("  InterestRateModel deployed at:", address(interestRateModel));

        // Deploy LiquidityCalculator (stateless math library)
        LiquidityCalculator liquidityCalculator = new LiquidityCalculator();
        console.log("  LiquidityCalculator deployed at:", address(liquidityCalculator));

        // ==================== Step 2: Deploy V4Oracle ====================

        console.log("Step 2: Deploying V4Oracle...");

        // Deploy V4Oracle with WETH as reference token and USD (address(0)) as chainlink reference
        V4Oracle oracle = new V4Oracle(POSITION_MANAGER, WETH, address(0));
        console.log("  V4Oracle deployed at:", address(oracle));

        // Configure oracle settings
        oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        if (sequencerUptimeFeed != address(0)) {
            oracle.setSequencerUptimeFeed(sequencerUptimeFeed);
            console.log("  Configured sequencer uptime feed");
        }

        // Configure ETH/USD feed (for WETH and native ETH)
        oracle.setTokenConfig(WETH, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(ETH, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        console.log("  Configured ETH/USD feed");

        // Configure USDC/USD feed
        oracle.setTokenConfig(USDC, AggregatorV3Interface(CHAINLINK_USDC_USD), MAX_FEED_AGE);
        console.log("  Configured USDC/USD feed");

        // ==================== Step 3: Deploy RevertHook action contracts ====================

        console.log("Step 3: Deploying RevertHook action contracts...");
        uint64 hookSidecarNonce = vm.getNonce(deployer);
        address predictedFeeController = vm.computeCreateAddress(deployer, hookSidecarNonce);
        address predictedSwapActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 1);
        address predictedPositionActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 2);
        address predictedAutoLeverageActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 3);
        address predictedAutoLendActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 4);

        bytes memory constructorArgs = abi.encode(
            deployer,
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator),
            HookFeeController(predictedFeeController),
            RevertHookPositionActions(predictedPositionActions),
            RevertHookAutoLeverageActions(predictedAutoLeverageActions),
            RevertHookAutoLendActions(predictedAutoLendActions)
        );
        bytes memory creationCodeWithArgs = abi.encodePacked(type(RevertHook).creationCode, constructorArgs);

        // ==================== Step 4: Deploy RevertHook with CREATE2 ====================

        console.log("Step 4: Deploying RevertHook with CREATE2 address mining...");
        console.log("  Mining for valid hook address...");
        (address expectedHookAddress, bytes32 salt) = findHookSalt(CREATE2_DEPLOYER, creationCodeWithArgs);
        console.log("  Found valid hook address:", expectedHookAddress);
        console.log("  Using salt:", vm.toString(salt));

        HookFeeController feeController =
            new HookFeeController(expectedHookAddress, deployer, PROTOCOL_FEE_BPS, PROTOCOL_FEE_BPS);
        require(address(feeController) == predictedFeeController, "Fee controller address mismatch");
        console.log("  HookFeeController deployed at:", address(feeController));
        RevertHookSwapActions swapActions = new RevertHookSwapActions(oracle, feeController);
        require(address(swapActions) == predictedSwapActions, "Swap actions address mismatch");
        console.log("  RevertHookSwapActions deployed at:", address(swapActions));

        // Deploy RevertHookPositionActions (delegatecall target 1)
        RevertHookPositionActions positionActions =
            new RevertHookPositionActions(
                IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), feeController, swapActions
            );
        console.log("  RevertHookPositionActions deployed at:", address(positionActions));

        // Deploy RevertHookAutoLeverageActions (delegatecall target 2)
        RevertHookAutoLeverageActions autoLeverageActions =
            new RevertHookAutoLeverageActions(
                IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), feeController, swapActions
            );
        console.log("  RevertHookAutoLeverageActions deployed at:", address(autoLeverageActions));

        RevertHookAutoLendActions autoLendActions =
            new RevertHookAutoLendActions(
                IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), feeController, swapActions
            );
        console.log("  RevertHookAutoLendActions deployed at:", address(autoLendActions));

        // Deploy RevertHook using CREATE2
        RevertHook revertHook = new RevertHook{salt: salt}(
            deployer, // owner
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator),
            feeController,
            positionActions,
            autoLeverageActions,
            autoLendActions
        );
        require(address(revertHook) == expectedHookAddress, "Hook address mismatch");
        console.log("  RevertHook deployed at:", address(revertHook));

        // Configure RevertHook settings
        revertHook.setMaxTicksFromOracle(MAX_TICKS_FROM_ORACLE);
        revertHook.setMinPositionValueNative(MIN_POSITION_VALUE_NATIVE);
        console.log("  RevertHook configured");

        // ==================== Step 5: Deploy V4Vault (USDC lending) ====================

        console.log("Step 5: Deploying V4Vault (USDC)...");

        V4Vault vault =
            new V4Vault("Revert Lend USDC", "rlUSDC", USDC, POSITION_MANAGER, interestRateModel, oracle, IWETH9(WETH));
        console.log("  V4Vault deployed at:", address(vault));

        // Configure collateral tokens
        vault.setTokenConfig(USDC, CF_STABLECOIN, type(uint32).max);
        vault.setTokenConfig(WETH, CF_ETH, type(uint32).max);
        vault.setTokenConfig(ETH, CF_ETH, type(uint32).max);
        console.log("  Configured collateral tokens (USDC, WETH, ETH)");

        // Configure vault limits
        vault.setLimits(
            MIN_LOAN_SIZE,
            GLOBAL_LEND_LIMIT,
            GLOBAL_DEBT_LIMIT,
            DAILY_LEND_INCREASE_LIMIT_MIN,
            DAILY_DEBT_INCREASE_LIMIT_MIN
        );
        vault.setReserveFactor(uint32(Q32 * 10 / 100)); // 10% reserve factor
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100)); // 5% reserve protection
        console.log("  Configured vault limits and reserve factors");

        // ==================== Step 6: Deploy Transformers ====================

        console.log("Step 6: Deploying Transformers...");

        // Deploy FlashloanLiquidator
        FlashloanLiquidator flashloanLiquidator =
            new FlashloanLiquidator(POSITION_MANAGER, UNIVERSAL_ROUTER, zeroXAllowanceHolder);
        console.log("  FlashloanLiquidator deployed at:", address(flashloanLiquidator));

        // Deploy V4Utils
        V4Utils v4Utils = new V4Utils(POSITION_MANAGER, UNIVERSAL_ROUTER, zeroXAllowanceHolder, IPermit2(PERMIT2));
        console.log("  V4Utils deployed at:", address(v4Utils));

        // Deploy LeverageTransformer
        LeverageTransformer leverageTransformer =
            new LeverageTransformer(POSITION_MANAGER, UNIVERSAL_ROUTER, zeroXAllowanceHolder, IPermit2(PERMIT2));
        console.log("  LeverageTransformer deployed at:", address(leverageTransformer));

        // ==================== Step 7: Configure Integrations ====================

        console.log("Step 7: Configuring Integrations...");

        // Register V4Utils with vault as transformer
        v4Utils.setVault(address(vault));
        vault.setTransformer(address(v4Utils), true);
        console.log("  V4Utils registered with vault");

        // Register LeverageTransformer with vault as transformer
        leverageTransformer.setVault(address(vault));
        vault.setTransformer(address(leverageTransformer), true);
        console.log("  LeverageTransformer registered with vault");

        // Register RevertHook with vault as transformer
        revertHook.setVault(address(vault));
        vault.setTransformer(address(revertHook), true);
        console.log("  RevertHook registered as vault transformer");

        // Allow RevertHook in vault hook allowlist
        vault.setHookAllowList(address(revertHook), true);
        console.log("  RevertHook added to vault hook allowlist");

        // Set up auto-lend vault in RevertHook for USDC
        revertHook.setAutoLendVault(USDC, vault);
        console.log("  Auto-lend vault configured for USDC");

        vm.stopBroadcast();

        // ==================== Deployment Summary ====================

        console.log("");
        console.log("===========================================");
        console.log("         DEPLOYMENT SUMMARY                ");
        console.log("===========================================");
        console.log("Network: Base (Chain ID: 8453)");
        console.log("-------------------------------------------");
        console.log("Core Infrastructure:");
        console.log("  InterestRateModel:     ", address(interestRateModel));
        console.log("  LiquidityCalculator:   ", address(liquidityCalculator));
        console.log("  V4Oracle:              ", address(oracle));
        console.log("-------------------------------------------");
        console.log("Hook Contracts:");
        console.log("  RevertHookPositionActions:", address(positionActions));
        console.log("  RevertHookAutoLeverageActions: ", address(autoLeverageActions));
        console.log("  RevertHookAutoLendActions:", address(autoLendActions));
        console.log("  RevertHook:            ", address(revertHook));
        console.log("-------------------------------------------");
        console.log("Vault & Transformers:");
        console.log("  V4Vault (rlUSDC):      ", address(vault));
        console.log("  V4Utils:               ", address(v4Utils));
        console.log("  LeverageTransformer:   ", address(leverageTransformer));
        console.log("  FlashloanLiquidator:   ", address(flashloanLiquidator));
        console.log("===========================================");
    }
}
