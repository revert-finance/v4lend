// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {HookRouteController} from "src/hook/HookRouteController.sol";
import {HookAuctionController} from "src/hook/HookAuctionController.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";

/// @title HookAuctionControllerHandler
/// @notice Random-walks the auction lifecycle: bids/outbids from a small actor set, time warps,
///         permissionless drips, liquidity add/remove (including down to zero), wind-down and
///         re-enable, and claims. Tracks no ghost state - the invariant is expressed purely in
///         terms of the controller's own accounting.
contract HookAuctionControllerHandler is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint32 public constant EPOCH_LENGTH = 3600;
    uint128 public constant RESERVE = 1e15;

    HookAuctionController public auctionController;
    RevertHook public hook;
    PoolKey public poolKey;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;
    IERC20 public auctionToken;

    address[3] public bidders;
    address[3] public executors;
    address public feeRecipient;
    address public sweepSink;
    uint256 public fullRangeTokenId;
    uint128 public positionLiquidity;

    constructor() {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        auctionToken = IERC20(Currency.unwrap(currency1));

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4450 << 144)
        );

        feeRecipient = makeAddr("feeRecipient");
        sweepSink = makeAddr("sweepSink");

        MockV4Oracle v4Oracle = new MockV4Oracle(positionManager);
        RevertHookStack memory stack = deployRevertHookStack(flags, v4Oracle, feeRecipient);
        hook = stack.hook;
        auctionController = stack.auctionController;

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        positionLiquidity = 100e18;
        (fullRangeTokenId,) = positionManager.mint(
            poolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            positionLiquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        auctionController.configurePool(
            poolKey,
            HookAuctionController.PoolAuctionConfig({
                auctionCurrency: currency1,
                normalLpFee: 3000,
                feeDiscountPpm: 500_000,
                epochStartTime: 0,
                epochLengthSeconds: EPOCH_LENGTH,
                minDripSeconds: 60,
                openingBidReserve: RESERVE,
                minBidBumpPpm: 50_000,
                protocolFeeBps: 1000,
                protocolFeeRecipient: feeRecipient,
                biddingEnabled: true
            })
        );

        for (uint256 i = 0; i < 3; i++) {
            bidders[i] = makeAddr(string(abi.encodePacked("bidder", i)));
            executors[i] = makeAddr(string(abi.encodePacked("executor", i)));
            auctionToken.transfer(bidders[i], 1_000e18);
            vm.prank(bidders[i]);
            auctionToken.approve(address(auctionController), type(uint256).max);
        }
    }

    // ==================== Handler actions ====================

    function bid(uint256 bidderSeed, uint256 executorSeed, uint256 amountSeed) external {
        address bidder = bidders[bound(bidderSeed, 0, 2)];
        address executor = executors[bound(executorSeed, 0, 2)];
        uint256 minBid;
        try auctionController.minNextBid(poolId) returns (uint256 m) {
            minBid = m;
        } catch {
            return;
        }
        uint256 amount = bound(amountSeed, minBid, minBid * 3 + 1e18);
        if (auctionToken.balanceOf(bidder) < amount) return;
        vm.prank(bidder);
        try auctionController.bidNext(poolKey, executor, amount) {} catch {}
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 * EPOCH_LENGTH));
    }

    function dripPool(uint256) external {
        auctionController.drip(poolKey);
    }

    function addLiquidity(uint256 liquiditySeed) external {
        uint128 liquidity = uint128(bound(liquiditySeed, 1e15, 50e18));
        try this.increaseLiquidityExternal(liquidity) {
            positionLiquidity += liquidity;
        } catch {}
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
        try this.decreaseLiquidityExternal(liquidity) {
            positionLiquidity -= liquidity;
        } catch {}
    }

    function decreaseLiquidityExternal(uint128 liquidity) external {
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    function toggleBidding(bool enabled) external {
        try auctionController.setBiddingEnabled(poolKey, enabled) {} catch {}
    }

    function claimRefund(uint256 bidderSeed) external {
        address bidder = bidders[bound(bidderSeed, 0, 2)];
        vm.prank(bidder);
        try auctionController.claimRefund(currency1, bidder) {} catch {}
    }

    function claimProtocolFees(uint256) external {
        vm.prank(feeRecipient);
        try auctionController.claimProtocolFees(currency1, feeRecipient) {} catch {}
    }

    function sweep(uint256) external {
        try auctionController.sweepPendingDonation(poolKey, sweepSink) {} catch {}
    }

    // ==================== Obligation accounting for the invariant ====================

    /// @notice Everything the controller owes, computable from its own public state.
    function totalObligations() external view returns (uint256 total) {
        (,, uint256 pendingDonation) = auctionController.getPoolAuctionState(poolId);
        total = pendingDonation;

        // refund escrow across all bidders + the sweep sink
        for (uint256 i = 0; i < 3; i++) {
            total += auctionController.refunds(currency1, bidders[i]);
        }
        total += auctionController.refunds(currency1, sweepSink);

        // accrued but unclaimed protocol fees
        total += auctionController.protocolFeesAccrued(currency1, feeRecipient);

        // the active epoch's bid: either not yet materialized (whole bid owed) or the
        // undonated drip remainder plus its not-yet-accrued... (materialize accrues the
        // protocol fee immediately, so post-materialization the remainder is totalDrip - donated)
        (,, uint256 activeBid, uint256 activeTotalDrip, uint256 activeDonated,, bool materialized) =
            auctionController.getEpochAuction(poolId, false);
        total += materialized ? activeTotalDrip - activeDonated : activeBid;

        // a queued next-epoch bid is fully owed (refundable until its epoch starts)
        (,, uint256 nextBid,,,,) = auctionController.getEpochAuction(poolId, true);
        total += nextBid;
    }

    function controllerBalance() external view returns (uint256) {
        return auctionToken.balanceOf(address(auctionController));
    }
}

/// @title HookAuctionControllerInvariantTest
/// @notice Core solvency invariant: the controller's auction-currency balance always exactly
///         backs its obligations (pending donations + refund escrow + unclaimed protocol fees +
///         the undonated remainder of the active bid + the queued bid). Donations leave the
///         balance and the obligations together; nothing can drain escrowed value.
contract HookAuctionControllerInvariantTest is BaseTest {
    HookAuctionControllerHandler public handler;

    function setUp() public {
        handler = new HookAuctionControllerHandler();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.bid.selector;
        selectors[1] = handler.warp.selector;
        selectors[2] = handler.dripPool.selector;
        selectors[3] = handler.addLiquidity.selector;
        selectors[4] = handler.removeLiquidity.selector;
        selectors[5] = handler.toggleBidding.selector;
        selectors[6] = handler.claimRefund.selector;
        selectors[7] = handler.claimProtocolFees.selector;
        selectors[8] = handler.sweep.selector;
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
}
