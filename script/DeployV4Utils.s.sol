// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

contract DeployV4Utils is Script {
    function setUp() public {}

    function run(address positionManager, address universalRouter, address zeroxAllowanceHolder, address permit2)
        public
        returns (V4Utils v4Utils)
    {
        address feeCollectionHook = vm.envOr("FEE_COLLECTION_HOOK", address(0));

        vm.startBroadcast();

        console2.log("Deploying V4Utils...");
        console2.log("PositionManager:", positionManager);
        console2.log("UniversalRouter:", universalRouter);
        console2.log("0x AllowanceHolder:", zeroxAllowanceHolder);
        console2.log("Permit2:", permit2);
        console2.log("Fee collection hook:", feeCollectionHook);

        v4Utils =
            new V4Utils(IPositionManager(positionManager), universalRouter, zeroxAllowanceHolder, IPermit2(permit2));

        if (feeCollectionHook != address(0)) {
            v4Utils.setFeeCollectionHook(feeCollectionHook);
        }

        console2.log("V4Utils deployed at:", address(v4Utils));

        vm.stopBroadcast();
    }
}
