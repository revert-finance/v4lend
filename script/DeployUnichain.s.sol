// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

// import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";
// import {V4Vault} from "src/vault/V4Vault.sol";
// import {InterestRateModel} from "src/vault/InterestRateModel.sol";
// import {FlashloanLiquidator} from "src/vault/liquidation/FlashloanLiquidator.sol";
// import {LeverageTransformer} from "src/vault/transformers/LeverageTransformer.sol";
import {LiquidityCalculator, ILiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {RevertHook} from "src/RevertHook.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
// import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title DeployUnichain
/// @notice Deployment script for RevertHook and all related contracts on Unichain
/// @dev Run with: forge script script/DeployUnichain.s.sol:DeployUnichain --chain-id 130 --rpc-url <rpc> --broadcast --verify
contract DeployUnichain is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // ==================== Unichain Contract Addresses ====================
    // Source: https://docs.uniswap.org/contracts/v4/deployments

    IPositionManager constant POSITION_MANAGER = IPositionManager(0x4529A01c7A0410167c5740C487A8DE60232617bf);
    address constant UNIVERSAL_ROUTER = 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;


    // CREATE2 Deployer Proxy used by Forge for CREATE2 deployments
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // 0x Protocol AllowanceHolder - placeholder, update when available on Unichain
    address constant ZEROX_ALLOWANCE_HOLDER = address(0); // TODO: Update when 0x deploys to Unichain

    // ==================== Unichain Token Addresses ====================
    // Common token addresses on Unichain mainnet

    address constant WETH = 0x4200000000000000000000000000000000000006; // Standard OP Stack WETH
    address constant ETH = address(0);

    // Stablecoins - placeholder addresses, update with actual Unichain addresses
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant USDT = 0x9151434b16b9763660705744891fA906F660EcC5;
    address constant DAI = 0x20CAb320A855b39F724131C69424240519573f81;

    // Other tokens
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant UNI = 0x8f187aA05619a017077f5308904739877ce9eA21;

    // ==================== RedStone Oracle Feed Addresses ====================
    // Source: https://docs.redstone.finance - Classic/Push Model feeds on Unichain
    // These implement the Chainlink AggregatorV3Interface

    address constant REDSTONE_ETH_USD = 0xe8D9FbC10e00ecc9f0694617075fDAF657a76FB2;
    address constant REDSTONE_BTC_USD = 0xc44be6D00307c3565FDf753e852Fc003036cBc13;
    address constant REDSTONE_USDC_USD = 0xD15862FC3D5407A03B696548b6902D6464A69b8c;
    address constant REDSTONE_USDT_USD = 0x58fa68A373956285dDfb340EDf755246f8DfCA16;
    address constant REDSTONE_DAI_USD = 0xE94c9f9A1893f23be38A5C0394E46Ac05e8a5f8C;
    address constant REDSTONE_UNI_USD = 0xf1454949C6dEdfb500ae63Aa6c784Aa1Dde08A6c;

    // L2 Sequencer Uptime Feed (for L2 oracle safety)
    address constant SEQUENCER_UPTIME_FEED = address(0); // TODO: Update if RedStone provides sequencer feed

    // ==================== Configuration Constants ====================

    uint32 constant MAX_FEED_AGE = 86400; // 24 hours max feed age
    uint16 constant MAX_POOL_PRICE_DIFFERENCE = 200; // 2% max difference between pool and oracle price

    // // Interest rate model parameters (similar to Compound V2)
    // uint256 constant BASE_RATE_PER_YEAR = 0; // 0% base rate
    // uint256 constant MULTIPLIER_PER_YEAR = Q64 * 5 / 100; // 5% at kink
    // uint256 constant JUMP_MULTIPLIER_PER_YEAR = Q64 * 109 / 100; // 109% above kink
    // uint256 constant KINK = Q64 * 80 / 100; // 80% utilization kink

    // // Collateral factors (in Q32 format)
    // uint32 constant CF_STABLECOIN = uint32(Q32 * 850 / 1000); // 85% for stablecoins
    // uint32 constant CF_ETH = uint32(Q32 * 775 / 1000); // 77.5% for ETH
    // uint32 constant CF_BTC = uint32(Q32 * 750 / 1000); // 75% for BTC
    // uint32 constant CF_OTHER = uint32(Q32 * 650 / 1000); // 65% for other tokens

    // RevertHook configuration
    uint16 constant PROTOCOL_FEE_BPS = 100; // 1% protocol fee
    int24 constant MAX_TICKS_FROM_ORACLE = 100; // Max tick deviation from oracle price
    uint256 constant MIN_POSITION_VALUE_NATIVE = 0.01 ether; // Minimum position value

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
    function findHookSalt(address deployer, bytes memory creationCodeWithArgs) internal view returns (address hookAddress, bytes32 salt) {
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
        revert("DeployUnichain: could not find valid hook salt");
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

        vm.startBroadcast();

        console.log("Deploying RevertHook infrastructure on Unichain...");
        console.log("Deployer:", deployer);

        // ==================== Step 1: Deploy Core Infrastructure ====================

        // // Deploy InterestRateModel
        // InterestRateModel interestRateModel = new InterestRateModel(
        //     BASE_RATE_PER_YEAR,
        //     MULTIPLIER_PER_YEAR,
        //     JUMP_MULTIPLIER_PER_YEAR,
        //     KINK
        // );
        // console.log("InterestRateModel deployed at:", address(interestRateModel));

        // Deploy LiquidityCalculator
        LiquidityCalculator liquidityCalculator = new LiquidityCalculator();
        console.log("LiquidityCalculator deployed at:", address(liquidityCalculator));

        // ==================== Step 2: Deploy V4Oracle ====================

        // Deploy V4Oracle with WETH as reference token and USD (address(0)) as chainlink reference
        V4Oracle oracle = new V4Oracle(POSITION_MANAGER, WETH, address(0));
        console.log("V4Oracle deployed at:", address(oracle));

        // Configure oracle settings
        oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        oracle.setSequencerUptimeFeed(SEQUENCER_UPTIME_FEED);

        // Configure token feeds (RedStone feeds implement AggregatorV3Interface)
        // ETH/USD
        if (REDSTONE_ETH_USD != address(0)) {
            oracle.setTokenConfig(WETH, AggregatorV3Interface(REDSTONE_ETH_USD), MAX_FEED_AGE);
            oracle.setTokenConfig(ETH, AggregatorV3Interface(REDSTONE_ETH_USD), MAX_FEED_AGE);
            console.log("Configured ETH/USD feed");
        }

        // BTC/USD
        if (REDSTONE_BTC_USD != address(0) && WBTC != address(0)) {
            oracle.setTokenConfig(WBTC, AggregatorV3Interface(REDSTONE_BTC_USD), MAX_FEED_AGE);
            console.log("Configured BTC/USD feed");
        }

        // USDC/USD
        if (REDSTONE_USDC_USD != address(0) && USDC != address(0)) {
            oracle.setTokenConfig(USDC, AggregatorV3Interface(REDSTONE_USDC_USD), MAX_FEED_AGE);
            console.log("Configured USDC/USD feed");
        }

        // USDT/USD
        if (REDSTONE_USDT_USD != address(0) && USDT != address(0)) {
            oracle.setTokenConfig(USDT, AggregatorV3Interface(REDSTONE_USDT_USD), MAX_FEED_AGE);
            console.log("Configured USDT/USD feed");
        }

        // DAI/USD
        if (REDSTONE_DAI_USD != address(0) && DAI != address(0)) {
            oracle.setTokenConfig(DAI, AggregatorV3Interface(REDSTONE_DAI_USD), MAX_FEED_AGE);
            console.log("Configured DAI/USD feed");
        }

        // UNI/USD
        if (REDSTONE_UNI_USD != address(0) && UNI != address(0)) {
            oracle.setTokenConfig(UNI, AggregatorV3Interface(REDSTONE_UNI_USD), MAX_FEED_AGE);
            console.log("Configured UNI/USD feed");
        }

        // ==================== Step 3: Deploy RevertHook action contracts ====================

        // Deploy RevertHookPositionActions separately to avoid initcode size limit
        RevertHookPositionActions positionActions = new RevertHookPositionActions(
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator)
        );
        console.log("RevertHookPositionActions deployed at:", address(positionActions));

        // Deploy RevertHookAutoLeverageActions separately to avoid initcode size limit
        RevertHookAutoLeverageActions autoLeverageActions = new RevertHookAutoLeverageActions(
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator)
        );
        console.log("RevertHookAutoLeverageActions deployed at:", address(autoLeverageActions));

        RevertHookAutoLendActions autoLendActions = new RevertHookAutoLendActions(
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator)
        );
        console.log("RevertHookAutoLendActions deployed at:", address(autoLendActions));

        // ==================== Step 4: Deploy RevertHook with CREATE2 ====================

        // Prepare constructor arguments for RevertHook
        // Constructor: (owner_, protocolFeeRecipient_, permit2, v4Oracle, liquidityCalculator, positionActions, autoLeverageActions, autoLendActions)
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

        // Mine for a valid hook address
        // Note: Forge uses CREATE2_DEPLOYER (0x4e59b44847b379578588920cA78FbF26c0B4956C) for CREATE2 deployments
        console.log("Mining for valid hook address...");
        (address expectedHookAddress, bytes32 salt) = findHookSalt(CREATE2_DEPLOYER, creationCodeWithArgs);
        console.log("Found valid hook address:", expectedHookAddress);
        console.log("Using salt:", vm.toString(salt));

        // Deploy RevertHook using CREATE2
        RevertHook revertHook = new RevertHook{salt: salt}(
            deployer, // owner
            deployer, // protocolFeeRecipient
            IPermit2(PERMIT2),
            oracle,
            ILiquidityCalculator(liquidityCalculator),
            positionActions,
            autoLeverageActions,
            autoLendActions
        );
        require(address(revertHook) == expectedHookAddress, "Hook address mismatch");
        console.log("RevertHook deployed at:", address(revertHook));

        // Configure RevertHook settings
        revertHook.setProtocolFeeBps(PROTOCOL_FEE_BPS);
        revertHook.setMaxTicksFromOracle(MAX_TICKS_FROM_ORACLE);
        revertHook.setMinPositionValueNative(MIN_POSITION_VALUE_NATIVE);

        // // ==================== Step 4: Deploy V4Vault (USDC lending) ====================

        // V4Vault vault;
        // if (USDC != address(0)) {
        //     vault = new V4Vault(
        //         "Revert Lend USDC",
        //         "rlUSDC",
        //         USDC,
        //         POSITION_MANAGER,
        //         interestRateModel,
        //         oracle,
        //         IWETH9(WETH)
        //     );
        //     console.log("V4Vault (USDC) deployed at:", address(vault));

        //     // Configure collateral tokens
        //     if (USDC != address(0)) {
        //         vault.setTokenConfig(USDC, CF_STABLECOIN, type(uint32).max);
        //     }
        //     vault.setTokenConfig(WETH, CF_ETH, type(uint32).max);
        //     vault.setTokenConfig(ETH, CF_ETH, type(uint32).max);
        //     if (WBTC != address(0)) {
        //         vault.setTokenConfig(WBTC, CF_BTC, type(uint32).max);
        //     }
        //     if (USDT != address(0)) {
        //         vault.setTokenConfig(USDT, CF_STABLECOIN, type(uint32).max);
        //     }
        //     if (DAI != address(0)) {
        //         vault.setTokenConfig(DAI, CF_STABLECOIN, type(uint32).max);
        //     }
        //     if (UNI != address(0)) {
        //         vault.setTokenConfig(UNI, CF_OTHER, type(uint32).max);
        //     }

        //     // Configure vault limits
        //     vault.setLimits(
        //         100000,           // minLoanSize: 0.1 USDC (assuming 6 decimals)
        //         1000000000000,    // globalLendLimit: 1M USDC
        //         399000000000000,  // globalDebtLimit
        //         100000000000,     // dailyLendIncreaseLimitMin
        //         75000000000       // dailyDebtIncreaseLimitMin
        //     );
        //     vault.setReserveFactor(uint32(Q32 * 10 / 100)); // 10% reserve factor
        //     vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100)); // 5% reserve protection

        // }

        // // ==================== Step 5: Deploy Transformers ====================

        // // Deploy FlashloanLiquidator
        // FlashloanLiquidator flashloanLiquidator = new FlashloanLiquidator(
        //     POSITION_MANAGER,
        //     UNIVERSAL_ROUTER,
        //     ZEROX_ALLOWANCE_HOLDER
        // );
        // console.log("FlashloanLiquidator deployed at:", address(flashloanLiquidator));

        // // Deploy V4Utils
        // V4Utils v4Utils = new V4Utils(
        //     POSITION_MANAGER,
        //     UNIVERSAL_ROUTER,
        //     ZEROX_ALLOWANCE_HOLDER,
        //     IPermit2(PERMIT2)
        // );
        // console.log("V4Utils deployed at:", address(v4Utils));

        // // Deploy LeverageTransformer
        // LeverageTransformer leverageTransformer = new LeverageTransformer(
        //     POSITION_MANAGER,
        //     UNIVERSAL_ROUTER,
        //     ZEROX_ALLOWANCE_HOLDER,
        //     IPermit2(PERMIT2)
        // );
        // console.log("LeverageTransformer deployed at:", address(leverageTransformer));

        // // ==================== Step 6: Configure Vault-Transformer Integration ====================

        // if (address(vault) != address(0)) {
        //     v4Utils.setVault(address(vault));
        //     vault.setTransformer(address(v4Utils), true);
        //     console.log("V4Utils registered with vault");

        //     leverageTransformer.setVault(address(vault));
        //     vault.setTransformer(address(leverageTransformer), true);
        //     console.log("LeverageTransformer registered with vault");

        //     // Allow RevertHook in vault
        //     vault.setHookAllowList(address(revertHook), true);
        //     console.log("RevertHook added to vault hook allowlist");
        // }

        vm.stopBroadcast();

        // ==================== Deployment Summary ====================

        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("Chain: Unichain (130)");
        console.log("LiquidityCalculator:", address(liquidityCalculator));
        console.log("V4Oracle:", address(oracle));
        console.log("RevertHookPositionActions:", address(positionActions));
        console.log("RevertHookAutoLeverageActions:", address(autoLeverageActions));
        console.log("RevertHookAutoLendActions:", address(autoLendActions));
        console.log("RevertHook:", address(revertHook));
        console.log("=========================================\n");
    }
}
