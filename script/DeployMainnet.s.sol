// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {FlashloanLiquidator} from "src/vault/liquidation/FlashloanLiquidator.sol";
import {LeverageTransformer} from "src/vault/transformers/LeverageTransformer.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

contract DeployMainnet is Script {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    IPositionManager constant positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    address EX0x = 0x0000000000001fF3684f28c67538d4D072C22734;
    address UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // initially supported coins
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ETH = 0x0000000000000000000000000000000000000000;

    function run() external {
        vm.startBroadcast();
        
        // 5% base rate - after 80% - 109% (like in compound v2 deployed)
        InterestRateModel interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

        V4Oracle oracle = new V4Oracle(positionManager, address(WETH), address(0));
        oracle.setMaxPoolPriceDifference(200);
        oracle.setSequencerUptimeFeed(address(0));

        oracle.setTokenConfig(
            USDC,
            AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6),
            86400
        );
        oracle.setTokenConfig(
            WETH,
            AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419),
            86400
        );
        oracle.setTokenConfig(
            ETH,
            AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419),
            86400
        );
       

        V4Vault vault = new V4Vault("Revert Lend USDC", "rlUSDC", address(USDC), positionManager, interestRateModel, oracle, IWETH9(WETH));
        vault.setTokenConfig(USDC, uint32(Q32 * 850 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(WETH, uint32(Q32 *  775 / 1000), type(uint32).max); // max 100% collateral value
        vault.setTokenConfig(ETH, uint32(Q32 *  775 / 1000), type(uint32).max); // max 100% collateral value


        vault.setLimits(100000, 1000000000000, 399000000000000, 100000000000, 75000000000);
        vault.setReserveFactor(uint32(Q32 * 10 / 100));
        vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));

        new FlashloanLiquidator(positionManager, UNIVERSAL_ROUTER, EX0x);

        // deploy transformers and automators
        V4Utils v4Utils = new V4Utils(positionManager, UNIVERSAL_ROUTER, EX0x, IPermit2(PERMIT2));
        v4Utils.setVault(address(vault));
        vault.setTransformer(address(v4Utils), true);

        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, UNIVERSAL_ROUTER, EX0x, IPermit2(PERMIT2));
        leverageTransformer.setVault(address(vault));
        vault.setTransformer(address(leverageTransformer), true);
        
        //AutoRange autoRange = AutoRange(payable(0x5ff2195BA28d2544AeD91e30e5f74B87d4F158dE));
        //autoRange.setVault(address(vault));
        //vault.setTransformer(address(autoRange), true);
 
        //AutoCollect autoCollect = AutoCollect(payable(0x9D97c76102E72883CD25Fa60E0f4143516d5b6db));
        //autoCollect.setVault(address(vault));
        //vault.setTransformer(address(autoCollect), true);

        //AutoExit autoExit = AutoExit();

        vm.stopBroadcast();
    }
}
