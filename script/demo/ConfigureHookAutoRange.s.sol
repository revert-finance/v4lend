// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";

import {HookathonDemoBase} from "./HookathonDemoBase.s.sol";

contract ConfigureHookAutoRange is HookathonDemoBase {
    function run() external {
        DemoContext memory ctx = _loadDemoContext();
        uint256 tokenId = vm.envUint("TOKEN_ID");

        RevertHook hook = RevertHook(payable(ctx.hook));

        (, PositionInfo positionInfo) = _positionInfo(ctx.positionManager, tokenId);
        int24 tickSpacing = ctx.poolKey.tickSpacing;

        uint32 maxPriceImpactBps0 = uint32(vm.envOr("MAX_PRICE_IMPACT_BPS0", uint256(100)));
        uint32 maxPriceImpactBps1 = uint32(vm.envOr("MAX_PRICE_IMPACT_BPS1", uint256(100)));

        int24 autoRangeLowerLimit = int24(vm.envOr("AUTO_RANGE_LOWER_LIMIT", int256(0)));
        int24 autoRangeUpperLimit = int24(vm.envOr("AUTO_RANGE_UPPER_LIMIT", int256(0)));
        int24 autoRangeLowerDelta = int24(vm.envOr("AUTO_RANGE_LOWER_DELTA", int256(-tickSpacing)));
        int24 autoRangeUpperDelta = int24(vm.envOr("AUTO_RANGE_UPPER_DELTA", int256(tickSpacing)));

        console.log("== Hookathon demo: configure autorange ==");
        _logPool(ctx);
        console.log("Token ID:", tokenId);
        console.log("Position tickLower:", int256(positionInfo.tickLower()));
        console.log("Position tickUpper:", int256(positionInfo.tickUpper()));
        console.log("autoRangeLowerLimit:", int256(autoRangeLowerLimit));
        console.log("autoRangeUpperLimit:", int256(autoRangeUpperLimit));
        console.log("autoRangeLowerDelta:", int256(autoRangeLowerDelta));
        console.log("autoRangeUpperDelta:", int256(autoRangeUpperDelta));

        vm.startBroadcast();
        hook.setGeneralConfig(tokenId, 0, 0, IHooks(address(0)), maxPriceImpactBps0, maxPriceImpactBps1);
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: autoRangeLowerLimit,
                autoRangeUpperLimit: autoRangeUpperLimit,
                autoRangeLowerDelta: autoRangeLowerDelta,
                autoRangeUpperDelta: autoRangeUpperDelta,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        vm.stopBroadcast();

        console.log("AutoRange configured for tokenId:", tokenId);
    }
}
