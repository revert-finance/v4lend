// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {DirectSwapper, BlacklistingToken} from "test/hook/HookAuctionController.t.sol";

import {RevertHook} from "src/RevertHook.sol";
import {HookLeaseController} from "src/hook/HookLeaseController.sol";

contract HookLeaseControllerTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 internal constant PPM = 1_000_000;
    uint32 internal constant MIN_DRIP = 60;
    uint32 internal constant DRIP_HORIZON = 3600;
    uint32 internal constant MIN_RENT_SECONDS = 3600; // must prepay at least 1h of rent
    uint16 internal constant PROTOCOL_FEE_BPS = 1000; // 10%
    uint24 internal constant NORMAL_FEE = 3000;
    // price / 36_000 per second: a lease burns 100% of its self-assessed price in 10 hours
    uint64 internal constant TAX_X64 = uint64((uint256(1) << 64) / 36_000);

    Currency currency0;
    Currency currency1;

    PoolKey leasePoolKey;
    PoolId leasePoolId;

    RevertHook hook;
    HookLeaseController leaseController;
    MockV4Oracle v4Oracle;

    DirectSwapper lesseeSwapper;
    DirectSwapper otherSwapper;

    address lesseeA;
    address lesseeB;
    address protocolFeeRecipient;

    uint256 fullRangeTokenId;
    IERC20 token0;
    IERC20 token1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4452 << 144) // Namespace the hook to avoid collisions
        );

        v4Oracle = new MockV4Oracle(positionManager);
        protocolFeeRecipient = makeAddr("protocolFeeRecipient");

        // wire the LEASE controller into the hook's auction-controller slot: both mechanisms
        // implement IHookAuctionController, so the deployment chooses one of the two
        leaseController = new HookLeaseController(flags, poolManager);
        RevertHookStack memory stack =
            deployRevertHookStackWithController(flags, v4Oracle, protocolFeeRecipient, address(leaseController));
        hook = stack.hook;

        leasePoolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        leasePoolId = leasePoolKey.toId();
        poolManager.initialize(leasePoolKey, Constants.SQRT_PRICE_1_1);

        (fullRangeTokenId,) = positionManager.mint(
            leasePoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        lesseeA = makeAddr("lesseeA");
        lesseeB = makeAddr("lesseeB");
        token0 = IERC20(Currency.unwrap(currency0));
        token1 = IERC20(Currency.unwrap(currency1));
        token1.transfer(lesseeA, 100e18);
        token1.transfer(lesseeB, 100e18);
        vm.prank(lesseeA);
        token1.approve(address(leaseController), type(uint256).max);
        vm.prank(lesseeB);
        token1.approve(address(leaseController), type(uint256).max);

        lesseeSwapper = new DirectSwapper(poolManager);
        otherSwapper = new DirectSwapper(poolManager);
        token0.transfer(address(lesseeSwapper), 100e18);
        token1.transfer(address(lesseeSwapper), 100e18);
        token0.transfer(address(otherSwapper), 100e18);
        token1.transfer(address(otherSwapper), 100e18);

        leaseController.configurePool(leasePoolKey, _defaultConfig());
    }

    function _defaultConfig() internal view returns (HookLeaseController.PoolLeaseConfig memory) {
        return HookLeaseController.PoolLeaseConfig({
            startTime: 0, // defaults to now
            minDripSeconds: MIN_DRIP,
            dripHorizonSeconds: DRIP_HORIZON,
            normalLpFee: NORMAL_FEE,
            feeDiscountPpm: PPM, // zero-fee lessee
            leasingEnabled: true,
            auctionCurrency: currency1,
            minBuyoutBumpPpm: 50_000, // 5%
            protocolFeeBps: PROTOCOL_FEE_BPS,
            minRentDepositSeconds: MIN_RENT_SECONDS,
            protocolFeeRecipient: protocolFeeRecipient,
            taxRatePerSecondX64: TAX_X64
        });
    }

    function _startLease(address lessee, address executor, uint256 price, uint256 rentDeposit) internal {
        vm.prank(lessee);
        leaseController.startLease(leasePoolKey, executor, price, rentDeposit);
    }

    /// @dev Compares the swap output of the lessee's executor vs a plain swapper at the same
    ///      pool state (each in its own snapshot).
    function _swapOutcomes(uint256 amountIn) internal returns (uint256 outLessee, uint256 outOther) {
        uint256 snap = vm.snapshotState();
        outLessee = lesseeSwapper.swapExactIn(leasePoolKey, true, amountIn);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        outOther = otherSwapper.swapExactIn(leasePoolKey, true, amountIn);
        vm.revertToState(snap);
    }

    // ==================== Lifecycle ====================

    /// @notice READ THIS ONE to understand the mechanism. Walks the whole Harberger-lease
    ///         lifecycle end to end; every other test isolates one property of it.
    ///
    ///         Flow: configure a 0.30% pool with a 100% lessee discount -> A leases the executor
    ///         slot (self-assessed price 1e18, 2h of prepaid rent) -> A's executor swaps fee-free
    ///         while everyone else pays 0.30% -> rent accrues with time and drips to in-range LPs
    ///         (minus a 10% protocol fee) -> B takes the slot with a Harberger buyout at +5% ->
    ///         A is made whole from escrow (deposit + unused rent) -> the discount follows to B's
    ///         executor -> B exits and gets deposit + remaining rent back; the slot is vacant.
    function testFullLeaseLifecycle() public {
        uint256 price = 1e18;
        uint256 rent = 0.2e18; // 2h at 1e18/10h

        // ---- A leases the slot ----
        uint256 balABefore = token1.balanceOf(lesseeA);
        _startLease(lesseeA, address(lesseeSwapper), price, rent);
        assertEq(balABefore - token1.balanceOf(lesseeA), price + rent, "A escrows price + rent");

        (address lessee, address executor,, uint24 lpFee) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, lesseeA);
        assertEq(executor, address(lesseeSwapper));
        assertEq(lpFee, 0, "100% discount = zero-fee lessee");

        // ---- discount: A's executor swaps fee-free, everyone else pays the baseline ----
        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "lessee executor must get the discount");
        // 0.30% fee difference on ~1:1 pool
        assertApproxEqRel(outLessee - outOther, 0.003e18, 0.1e18, "difference is roughly the LP fee");

        // ---- rent accrues and drips to in-range LPs ----
        vm.warp(block.timestamp + 1800); // half an hour
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        (,,, uint256 rentBalance,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        uint256 accrued = rent - rentBalance;
        assertApproxEqAbs(accrued, 0.05e18, 1e6, "half an hour = a quarter of the 2h deposit");
        uint256 fee = accrued * PROTOCOL_FEE_BPS / 10_000;
        assertEq(
            leaseController.protocolFeesAccrued(currency1, protocolFeeRecipient), fee, "protocol fee split off"
        );
        uint256 donated = token1.balanceOf(address(poolManager)) - pmBefore;
        assertGt(donated, 0, "rent dripped to the pool's LPs");
        assertEq(pending + donated + fee, accrued, "accrued rent = pending + donated + protocol fee");

        // ---- B takes the slot Harberger-style ----
        uint256 minBuyout = leaseController.minBuyoutPrice(leasePoolId);
        assertEq(minBuyout, price + price * 50_000 / PPM, "buyout must beat the self-assessed price by 5%");
        vm.prank(lesseeB);
        leaseController.buyout(leasePoolKey, address(otherSwapper), minBuyout, rent);

        // A is made whole from escrow: deposit + unused rent
        (,,, uint256 rentBalanceAfterBuyout,,,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(rentBalanceAfterBuyout, rent, "B's fresh rent deposit");
        uint256 refundA = leaseController.refunds(currency1, lesseeA);
        assertGt(refundA, 0, "A's refund escrowed");
        uint256 balA = token1.balanceOf(lesseeA);
        vm.prank(lesseeA);
        leaseController.claimRefund(currency1, lesseeA);
        assertEq(token1.balanceOf(lesseeA) - balA, refundA, "A claims deposit + unused rent");

        // ---- the discount followed the slot ----
        (uint256 outB, uint256 outA) = (0, 0);
        {
            uint256 snap = vm.snapshotState();
            outA = lesseeSwapper.swapExactIn(leasePoolKey, true, 1e18);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            outB = otherSwapper.swapExactIn(leasePoolKey, true, 1e18);
            vm.revertToState(snap);
        }
        assertGt(outB, outA, "discount moved to B's executor");

        // ---- B exits; the slot is vacant ----
        uint256 balB = token1.balanceOf(lesseeB);
        vm.prank(lesseeB);
        uint256 refundB = leaseController.exitLease(leasePoolKey);
        assertEq(token1.balanceOf(lesseeB) - balB, refundB, "B refunded directly on exit");
        (lessee, executor,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, address(0), "slot vacant after exit");

        // protocol fees are claimable
        uint256 feesNow = leaseController.protocolFeesAccrued(currency1, protocolFeeRecipient);
        assertGt(feesNow, 0);
        vm.prank(protocolFeeRecipient);
        leaseController.claimProtocolFees(currency1, protocolFeeRecipient);
        assertEq(token1.balanceOf(protocolFeeRecipient), feesNow);
    }

    // ==================== Configuration ====================

    function testConfigureValidation() public {
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();

        // static-fee pool / wrong hook / uninitialized pool
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(staticKey, config);
        PoolKey memory foreignKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(1)));
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(foreignKey, config);
        PoolKey memory freshKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(freshKey, config);

        // field validations, each checked in isolation on the valid pool
        HookLeaseController.PoolLeaseConfig memory bad;

        bad = _defaultConfig();
        bad.auctionCurrency = Currency.wrap(address(0xbeef)); // not a pool side
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.normalLpFee = uint24(LPFeeLibrary.MAX_LP_FEE + 1);
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.feeDiscountPpm = PPM + 1;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.protocolFeeBps = 2001;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.protocolFeeRecipient = address(0);
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.minDripSeconds = 0;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.dripHorizonSeconds = MIN_DRIP - 1; // below the throttle
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.dripHorizonSeconds = 30 days + 1;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.minBuyoutBumpPpm = 0;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.minRentDepositSeconds = 0;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        bad = _defaultConfig();
        bad.taxRatePerSecondX64 = 0;
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        vm.warp(block.timestamp + 1000); // ensure timestamp-1 is not the 0 "defaults to now" sentinel
        bad = _defaultConfig();
        bad.startTime = uint64(block.timestamp - 1); // in the past
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, bad);

        // non-owner cannot configure
        vm.prank(lesseeA);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        leaseController.configurePool(leasePoolKey, config);
    }

    function testConfigureRequiresCleanState() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        vm.expectRevert(HookLeaseController.PoolStateNotClean.selector);
        leaseController.configurePool(leasePoolKey, _defaultConfig());

        // exit clears the lease, but accrued-but-undonated rent still blocks reconfiguration
        vm.warp(block.timestamp + 600);
        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
        (,,,,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        if (pending != 0) {
            vm.expectRevert(HookLeaseController.PoolStateNotClean.selector);
            leaseController.configurePool(leasePoolKey, _defaultConfig());
        }
    }

    // ==================== Lease entry requirements ====================

    function testStartLeaseRequirements() public {
        uint256 minDeposit = leaseController.rentPerSecond(leasePoolId); // for price... computed below

        // unconfigured pool
        PoolKey memory otherKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        vm.expectRevert(HookLeaseController.PoolNotConfigured.selector);
        vm.prank(lesseeA);
        leaseController.startLease(otherKey, address(lesseeSwapper), 1e18, 1e18);

        // invalid executors
        vm.startPrank(lesseeA);
        vm.expectRevert(HookLeaseController.InvalidExecutor.selector);
        leaseController.startLease(leasePoolKey, address(0), 1e18, 1e18);
        vm.expectRevert(HookLeaseController.InvalidExecutor.selector);
        leaseController.startLease(leasePoolKey, address(poolManager), 1e18, 1e18);
        vm.stopPrank();

        // denied executor
        leaseController.setExecutorDenied(address(lesseeSwapper), true);
        vm.expectRevert(HookLeaseController.InvalidExecutor.selector);
        vm.prank(lesseeA);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 1e18, 1e18);
        leaseController.setExecutorDenied(address(lesseeSwapper), false);

        // zero price / oversized price
        vm.startPrank(lesseeA);
        vm.expectRevert(HookLeaseController.InvalidPrice.selector);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 0, 1e18);

        // rent deposit below minRentDepositSeconds of rent
        uint256 price = 1e18;
        minDeposit = price / 36_000 * MIN_RENT_SECONDS; // ~= rps * seconds (rps rounds up)
        vm.expectRevert(HookLeaseController.InvalidRentDeposit.selector);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), price, minDeposit / 2);

        // valid start, then double-start rejected
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), price, 0.2e18);
        vm.stopPrank();
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        vm.prank(lesseeB);
        leaseController.startLease(leasePoolKey, address(otherSwapper), price, 0.2e18);
    }

    function testStartLeaseRespectsStartTime() public {
        // reconfigure a future start on a clean pool
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.startTime = uint64(block.timestamp + 1000);
        leaseController.configurePool(leasePoolKey, config);

        vm.expectRevert(HookLeaseController.LeasingNotStarted.selector);
        vm.prank(lesseeA);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 1e18, 0.2e18);

        // and beforeSwap applies no discount before startTime
        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertEq(outLessee, outOther, "no discount before startTime");

        vm.warp(block.timestamp + 1000);
        vm.prank(lesseeA);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 1e18, 0.2e18);
    }

    // ==================== Discount semantics ====================

    function testDiscountOnlyForExecutorWhileRentSolvent() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18); // 2h of rent

        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "discount while solvent");

        // beyond paidThrough the rent is exhausted: no discount, even for the executor
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough) + 1);
        (outLessee, outOther) = _swapOutcomes(1e18);
        assertEq(outLessee, outOther, "no discount once rent is exhausted");

        // topping up rent is blocked?? no - still enabled: restore the discount
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 0.2e18);
        (outLessee, outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "discount restored after refunding rent");
    }

    /// @notice Codex P1: a zero-duration rent top-up must not activate the discount. On an
    ///         insolvent lease, fundRent with sub-second dust floors rentBalance/rps to zero, so
    ///         paidThrough == now; with an inclusive comparison the lessee could re-arm the
    ///         discount every block for 1 wei. The comparison is strict: a deposit covering k
    ///         seconds grants exactly [start, start+k), so dust grants nothing.
    function testDustRentTopUpDoesNotActivateDiscount() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough) + 100); // insolvent

        // dust top-up: less than one second of rent
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 1);
        (,,,,, uint40 paidThroughAfter,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(paidThroughAfter, uint40(block.timestamp), "dust floors the runway to zero duration");

        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertEq(outLessee, outOther, "zero-duration top-up must not grant the discount");
        (address lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, address(0), "view agrees: no active discount");

        // a real top-up (>= 1s of rent) re-activates it
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 0.1e18);
        (outLessee, outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "a positive-duration top-up restores the discount");
    }

    function testPaidThroughSaturation() public {
        // a huge prepaid rent saturates paidThrough at uint40 max instead of overflowing
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.taxRatePerSecondX64 = 1; // ~zero tax: rps rounds up to 1 wei/second
        leaseController.configurePool(leasePoolKey, config);

        _startLease(lesseeA, address(lesseeSwapper), 1e18, 50e18); // 50e18 seconds of rent
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(paidThrough, type(uint40).max, "paidThrough saturates");

        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "discount active with saturated paidThrough");
    }

    // ==================== Rent accrual and dripping ====================

    function testRentAccrualSplitsProtocolFee() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId);

        vm.warp(block.timestamp + 1000);
        leaseController.drip(leasePoolKey);

        uint256 owed = rps * 1000;
        uint256 fee = owed * PROTOCOL_FEE_BPS / 10_000;
        assertEq(leaseController.protocolFeesAccrued(currency1, protocolFeeRecipient), fee);
        (,,, uint256 rentBalance,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(rentBalance, 0.2e18 - owed, "rent burned from the deposit");
        // net rent is split between the pending bucket and what already donated
        uint256 controllerBal = token1.balanceOf(address(leaseController));
        assertEq(
            controllerBal,
            1e18 + rentBalance + pending + fee + leaseController.refunds(currency1, lesseeA),
            "controller balance backs deposit + rent + pending + fees"
        );
    }

    function testDripThrottleAndGradualRelease() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);

        // accumulate half an hour of rent, then drip once: the release is one bounded slice
        vm.warp(block.timestamp + 1800);
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        uint256 firstDrip = token1.balanceOf(address(poolManager)) - pmBefore;
        (,,,,,, uint256 pendingAfter) = leaseController.getPoolLeaseState(leasePoolId);
        assertGt(firstDrip, 0, "first drip releases a slice");
        assertGt(pendingAfter, 0, "the rest stays pending (gradual anti-JIT release)");

        // a second drip inside minDripSeconds releases nothing
        vm.warp(block.timestamp + MIN_DRIP - 2);
        pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        assertEq(token1.balanceOf(address(poolManager)), pmBefore, "throttled drip releases nothing");

        // after the throttle, the next slice flows
        vm.warp(block.timestamp + MIN_DRIP);
        pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        assertGt(token1.balanceOf(address(poolManager)), pmBefore, "next slice after the throttle");
    }

    function testZeroLiquidityGapDoesNotDumpToJIT() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);

        // burn all liquidity, let rent accrue for a long stretch
        positionManager.decreaseLiquidity(
            fullRangeTokenId,
            positionManager.getPositionLiquidity(fullRangeTokenId),
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        vm.warp(block.timestamp + 2 * DRIP_HORIZON);
        leaseController.drip(leasePoolKey); // zero liquidity: advances the clock, donates nothing
        (,,,,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        assertGt(pending, 0, "rent accrued into pending during the gap");

        // a JIT LP mints and drips in the same block: the mint's beforeAddLiquidity advanced the
        // clock at zero liquidity, so the drip is throttled and releases NOTHING
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        (uint256 jitTokenId,) = positionManager.mint(
            leasePoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        uint256 mintCost = pmBefore < token1.balanceOf(address(poolManager))
            ? token1.balanceOf(address(poolManager)) - pmBefore
            : 0;
        leaseController.drip(leasePoolKey);
        assertEq(
            token1.balanceOf(address(poolManager)) - pmBefore,
            mintCost,
            "same-block JIT drip captures none of the accrued rent"
        );

        // after holding for minDripSeconds the JIT gets one bounded slice, not the whole bucket
        vm.warp(block.timestamp + MIN_DRIP + 1);
        leaseController.drip(leasePoolKey);
        (,,,,,, uint256 pendingAfter) = leaseController.getPoolLeaseState(leasePoolId);
        assertGt(pendingAfter, 0, "bounded slice: the bucket does not dump at once");
        jitTokenId; // silence unused
    }

    // ==================== Buyout / price / exit ====================

    function testBuyoutBelowMinPriceReverts() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 minBuyout = leaseController.minBuyoutPrice(leasePoolId);
        vm.expectRevert(HookLeaseController.InvalidPrice.selector);
        vm.prank(lesseeB);
        leaseController.buyout(leasePoolKey, address(otherSwapper), minBuyout - 1, 0.3e18);
    }

    function testBuyoutOnVacantSlotReverts() public {
        vm.expectRevert(HookLeaseController.NoActiveLease.selector);
        vm.prank(lesseeB);
        leaseController.buyout(leasePoolKey, address(otherSwapper), 1e18, 0.3e18);
    }

    function testMinBuyoutPriceRoundsUpForTinyPrices() public {
        _startLease(lesseeA, address(lesseeSwapper), 1, 0.1e18); // 1 wei price
        assertEq(leaseController.minBuyoutPrice(leasePoolId), 2, "bump is at least 1 wei");
    }

    function testSetPriceRaiseAndLower() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        (,,,,, uint40 paidThroughBefore,) = leaseController.getPoolLeaseState(leasePoolId);

        // raising the price pulls the difference and shortens paidThrough (higher rent)
        uint256 balBefore = token1.balanceOf(lesseeA);
        vm.prank(lesseeA);
        leaseController.setPrice(leasePoolKey, 2e18);
        assertEq(balBefore - token1.balanceOf(lesseeA), 1e18, "difference pulled");
        (,, uint256 price,,, uint40 paidThroughRaised,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(price, 2e18);
        assertLt(paidThroughRaised, paidThroughBefore, "double rent halves the runway");

        // lowering refunds the difference and extends the runway again
        balBefore = token1.balanceOf(lesseeA);
        vm.prank(lesseeA);
        leaseController.setPrice(leasePoolKey, 0.5e18);
        assertEq(token1.balanceOf(lesseeA) - balBefore, 1.5e18, "difference refunded");
        (,, price,,, paidThroughBefore,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(price, 0.5e18);
        assertGt(paidThroughBefore, paidThroughRaised, "lower rent extends the runway");

        // and the buyout threshold followed the price down (the Harberger honesty incentive)
        assertEq(leaseController.minBuyoutPrice(leasePoolId), 0.5e18 + 0.5e18 * 50_000 / PPM);

        // no-ops and zero are rejected; non-lessee cannot touch the price
        vm.startPrank(lesseeA);
        vm.expectRevert(HookLeaseController.InvalidPrice.selector);
        leaseController.setPrice(leasePoolKey, 0.5e18);
        vm.expectRevert(HookLeaseController.InvalidPrice.selector);
        leaseController.setPrice(leasePoolKey, 0);
        vm.stopPrank();
        vm.expectRevert(HookLeaseController.NotLessee.selector);
        vm.prank(lesseeB);
        leaseController.setPrice(leasePoolKey, 3e18);
    }

    function testFundRentExtendsPaidThrough() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        (,,,,, uint40 before_,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 0.2e18);
        (,,,,, uint40 after_,) = leaseController.getPoolLeaseState(leasePoolId);
        assertGt(after_, before_, "more prepaid rent extends the runway");

        vm.expectRevert(HookLeaseController.NotLessee.selector);
        vm.prank(lesseeB);
        leaseController.fundRent(leasePoolKey, 1);
    }

    function testExitRefundsDepositAndUnusedRent() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId);
        vm.warp(block.timestamp + 1000);

        uint256 balBefore = token1.balanceOf(lesseeA);
        vm.prank(lesseeA);
        uint256 refund = leaseController.exitLease(leasePoolKey);
        assertEq(refund, 1e18 + 0.2e18 - rps * 1000, "deposit + unused rent");
        assertEq(token1.balanceOf(lesseeA) - balBefore, refund);
    }

    // ==================== Wind-down / eviction / sweep ====================

    function testWindDownHonorsRunningLease() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        leaseController.setLeasingEnabled(leasePoolKey, false);

        // no new commitments of any kind
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        vm.prank(lesseeB);
        leaseController.buyout(leasePoolKey, address(otherSwapper), 2e18, 0.3e18);
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 1e17);
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        vm.prank(lesseeA);
        leaseController.setPrice(leasePoolKey, 2e18); // raising = new commitment

        // but the running lease is honored while its prepaid rent lasts
        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "discount honored during wind-down");

        // reducing exposure stays possible: lowering the price and exiting
        vm.prank(lesseeA);
        leaseController.setPrice(leasePoolKey, 0.5e18);
        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
    }

    function testEvictOnlyDisabledAndInsolvent() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);

        // enabled -> cannot evict at all
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        leaseController.evictLease(leasePoolKey);

        leaseController.setLeasingEnabled(leasePoolKey, false);

        // solvent -> cannot evict
        vm.expectRevert(HookLeaseController.LeaseStillSolvent.selector);
        leaseController.evictLease(leasePoolKey);

        // insolvent -> evictable; the price deposit goes to the lessee's escrow
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough) + 1);
        uint256 refund = leaseController.evictLease(leasePoolKey);
        assertEq(refund, 1e18, "price deposit refunded (all rent consumed)");
        assertEq(leaseController.refunds(currency1, lesseeA), refund, "escrowed, not pushed");
        (address lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, address(0), "slot vacated");
    }

    function testSweepRequiresWindDownAndVacancy() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        vm.warp(block.timestamp + 1000);
        leaseController.drip(leasePoolKey);

        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        leaseController.sweepPendingDonation(leasePoolKey, address(this));

        leaseController.setLeasingEnabled(leasePoolKey, false);
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        leaseController.sweepPendingDonation(leasePoolKey, address(this));

        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
        (,,,,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        vm.assertGt(pending, 0);
        uint256 swept = leaseController.sweepPendingDonation(leasePoolKey, address(this));
        assertEq(swept, pending);
        assertEq(leaseController.refunds(currency1, address(this)), swept, "escrow-credited");

        // pool is clean now: reconfiguration works
        leaseController.configurePool(leasePoolKey, _defaultConfig());
    }

    function testSetNormalLpFeeFrozenWhileLeaseActive() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        leaseController.setNormalLpFee(leasePoolKey, 500);

        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
        leaseController.setNormalLpFee(leasePoolKey, 500);
        (,,, uint24 storedFee) = poolManager.getSlot0(leasePoolId);
        assertEq(storedFee, 500, "baseline re-mirrored into the pool");
    }

    // ==================== Isolation / robustness ====================

    event DonateFailed(PoolId indexed poolId, uint256 amount);

    function testDonateFailureIsIsolatedAndDoesNotBrickPool() public {
        // same safety property as the epoch controller: a blacklisting auction currency makes
        // the donate leg revert, but the swap succeeds and the lessee keeps the discount
        BlacklistingToken bt = new BlacklistingToken();
        bt.mint(address(this), 10_000_000 ether);
        bt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(bt), address(positionManager), type(uint160).max, type(uint48).max);
        MockERC20 partner = deployToken();

        (Currency c0, Currency c1) = address(bt) < address(partner)
            ? (Currency.wrap(address(bt)), Currency.wrap(address(partner)))
            : (Currency.wrap(address(partner)), Currency.wrap(address(bt)));
        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId pid = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.auctionCurrency = Currency.wrap(address(bt));
        config.feeDiscountPpm = 500_000;
        leaseController.configurePool(key, config);

        bt.mint(lesseeA, 10e18);
        vm.startPrank(lesseeA);
        bt.approve(address(leaseController), type(uint256).max);
        leaseController.startLease(key, address(lesseeSwapper), 1e18, 0.5e18);
        vm.stopPrank();

        bt.mint(address(lesseeSwapper), 100e18);
        partner.mint(address(lesseeSwapper), 100e18);
        bt.mint(address(otherSwapper), 100e18);
        partner.mint(address(otherSwapper), 100e18);

        // rent accrues, then the controller gets blacklisted so its donate transfer reverts
        vm.warp(block.timestamp + 1800);
        bt.setBlockedSender(address(leaseController));

        bool zeroForOne = Currency.unwrap(c0) != address(bt);
        uint256 snap = vm.snapshotState();
        uint256 outLessee = lesseeSwapper.swapExactIn(key, zeroForOne, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(key, zeroForOne, 1e18);
        vm.revertToState(snap);
        assertGt(outLessee, 0, "swap succeeds despite the donate failure");
        assertGt(outLessee, outOther, "lessee keeps the discount despite the donate failure");

        vm.expectEmit(true, false, false, false, address(leaseController));
        emit DonateFailed(pid, 0);
        lesseeSwapper.swapExactIn(key, zeroForOne, 1e18);
    }

    function testHookOnlyEntryPoints() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        leaseController.beforeSwap(leasePoolKey, address(this));
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        leaseController.beforeLiquidityChange(leasePoolKey);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        leaseController.donateExternal(leasePoolKey, currency1, 1);
    }

    function testUnconfiguredPoolSwapsUntouched() public {
        // a hooked dynamic-fee pool with NO lease config: the controller exits on one slot read
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key,
            TickMath.minUsableTick(10),
            TickMath.maxUsableTick(10),
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        uint256 out = otherSwapper.swapExactIn(key, true, 1e17);
        assertGt(out, 0, "unconfigured pool swaps normally");
    }

    // ==================== Gas ====================

    function testGas_HookSwapOverhead() public {
        // hooked pool WITHOUT a lease configuration: the controller must exit on one slot load
        PoolKey memory plainHooked = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolManager.initialize(plainHooked, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            plainHooked,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        otherSwapper.swapExactIn(plainHooked, true, 1e18); // warm pool + token slots
        uint256 gasBefore = gasleft();
        otherSwapper.swapExactIn(plainHooked, true, 1e18);
        uint256 unconfiguredSwapGas = gasBefore - gasleft();
        vm.snapshotGasLastCall("HookLease", "swap_unconfiguredPool");

        // configured pool with an active lease, non-lessee swap, drip throttled
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 1e18);
        otherSwapper.swapExactIn(leasePoolKey, true, 1e18); // warm + first accrual/drip
        gasBefore = gasleft();
        otherSwapper.swapExactIn(leasePoolKey, true, 1e18);
        uint256 configuredSwapGas = gasBefore - gasleft();
        vm.snapshotGasLastCall("HookLease", "swap_configuredPool_nonLessee");

        assertLt(unconfiguredSwapGas, 60_000, "unconfigured-pool swap gas regressed");
        assertLt(configuredSwapGas, 70_000, "configured-pool swap gas regressed");
    }

    // ==================== Claims ====================

    function testClaimNothingReverts() public {
        vm.expectRevert(HookLeaseController.NothingToClaim.selector);
        leaseController.claimRefund(currency1, address(this));
        vm.expectRevert(HookLeaseController.NothingToClaim.selector);
        leaseController.claimProtocolFees(currency1, address(this));
    }
}
