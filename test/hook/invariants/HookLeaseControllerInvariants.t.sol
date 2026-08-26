// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {RevertHook} from "src/RevertHook.sol";
import {HookLeaseController} from "src/hook/HookLeaseController.sol";

/// @title HookLeaseControllerHandler
/// @notice Random-walks the Harberger-lease lifecycle: starts/buyouts/exits from a small actor
///         set, price moves in both directions, rent top-ups, time warps, permissionless drips,
///         liquidity add/remove (including down to zero), wind-down and re-enable, eviction and
///         claims. Tracks no ghost state - the invariants are expressed purely in terms of the
///         controller's own accounting.
contract HookLeaseControllerHandler is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint96 public constant MIN_PRICE = 1e15;

    HookLeaseController public leaseController;
    RevertHook public hook;
    PoolKey public poolKey;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;
    IERC20 public leaseToken;

    address[3] public actors;
    address[3] public executors;
    address public feeRecipient;
    address public sweepSink;
    uint256 public fullRangeTokenId;

    constructor() {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        leaseToken = IERC20(Currency.unwrap(currency1));

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4453 << 144)
        );

        feeRecipient = makeAddr("feeRecipient");
        sweepSink = makeAddr("sweepSink");

        MockV4Oracle v4Oracle = new MockV4Oracle(positionManager);
        leaseController = new HookLeaseController(flags, poolManager);
        RevertHookStack memory stack =
            deployRevertHookStackWithController(flags, v4Oracle, feeRecipient, address(leaseController));
        hook = stack.hook;

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        (fullRangeTokenId,) = positionManager.mint(
            poolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        leaseController.configurePool(
            poolKey,
            HookLeaseController.PoolLeaseConfig({
                startTime: 0,
                minDripSeconds: 60,
                dripHorizonSeconds: 3600,
                normalLpFee: 3000,
                feeDiscountPpm: 500_000,
                leasingEnabled: true,
                auctionCurrency: currency1,
                minBuyoutBumpPpm: 50_000,
                protocolFeeBps: 1000,
                minRentDepositSeconds: 600,
                protocolFeeRecipient: feeRecipient,
                taxRatePerSecondX64: uint64((uint256(1) << 64) / 36_000)
            })
        );

        for (uint256 i = 0; i < 3; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", i)));
            executors[i] = makeAddr(string(abi.encodePacked("executor", i)));
            leaseToken.transfer(actors[i], 1_000e18);
            vm.prank(actors[i]);
            leaseToken.approve(address(leaseController), type(uint256).max);
        }
    }

    // ==================== Handler actions ====================

    function start(uint256 actorSeed, uint256 executorSeed, uint256 priceSeed, uint256 rentSeed) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 price = bound(priceSeed, MIN_PRICE, 10e18);
        uint256 rps = leaseController.rentPerSecond(poolId);
        rps; // rps of the CURRENT price; deposit is bounded generously instead
        uint256 rent = bound(rentSeed, price / 36_000 * 600 + 600, 5e18);
        if (leaseToken.balanceOf(actor) < price + rent) return;
        vm.prank(actor);
        try leaseController.startLease(poolKey, executors[bound(executorSeed, 0, 2)], price, rent) {} catch {}
    }

    function takeOver(uint256 actorSeed, uint256 executorSeed, uint256 rentSeed) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 newPrice;
        try leaseController.minBuyoutPrice(poolId) returns (uint256 m) {
            newPrice = m;
        } catch {
            return;
        }
        uint256 rent = bound(rentSeed, newPrice / 36_000 * 600 + 600, 5e18);
        if (leaseToken.balanceOf(actor) < newPrice + rent) return;
        vm.prank(actor);
        try leaseController.buyout(poolKey, executors[bound(executorSeed, 0, 2)], newPrice, rent) {} catch {}
    }

    function movePrice(uint256 actorSeed, uint256 priceSeed) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 newPrice = bound(priceSeed, 1, 20e18);
        vm.prank(actor);
        try leaseController.setPrice(poolKey, newPrice) {} catch {}
    }

    function topUpRent(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 amount = bound(amountSeed, 1, 1e18);
        if (leaseToken.balanceOf(actor) < amount) return;
        vm.prank(actor);
        try leaseController.fundRent(poolKey, amount) {} catch {}
    }

    function exit(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        vm.prank(actor);
        try leaseController.exitLease(poolKey) {} catch {}
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 * 3600));
    }

    function dripPool(uint256) external {
        leaseController.drip(poolKey);
    }

    function addLiquidity(uint256 liquiditySeed) external {
        uint128 liquidity = uint128(bound(liquiditySeed, 1e15, 50e18));
        try this.increaseLiquidityExternal(liquidity) {} catch {}
    }

    function increaseLiquidityExternal(uint128 liquidity) external {
        positionManager.increaseLiquidity(
            fullRangeTokenId, liquidity, type(uint256).max, type(uint256).max, block.timestamp, Constants.ZERO_BYTES
        );
    }

    function removeLiquidity(uint256 liquiditySeed, bool removeAll) external {
        uint128 current = positionManager.getPositionLiquidity(fullRangeTokenId);
        if (current == 0) return;
        uint128 liquidity = removeAll ? current : uint128(bound(liquiditySeed, 1, current));
        try this.decreaseLiquidityExternal(liquidity) {} catch {}
    }

    function decreaseLiquidityExternal(uint128 liquidity) external {
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    function toggleLeasing(bool enabled) external {
        try leaseController.setLeasingEnabled(poolKey, enabled) {} catch {}
    }

    function evict(uint256) external {
        try leaseController.evictLease(poolKey) {} catch {}
    }

    function claimRefund(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        vm.prank(actor);
        try leaseController.claimRefund(currency1, actor) {} catch {}
    }

    function claimProtocolFees(uint256) external {
        vm.prank(feeRecipient);
        try leaseController.claimProtocolFees(currency1, feeRecipient) {} catch {}
    }

    function sweep(uint256) external {
        try leaseController.sweepPendingDonation(poolKey, sweepSink) {} catch {}
    }

    // ==================== Obligation accounting for the invariants ====================

    /// @notice Everything the controller owes, computable from its own public state: the
    ///         lessee's price deposit and unaccrued rent, the pending bucket, the refund escrow
    ///         and unclaimed protocol fees.
    function totalObligations() external view returns (uint256 total) {
        (,, uint256 price, uint256 rentBalance,,, uint256 pendingDonation) =
            leaseController.getPoolLeaseState(poolId);
        total = price + rentBalance + pendingDonation;

        for (uint256 i = 0; i < 3; i++) {
            total += leaseController.refunds(currency1, actors[i]);
        }
        total += leaseController.refunds(currency1, sweepSink);
        total += leaseController.protocolFeesAccrued(currency1, feeRecipient);
    }

    function controllerBalance() external view returns (uint256) {
        return leaseToken.balanceOf(address(leaseController));
    }
}

/// @title HookLeaseControllerInvariantTest
/// @notice Core solvency invariant: the controller's balance always exactly backs its
///         obligations (the lessee's price deposit + unaccrued rent + pending donations +
///         refund escrow + unclaimed protocol fees). Plus consistency of the slot-0 hot-path
///         fields, which alone decide the fee discount and the drip gates in beforeSwap.
contract HookLeaseControllerInvariantTest is BaseTest {
    HookLeaseControllerHandler public handler;

    function setUp() public {
        handler = new HookLeaseControllerHandler();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.start.selector;
        selectors[1] = handler.takeOver.selector;
        selectors[2] = handler.movePrice.selector;
        selectors[3] = handler.topUpRent.selector;
        selectors[4] = handler.exit.selector;
        selectors[5] = handler.warp.selector;
        selectors[6] = handler.dripPool.selector;
        selectors[7] = handler.addLiquidity.selector;
        selectors[8] = handler.removeLiquidity.selector;
        selectors[9] = handler.toggleLeasing.selector;
        selectors[10] = handler.evict.selector;
        selectors[11] = handler.claimRefund.selector;
        selectors[12] = handler.claimProtocolFees.selector;
        selectors[13] = handler.sweep.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The controller can always pay out everything it owes.
    function invariant_ControllerBalanceBacksObligations() public view {
        assertEq(
            handler.controllerBalance(),
            handler.totalObligations(),
            "controller balance must exactly equal its obligations"
        );
    }

    /// @notice The slot-0 hot-path fields never diverge from the rest of the lease state.
    ///         beforeSwap decides the fee discount from executor+paidThrough and the drip gates
    ///         from hasPending alone, so a divergence would mis-price swaps or strand rent.
    function invariant_HotPathStateConsistent() public view {
        HookLeaseController controller = handler.leaseController();
        PoolId poolId = handler.poolId();
        (address executor, uint40 paidThrough, uint40 lastDripTime, bool hasPending) =
            controller.getHotPathState(poolId);
        (address lessee,, uint256 price, uint256 rentBalance, uint64 lastAccrualTime,, uint256 pendingDonation) =
            controller.getPoolLeaseState(poolId);

        assertEq(hasPending, pendingDonation != 0, "hasPending diverged from pendingDonation");
        if (hasPending) {
            // every empty-to-nonempty transition initializes the drip clock, so a fresh bucket
            // can never be measured against a stale timestamp (full-horizon JIT dump)
            assertGt(lastDripTime, 0, "pending bucket must have a drip clock");
        }
        assertEq(executor == address(0), lessee == address(0), "executor/lessee vacancy diverged");
        if (lessee != address(0)) {
            uint256 expected = uint256(lastAccrualTime) + rentBalance / controller.rentPerSecond(poolId);
            if (expected > type(uint40).max) {
                expected = type(uint40).max;
            }
            // never a discount beyond the actual rent runway...
            assertLe(paidThrough, uint40(expected), "paidThrough grants more than the rent runway");
            // ...and exactly the runway while rent remains (once rentBalance hits 0,
            // lastAccrualTime keeps advancing on touches while paidThrough correctly stays
            // frozen at the true runout, so equality only holds with rent left)
            if (rentBalance != 0) {
                assertEq(paidThrough, uint40(expected), "paidThrough short-changes the rent runway");
            }
            assertGt(price, 0, "active lease must have a price deposit");
        } else {
            assertEq(paidThrough, 0, "vacant slot must have no rent runway");
            assertEq(price + rentBalance, 0, "vacant slot must hold no deposit");
        }
    }
}
