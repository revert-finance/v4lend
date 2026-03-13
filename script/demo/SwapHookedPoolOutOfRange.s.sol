// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {HookathonDemoBase} from "./HookathonDemoBase.s.sol";

contract SwapHookedPoolOutOfRange is HookathonDemoBase {
    function run() external {
        DemoContext memory ctx = _loadDemoContext();
        uint256 tokenId = vm.envUint("TOKEN_ID");

        (, PositionInfo positionInfo) = _positionInfo(ctx.positionManager, tokenId);

        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        address tokenIn = zeroForOne ? Currency.unwrap(ctx.poolKey.currency0) : Currency.unwrap(ctx.poolKey.currency1);

        uint128 amountIn = uint128(vm.envOr("AMOUNT_IN", uint256(_defaultSwapAmount(tokenIn))));
        uint128 amountOutMinimum = uint128(vm.envOr("AMOUNT_OUT_MIN", uint256(0)));
        uint256 maxSwapSteps = vm.envOr("MAX_SWAP_STEPS", uint256(8));

        console.log("== Hookathon demo: push pool out of range ==");
        _logPool(ctx);
        console.log("Token ID:", tokenId);
        console.log("Position tickLower:", int256(positionInfo.tickLower()));
        console.log("Position tickUpper:", int256(positionInfo.tickUpper()));
        console.log("Swap direction zeroForOne:", zeroForOne);
        console.log("Amount in per swap:", uint256(amountIn));
        console.log("Max swap steps:", maxSwapSteps);

        vm.startBroadcast();
        _approveForUniversalRouter(ctx);

        for (uint256 i = 0; i < maxSwapSteps; i++) {
            int24 currentTick = _currentTick(ctx);
            bool outOfRange = currentTick < positionInfo.tickLower() || currentTick >= positionInfo.tickUpper();
            if (outOfRange) {
                console.log("Position already out of range at tick:", int256(currentTick));
                break;
            }

            console.log("Swap step:", i + 1);
            console.log("Tick before:", int256(currentTick));
            _swapExactInputSingle(ctx, zeroForOne, amountIn, amountOutMinimum);
            console.log("Tick after:", int256(_currentTick(ctx)));
        }

        vm.stopBroadcast();

        int24 finalTick = _currentTick(ctx);
        bool finalOutOfRange = finalTick < positionInfo.tickLower() || finalTick >= positionInfo.tickUpper();
        console.log("Final tick:", int256(finalTick));
        console.log("Out of range:", finalOutOfRange);
        require(finalOutOfRange, "Demo: position still in range");
    }
}
