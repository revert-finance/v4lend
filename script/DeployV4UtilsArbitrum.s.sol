// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {V4Utils} from "../src/vault/transformers/V4Utils.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

/// @title DeployV4UtilsArbitrum
/// @notice Standalone V4Utils deployment script for Arbitrum One.
/// @dev Run with: forge script script/DeployV4UtilsArbitrum.s.sol:DeployV4UtilsArbitrum --chain-id 42161 --rpc-url <rpc> --broadcast --verify
contract DeployV4UtilsArbitrum is Script {
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;

    address internal constant POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address internal constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {}

    function run() external returns (V4Utils v4Utils) {
        require(block.chainid == ARBITRUM_CHAIN_ID, "DeployV4UtilsArbitrum: wrong chain");

        vm.startBroadcast();

        console2.log("Deploying V4Utils on Arbitrum One...");
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
