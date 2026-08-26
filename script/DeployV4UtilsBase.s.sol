// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {V4Utils} from "../src/vault/transformers/V4Utils.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

/// @title DeployV4UtilsBase
/// @notice Standalone V4Utils deployment script for Base.
/// @dev Run with: forge script script/DeployV4UtilsBase.s.sol:DeployV4UtilsBase --chain-id 8453 --rpc-url <rpc> --broadcast --verify
contract DeployV4UtilsBase is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {}

    function run() external returns (V4Utils v4Utils) {
        require(block.chainid == BASE_CHAIN_ID, "DeployV4UtilsBase: wrong chain");

        vm.startBroadcast();

        console2.log("Deploying V4Utils on Base...");
        console2.log("PositionManager:", POSITION_MANAGER);
        console2.log("UniversalRouter:", UNIVERSAL_ROUTER);
        console2.log("0x AllowanceHolder:", ZEROX_ALLOWANCE_HOLDER);
        console2.log("Permit2:", PERMIT2);

        v4Utils = new V4Utils(
            IPositionManager(POSITION_MANAGER),
            UNIVERSAL_ROUTER,
            ZEROX_ALLOWANCE_HOLDER,
            IPermit2(PERMIT2)
        );

        console2.log("V4Utils deployed at:", address(v4Utils));

        vm.stopBroadcast();
    }
}
