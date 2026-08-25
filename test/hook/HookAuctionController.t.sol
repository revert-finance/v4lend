// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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
import {HookOwnedControllerBase} from "src/hook/HookOwnedControllerBase.sol";
import {HookAuctionController} from "src/hook/HookAuctionController.sol";
import {IHookAuctionController} from "src/hook/interfaces/IHookAuctionController.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @notice Minimal direct PoolManager swapper. The auction controller recognizes the
///         epoch winner as the contract that calls PoolManager.swap, so tests use this
///         to exercise winner and non-winner swap paths with identical mechanics.
contract DirectSwapper is IUnlockCallback {
    IPoolManager internal immutable poolManager;
    address internal immutable operator;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        operator = msg.sender;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256 amountOut) {
        require(msg.sender == operator, "DirectSwapper: not operator");
        amountOut = abi.decode(poolManager.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "DirectSwapper: not poolManager");
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

        Currency inCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 owed = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 received = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));

        poolManager.sync(inCurrency);
        IERC20(Currency.unwrap(inCurrency)).transfer(address(poolManager), owed);
        poolManager.settle();
        poolManager.take(outCurrency, address(this), received);

        return abi.encode(received);
    }
}

/// @notice Controller mock that always reverts - used to verify the hook's fail-open glue.
contract RevertingAuctionController is IHookAuctionController {
    error Broken();

    function beforeSwap(PoolKey calldata, address) external pure returns (uint24) {
        revert Broken();
    }

    function beforeLiquidityChange(PoolKey calldata) external pure {
        revert Broken();
    }
}

contract HookAuctionControllerTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event AuctionControllerFailed(PoolId indexed poolId);

    uint32 internal constant PPM = 1_000_000;
    uint32 internal constant EPOCH_LENGTH = 3600;
    uint32 internal constant MIN_DRIP = 60;
    uint128 internal constant RESERVE = 1e15;
    uint16 internal constant PROTOCOL_FEE_BPS = 1000; // 10%
    uint24 internal constant NORMAL_FEE = 3000;

    Currency currency0;
    Currency currency1;

    PoolKey auctionPoolKey;
    PoolKey plainPoolKey;
    PoolId auctionPoolId;

    RevertHook hook;
    HookFeeController feeController;
    HookAuctionController auctionController;
    RevertHookAutoLendActions autoLendActionsRef;
    MockV4Oracle v4Oracle;

    DirectSwapper winnerSwapper;
    DirectSwapper otherSwapper;

    address bidderA;
    address bidderB;
    address protocolFeeRecipient;

    uint256 fullRangeTokenId;
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
            ) ^ (0x4446 << 144) // Namespace the hook to avoid collisions
        );

        v4Oracle = new MockV4Oracle(positionManager);
        protocolFeeRecipient = makeAddr("protocolFeeRecipient");

        LiquidityCalculator liquidityCalculator = new LiquidityCalculator();
        feeController = new HookFeeController(flags, protocolFeeRecipient, 200, 200);
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
        autoLendActionsRef = autoLendActions;

        bytes memory constructorArgs = abi.encode(
            address(this), v4Oracle, feeController, auctionController, positionActions, autoLeverageActions, autoLendActions
        );
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(payable(flags));

        auctionPoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        auctionPoolId = auctionPoolKey.toId();
        plainPoolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(auctionPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(plainPoolKey, Constants.SQRT_PRICE_1_1);

        (fullRangeTokenId,) = positionManager.mint(
            auctionPoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // fund bidders and swappers
        bidderA = makeAddr("bidderA");
        bidderB = makeAddr("bidderB");
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        token1.transfer(bidderA, 100e18);
        token1.transfer(bidderB, 100e18);
        vm.prank(bidderA);
        token1.approve(address(auctionController), type(uint256).max);
        vm.prank(bidderB);
        token1.approve(address(auctionController), type(uint256).max);

        winnerSwapper = new DirectSwapper(poolManager);
        otherSwapper = new DirectSwapper(poolManager);
        token0.transfer(address(winnerSwapper), 100e18);
        token1.transfer(address(winnerSwapper), 100e18);
        token0.transfer(address(otherSwapper), 100e18);
        token1.transfer(address(otherSwapper), 100e18);

        startTime = uint64(block.timestamp);
        auctionController.configurePool(auctionPoolKey, _defaultConfig());
    }

    function _defaultConfig() internal view returns (HookAuctionController.PoolAuctionConfig memory) {
        return HookAuctionController.PoolAuctionConfig({
            auctionCurrency: currency1,
            normalLpFee: NORMAL_FEE,
            feeDiscountPpm: PPM, // zero-fee winner
            epochStartTime: 0, // defaults to now
            epochLengthSeconds: EPOCH_LENGTH,
            minDripSeconds: MIN_DRIP,
            openingBidReserve: RESERVE,
            minBidBumpPpm: 50_000, // 5%
            protocolFeeBps: PROTOCOL_FEE_BPS,
            protocolFeeRecipient: protocolFeeRecipient,
            biddingEnabled: true
        });
    }

    function _bid(address bidder, address executor, uint256 amount) internal {
        vm.prank(bidder);
        auctionController.bidNext(auctionPoolKey, executor, amount);
    }

    function _warpToEpoch(uint64 epoch) internal {
        vm.warp(uint256(startTime) + uint256(epoch) * EPOCH_LENGTH + 1);
    }

    /// @dev Pending donation now releases gradually (anti-JIT); drive it to empty by warping a
    ///      full epoch per drip so the flush branch releases the remainder. Warps then drips
    ///      before checking, so the first call also rolls any end-of-epoch remainder into pending.
    function _drainPending(PoolKey memory key) internal {
        for (uint256 i = 0; i < 60; i++) {
            vm.warp(block.timestamp + EPOCH_LENGTH);
            auctionController.drip(key);
            (,, uint256 pending) = auctionController.getPoolAuctionState(key.toId());
            if (pending == 0) break;
        }
    }

    // ==================== Configuration ====================

    function testConfigureValidations() public {
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();

        // static-fee pool with this hook is rejected
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        vm.expectRevert(HookAuctionController.InvalidConfig.selector);
        auctionController.configurePool(staticKey, config);

        // uninitialized dynamic pool is rejected
        PoolKey memory uninitializedKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        vm.expectRevert(HookAuctionController.InvalidConfig.selector);
        auctionController.configurePool(uninitializedKey, config);

        // auction currency must be a pool side
        config = _defaultConfig();
        config.auctionCurrency = Currency.wrap(makeAddr("otherToken"));
        vm.expectRevert(HookAuctionController.InvalidConfig.selector);
        auctionController.configurePool(auctionPoolKey, config);

        // only the hook owner can configure
        vm.prank(bidderA);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        auctionController.configurePool(auctionPoolKey, _defaultConfig());

        // baseline fee is mirrored into the pool's stored dynamic fee
        (,,, uint24 lpFee) = poolManager.getSlot0(auctionPoolId);
        assertEq(lpFee, NORMAL_FEE, "stored dynamic fee should be the baseline fee");
    }

    function testUpdateDynamicLPFeeIsControllerOnly() public {
        // non-owner cannot touch the baseline
        vm.prank(bidderA);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        auctionController.setNormalLpFee(auctionPoolKey, 500);

        // even the hook owner can no longer call the passthrough directly (controller-only),
        // so the stored fee and the winner's fee cannot drift apart
        vm.expectRevert();
        hook.updateDynamicLPFee(auctionPoolKey, 500);

        // the owner changes the baseline through the controller, which re-mirrors atomically
        auctionController.setNormalLpFee(auctionPoolKey, 500);
        (,,, uint24 lpFee) = poolManager.getSlot0(auctionPoolId);
        assertEq(lpFee, 500, "stored fee re-mirrored");
        assertEq(auctionController.winnerLpFee(auctionPoolId), 0, "winner fee still derived from baseline");
    }

    function testConfigureRejectsZeroReserveOrBump() public {
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.openingBidReserve = 0;
        vm.expectRevert(HookAuctionController.InvalidConfig.selector);
        auctionController.configurePool(auctionPoolKey, config);

        config = _defaultConfig();
        config.minBidBumpPpm = 0;
        vm.expectRevert(HookAuctionController.InvalidConfig.selector);
        auctionController.configurePool(auctionPoolKey, config);
    }

    function testSweepPendingDonationRescuesStuckValue() public {
        // Drive value into pending with the pool empty, so it can never drip.
        uint256 bid = 1e18;
        _bid(bidderA, address(winnerSwapper), bid);
        _warpToEpoch(1);
        uint256 liquidity = positionManager.getPositionLiquidity(fullRangeTokenId);
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        _warpToEpoch(3);
        auctionController.drip(auctionPoolKey);
        (,, uint256 pending) = auctionController.getPoolAuctionState(auctionPoolId);
        assertGt(pending, 0);

        // sweep requires the pool to be wound down first
        vm.expectRevert(HookAuctionController.BiddingDisabled.selector);
        auctionController.sweepPendingDonation(auctionPoolKey, address(this));

        auctionController.setBiddingEnabled(auctionPoolKey, false);
        address sink = makeAddr("sink");
        uint256 swept = auctionController.sweepPendingDonation(auctionPoolKey, sink);
        assertEq(swept, pending);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(sink), pending);

        // pending cleared, so the pool can be reconfigured
        (,, uint256 pendingAfter) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pendingAfter, 0);
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.epochStartTime = uint64(block.timestamp);
        auctionController.configurePool(auctionPoolKey, config); // no longer reverts PoolStateNotClean
    }

    function testMinNextBidReflectsPendingRollover() public {
        _bid(bidderA, address(winnerSwapper), 5e15); // epoch 1 winner
        // move into epoch 1 without any pool touch: the stored next slot is stale
        vm.warp(uint256(startTime) + EPOCH_LENGTH + 1);
        // effective next bid is 0 (rollover pending), so only the reserve is required, not 5e15+bump
        assertEq(auctionController.minNextBid(auctionPoolId), RESERVE);
    }

    // ==================== Bidding ====================

    function testBidReserveBumpAndEscrowRefund() public {
        // below reserve
        vm.expectRevert(HookAuctionController.InvalidBid.selector);
        _bid(bidderA, address(winnerSwapper), RESERVE - 1);

        _bid(bidderA, address(winnerSwapper), RESERVE);

        // outbid must exceed 5% bump
        uint256 minBid = auctionController.minNextBid(auctionPoolId);
        assertEq(minBid, RESERVE + RESERVE * 50_000 / PPM);
        vm.expectRevert(HookAuctionController.InvalidBid.selector);
        _bid(bidderB, address(otherSwapper), minBid - 1);

        uint256 bidderABalanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(bidderA);
        _bid(bidderB, address(otherSwapper), minBid);

        // refund escrowed, not pushed
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(bidderA), bidderABalanceBefore);
        assertEq(auctionController.refunds(currency1, bidderA), RESERVE);

        vm.prank(bidderA);
        auctionController.claimRefund(currency1, bidderA);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(bidderA), bidderABalanceBefore + RESERVE);

        vm.prank(bidderA);
        vm.expectRevert(HookAuctionController.NothingToClaim.selector);
        auctionController.claimRefund(currency1, bidderA);
    }

    function testExecutorDenylist() public {
        // permissionless by default: any executor accepted
        _bid(bidderA, address(winnerSwapper), RESERVE);

        // deny a (mock) shared router; it can no longer be registered, but others still can
        address sharedRouter = makeAddr("sharedRouter");
        auctionController.setExecutorDenied(sharedRouter, true);
        vm.prank(bidderB);
        vm.expectRevert(HookAuctionController.InvalidExecutor.selector);
        auctionController.bidNext(auctionPoolKey, sharedRouter, RESERVE * 2);

        // a normal executor is unaffected
        _bid(bidderB, address(otherSwapper), RESERVE * 2);

        // re-allowing lifts the block
        auctionController.setExecutorDenied(sharedRouter, false);
        _bid(bidderA, address(winnerSwapper), RESERVE * 4); // outbid stands, sanity that bidding still works

        // non-owner cannot manage the denylist
        vm.prank(bidderA);
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        auctionController.setExecutorDenied(sharedRouter, true);
    }

    function testBidInvalidExecutors() public {
        vm.expectRevert(HookAuctionController.InvalidExecutor.selector);
        _bid(bidderA, address(0), RESERVE);
        vm.expectRevert(HookAuctionController.InvalidExecutor.selector);
        _bid(bidderA, address(poolManager), RESERVE);
        vm.expectRevert(HookAuctionController.InvalidExecutor.selector);
        _bid(bidderA, address(hook), RESERVE);
        vm.expectRevert(HookAuctionController.InvalidExecutor.selector);
        _bid(bidderA, address(auctionController), RESERVE);
    }

    // ==================== Winner fee ====================

    function testWinnerGetsDiscountedFeeOnlyInWonEpoch() public {
        uint256 bid = 1e18;
        _bid(bidderA, address(winnerSwapper), bid);

        uint256 amountIn = 1e18;

        // epoch 0: bid targets epoch 1, no discount yet
        uint256 snap = vm.snapshotState();
        uint256 outSameEpoch = winnerSwapper.swapExactIn(auctionPoolKey, true, amountIn);
        vm.revertToState(snap);

        // epoch 1: winner swaps fee-free, others pay the baseline fee
        _warpToEpoch(1);
        snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(auctionPoolKey, true, amountIn);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(auctionPoolKey, true, amountIn);
        vm.revertToState(snap);

        assertApproxEqRel(outSameEpoch, outOther, 1e12, "no discount before the won epoch");
        assertGt(outWinner, outOther, "winner should get a better rate");
        // zero fee vs 0.3%: outWinner = outOther / 0.997
        assertApproxEqRel(outWinner, outOther * PPM / (PPM - NORMAL_FEE), 1e14);

        // epoch 2: discount is gone
        _warpToEpoch(2);
        snap = vm.snapshotState();
        uint256 outExpired = winnerSwapper.swapExactIn(auctionPoolKey, true, amountIn);
        vm.revertToState(snap);
        assertApproxEqRel(outExpired, outOther, 1e12, "discount must end with the epoch");
    }

    function testPartialDiscount() public {
        // reconfigure with 50% discount before any bids
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.feeDiscountPpm = 500_000;
        auctionController.configurePool(auctionPoolKey, config);
        startTime = uint64(block.timestamp);
        assertEq(auctionController.winnerLpFee(auctionPoolId), 1500);

        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1);

        uint256 snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);

        // 0.15% vs 0.3% fee
        assertApproxEqRel(outWinner, outOther * (PPM - 1500) / (PPM - NORMAL_FEE), 1e14);
    }

    function testProtocolFeeMaterializesOnceAndIsClaimable() public {
        uint256 bid = 1e18;
        _bid(bidderA, address(winnerSwapper), bid);
        _warpToEpoch(1);

        // first pool touch materializes the epoch
        otherSwapper.swapExactIn(auctionPoolKey, true, 1e15);
        uint256 expectedProtocolFee = bid * PROTOCOL_FEE_BPS / 10_000;
        assertEq(auctionController.protocolFeesAccrued(currency1, protocolFeeRecipient), expectedProtocolFee);

        // second touch does not double count
        otherSwapper.swapExactIn(auctionPoolKey, true, 1e15);
        assertEq(auctionController.protocolFeesAccrued(currency1, protocolFeeRecipient), expectedProtocolFee);

        vm.prank(protocolFeeRecipient);
        auctionController.claimProtocolFees(currency1, protocolFeeRecipient);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(protocolFeeRecipient), expectedProtocolFee);
    }

    // ==================== Dripping ====================

    function testDripVestsLinearlyAndReachesLps() public {
        uint256 bid = 1e18;
        uint256 totalDrip = bid - bid * PROTOCOL_FEE_BPS / 10_000;
        _bid(bidderA, address(winnerSwapper), bid);

        // halfway through epoch 1
        vm.warp(uint256(startTime) + EPOCH_LENGTH + EPOCH_LENGTH / 2);
        auctionController.drip(auctionPoolKey);
        (,,,, uint256 donated,,) = auctionController.getEpochAuction(auctionPoolId, false);
        assertApproxEqAbs(donated, totalDrip / 2, totalDrip / EPOCH_LENGTH + 1, "half vested at half epoch");

        // past epoch end the undripped remainder rolls into the pending bucket, which releases
        // gradually; drive it to empty, then confirm the LP collects the whole bid's drip.
        _drainPending(auctionPoolKey);
        (,, uint256 pendingDonation) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pendingDonation, 0, "pending fully drained");

        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        positionManager.decreaseLiquidity(
            fullRangeTokenId, 0, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        uint256 collected = IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balance1Before;
        assertApproxEqAbs(collected, totalDrip, 10, "LP eventually collects the full drip");
    }

    function testPendingReleasesGraduallyNotInOneBlock() public {
        // A winner's proceeds accrue while the pool has zero in-range liquidity, filling the
        // pending bucket. A JIT position must NOT be able to capture the whole bucket at once.
        uint256 bid = 1e18;
        uint256 totalDrip = bid - bid * PROTOCOL_FEE_BPS / 10_000;
        _bid(bidderA, address(winnerSwapper), bid);
        _warpToEpoch(1);

        uint256 liquidity = positionManager.getPositionLiquidity(fullRangeTokenId);
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        _warpToEpoch(3);
        auctionController.drip(auctionPoolKey); // materialize + carry into pending (no liquidity)
        (,, uint256 pendingBefore) = auctionController.getPoolAuctionState(auctionPoolId);
        // ~all of the drip is parked (a sliver may have vested in the 1s before the removal)
        assertGt(pendingBefore, totalDrip * 99 / 100, "~whole drip parked as pending");

        // JIT: add liquidity then immediately drip in the same timestamp
        positionManager.mint(
            auctionPoolKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        auctionController.drip(auctionPoolKey);
        (,, uint256 pendingAfter) = auctionController.getPoolAuctionState(auctionPoolId);
        // one release is capped to ~minDripSeconds/epochLength of the bucket, far below the whole
        assertGt(pendingAfter, pendingBefore * 90 / 100, "single-block capture is bounded");
    }

    function testPendingCatchupBoundedAfterZeroLiquidityGap() public {
        // Codex P2: pending dripped once, then the pool sits at zero liquidity for a full epoch;
        // the first LP to reappear must NOT be able to capture the whole accrued bucket at once.
        uint256 bid = 1e18;
        _bid(bidderA, address(winnerSwapper), bid);
        _warpToEpoch(1);
        auctionController.drip(auctionPoolKey); // active-epoch drip once, with liquidity present

        // remove all liquidity, let a couple of epochs pass
        uint256 liquidity = positionManager.getPositionLiquidity(fullRangeTokenId);
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        _warpToEpoch(4);
        auctionController.drip(auctionPoolKey); // zero liquidity: clock advanced, nothing released
        (,, uint256 pendingBefore) = auctionController.getPoolAuctionState(auctionPoolId);
        assertGt(pendingBefore, 0);

        // JIT reappears and immediately drips in the same block
        positionManager.mint(
            auctionPoolKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        auctionController.drip(auctionPoolKey);
        (,, uint256 pendingAfter) = auctionController.getPoolAuctionState(auctionPoolId);
        // throttled in the same block: essentially nothing is released to the JIT
        assertEq(pendingAfter, pendingBefore, "no catch-up dumped to a same-block JIT");
    }

    function testLargePendingDoesNotOverflowAndIsSweepable() public {
        // Codex P2: with protocolFeeBps == 0, carrying several near-MAX_BID_AMOUNT epochs into the
        // pending bucket must not overflow / brick the pool. pendingDonation is uint256.
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.protocolFeeBps = 0;
        config.feeDiscountPpm = 500_000;
        auctionController.configurePool(auctionPoolKey, config);
        startTime = uint64(block.timestamp);

        uint256 huge = uint256(uint128(type(int128).max)); // MAX_BID_AMOUNT
        // remove liquidity so every winning epoch's proceeds carry into pending
        uint256 liquidity = positionManager.getPositionLiquidity(fullRangeTokenId);
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        for (uint64 e = 0; e < 3; e++) {
            deal(address(token1), bidderA, huge);
            vm.prank(bidderA);
            token1.approve(address(auctionController), huge);
            vm.prank(bidderA);
            auctionController.bidNext(auctionPoolKey, address(winnerSwapper), huge);
            _warpToEpoch(e + 1);
            auctionController.drip(auctionPoolKey); // carries prior epoch into pending, no revert
        }

        (,, uint256 pending) = auctionController.getPoolAuctionState(auctionPoolId);
        assertGt(pending, huge, "aggregate exceeds a single MAX_BID_AMOUNT without overflow");

        // still recoverable
        auctionController.setBiddingEnabled(auctionPoolKey, false);
        uint256 swept = auctionController.sweepPendingDonation(auctionPoolKey, makeAddr("sink"));
        assertEq(swept, pending);
    }

    function testDripHonorsMinDripSecondsAndCatchesUp() public {
        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1);

        auctionController.drip(auctionPoolKey);
        (,,,, uint256 donatedFirst,,) = auctionController.getEpochAuction(auctionPoolId, false);

        // within the throttle window nothing new drips
        vm.warp(block.timestamp + MIN_DRIP / 2);
        auctionController.drip(auctionPoolKey);
        (,,,, uint256 donatedThrottled,,) = auctionController.getEpochAuction(auctionPoolId, false);
        assertEq(donatedThrottled, donatedFirst);

        // after the window the vesting catches up
        vm.warp(block.timestamp + MIN_DRIP);
        auctionController.drip(auctionPoolKey);
        (,,,, uint256 donatedLater,,) = auctionController.getEpochAuction(auctionPoolId, false);
        assertGt(donatedLater, donatedFirst);
    }

    function testSkippedEpochRefundsUnservedWinner() public {
        // Bidder wins epoch 1 during epoch 0, but the pool is never touched for several epochs,
        // so that winner is never promoted to active and never gets a discounted swap. Their bid
        // must be refunded, not confiscated into LP drip.
        uint256 bid = 1e18;
        _bid(bidderA, address(winnerSwapper), bid);

        _warpToEpoch(4);
        auctionController.drip(auctionPoolKey);

        assertEq(auctionController.refunds(currency1, bidderA), bid, "unserved winner is refunded");
        (,, uint256 pendingDonation) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pendingDonation, 0, "nothing dripped to LPs");

        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        positionManager.decreaseLiquidity(
            fullRangeTokenId, 0, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balance1Before, 0, "LP collects nothing"
        );

        vm.prank(bidderA);
        auctionController.claimRefund(currency1, bidderA);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(bidderA), 100e18, "bidder made whole");
    }

    function testZeroLiquidityKeepsValuePending() public {
        uint256 bid = 1e18;
        uint256 totalDrip = bid - bid * PROTOCOL_FEE_BPS / 10_000;
        _bid(bidderA, address(winnerSwapper), bid);
        _warpToEpoch(1);

        // removing all liquidity first drips the vested part to the leaving LP,
        // afterwards nothing can be donated
        uint256 liquidity = positionManager.getPositionLiquidity(fullRangeTokenId);
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        _warpToEpoch(3);
        auctionController.drip(auctionPoolKey);
        (,, uint256 pendingDonation) = auctionController.getPoolAuctionState(auctionPoolId);
        assertGt(pendingDonation, 0, "undonatable value must be kept pending");

        // adding liquidity back lets the pending bucket drain (gradually, anti-JIT)
        positionManager.mint(
            auctionPoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        _drainPending(auctionPoolKey);
        (,, pendingDonation) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pendingDonation, 0, "pending fully drains once liquidity exists");

        // conservation: everything the controller no longer holds went to LPs or protocol fees
        uint256 controllerBalance = IERC20(Currency.unwrap(currency1)).balanceOf(address(auctionController));
        uint256 protocolFee = bid - totalDrip;
        assertEq(controllerBalance, protocolFee, "controller keeps only unclaimed protocol fees");
    }

    // ==================== Deactivation ====================

    function testDeactivationHonorsRunningEpochAndRefundsNextBid() public {
        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1);

        // bidderB bids for epoch 2, then the owner deactivates
        _bid(bidderB, address(otherSwapper), 1e18);
        auctionController.setBiddingEnabled(auctionPoolKey, false);

        // next-epoch bid is refunded to escrow
        assertEq(auctionController.refunds(currency1, bidderB), 1e18);

        // no new bids
        vm.expectRevert(HookAuctionController.BiddingDisabled.selector);
        _bid(bidderB, address(otherSwapper), 2e18);

        // the running epoch's winner keeps the discount until epoch end
        uint256 snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        assertGt(outWinner, outOther, "running epoch must be honored");

        // wind-down: after the epoch everything is a plain dynamic-fee pool again
        _warpToEpoch(2);
        auctionController.drip(auctionPoolKey);
        (,,,, uint256 donated,,) = auctionController.getEpochAuction(auctionPoolId, false);
        assertEq(donated, 0, "no active auction after wind-down");

        snap = vm.snapshotState();
        uint256 outAfter = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        assertApproxEqRel(outAfter, outOther, 1e12, "no discount after wind-down");

        // the previous epoch's undripped remainder drains gradually to LPs
        _drainPending(auctionPoolKey);
        (,, uint256 pendingDonation) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pendingDonation, 0, "old epoch fully dripped");

        // re-enable: bidding works again
        auctionController.setBiddingEnabled(auctionPoolKey, true);
        _bid(bidderB, address(otherSwapper), RESERVE);
    }

    function testBidsPausedSuspendsDiscountAndBids() public {
        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1);

        auctionController.setBidsPaused(true);

        vm.expectRevert(HookAuctionController.BiddingDisabled.selector);
        _bid(bidderB, address(otherSwapper), 2e18);

        uint256 snap = vm.snapshotState();
        uint256 outWinnerPaused = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        assertApproxEqRel(outWinnerPaused, outOther, 1e12, "no discount while paused");

        // drip still works while paused
        auctionController.drip(auctionPoolKey);

        auctionController.setBidsPaused(false);
        snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        assertGt(outWinner, outOther, "discount restored after unpause");
    }

    // ==================== Fail-open glue ====================

    function testHookFailsOpenWhenControllerReverts() public {
        // separate hook wired to an always-reverting controller
        address flags2 = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4447 << 144)
        );
        RevertingAuctionController brokenController = new RevertingAuctionController();
        _deployHookTo(flags2, address(brokenController));

        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flags2));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        // No configured baseline fee (the controller reverts), so the pool runs at the 0% dynamic
        // default; the point is that swaps and liquidity ops still succeed fail-open.

        // liquidity ops and swaps succeed despite the broken controller
        positionManager.mint(
            key,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        vm.expectEmit(true, false, false, false, flags2);
        emit AuctionControllerFailed(key.toId());
        uint256 amountOut = otherSwapper.swapExactIn(key, true, 1e18);
        assertGt(amountOut, 0, "swap must succeed fail-open");
    }

    function testHookWorksWithZeroController() public {
        address flags3 = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4448 << 144)
        );
        _deployHookTo(flags3, address(0));

        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(flags3));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        uint256 amountOut = otherSwapper.swapExactIn(key, true, 1e18);
        assertGt(amountOut, 0);
    }

    function _deployHookTo(address flags, address controller) internal {
        LiquidityCalculator liquidityCalculator = new LiquidityCalculator();
        HookFeeController feeController2 = new HookFeeController(flags, protocolFeeRecipient, 200, 200);
        HookRouteController routeController2 = new HookRouteController(flags);
        RevertHookSwapActions swapActions2 = new RevertHookSwapActions(poolManager, feeController2);
        RevertHookPositionActions positionActions2 =
            new RevertHookPositionActions(permit2, v4Oracle, liquidityCalculator, routeController2, swapActions2);
        RevertHookAutoLeverageActions autoLeverageActions2 =
            new RevertHookAutoLeverageActions(permit2, v4Oracle, liquidityCalculator, routeController2, swapActions2);
        RevertHookAutoLendActions autoLendActions2 = new RevertHookAutoLendActions(
            permit2, v4Oracle, liquidityCalculator, feeController2, routeController2, swapActions2
        );
        bytes memory constructorArgs = abi.encode(
            address(this), v4Oracle, feeController2, controller, positionActions2, autoLeverageActions2, autoLendActions2
        );
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
    }

    // ==================== Accounting ====================

    function testControllerBalanceMatchesObligations() public {
        // epoch 0: A bids, B outbids
        _bid(bidderA, address(winnerSwapper), RESERVE);
        _bid(bidderB, address(otherSwapper), RESERVE * 2);

        // epoch 1: B is winner; A bids for epoch 2
        _warpToEpoch(1);
        _bid(bidderA, address(winnerSwapper), RESERVE);

        // epoch 2 partially elapsed, some dripping happened
        vm.warp(uint256(startTime) + 2 * EPOCH_LENGTH + EPOCH_LENGTH / 3);
        auctionController.drip(auctionPoolKey);

        (,, uint256 pendingDonation) = auctionController.getPoolAuctionState(auctionPoolId);
        (,, uint256 activeBid, uint256 activeTotalDrip, uint256 activeDonated,,) =
            auctionController.getEpochAuction(auctionPoolId, false);
        (,, uint256 nextBid,,,,) = auctionController.getEpochAuction(auctionPoolId, true);

        uint256 obligations = auctionController.refunds(currency1, bidderA)
            + auctionController.refunds(currency1, bidderB)
            + auctionController.protocolFeesAccrued(currency1, protocolFeeRecipient) + pendingDonation + nextBid
            + (activeBid == 0 ? 0 : activeTotalDrip - activeDonated);

        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(auctionController)),
            obligations,
            "controller balance must exactly back all obligations"
        );
    }

    // ==================== Hook access ====================

    function testControllerEntryPointsAreHookOnly() public {
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        auctionController.beforeSwap(auctionPoolKey, address(this));
        vm.expectRevert(HookOwnedControllerBase.Unauthorized.selector);
        auctionController.beforeLiquidityChange(auctionPoolKey);
    }

    function testTakeProtocolFeesRejectsDirectCall() public {
        // takeProtocolFees is delegatecall-only; a direct call on the sidecar (which would run on
        // its own storage and could emit spoofed SendProtocolFee events) must revert.
        vm.expectRevert(); // Unauthorized (Constants.Unauthorized selector)
        autoLendActionsRef.takeProtocolFees(1, auctionPoolKey, toBalanceDelta(int128(1), int128(1)));
    }
}
