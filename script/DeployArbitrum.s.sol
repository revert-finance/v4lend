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
import {HookRouteController} from "src/hook/HookRouteController.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title DeployArbitrum
/// @notice Deployment script for RevertHook and all related contracts on Arbitrum One
/// @dev Run with: forge script script/DeployArbitrum.s.sol:DeployArbitrum --chain-id 42161 --rpc-url <rpc> --broadcast --verify
contract DeployArbitrum is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // ==================== Arbitrum Network Contract Addresses ====================
    // Source: https://docs.uniswap.org/contracts/v4/deployments

    IPositionManager constant POSITION_MANAGER = IPositionManager(0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869);
    address constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // CREATE2 Deployer Proxy used by Forge for CREATE2 deployments
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // 0x Protocol AllowanceHolder - overridable via env if needed
    // Source: https://docs.0x.org/docs/core-concepts/0x-cheat-sheet
    address constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // ==================== Arbitrum Token Addresses ====================
    // Asset and collateral set copied from lend-v3 Arbitrum deployment.
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDC_E = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ETH = address(0);
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    // ==================== Arbitrum Oracle Feed Addresses ====================
    // Token feed set copied from lend-v3 Arbitrum deployment.
    address constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant CHAINLINK_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address constant CHAINLINK_DAI_USD = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant CHAINLINK_ARB_USD = 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6;

    // L2 Sequencer Uptime Feed for Arbitrum
    address constant SEQUENCER_UPTIME_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // ==================== Configuration Constants ====================

    uint32 constant MAX_FEED_AGE = 86400; // 24 hours max feed age
    uint16 constant MAX_POOL_PRICE_DIFFERENCE = 200; // 2% max difference between pool and oracle price

    uint256 constant BASE_RATE_PER_YEAR = 0; // 0% base rate
    uint256 constant MULTIPLIER_PER_YEAR = Q64 * 5 / 100; // 5% at kink
    uint256 constant JUMP_MULTIPLIER_PER_YEAR = Q64 * 109 / 100; // 109% above kink
    uint256 constant KINK = Q64 * 80 / 100; // 80% utilization kink

    // Collateral factors / value caps mapped from lend-v3 deployment.
    uint32 constant CF_STABLECOIN = uint32(Q32 * 850 / 1000); // 85%
    uint32 constant CF_ETH = uint32(Q32 * 775 / 1000); // 77.5%
    uint32 constant CF_BTC = uint32(Q32 * 775 / 1000); // 77.5%
    uint32 constant CF_ARB = uint32(Q32 * 600 / 1000); // 60%

    uint32 constant LIMIT_FULL = type(uint32).max;
    uint32 constant LIMIT_20_PCT = uint32(Q32 * 20 / 100);

    uint16 constant PROTOCOL_FEE_BPS = 100; // 1% protocol fee
    int24 constant MAX_TICKS_FROM_ORACLE = 100;
    uint256 constant MIN_POSITION_VALUE_NATIVE = 0.01 ether;

    uint256 constant MIN_LOAN_SIZE = 100000; // 0.1 USDC (6 decimals)
    uint256 constant GLOBAL_LEND_LIMIT = 1000000000000; // 1M USDC
    uint256 constant GLOBAL_DEBT_LIMIT = 399000000000000; // 399M USDC
    uint256 constant DAILY_LEND_INCREASE_LIMIT_MIN = 100000000000; // 100K USDC
    uint256 constant DAILY_DEBT_INCREASE_LIMIT_MIN = 75000000000; // 75K USDC

    uint256 constant MAX_LOOP = 500_000;

    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

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
        revert("DeployArbitrum: could not find valid hook salt");
    }

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
        address deployer = msg.sender;
        address zeroXAllowanceHolder = vm.envOr("ZEROX_ALLOWANCE_HOLDER", ZEROX_ALLOWANCE_HOLDER);
        address sequencerUptimeFeed = vm.envOr("SEQUENCER_UPTIME_FEED", SEQUENCER_UPTIME_FEED);

        vm.startBroadcast();

        console.log("==============================================");
        console.log("Deploying Revert infrastructure on Arbitrum...");
        console.log("==============================================");
        console.log("Deployer:", deployer);
        console.log("0x AllowanceHolder:", zeroXAllowanceHolder);
        console.log("Sequencer Uptime Feed:", sequencerUptimeFeed);
        console.log("");

        console.log("Step 1: Deploying Core Infrastructure...");
        InterestRateModel interestRateModel =
            new InterestRateModel(BASE_RATE_PER_YEAR, MULTIPLIER_PER_YEAR, JUMP_MULTIPLIER_PER_YEAR, KINK);
        console.log("  InterestRateModel deployed at:", address(interestRateModel));

        LiquidityCalculator liquidityCalculator = new LiquidityCalculator();
        console.log("  LiquidityCalculator deployed at:", address(liquidityCalculator));

        console.log("Step 2: Deploying V4Oracle...");
        V4Oracle oracle = new V4Oracle(POSITION_MANAGER, WETH, address(0));
        console.log("  V4Oracle deployed at:", address(oracle));

        oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        if (sequencerUptimeFeed != address(0)) {
            oracle.setSequencerUptimeFeed(sequencerUptimeFeed);
            console.log("  Configured sequencer uptime feed");
        }

        oracle.setTokenConfig(USDC, AggregatorV3Interface(CHAINLINK_USDC_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(USDC_E, AggregatorV3Interface(CHAINLINK_USDC_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(USDT, AggregatorV3Interface(CHAINLINK_USDT_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(DAI, AggregatorV3Interface(CHAINLINK_DAI_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(WETH, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(ETH, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(WBTC, AggregatorV3Interface(CHAINLINK_BTC_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(ARB, AggregatorV3Interface(CHAINLINK_ARB_USD), MAX_FEED_AGE);
        console.log("  Configured USDC, USDC.e, USDT, DAI, ETH, WBTC, and ARB feeds");

        console.log("Step 3: Deploying RevertHook action contracts...");
        uint64 hookSidecarNonce = vm.getNonce(deployer);
        address predictedFeeController = vm.computeCreateAddress(deployer, hookSidecarNonce);
        address predictedRouteController = vm.computeCreateAddress(deployer, hookSidecarNonce + 1);
        address predictedSwapActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 2);
        address predictedPositionActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 3);
        address predictedAutoLeverageActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 4);
        address predictedAutoLendActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 5);

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

        console.log("Step 4: Deploying RevertHook with CREATE2 address mining...");
        console.log("  Mining for valid hook address...");
        (address expectedHookAddress, bytes32 salt) = findHookSalt(CREATE2_DEPLOYER, creationCodeWithArgs);
        console.log("  Found valid hook address:", expectedHookAddress);
        console.log("  Using salt:", vm.toString(salt));

        HookFeeController feeController =
            new HookFeeController(expectedHookAddress, deployer, PROTOCOL_FEE_BPS, PROTOCOL_FEE_BPS);
        require(address(feeController) == predictedFeeController, "Fee controller address mismatch");
        console.log("  HookFeeController deployed at:", address(feeController));
        HookRouteController routeController = new HookRouteController(expectedHookAddress);
        require(address(routeController) == predictedRouteController, "Route controller address mismatch");
        console.log("  HookRouteController deployed at:", address(routeController));
        RevertHookSwapActions swapActions = new RevertHookSwapActions(oracle, feeController);
        require(address(swapActions) == predictedSwapActions, "Swap actions address mismatch");
        console.log("  RevertHookSwapActions deployed at:", address(swapActions));

        RevertHookPositionActions positionActions = new RevertHookPositionActions(
            IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), routeController, swapActions
        );
        console.log("  RevertHookPositionActions deployed at:", address(positionActions));

        RevertHookAutoLeverageActions autoLeverageActions =
            new RevertHookAutoLeverageActions(
                IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator), routeController, swapActions
            );
        console.log("  RevertHookAutoLeverageActions deployed at:", address(autoLeverageActions));

        RevertHookAutoLendActions autoLendActions =
            new RevertHookAutoLendActions(
                IPermit2(PERMIT2),
                oracle,
                ILiquidityCalculator(liquidityCalculator),
                feeController,
                routeController,
                swapActions
            );
        console.log("  RevertHookAutoLendActions deployed at:", address(autoLendActions));

        RevertHook revertHook = new RevertHook{salt: salt}(
            deployer,
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

        revertHook.setMaxTicksFromOracle(MAX_TICKS_FROM_ORACLE);
        revertHook.setMinPositionValueNative(MIN_POSITION_VALUE_NATIVE);
        console.log("  RevertHook configured");

        console.log("Step 5: Deploying V4Vault (USDC)...");
        V4Vault vault =
            new V4Vault("Revert Lend Arbitrum USDC", "rlArbUSDC", USDC, POSITION_MANAGER, interestRateModel, oracle, IWETH9(WETH));
        console.log("  V4Vault deployed at:", address(vault));

        vault.setTokenConfig(USDC, CF_STABLECOIN, LIMIT_FULL);
        vault.setTokenConfig(USDC_E, CF_STABLECOIN, LIMIT_FULL);
        vault.setTokenConfig(USDT, CF_STABLECOIN, LIMIT_20_PCT);
        vault.setTokenConfig(DAI, CF_STABLECOIN, LIMIT_FULL);
        vault.setTokenConfig(WETH, CF_ETH, LIMIT_FULL);
        vault.setTokenConfig(ETH, CF_ETH, LIMIT_FULL);
        vault.setTokenConfig(WBTC, CF_BTC, LIMIT_FULL);
        vault.setTokenConfig(ARB, CF_ARB, LIMIT_20_PCT);
        console.log("  Configured collateral tokens from lend-v3 Arbitrum support set");

        vault.setLimits(
            MIN_LOAN_SIZE,
            GLOBAL_LEND_LIMIT,
            GLOBAL_DEBT_LIMIT,
            DAILY_LEND_INCREASE_LIMIT_MIN,
            DAILY_DEBT_INCREASE_LIMIT_MIN
        );
        vault.setReserveFactor(uint32(Q32 * 10 / 100));
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));
        console.log("  Configured vault limits and reserve factors");

        console.log("Step 6: Deploying transformers...");
        FlashloanLiquidator flashloanLiquidator =
            new FlashloanLiquidator(POSITION_MANAGER, UNIVERSAL_ROUTER, zeroXAllowanceHolder);
        console.log("  FlashloanLiquidator deployed at:", address(flashloanLiquidator));

        V4Utils v4Utils = new V4Utils(POSITION_MANAGER, UNIVERSAL_ROUTER, zeroXAllowanceHolder, IPermit2(PERMIT2));
        console.log("  V4Utils deployed at:", address(v4Utils));

        LeverageTransformer leverageTransformer =
            new LeverageTransformer(POSITION_MANAGER, UNIVERSAL_ROUTER, zeroXAllowanceHolder, IPermit2(PERMIT2));
        console.log("  LeverageTransformer deployed at:", address(leverageTransformer));

        console.log("Step 7: Configuring integrations...");
        v4Utils.setVault(address(vault));
        vault.setTransformer(address(v4Utils), true);
        console.log("  V4Utils registered with vault");

        leverageTransformer.setVault(address(vault));
        vault.setTransformer(address(leverageTransformer), true);
        console.log("  LeverageTransformer registered with vault");

        revertHook.setVault(address(vault));
        vault.setTransformer(address(revertHook), true);
        console.log("  RevertHook registered as vault transformer");

        vault.setHookAllowList(address(revertHook), true);
        console.log("  RevertHook added to vault hook allowlist");

        revertHook.setAutoLendVault(USDC, vault);
        console.log("  Auto-lend vault configured for USDC");

        vm.stopBroadcast();

        console.log("");
        console.log("==============================================");
        console.log("              DEPLOYMENT SUMMARY               ");
        console.log("==============================================");
        console.log("Network: Arbitrum One (Chain ID: 42161)");
        console.log("----------------------------------------------");
        console.log("Core Infrastructure:");
        console.log("  InterestRateModel:            ", address(interestRateModel));
        console.log("  LiquidityCalculator:          ", address(liquidityCalculator));
        console.log("  V4Oracle:                     ", address(oracle));
        console.log("----------------------------------------------");
        console.log("Hook Contracts:");
        console.log("  RevertHookPositionActions:    ", address(positionActions));
        console.log("  RevertHookAutoLeverageActions:", address(autoLeverageActions));
        console.log("  RevertHookAutoLendActions:    ", address(autoLendActions));
        console.log("  RevertHook:                   ", address(revertHook));
        console.log("----------------------------------------------");
        console.log("Vault & Transformers:");
        console.log("  V4Vault (rlArbUSDC):          ", address(vault));
        console.log("  V4Utils:                      ", address(v4Utils));
        console.log("  LeverageTransformer:          ", address(leverageTransformer));
        console.log("  FlashloanLiquidator:          ", address(flashloanLiquidator));
        console.log("==============================================");
    }
}
