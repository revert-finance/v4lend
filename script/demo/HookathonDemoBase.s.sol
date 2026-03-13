// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {IUniversalRouter} from "src/shared/swap/IUniversalRouter.sol";

abstract contract HookathonDemoBase is Script {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant UNICHAIN_CHAIN_ID = 130;

    address internal constant BASE_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant UNICHAIN_POSITION_MANAGER = 0x4529A01c7A0410167c5740C487A8DE60232617bf;

    address internal constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant UNICHAIN_UNIVERSAL_ROUTER = 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3;

    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant UNICHAIN_WETH = 0x4200000000000000000000000000000000000006;

    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNICHAIN_USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;

    struct DemoContext {
        address hook;
        IPositionManager positionManager;
        IUniversalRouter universalRouter;
        IPermit2 permit2;
        PoolKey poolKey;
    }

    function _loadDemoContext() internal view returns (DemoContext memory ctx) {
        uint256 chainId = block.chainid;

        ctx.hook = vm.envAddress("REVERT_HOOK");
        ctx.positionManager = IPositionManager(vm.envOr("POSITION_MANAGER", _defaultPositionManager(chainId)));
        ctx.universalRouter = IUniversalRouter(vm.envOr("UNIVERSAL_ROUTER", _defaultUniversalRouter(chainId)));
        ctx.permit2 = IPermit2(vm.envOr("PERMIT2", PERMIT2_ADDRESS));

        address token0 = vm.envOr("POOL_TOKEN0", _defaultToken0(chainId));
        address token1 = vm.envOr("POOL_TOKEN1", _defaultToken1(chainId));
        require(token0 != address(0) && token1 != address(0), "Demo: set POOL_TOKEN0 and POOL_TOKEN1");

        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60))));

        ctx.poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(ctx.hook)
        });
    }

    function _approveForPositionManager(DemoContext memory ctx) internal {
        address token0 = Currency.unwrap(ctx.poolKey.currency0);
        address token1 = Currency.unwrap(ctx.poolKey.currency1);

        require(token0 != address(0) && token1 != address(0), "Demo: ERC20 pools only");

        IERC20(token0).forceApprove(address(ctx.permit2), type(uint256).max);
        IERC20(token1).forceApprove(address(ctx.permit2), type(uint256).max);

        ctx.permit2.approve(token0, address(ctx.positionManager), type(uint160).max, type(uint48).max);
        ctx.permit2.approve(token1, address(ctx.positionManager), type(uint160).max, type(uint48).max);
    }

    function _approveForUniversalRouter(DemoContext memory ctx) internal {
        address token0 = Currency.unwrap(ctx.poolKey.currency0);
        address token1 = Currency.unwrap(ctx.poolKey.currency1);

        require(token0 != address(0) && token1 != address(0), "Demo: ERC20 pools only");

        IERC20(token0).forceApprove(address(ctx.permit2), type(uint256).max);
        IERC20(token1).forceApprove(address(ctx.permit2), type(uint256).max);

        ctx.permit2.approve(token0, address(ctx.universalRouter), type(uint160).max, type(uint48).max);
        ctx.permit2.approve(token1, address(ctx.universalRouter), type(uint160).max, type(uint48).max);
    }

    function _currentTick(DemoContext memory ctx) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(ctx.positionManager.poolManager(), ctx.poolKey.toId());
    }

    function _currentTickLower(DemoContext memory ctx) internal view returns (int24) {
        int24 tick = _currentTick(ctx);
        int24 spacing = ctx.poolKey.tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) {
            compressed--;
        }
        return compressed * spacing;
    }

    function _positionInfo(IPositionManager positionManager, uint256 tokenId)
        internal
        view
        returns (PoolKey memory poolKey, PositionInfo positionInfo)
    {
        return positionManager.getPoolAndPositionInfo(tokenId);
    }

    function _mintPosition(DemoContext memory ctx, int24 tickLower, int24 tickUpper, uint128 liquidity, address owner)
        internal
        returns (uint256 tokenId)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            ctx.poolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, owner, bytes("")
        );
        paramsArray[1] = abi.encode(ctx.poolKey.currency0, ctx.poolKey.currency1, owner);

        uint256 nextTokenIdBefore = ctx.positionManager.nextTokenId();
        ctx.positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
        tokenId = ctx.positionManager.nextTokenId() - 1;
        require(tokenId >= nextTokenIdBefore, "Demo: mint failed");
    }

    function _swapExactInputSingle(DemoContext memory ctx, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum)
        internal
    {
        bytes memory commands = hex"10";
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: ctx.poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? ctx.poolKey.currency0 : ctx.poolKey.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? ctx.poolKey.currency1 : ctx.poolKey.currency0, amountOutMinimum);
        inputs[0] = abi.encode(actions, params);

        ctx.universalRouter.execute(commands, inputs, block.timestamp);
    }

    function _defaultPositionManager(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_CHAIN_ID) {
            return BASE_POSITION_MANAGER;
        }
        if (chainId == UNICHAIN_CHAIN_ID) {
            return UNICHAIN_POSITION_MANAGER;
        }
        return address(0);
    }

    function _defaultUniversalRouter(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_CHAIN_ID) {
            return BASE_UNIVERSAL_ROUTER;
        }
        if (chainId == UNICHAIN_CHAIN_ID) {
            return UNICHAIN_UNIVERSAL_ROUTER;
        }
        return address(0);
    }

    function _defaultToken0(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_CHAIN_ID) {
            return BASE_USDC;
        }
        if (chainId == UNICHAIN_CHAIN_ID) {
            return UNICHAIN_USDC;
        }
        return address(0);
    }

    function _defaultToken1(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_CHAIN_ID) {
            return BASE_WETH;
        }
        if (chainId == UNICHAIN_CHAIN_ID) {
            return UNICHAIN_WETH;
        }
        return address(0);
    }

    function _defaultSwapAmount(address tokenIn) internal pure returns (uint128) {
        if (tokenIn == BASE_USDC || tokenIn == UNICHAIN_USDC) {
            return 10_000e6;
        }
        if (tokenIn == BASE_WETH || tokenIn == UNICHAIN_WETH) {
            return 0.5 ether;
        }
        return 1 ether;
    }

    function _logPool(DemoContext memory ctx) internal view {
        console.log("Hook:", ctx.hook);
        console.log("PositionManager:", address(ctx.positionManager));
        console.log("UniversalRouter:", address(ctx.universalRouter));
        console.log("Permit2:", address(ctx.permit2));
        console.log("Token0:", Currency.unwrap(ctx.poolKey.currency0));
        console.log("Token1:", Currency.unwrap(ctx.poolKey.currency1));
        console.log("Fee:", uint256(ctx.poolKey.fee));
        console.log("Tick spacing:", int256(ctx.poolKey.tickSpacing));
        console.log("Current tick:", int256(_currentTick(ctx)));
    }
}
