// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {HookRouteController} from "src/hook/HookRouteController.sol";
import {HookAuctionController} from "src/hook/HookAuctionController.sol";
import {AuctionArbExecutor} from "src/automators/AuctionArbExecutor.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

contract AuctionArbExecutorTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint32 internal constant EPOCH_LENGTH = 3600;

    Currency currency0;
    Currency currency1;

    PoolKey auctionPoolKey;
    PoolKey plainPoolKey;

    RevertHook hook;
    HookAuctionController auctionController;
    AuctionArbExecutor executor;
    MockV4Oracle v4Oracle;

    address profitRecipient;
    uint64 startTime;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4449 << 144)
        );

        v4Oracle = new MockV4Oracle(positionManager);
        profitRecipient = makeAddr("profitRecipient");

        LiquidityCalculator liquidityCalculator = new LiquidityCalculator();
        HookFeeController feeController = new HookFeeController(flags, makeAddr("feeRecipient"), 200, 200);
        HookRouteController routeController = new HookRouteController(flags);
        auctionController = new HookAuctionController(flags, poolManager);
        RevertHookSwapActions swapActions = new RevertHookSwapActions(poolManager, feeController);
        RevertHookPositionActions positionActions =
            new RevertHookPositionActions(permit2, v4Oracle, liquidityCalculator, routeController, swapActions);
        RevertHookAutoLeverageActions autoLeverageActions =
            new RevertHookAutoLeverageActions(permit2, v4Oracle, liquidityCalculator, routeController, swapActions);
        RevertHookAutoLendActions autoLendActions = new RevertHookAutoLendActions(
            permit2, v4Oracle, liquidityCalculator, feeController, routeController, swapActions
        );
        bytes memory constructorArgs = abi.encode(
            address(this), v4Oracle, feeController, auctionController, positionActions, autoLeverageActions, autoLendActions
        );
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(payable(flags));

        auctionPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        plainPoolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(auctionPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(plainPoolKey, Constants.SQRT_PRICE_1_1);

        positionManager.mint(
            auctionPoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            1000e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        positionManager.mint(
            plainPoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            1000e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        executor = new AuctionArbExecutor(poolManager, address(this));

        // win the next epoch with the executor registered
        startTime = uint64(block.timestamp);
        HookAuctionController.PoolAuctionConfig memory config = HookAuctionController.PoolAuctionConfig({
            auctionCurrency: currency1,
            normalLpFee: 3000,
            feeDiscountPpm: 1_000_000,
            epochStartTime: 0,
            epochLengthSeconds: EPOCH_LENGTH,
            minDripSeconds: 60,
            openingBidReserve: 1e15,
            minBidBumpPpm: 50_000,
            protocolFeeBps: 1000,
            protocolFeeRecipient: makeAddr("feeRecipient"),
            biddingEnabled: true
        });
        auctionController.configurePool(auctionPoolKey, config);
        IERC20(Currency.unwrap(currency1)).approve(address(auctionController), type(uint256).max);
        auctionController.bidNext(auctionPoolKey, address(executor), 1e15);
        vm.warp(uint256(startTime) + EPOCH_LENGTH + 1);

        // create a price gap: push currency1 price up in the plain pool so the cycle
        // "sell 1 for 0 in the plain pool, buy 1 for 0-fee in the auction pool" is profitable
        swapRouter.swapExactTokensForTokens({
            amountIn: 50e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: plainPoolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _arbRoute(uint256 amountIn, uint256 minProfit)
        internal
        view
        returns (AuctionArbExecutor.V4Route memory route)
    {
        AuctionArbExecutor.V4Hop[] memory hops = new AuctionArbExecutor.V4Hop[](2);
        // hop 1: currency1 -> currency0 in the plain pool (currency0 is cheap there)
        hops[0] = AuctionArbExecutor.V4Hop({
            key: plainPoolKey,
            zeroForOne: false,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        // hop 2: currency0 -> currency1 in the auction pool at the winner's zero fee
        hops[1] = AuctionArbExecutor.V4Hop({
            key: auctionPoolKey,
            zeroForOne: true,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        route = AuctionArbExecutor.V4Route({
            startCurrency: currency1,
            amountIn: amountIn,
            minProfit: minProfit,
            profitRecipient: profitRecipient,
            deadline: block.timestamp + 60,
            hops: hops
        });
    }

    function testWinnerArbCycleIsProfitable() public {
        uint256 profit = executor.executeV4Route(_arbRoute(10e18, 1));
        assertGt(profit, 0, "arb must be profitable at the winner fee");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(profitRecipient), profit);
    }

    function testNonWinnerPaysFeesAndEarnsLess() public {
        // identical route executed by a non-winner executor earns strictly less
        AuctionArbExecutor nonWinner = new AuctionArbExecutor(poolManager, address(this));

        uint256 snap = vm.snapshotState();
        uint256 winnerProfit = executor.executeV4Route(_arbRoute(10e18, 1));
        vm.revertToState(snap);

        uint256 nonWinnerProfit = nonWinner.executeV4Route(_arbRoute(10e18, 1));
        assertGt(winnerProfit, nonWinnerProfit, "fee discount must increase arb profit");
    }

    function testMinProfitEnforced() public {
        vm.expectPartialRevert(AuctionArbExecutor.InsufficientProfit.selector);
        executor.executeV4Route(_arbRoute(10e18, type(uint128).max));
    }

    function testOwnerOnlyAndDeadline() public {
        AuctionArbExecutor.V4Route memory route = _arbRoute(1e18, 1);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        executor.executeV4Route(route);

        route.deadline = block.timestamp - 1;
        vm.expectRevert(AuctionArbExecutor.DeadlineExpired.selector);
        executor.executeV4Route(route);
    }
}
