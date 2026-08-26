// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {HookAuctionController} from "src/hook/HookAuctionController.sol";

/// @notice Lean direct swapper so measurements attribute to pool+hook mechanics, not router logic.
contract ProfileSwapper is IUnlockCallback {
    IPoolManager internal immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256) {
        return abi.decode(poolManager.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pm");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;
        uint256 owed = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 received = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        poolManager.sync(inC);
        IERC20(Currency.unwrap(inC)).transfer(address(poolManager), owed);
        poolManager.settle();
        poolManager.take(outC, address(this), received);
        return abi.encode(received);
    }
}

/// @title SwapGasProfile
/// @notice Per-transaction swap gas profile across pool configurations. Each test measures the
///         FIRST swap in its test body, so all storage written in setUp is cold - matching what a
///         real user transaction pays. Numbers are recorded as forge gas snapshots
///         (snapshots/SwapGasProfile.json) so changes to the hot path show up in diffs.
/// @dev The MockV4Oracle's price read is a single pool slot0 load; the production V4Oracle does
///      two Chainlink rounds + two v3 TWAP observations (~15-25k cold), so add that premium to
///      every scenario marked (tick move) when projecting mainnet costs.
contract SwapGasProfileTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint32 internal constant EPOCH_LENGTH = 3600;

    Currency currency0;
    Currency currency1;

    PoolKey hooklessKey;
    PoolKey hookedKey; // static fee, no auction, no triggers
    PoolKey triggerKey; // static fee, one registered (far) trigger position
    PoolKey auctionKey; // dynamic fee, auction configured

    RevertHook hook;
    HookAuctionController auctionController;
    MockV4Oracle v4Oracle;
    ProfileSwapper swapper;
    ProfileSwapper winnerSwapper;

    uint64 startTime;

    uint256 constant SMALL = 1e6; // stays inside the current tick-spacing bucket
    uint256 constant LARGE = 20e18; // moves the tick across multiple 60-tick buckets

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4451 << 144)
        );

        v4Oracle = new MockV4Oracle(positionManager);
        RevertHookStack memory stack = deployRevertHookStack(flags, v4Oracle, makeAddr("feeRecipient"));
        hook = stack.hook;
        auctionController = stack.auctionController;

        hooklessKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        hookedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        triggerKey = PoolKey(currency0, currency1, 3001, 60, IHooks(hook));
        auctionKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(hooklessKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(hookedKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(triggerKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(auctionKey, Constants.SQRT_PRICE_1_1);

        // oracle reference for these tokens (production: Chainlink+TWAP; mock: reads this pool)
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), hooklessKey);

        PoolKey[4] memory keys = [hooklessKey, hookedKey, triggerKey, auctionKey];
        for (uint256 i = 0; i < 4; i++) {
            positionManager.mint(
                keys[i], TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1000e18,
                type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
            );
        }

        // register one auto-range trigger far from the current tick on triggerKey's position
        uint256 trigTokenId = positionManager.nextTokenId();
        positionManager.mint(
            triggerKey, -1200, 1200, 10e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        hook.setPositionConfig(
            trigTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: false,
                autoExitSwapOnUpperTrigger: false,
                autoRangeLowerLimit: 600,
                autoRangeUpperLimit: 600,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // configure the auction pool + install a winner for the current epoch
        swapper = new ProfileSwapper(poolManager);
        winnerSwapper = new ProfileSwapper(poolManager);
        IERC20 t0 = IERC20(Currency.unwrap(currency0));
        IERC20 t1 = IERC20(Currency.unwrap(currency1));
        t0.transfer(address(swapper), 1_000e18);
        t1.transfer(address(swapper), 1_000e18);
        t0.transfer(address(winnerSwapper), 1_000e18);
        t1.transfer(address(winnerSwapper), 1_000e18);

        startTime = uint64(block.timestamp);
        auctionController.configurePool(
            auctionKey,
            HookAuctionController.PoolAuctionConfig({
                auctionCurrency: currency1,
                normalLpFee: 3000,
                feeDiscountPpm: 500_000,
                epochStartTime: 0,
                epochLengthSeconds: EPOCH_LENGTH,
                minDripSeconds: 60,
                openingBidReserve: 1e15,
                minBidBumpPpm: 50_000,
                protocolFeeBps: 1000,
                protocolFeeRecipient: makeAddr("feeRecipient"),
                biddingEnabled: true
            })
        );
        t1.approve(address(auctionController), type(uint256).max);
        auctionController.bidNext(auctionKey, address(winnerSwapper), 1e18);

        // Prime every pool with one large swap so tick cursors and hook slots hold nonzero
        // values - measured swaps then pay steady-state costs (cold reads + dirty writes), not
        // one-time zero->nonzero SSTOREs that only the first-ever bucket move of a pool pays.
        swapper.swapExactIn(hooklessKey, true, LARGE);
        swapper.swapExactIn(hookedKey, true, LARGE);
        swapper.swapExactIn(triggerKey, true, LARGE);
        swapper.swapExactIn(auctionKey, true, LARGE);
        // move into the won epoch and let the first (expensive) sync+materialize+drip happen in
        // setUp, so the measured swaps below see the steady state (cold storage, no donate due)
        vm.warp(uint256(startTime) + EPOCH_LENGTH + EPOCH_LENGTH / 4);
        auctionController.drip(auctionKey);
    }

    // ==================== Scenarios (first swap in each test body = cold, like a real tx) ====

    function testGasProfile_1_baseline_hookless_tickMove() public {
        swapper.swapExactIn(hooklessKey, true, LARGE);
        vm.snapshotGasLastCall("SwapGasProfile", "1_hookless_tickMove");
    }

    function testGasProfile_2_hooked_smallSwap_noTickMove() public {
        // buy direction: at the current (already primed-down) price a tiny buy stays inside the
        // tick bucket, so this exercises the cursor==liveTick fast path
        swapper.swapExactIn(hookedKey, false, SMALL);
        vm.snapshotGasLastCall("SwapGasProfile", "2_hooked_noTickMove");
    }

    function testGasProfile_3_hooked_tickMove_noTriggers() public {
        swapper.swapExactIn(hookedKey, true, LARGE);
        vm.snapshotGasLastCall("SwapGasProfile", "3_hooked_tickMove_noTriggers");
    }

    function testGasProfile_4_hooked_tickMove_triggerRegisteredNotHit() public {
        swapper.swapExactIn(triggerKey, true, LARGE);
        vm.snapshotGasLastCall("SwapGasProfile", "4_hooked_tickMove_triggerFar");
    }

    function testGasProfile_5_baseline_hookless_smallSwap() public {
        swapper.swapExactIn(hooklessKey, false, SMALL);
        vm.snapshotGasLastCall("SwapGasProfile", "5_hookless_noTickMove");
    }

    function testGasProfile_6_auction_nonWinner_tickMove() public {
        swapper.swapExactIn(auctionKey, true, LARGE);
        vm.snapshotGasLastCall("SwapGasProfile", "6_auction_nonWinner_tickMove");
    }

    function testGasProfile_7_auction_winner_tickMove() public {
        winnerSwapper.swapExactIn(auctionKey, true, LARGE);
        vm.snapshotGasLastCall("SwapGasProfile", "7_auction_winner_tickMove");
    }

    function testGasProfile_8_auction_nonWinner_dripDue() public {
        // one minDripSeconds later a drip is due: this swap carries a real donate+settle
        vm.warp(block.timestamp + 61);
        swapper.swapExactIn(auctionKey, true, LARGE);
        vm.snapshotGasLastCall("SwapGasProfile", "8_auction_nonWinner_dripDue");
    }
}
