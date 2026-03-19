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
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title DeployMainnet
/// @notice Deployment script for RevertHook and all related contracts on Ethereum mainnet
/// @dev Run with: forge script script/DeployMainnet.s.sol:DeployMainnet --chain-id 1 --rpc-url <rpc> --broadcast --verify
contract DeployMainnet is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // ==================== Mainnet Contract Addresses ====================

    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // ==================== Mainnet Token Addresses ====================

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ETH = address(0);

    // ==================== Mainnet Chainlink Feeds ====================

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // ==================== Configuration Constants ====================

    uint32 constant MAX_FEED_AGE = 86400;
    uint16 constant MAX_POOL_PRICE_DIFFERENCE = 200;

    uint256 constant BASE_RATE_PER_YEAR = 0;
    uint256 constant MULTIPLIER_PER_YEAR = Q64 * 5 / 100;
    uint256 constant JUMP_MULTIPLIER_PER_YEAR = Q64 * 109 / 100;
    uint256 constant KINK = Q64 * 80 / 100;

    uint32 constant CF_STABLECOIN = uint32(Q32 * 850 / 1000);
    uint32 constant CF_ETH = uint32(Q32 * 775 / 1000);

    uint16 constant PROTOCOL_FEE_BPS = 100;
    int24 constant MAX_TICKS_FROM_ORACLE = 100;
    uint256 constant MIN_POSITION_VALUE_NATIVE = 0.01 ether;

    uint256 constant MIN_LOAN_SIZE = 100000;
    uint256 constant GLOBAL_LEND_LIMIT = 1000000000000;
    uint256 constant GLOBAL_DEBT_LIMIT = 399000000000000;
    uint256 constant DAILY_LEND_INCREASE_LIMIT_MIN = 100000000000;
    uint256 constant DAILY_DEBT_INCREASE_LIMIT_MIN = 75000000000;

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
        revert("DeployMainnet: could not find valid hook salt");
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

        vm.startBroadcast();

        console.log("==============================================");
        console.log("Deploying Revert infrastructure on Mainnet...");
        console.log("==============================================");
        console.log("Deployer:", deployer);
        console.log("0x AllowanceHolder:", zeroXAllowanceHolder);
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
        oracle.setSequencerUptimeFeed(address(0));
        oracle.setTokenConfig(USDC, AggregatorV3Interface(CHAINLINK_USDC_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(WETH, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        oracle.setTokenConfig(ETH, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        console.log("  Configured USDC/USD and ETH/USD feeds");

        console.log("Step 3: Deploying RevertHook action contracts...");
        RevertHookPositionActions positionActions =
            new RevertHookPositionActions(IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator));
        console.log("  RevertHookPositionActions deployed at:", address(positionActions));

        RevertHookAutoLeverageActions autoLeverageActions =
            new RevertHookAutoLeverageActions(IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator));
        console.log("  RevertHookAutoLeverageActions deployed at:", address(autoLeverageActions));

        RevertHookAutoLendActions autoLendActions =
            new RevertHookAutoLendActions(IPermit2(PERMIT2), oracle, ILiquidityCalculator(liquidityCalculator));
        console.log("  RevertHookAutoLendActions deployed at:", address(autoLendActions));

        console.log("Step 4: Deploying RevertHook with CREATE2 address mining...");
        bytes memory constructorArgs = abi.encode(
            deployer,
            deployer,
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator),
            positionActions,
            autoLeverageActions,
            autoLendActions
        );
        bytes memory creationCodeWithArgs = abi.encodePacked(type(RevertHook).creationCode, constructorArgs);
        console.log("  Mining for valid hook address...");
        (address expectedHookAddress, bytes32 salt) = findHookSalt(CREATE2_DEPLOYER, creationCodeWithArgs);
        console.log("  Found valid hook address:", expectedHookAddress);
        console.log("  Using salt:", vm.toString(salt));

        RevertHook revertHook = new RevertHook{salt: salt}(
            deployer,
            deployer,
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator),
            positionActions,
            autoLeverageActions,
            autoLendActions
        );
        require(address(revertHook) == expectedHookAddress, "Hook address mismatch");
        console.log("  RevertHook deployed at:", address(revertHook));

        revertHook.setProtocolFeeBps(PROTOCOL_FEE_BPS);
        revertHook.setMaxTicksFromOracle(MAX_TICKS_FROM_ORACLE);
        revertHook.setMinPositionValueNative(MIN_POSITION_VALUE_NATIVE);
        console.log("  RevertHook configured");

        console.log("Step 5: Deploying V4Vault (USDC)...");
        V4Vault vault =
            new V4Vault("Revert Lend USDC", "rlUSDC", USDC, POSITION_MANAGER, interestRateModel, oracle, IWETH9(WETH));
        console.log("  V4Vault deployed at:", address(vault));

        vault.setTokenConfig(USDC, CF_STABLECOIN, type(uint32).max);
        vault.setTokenConfig(WETH, CF_ETH, type(uint32).max);
        vault.setTokenConfig(ETH, CF_ETH, type(uint32).max);
        console.log("  Configured collateral tokens (USDC, WETH, ETH)");

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
        console.log("Network: Ethereum Mainnet (Chain ID: 1)");
        console.log("----------------------------------------------");
        console.log("Core Infrastructure:");
        console.log("  InterestRateModel:          ", address(interestRateModel));
        console.log("  LiquidityCalculator:        ", address(liquidityCalculator));
        console.log("  V4Oracle:                   ", address(oracle));
        console.log("----------------------------------------------");
        console.log("Hook Contracts:");
        console.log("  RevertHookPositionActions:  ", address(positionActions));
        console.log("  RevertHookAutoLeverageActions:", address(autoLeverageActions));
        console.log("  RevertHookAutoLendActions:  ", address(autoLendActions));
        console.log("  RevertHook:                 ", address(revertHook));
        console.log("----------------------------------------------");
        console.log("Vault & Transformers:");
        console.log("  V4Vault (rlUSDC):           ", address(vault));
        console.log("  V4Utils:                    ", address(v4Utils));
        console.log("  LeverageTransformer:        ", address(leverageTransformer));
        console.log("  FlashloanLiquidator:        ", address(flashloanLiquidator));
        console.log("==============================================");
    }
}
