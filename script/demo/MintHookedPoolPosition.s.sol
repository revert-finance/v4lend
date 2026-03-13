// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";

import {HookathonDemoBase} from "./HookathonDemoBase.s.sol";

contract MintHookedPoolPosition is HookathonDemoBase {
    function run() external {
        DemoContext memory ctx = _loadDemoContext();

        uint256 widthMultiplierRaw = vm.envOr("MINT_RANGE_MULTIPLIER", uint256(2));
        require(widthMultiplierRaw > 0, "Demo: MINT_RANGE_MULTIPLIER must be > 0");
        require(widthMultiplierRaw <= uint256(uint24(type(int24).max)), "Demo: MINT_RANGE_MULTIPLIER too large");

        uint128 liquidity = uint128(vm.envOr("MINT_LIQUIDITY", uint256(1e13)));
        require(liquidity > 0, "Demo: MINT_LIQUIDITY must be > 0");

        int24 currentTickLower = _currentTickLower(ctx);
        int24 tickSpacing = ctx.poolKey.tickSpacing;
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 widthMultiplier = int24(uint24(widthMultiplierRaw));

        int24 tickLower = int24(vm.envOr("MINT_TICK_LOWER", int256(currentTickLower - widthMultiplier * tickSpacing)));
        int24 tickUpper = int24(vm.envOr("MINT_TICK_UPPER", int256(currentTickLower + widthMultiplier * tickSpacing)));

        require(tickLower < tickUpper, "Demo: invalid mint range");

        console.log("== Hookathon demo: mint hooked position ==");
        _logPool(ctx);
        console.log("Mint tickLower:", int256(tickLower));
        console.log("Mint tickUpper:", int256(tickUpper));
        console.log("Mint liquidity:", uint256(liquidity));

        vm.startBroadcast();
        _approveForPositionManager(ctx);
        uint256 tokenId = _mintPosition(ctx, tickLower, tickUpper, liquidity, msg.sender);
        vm.stopBroadcast();

        console.log("Minted tokenId:", tokenId);
    }
}
