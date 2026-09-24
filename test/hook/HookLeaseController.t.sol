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
        uint256 rps = leaseController.rentPerSecond(leasePoolId);
        vm.warp(block.timestamp + 1800); // half an hour
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey); // creates the fresh bucket (its own clock starts now)
        vm.warp(block.timestamp + MIN_DRIP + 1);
        leaseController.drip(leasePoolKey); // first bounded slice
        (,,, uint256 rentBalance,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        uint256 accrued = rent - rentBalance;
        assertEq(accrued, rps * (1800 + MIN_DRIP + 1), "rent accrues per second");
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

    function testConfigureRejectsControllerAsProtocolFeeRecipient() public {
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.protocolFeeRecipient = address(leaseController);
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, config);

        config.protocolFeeRecipient = leaseController.hook();
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, config);

        config.protocolFeeRecipient = address(poolManager);
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, config);
    }

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

        // Codex P2: the mandatory rent deposit must stay escrowable at every installable price,
        // or an incumbent could raise to a price whose buyout deposit exceeds the escrow cap
        // (un-buyoutable slot). tax * minRentDepositSeconds must not exceed ~100% of the price.
        bad = _defaultConfig();
        bad.minRentDepositSeconds = 36_000; // 10h at a 100%-per-10h tax: prepay == 100% of price
        bad.taxRatePerSecondX64 = TAX_X64 + 1; // nudge just past the feasibility bound
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

    /// @notice Staged launch (lease variant): configure with leasing DISABLED so the pool trades
    ///         at the baseline fee while no lease can start; enable later to open the market.
    function testStagedLaunchConfigureDisabledThenEnable() public {
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.leasingEnabled = false;
        leaseController.configurePool(leasePoolKey, config);

        (,,, uint24 storedFee) = poolManager.getSlot0(leasePoolId);
        assertEq(storedFee, NORMAL_FEE, "baseline fee mirrored while staged");
        assertGt(otherSwapper.swapExactIn(leasePoolKey, true, 1e18), 0, "pool trades normally");

        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        vm.prank(lesseeA);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 1e18, 0.2e18);

        leaseController.setLeasingEnabled(leasePoolKey, true);
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "lease market fully live after enabling");
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

    /// @notice External audit V4LE-22: paidThrough used to saturate at uint40.max. At the minimum
    ///         price (1 raw unit) rent rounds up to 1 raw unit per second, so ~1e-6 tokens of
    ///         prepaid rent reached the sentinel and the lease could never be evicted (evictLease
    ///         reverts while now < paidThrough) nor the pool reconfigured. The prepaid runway is now
    ///         bounded at install, top-up and price cut, so the sentinel is unreachable.
    function testPrepaidRunwayIsBoundedSoPaidThroughCannotSaturate() public {
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.taxRatePerSecondX64 = 1; // ~zero tax: rps rounds up to 1 wei/second at any price
        leaseController.configurePool(leasePoolKey, config);
        uint256 maxRunway = leaseController.MAX_PREPAID_RUNWAY_SECONDS();

        // the audit's exploit: minimum price, a deposit that reaches the uint40 sentinel
        uint256 sentinelDeposit = uint256(type(uint40).max) - block.timestamp + 1;
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.PrepaidRunwayTooLong.selector);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 1, sentinelDeposit);

        // one second past the bound is refused, the bound itself is accepted
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.PrepaidRunwayTooLong.selector);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), 1, maxRunway + 1);
        _startLease(lesseeA, address(lesseeSwapper), 1, maxRunway);
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(paidThrough, block.timestamp + maxRunway, "runway exactly at the bound");
        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertGt(outLessee, outOther, "discount active within the bound");

        // a top-up cannot push past the bound either...
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.PrepaidRunwayTooLong.selector);
        leaseController.fundRent(leasePoolKey, 1);
        // ...but refilling what has accrued back up to the bound is fine
        vm.warp(block.timestamp + 100);
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 100);
        (,,,,, paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(paidThrough, block.timestamp + maxRunway, "top-up refills the runway to the bound");

        // wind-down terminates the lease within the bound: solvent until then, evictable after
        leaseController.setLeasingEnabled(leasePoolKey, false);
        vm.warp(uint256(paidThrough) - 1);
        vm.expectRevert(HookLeaseController.LeaseStillSolvent.selector);
        leaseController.evictLease(leasePoolKey);
        vm.warp(uint256(paidThrough));
        leaseController.evictLease(leasePoolKey);
        leaseController.configurePool(leasePoolKey, _defaultConfig());
    }

    /// @notice External audit V4LE-22: a price cut lowers the rent and stretches the remaining
    ///         balance over a longer runway, so it is bounded like a deposit.
    function testPriceCutCannotStretchRunwayPastBound() public {
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.taxRatePerSecondX64 = 1;
        leaseController.configurePool(leasePoolKey, config);
        uint256 maxRunway = leaseController.MAX_PREPAID_RUNWAY_SECONDS();

        // price 3e19 -> rps = ceil(3e19 / 2^64) = 2 wei/s; a deposit of 2 * maxRunway is exactly the bound
        _startLease(lesseeA, address(lesseeSwapper), 3e19, 2 * maxRunway);
        assertEq(leaseController.rentPerSecond(leasePoolId), 2, "precondition: 2 wei/s");

        // cutting the price to rps = 1 would double the runway -> refused
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.PrepaidRunwayTooLong.selector);
        leaseController.setPrice(leasePoolKey, 1e18);

        // raising the price shortens the runway and is fine
        vm.prank(lesseeA);
        leaseController.setPrice(leasePoolKey, 4e19);
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        assertLt(paidThrough, block.timestamp + maxRunway, "raising the price shortens the runway");
    }

    /// @notice A mandatory deposit longer than the runway bound could never be installed.
    function testConfigureRejectsMinRentDepositBeyondRunwayBound() public {
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.taxRatePerSecondX64 = 1; // so a year of mandatory rent stays escrowable at the price cap
        config.minRentDepositSeconds = uint32(leaseController.MAX_PREPAID_RUNWAY_SECONDS() + 1);
        vm.expectRevert(HookLeaseController.InvalidConfig.selector);
        leaseController.configurePool(leasePoolKey, config);
        config.minRentDepositSeconds = uint32(leaseController.MAX_PREPAID_RUNWAY_SECONDS());
        leaseController.configurePool(leasePoolKey, config);
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
        uint256 rps = leaseController.rentPerSecond(leasePoolId);

        // fresh rent donates DIRECTLY to the LPs who were in range while it accrued
        vm.warp(block.timestamp + 1800);
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        uint256 firstDrip = token1.balanceOf(address(poolManager)) - pmBefore;
        (,,,,,, uint256 pendingAfter) = leaseController.getPoolLeaseState(leasePoolId);
        uint256 net = rps * 1800 - (rps * 1800 * PROTOCOL_FEE_BPS / 10_000);
        assertEq(firstDrip, net, "the whole accrual window donates directly to its LPs");
        assertEq(pendingAfter, 0, "nothing parked while liquidity is present");

        // a drip inside minDripSeconds is throttled: no accrual, no donation
        vm.warp(block.timestamp + MIN_DRIP - 2);
        pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        assertEq(token1.balanceOf(address(poolManager)), pmBefore, "throttled drip releases nothing");

        // after the throttle, the next window's rent flows
        vm.warp(block.timestamp + MIN_DRIP);
        pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        assertGt(token1.balanceOf(address(poolManager)), pmBefore, "next window after the throttle");
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

    /// @notice Audit follow-up (auction twin): the pending bucket aggregates every parked accrual,
    ///         so a release sized as a fraction of the WHOLE bucket lets a dust LP that appears after
    ///         a long zero-liquidity gap capture many horizons of rent per throttle slice. The release
    ///         must be paced by one horizon of rent, so the slice is what the lease itself would have
    ///         paid over the same interval however long the gap was.
    function testPendingSliceIsBoundedByRentRateNotByAggregate() public {
        uint256 price = 1e18;
        uint256 rps = _ceilRentPerSecond(price);
        _startLease(lesseeA, address(lesseeSwapper), price, 0.8e18);

        // no LPs for five horizons: all of that rent parks in the bucket
        _removeAllFullRangeLiquidity();
        vm.warp(block.timestamp + 5 * DRIP_HORIZON);
        leaseController.drip(leasePoolKey);
        (,,,,,, uint256 pendingBefore) = leaseController.getPoolLeaseState(leasePoolId);
        uint256 netRent = rps * 5 * DRIP_HORIZON * (10_000 - PROTOCOL_FEE_BPS) / 10_000;
        assertGt(pendingBefore, netRent * 99 / 100, "five horizons of net rent parked");
        assertEq(
            leaseController.getPendingReleasePerHorizon(leasePoolId),
            rps * DRIP_HORIZON,
            "pace is one horizon of gross rent"
        );

        // dust LP appears alone (its mint touch advances the clock at zero liquidity), holds one
        // throttle interval, drips: the bucket may release one interval of rent, not five horizons' share
        _mintFullRangeLiquidity(1e6);
        // via-ir treats block.timestamp as loop-invariant, so drive time from a local accumulator
        uint256 t = block.timestamp;
        uint256 hold = MIN_DRIP + 1;
        t += hold;
        vm.warp(t);
        leaseController.drip(leasePoolKey);
        (,,,,,, uint256 pendingAfter) = leaseController.getPoolLeaseState(leasePoolId);
        uint256 released = pendingBefore - pendingAfter;
        assertGt(released, 0, "a held slice is released");
        assertLe(released, rps * hold + 1, "pending slice bounded by the rent rate over the interval");

        // later slices are bounded the same way and the bucket still drains completely
        for (uint256 i = 0; i < 5; i++) {
            (,,,,,, uint256 before) = leaseController.getPoolLeaseState(leasePoolId);
            t += hold;
            vm.warp(t);
            leaseController.drip(leasePoolKey);
            (,,,,,, uint256 after_) = leaseController.getPoolLeaseState(leasePoolId);
            assertGt(before - after_, 0, "later slices keep flowing");
            assertLe(before - after_, rps * hold + 1, "later slices bounded too");
        }
        for (uint256 i = 0; i < 60; i++) {
            t += DRIP_HORIZON;
            vm.warp(t);
            leaseController.drip(leasePoolKey);
            (,,,,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
            if (pending == 0) break;
        }
        (,,,,,, uint256 pendingFinal) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(pendingFinal, 0, "aggregate still drains completely");
        assertEq(leaseController.getPendingReleasePerHorizon(leasePoolId), 0, "pace resets with the drained bucket");
    }

    /// @notice Codex P2 (fresh-clock): a pending bucket created by a LEASE ACTION outside the
    ///         drip path (here: exitLease parking the final accrual) gets its own clock - a
    ///         lastDripTime left stale by a long quiet gap must not dump the bucket at once.
    function testActionParkedBucketGetsItsOwnClock() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.5e18);
        vm.warp(block.timestamp + MIN_DRIP + 1);
        leaseController.drip(leasePoolKey); // direct stream: clock set, nothing pending

        // liquidity leaves, then a long quiet stretch: the lessee's exit accrues with nobody in
        // range, so the final accrual is PARKED (an action with LPs present would deliver directly)
        _removeAllFullRangeLiquidity();
        vm.warp(block.timestamp + 3 * DRIP_HORIZON);
        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
        (,,,,,, uint256 bucket) = leaseController.getPoolLeaseState(leasePoolId);
        assertGt(bucket, 0, "exit parked the final accrual");
        _mintFullRangeLiquidity(10e18); // same block: this touch is throttled by the fresh clock

        // a drip at the very same timestamp is throttled by the bucket's own fresh clock -
        // the 3-horizon-stale interval must not release everything
        uint256 pmBefore = token1.balanceOf(address(poolManager));
        leaseController.drip(leasePoolKey);
        assertEq(token1.balanceOf(address(poolManager)), pmBefore, "same-block drip releases nothing");

        // one throttle period later: a bounded slice, not the whole bucket
        vm.warp(block.timestamp + MIN_DRIP + 1);
        leaseController.drip(leasePoolKey);
        (,,,,,, uint256 remaining) = leaseController.getPoolLeaseState(leasePoolId);
        assertGt(token1.balanceOf(address(poolManager)), pmBefore, "bounded slice released");
        assertGt(remaining, 0, "most of the parked bucket still pending (gradual release)");
    }

    /// @notice Codex P2: a small bucket against a long horizon must not flush at once when the
    ///         proportional release rounds to zero - it releases one base unit per drip instead.
    function testTinyBucketDrainsUnitByUnitNotAtOnce() public {
        // rps = 1 wei/second so an exit parks a tiny, countable bucket
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.taxRatePerSecondX64 = 1;
        leaseController.configurePool(leasePoolKey, config);
        uint256 t0 = 1_900_000_000;
        vm.warp(t0);
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 30 days); // 30 days of 1 wei/s rent

        // 10 seconds of rent (10 wei, 1 wei protocol fee) parked by the exit at zero liquidity
        _removeAllFullRangeLiquidity();
        vm.warp(t0 + 10);
        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
        (,,,,,, uint256 bucket) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(bucket, 9, "9 wei parked (10 wei rent minus 10% fee)");
        _mintFullRangeLiquidity(10e18); // same block: throttled, releases nothing yet

        // 9 * 61 / 3600 rounds to zero proportionally: release exactly ONE unit, not the bucket
        vm.warp(t0 + 10 + MIN_DRIP + 1);
        leaseController.drip(leasePoolKey);
        (,,,,,, uint256 remaining) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(remaining, 8, "one base unit released; the rest stays on the gradual schedule");
    }

    event RentDripped(PoolId indexed poolId, uint256 amount);

    /// @notice Codex P2 (action front-run): a lessee cannot starve a departing LP by parking the
    ///         accrued rent with a 1-wei fundRent right before the LP's removal. The action itself
    ///         delivers the accrual to the LPs in range, so the removal has nothing left to lose.
    function testLeaseActionDeliversAccruedRentBeforeLPRemoval() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId);
        vm.warp(block.timestamp + 1800); // rent accrues; no touches in between

        // the front-running top-up: must donate the tenure's rent, not park it
        vm.expectEmit(true, false, false, false, address(leaseController));
        emit RentDripped(leasePoolId, 0);
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 1);
        (,,, uint256 rentBalance,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(pending, 0, "action accrual delivered to the LPs in range, not parked");
        uint256 accrued = 0.2e18 + 1 - rentBalance;
        assertEq(accrued, rps * 1800, "the whole tenure accrued in the action");

        // the LP leaves in the same block: nothing is owed to it any more, and nothing is parked
        _removeAllFullRangeLiquidity();
        (,,, rentBalance,,, pending) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(pending, 0, "removal parks nothing");
        uint256 fee = accrued * PROTOCOL_FEE_BPS / 10_000;
        assertEq(
            token1.balanceOf(address(leaseController)),
            1e18 + rentBalance + fee,
            "controller keeps only deposit + unaccrued rent + protocol fee"
        );
    }

    function _removeAllFullRangeLiquidity() internal {
        positionManager.decreaseLiquidity(
            fullRangeTokenId,
            positionManager.getPositionLiquidity(fullRangeTokenId),
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _mintFullRangeLiquidity(uint128 liquidity) internal returns (uint256 tokenId) {
        (tokenId,) = positionManager.mint(
            leasePoolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            liquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    /// @notice Codex P2 (departing LP): beforeRemoveLiquidity delivers the rent accrued during
    ///         the departing LP's tenure to the in-range set that includes them, BEFORE their
    ///         liquidity leaves - it is not parked for later LPs or the owner sweep.
    function testDepartingLPCollectsAccruedRent() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId);
        vm.warp(block.timestamp + 1800); // rent accrues; no touches in between

        // the removal itself must trigger the direct donation of the accrued rent
        vm.expectEmit(true, false, false, false, address(leaseController));
        emit RentDripped(leasePoolId, 0);
        positionManager.decreaseLiquidity(
            fullRangeTokenId,
            positionManager.getPositionLiquidity(fullRangeTokenId),
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // nothing was parked, and the controller paid the net rent out
        (,,, uint256 rentBalance,,, uint256 pending) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(pending, 0, "rent delivered to the departing LP, not parked");
        uint256 accrued = 0.2e18 - rentBalance;
        assertEq(accrued, rps * 1800, "the whole tenure accrued");
        uint256 fee = accrued * PROTOCOL_FEE_BPS / 10_000;
        assertEq(
            token1.balanceOf(address(leaseController)),
            1e18 + rentBalance + fee,
            "controller keeps only deposit + unaccrued rent + protocol fee"
        );
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
        // 1 wei price -> rent rounds up to 1 wei/second; the deposit is a runway, not a value
        _startLease(lesseeA, address(lesseeSwapper), 1, 30 days);
        assertEq(leaseController.minBuyoutPrice(leasePoolId), 2, "bump is at least 1 wei");
    }

    /// @notice Codex P2: no self-assessed price may make the slot un-buyoutable. The required
    ///         buyout price saturates at the escrow cap, so an incumbent at the cap is
    ///         contestable at equal price (a bump-headroom rule would only move the
    ///         un-buyoutable price one level down - any finite cap has a top).
    function testPriceCapAlwaysLeavesRoomForABuyout() public {
        uint256 maxEscrow = uint256(uint128(type(int128).max));

        // above the cap is not installable
        vm.expectRevert(HookLeaseController.InvalidPrice.selector);
        vm.prank(lesseeA);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), maxEscrow + 1, 1e18);

        // the cap itself is installable - and still buyable, at the cap exactly
        uint256 depositA = _ceilRentPerSecond(maxEscrow) * MIN_RENT_SECONDS;
        deal(Currency.unwrap(currency1), lesseeA, maxEscrow + depositA);
        vm.prank(lesseeA);
        leaseController.startLease(leasePoolKey, address(lesseeSwapper), maxEscrow, depositA);

        uint256 minBuyout = leaseController.minBuyoutPrice(leasePoolId);
        assertEq(minBuyout, maxEscrow, "required buyout price saturates at the cap");
        uint256 depositB = _ceilRentPerSecond(minBuyout) * MIN_RENT_SECONDS;
        deal(Currency.unwrap(currency1), lesseeB, minBuyout + depositB);
        vm.prank(lesseeB);
        leaseController.buyout(leasePoolKey, address(otherSwapper), minBuyout, depositB);
        (address lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, lesseeB, "the max-price incumbent was bought out at the cap");
    }

    /// @dev Mirrors the controller's mulDivRoundingUp(price, TAX_X64, 2^64) rent math.
    function _ceilRentPerSecond(uint256 price) internal pure returns (uint256) {
        uint256 num = price * TAX_X64;
        return num / (1 << 64) + (num % (1 << 64) == 0 ? 0 : 1);
    }

    /// @notice Codex P2: per-second accrual slices (forcible via fundRent, which accrues without
    ///         the drip throttle) must not round the protocol fee to zero forever - the sub-bps
    ///         remainder is carried across accruals.
    function testProtocolFeeSurvivesFragmentedAccruals() public {
        // taxRatePerSecondX64 = 1 -> rent rounds up to 1 wei/second: each 1s slice owes 1 wei,
        // and 1 * 1000 bps < 10000 would floor to zero fee on every slice without the carry.
        // Warp targets are LITERALS: via-ir may rematerialize a captured `block.timestamp`
        // variable into a fresh TIMESTAMP read (legal in real EVM, wrong under cheatcode warps),
        // which would compound the warp targets.
        uint256 base = 1_800_000_000;
        vm.warp(base);
        HookLeaseController.PoolLeaseConfig memory config = _defaultConfig();
        config.taxRatePerSecondX64 = 1;
        leaseController.configurePool(leasePoolKey, config);
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 30 days); // 30 days of 1 wei/s rent

        for (uint256 i = 1; i <= 30; i++) {
            vm.warp(base + i);
            vm.prank(lesseeA);
            leaseController.fundRent(leasePoolKey, 1); // forces an unthrottled 1-second accrual
        }
        // 30 wei of rent accrued at 10% protocol fee: the carry yields 3 wei instead of 0
        assertEq(
            leaseController.protocolFeesAccrued(currency1, protocolFeeRecipient),
            3,
            "sub-bps remainders must accumulate into whole-wei protocol fees"
        );
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

        // lowering the price would stretch the prepaid runway at the lower rate, so it is refused
        // too during wind-down; reducing exposure is done by exiting, which always works
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        leaseController.setPrice(leasePoolKey, 0.5e18);
        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
    }

    /// @notice Codex P2: the sub-second remainder of a rent deposit (rentBalance % rps) never buys
    ///         discount time (paidThrough floors), so an accrual after the lease ran out must not
    ///         sweep it; it stays refundable.
    function testInsolventAccrualPreservesSubSecondRemainder() public {
        // rps for price 1e18 is fixed by the config; a deposit of k whole seconds plus 40 wei
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId);
        vm.prank(lesseeA);
        leaseController.exitLease(leasePoolKey);
        uint256 deposit = rps * MIN_RENT_SECONDS + 40;
        _startLease(lesseeA, address(lesseeSwapper), 1e18, deposit);
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);

        // first accrual two seconds after the runway ended: charge only the covered seconds
        vm.warp(uint256(paidThrough) + 2);
        leaseController.drip(leasePoolKey);
        (,,, uint256 rentBalance,,,) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(rentBalance, 40, "the remainder that bought no time stays in the balance");

        vm.prank(lesseeA);
        uint256 refund = leaseController.exitLease(leasePoolKey);
        assertEq(refund, 1e18 + 40, "deposit plus the unspent remainder refunded");
    }

    /// @notice Codex P2: while leasing is disabled a lessee must not revive a run-out lease by
    ///         lowering the price (a lower rent rate stretches the remaining balance into a longer
    ///         runway), which would block the owner's eviction and wind-down.
    function testDisabledLeaseCannotExtendRunwayByLoweringPrice() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        leaseController.setLeasingEnabled(leasePoolKey, false);

        // solvent: lowering would push paidThrough out at the lower rate -> refused
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        leaseController.setPrice(leasePoolKey, 0.5e18);

        // run out, then try to revive from the sub-second remainder -> refused, eviction works
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough) + 1);
        leaseController.drip(leasePoolKey); // accrues the runway; the remainder stays in the balance
        vm.prank(lesseeA);
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        leaseController.setPrice(leasePoolKey, 1);
        leaseController.evictLease(leasePoolKey);
        (address lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, address(0), "owner wind-down not blocked");
    }

    event LeaseStarted(
        PoolId indexed poolId, address indexed lessee, address indexed executor, uint256 price, uint256 rentDeposit
    );
    event LeaseEvicted(PoolId indexed poolId, address indexed lessee, uint256 refund);
    event RefundEscrowed(PoolId indexed poolId, Currency indexed currency, address indexed account, uint256 amount);

    /// @notice L-05: eviction is gated by rent insolvency alone. A solvent lessee cannot be evicted
    ///         by anyone (owner included, leasing enabled or not); once now >= paidThrough ANY
    ///         caller can free the slot, with leasing still enabled. The price deposit (plus the
    ///         sub-second rent remainder) goes to the lessee's pull-refund escrow and the final
    ///         accrual is delivered to the LP in range rather than parked.
    function testEvictInsolventLeaseIsPermissionless() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId); // price is cleared by the eviction
        address stranger = makeAddr("stranger");

        // solvent -> nobody can evict, not even the owner
        vm.expectRevert(HookLeaseController.LeaseStillSolvent.selector);
        leaseController.evictLease(leasePoolKey);
        vm.expectRevert(HookLeaseController.LeaseStillSolvent.selector);
        vm.prank(stranger);
        leaseController.evictLease(leasePoolKey);

        // still solvent one second before the runway ends (strict boundary, same as the discount)
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough) - 1);
        vm.expectRevert(HookLeaseController.LeaseStillSolvent.selector);
        vm.prank(stranger);
        leaseController.evictLease(leasePoolKey);

        // insolvent -> a stranger evicts while leasing stays enabled
        vm.warp(uint256(paidThrough) + 1);
        uint256 remainder = 0.2e18 % rps;
        uint256 lesseeBalBefore = token1.balanceOf(lesseeA);
        vm.expectEmit(true, false, false, false, address(leaseController));
        emit RentDripped(leasePoolId, 0);
        vm.expectEmit(true, true, true, true, address(leaseController));
        emit RefundEscrowed(leasePoolId, currency1, lesseeA, 1e18 + remainder);
        vm.expectEmit(true, true, false, true, address(leaseController));
        emit LeaseEvicted(leasePoolId, lesseeA, 1e18 + remainder);
        vm.prank(stranger);
        uint256 refund = leaseController.evictLease(leasePoolKey);

        assertEq(refund, 1e18 + remainder, "price deposit plus the sub-second rent remainder refunded");
        assertEq(leaseController.refunds(currency1, lesseeA), refund, "escrowed, not pushed");
        assertEq(token1.balanceOf(lesseeA), lesseeBalBefore, "nothing pushed to the lessee");
        assertEq(leaseController.refunds(currency1, stranger), 0, "the evictor earns nothing");
        (address lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, address(0), "slot vacated");
        (
            address storedLessee,
            address storedExecutor,
            uint256 price,
            uint256 rentBalance,,
            uint40 pt,
            uint256 pending
        ) = leaseController.getPoolLeaseState(leasePoolId);
        assertEq(storedLessee, address(0));
        assertEq(storedExecutor, address(0));
        assertEq(price + rentBalance, 0, "deposit and rent balance cleared");
        assertEq(pt, 0, "runway cleared");
        assertEq(pending, 0, "eviction delivered the final accrual instead of parking it");
        assertTrue(
            leaseController.getPoolLeaseConfig(leasePoolId).leasingEnabled, "eviction did not need the market frozen"
        );

        // the discount is gone for the evicted executor
        (uint256 outLessee, uint256 outOther) = _swapOutcomes(1e18);
        assertEq(outLessee, outOther, "no discount after eviction");

        // vacant slot -> nothing to evict; the lessee pulls the escrow and can re-enter
        vm.expectRevert(HookLeaseController.NoActiveLease.selector);
        leaseController.evictLease(leasePoolKey);
        vm.prank(lesseeA);
        leaseController.claimRefund(currency1, lesseeA);
        assertEq(token1.balanceOf(lesseeA), lesseeBalBefore + refund, "escrow claimable");
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        (lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, lesseeA, "evicted lessee re-enters at their own price");
    }

    /// @notice L-05: the owner's wind-down still works the same way - once leasing is disabled and
    ///         the lease is insolvent the owner evicts and can reconfigure - eviction just no
    ///         longer REQUIRES the market to be disabled.
    function testOwnerWindDownEvictsInsolventLease() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        leaseController.setLeasingEnabled(leasePoolKey, false);

        // disabled but solvent -> the running lease is honored, no eviction
        vm.expectRevert(HookLeaseController.LeaseStillSolvent.selector);
        leaseController.evictLease(leasePoolKey);
        vm.expectRevert(HookLeaseController.PoolStateNotClean.selector);
        leaseController.configurePool(leasePoolKey, _defaultConfig());

        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough));
        // nobody can re-enter while leasing is disabled, even over an insolvent incumbent
        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        vm.prank(lesseeB);
        leaseController.startLease(leasePoolKey, address(otherSwapper), 1e18, 0.2e18);

        uint256 refund = leaseController.evictLease(leasePoolKey);
        assertEq(leaseController.refunds(currency1, lesseeA), refund, "deposit escrowed for the lessee");
        (address lessee,,,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, address(0), "slot freed");
        // clean state: the owner can reconfigure
        leaseController.configurePool(leasePoolKey, _defaultConfig());
    }

    /// @notice L-05: a lapsed lease has no claim on the slot. startLease over a rent-insolvent
    ///         incumbent evicts it (final accrual delivered, deposit + rent dust escrowed) and
    ///         installs the caller at the caller's OWN price - below the incumbent's and far below
    ///         the buyout floor - without the Harberger bump.
    function testStartLeaseOverInsolventIncumbentEvictsWithoutBump() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        uint256 rps = leaseController.rentPerSecond(leasePoolId);
        uint256 buyoutFloor = leaseController.minBuyoutPrice(leasePoolId);
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);

        uint256 newPrice = 0.5e18;
        uint256 newRent = 0.1e18;
        assertLt(newPrice, buyoutFloor, "test premise: the entrant pays less than the buyout floor");

        // insolvent exactly at paidThrough (strict boundary): the incumbent no longer holds the slot
        vm.warp(uint256(paidThrough));
        uint256 remainder = 0.2e18 % rps;
        uint256 refundA = 1e18 + remainder;
        uint256 balABefore = token1.balanceOf(lesseeA);
        uint256 balBBefore = token1.balanceOf(lesseeB);

        vm.expectEmit(true, false, false, false, address(leaseController));
        emit RentDripped(leasePoolId, 0);
        vm.expectEmit(true, true, true, true, address(leaseController));
        emit RefundEscrowed(leasePoolId, currency1, lesseeA, refundA);
        vm.expectEmit(true, true, false, true, address(leaseController));
        emit LeaseEvicted(leasePoolId, lesseeA, refundA);
        vm.expectEmit(true, true, true, true, address(leaseController));
        emit LeaseStarted(leasePoolId, lesseeB, address(otherSwapper), newPrice, newRent);
        _startLease(lesseeB, address(otherSwapper), newPrice, newRent);

        // incumbent made whole from escrow
        assertEq(leaseController.refunds(currency1, lesseeA), refundA, "incumbent deposit + rent dust escrowed");
        assertEq(token1.balanceOf(lesseeA), balABefore, "nothing pushed to the incumbent");
        // entrant paid exactly its own price + rent, no bump
        assertEq(balBBefore - token1.balanceOf(lesseeB), newPrice + newRent, "entrant escrows price + rent only");

        (address lessee, address executor, uint256 price,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, lesseeB, "entrant holds the slot");
        assertEq(executor, address(otherSwapper));
        assertEq(price, newPrice, "installed at the entrant's own price");
        (,,, uint256 rentBalance, uint64 lastAccrualTime, uint40 newPaidThrough, uint256 pending) =
            leaseController.getPoolLeaseState(leasePoolId);
        assertEq(rentBalance, newRent, "fresh rent balance, the incumbent's dust did not carry over");
        assertEq(lastAccrualTime, block.timestamp);
        assertEq(
            newPaidThrough,
            block.timestamp + newRent / leaseController.rentPerSecond(leasePoolId),
            "runway from the entrant's own rent"
        );
        assertEq(pending, 0, "final accrual of the incumbent delivered, not parked");

        // the discount followed the slot to the entrant's executor
        (uint256 outOldExecutor, uint256 outNewExecutor) = _swapOutcomes(1e18);
        assertLt(outOldExecutor, outNewExecutor, "discount moved to the entrant's executor");

        // the entrant is now a solvent incumbent: only a buyout can take the slot
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        _startLease(lesseeA, address(lesseeSwapper), 2e18, 0.3e18);

        // A pulls its escrow
        vm.prank(lesseeA);
        leaseController.claimRefund(currency1, lesseeA);
        assertEq(token1.balanceOf(lesseeA), balABefore + refundA);
    }

    /// @notice A solvent incumbent still holds the slot: startLease reverts right up to the last
    ///         covered second, and topping up the rent keeps it that way. The lapsed lessee can
    ///         also re-enter through startLease themselves (evict + reinstall).
    function testStartLeaseOverSolventIncumbentReverts() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        (,,,,, uint40 paidThrough,) = leaseController.getPoolLeaseState(leasePoolId);

        vm.warp(uint256(paidThrough) - 1);
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        _startLease(lesseeB, address(otherSwapper), 0.5e18, 0.1e18);

        // the incumbent extends its runway: still not startable afterwards
        vm.prank(lesseeA);
        leaseController.fundRent(leasePoolKey, 0.2e18);
        vm.warp(uint256(paidThrough) + 100);
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        _startLease(lesseeB, address(otherSwapper), 0.5e18, 0.1e18);

        // let it lapse; the lapsed lessee re-enters via startLease: old deposit escrowed, new lease fresh
        (,,,,, uint40 paidThrough2,) = leaseController.getPoolLeaseState(leasePoolId);
        vm.warp(uint256(paidThrough2));
        uint256 balBefore = token1.balanceOf(lesseeA);
        _startLease(lesseeA, address(lesseeSwapper), 2e18, 0.3e18);
        assertEq(balBefore - token1.balanceOf(lesseeA), 2e18 + 0.3e18, "new lease funded in full");
        assertGe(leaseController.refunds(currency1, lesseeA), 1e18, "old deposit escrowed for the same account");
        (address lessee,, uint256 price,) = leaseController.getActiveLessee(leasePoolId);
        assertEq(lessee, lesseeA);
        assertEq(price, 2e18);
    }

    function testSweepRequiresWindDownAndVacancy() public {
        _startLease(lesseeA, address(lesseeSwapper), 1e18, 0.2e18);
        vm.warp(block.timestamp + 1000);

        vm.expectRevert(HookLeaseController.LeasingDisabled.selector);
        leaseController.sweepPendingDonation(leasePoolKey, address(this));

        leaseController.setLeasingEnabled(leasePoolKey, false);
        vm.expectRevert(HookLeaseController.LeaseAlreadyActive.selector);
        leaseController.sweepPendingDonation(leasePoolKey, address(this));

        // the removal touch pays the departing LP its rent; what accrues afterwards with nobody in
        // range is parked by the exit into the pending bucket
        _removeAllFullRangeLiquidity();
        // via-IR treats block.timestamp as invariant within a call, so a second identical relative
        // warp would re-use the first value; read the current time through the cheatcode instead
        vm.warp(vm.getBlockTimestamp() + 1000);
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

        // rent accrues into a fresh bucket (creation touch donates nothing by design), then the
        // controller gets blacklisted so the NEXT drip's donate transfer reverts
        vm.warp(block.timestamp + 1800);
        leaseController.drip(key);
        vm.warp(block.timestamp + MIN_DRIP + 1);
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
