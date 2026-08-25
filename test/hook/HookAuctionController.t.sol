// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {V4Vault} from "src/vault/V4Vault.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

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

/// @notice ERC20 with a toggleable transfer fee - models an auction currency that starts
///         charging a fee only AFTER bids were escrowed. The controller's donate() then
///         under-settles the PoolManager, which must be detected inside donateExternal (revert
///         and isolate) rather than surfacing as CurrencyNotSettled at the end of the unlock.
contract FeeOnTransferToken is MockERC20 {
    uint256 public feeBps; // recipient-side: recipient receives amount - fee
    uint256 public senderFeeBps; // sender-side surcharge: sender is debited amount + fee

    constructor() MockERC20("FeeOnTransfer", "FOT", 18) {}

    function setFeeBps(uint256 newFeeBps) external {
        feeBps = newFeeBps;
    }

    function setSenderFeeBps(uint256 newSenderFeeBps) external {
        senderFeeBps = newSenderFeeBps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 surcharge = amount * senderFeeBps / 10_000;
        if (surcharge != 0) {
            _burn(msg.sender, surcharge);
        }
        uint256 fee = amount * feeBps / 10_000;
        if (fee != 0) {
            super.transfer(address(0xdead), fee);
        }
        return super.transfer(to, amount - fee);
    }
}

/// @notice ERC20 that reverts on transfers from a chosen sender - models an auction currency that
///         blacklists the controller, so the controller's donate() leg reverts.
contract BlacklistingToken is MockERC20 {
    address public blockedSender;

    constructor() MockERC20("Blacklist", "BLK", 18) {}

    function setBlockedSender(address account) external {
        blockedSender = account;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(msg.sender != blockedSender, "blocked");
        return super.transfer(to, amount);
    }
}

contract HookAuctionControllerTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;


    uint32 internal constant PPM = 1_000_000;
    uint32 internal constant EPOCH_LENGTH = 3600;
    uint32 internal constant MIN_DRIP = 60;
    uint96 internal constant RESERVE = 1e15;
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

        RevertHookStack memory stack = deployRevertHookStack(flags, v4Oracle, protocolFeeRecipient);
        hook = stack.hook;
        feeController = stack.feeController;
        auctionController = stack.auctionController;
        autoLendActionsRef = stack.autoLendActions;

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

    /// @notice READ THIS ONE to understand the system. It walks the entire auction lifecycle end
    ///         to end in a single flow; every other test in this file isolates one property of it.
    ///
    ///         Flow: configure a 0.30% pool with a 50% winner discount -> two searchers bid for the
    ///         next epoch, the loser's bid is escrowed and reclaimed -> in the won epoch the winner's
    ///         executor trades at 0.15% while everyone else pays 0.30% -> the winning bid splits into
    ///         a protocol fee and an LP drip that vests across the epoch -> the LP collects the drip
    ///         and the protocol recipient claims the fee -> the controller is left fully settled.
    function testFullAuctionLifecycle() public {
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        // ---- 1. Configure: 50% winner discount on a 0.30% pool (realistic launch shape) ----
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.feeDiscountPpm = 500_000; // winner pays half the LP fee
        auctionController.configurePool(auctionPoolKey, config);
        startTime = uint64(block.timestamp);
        assertEq(auctionController.winnerLpFee(auctionPoolId), 1500, "winner fee = 0.15% (half of 0.30%)");

        // ---- 2. Bidding during epoch 0 for the right to epoch 1: B outbids A ----
        _bid(bidderA, address(otherSwapper), RESERVE); // A opens at the reserve
        uint256 winningBid = auctionController.minNextBid(auctionPoolId); // reserve + 5% bump
        _bid(bidderB, address(winnerSwapper), winningBid); // B outbids and will be the winner

        // A's outbid bid is escrowed (pull-based refund), never pushed back automatically
        assertEq(auctionController.refunds(currency1, bidderA), RESERVE, "outbid bid escrowed");
        uint256 aBalBefore = token1.balanceOf(bidderA);
        vm.prank(bidderA);
        auctionController.claimRefund(currency1, bidderA);
        assertEq(token1.balanceOf(bidderA), aBalBefore + RESERVE, "A reclaims its outbid bid");

        // Still epoch 0: the discount was bought for epoch 1, so it does not apply yet
        uint256 snap = vm.snapshotState();
        uint256 outBeforeWin = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);

        // ---- 3. Epoch 1: the winner trades at 0.15%, everyone else at 0.30% ----
        _warpToEpoch(1);
        snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);

        assertApproxEqRel(outBeforeWin, outOther, 1e12, "no discount before the won epoch");
        assertGt(outWinner, outOther, "winner gets the better rate in its epoch");
        assertApproxEqRel(outWinner, outOther * (PPM - 1500) / (PPM - NORMAL_FEE), 1e14, "0.15% vs 0.30%");

        // ---- 4. First real pool touch of epoch 1 materializes the bid into fee + drip ----
        uint256 expectedProtocolFee = winningBid * PROTOCOL_FEE_BPS / 10_000;
        uint256 expectedDrip = winningBid - expectedProtocolFee;

        auctionController.drip(auctionPoolKey); // real tx: syncs epoch 1 active + materializes
        (address wBidder, address wExecutor, uint256 bid, uint256 totalDrip,,, bool materialized) =
            auctionController.getEpochAuction(auctionPoolId, false);
        assertTrue(materialized, "epoch materialized on first touch");
        assertEq(wBidder, bidderB, "B is the active-epoch winner");
        assertEq(wExecutor, address(winnerSwapper), "winner's executor recorded");
        assertEq(bid, winningBid);
        assertEq(totalDrip, expectedDrip, "drip = bid - protocol fee");
        assertEq(
            auctionController.protocolFeesAccrued(currency1, protocolFeeRecipient),
            expectedProtocolFee,
            "protocol fee accrued once"
        );

        // ---- 5. The drip vests across the epoch and reaches the LP (here the sole in-range LP) ----
        _drainPending(auctionPoolKey); // warps past epoch end and drains the pending bucket to zero
        (,, uint256 pending) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pending, 0, "everything vested");

        uint256 lpBefore = token1.balanceOf(address(this));
        positionManager.decreaseLiquidity(
            fullRangeTokenId, 0, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        assertApproxEqAbs(
            token1.balanceOf(address(this)) - lpBefore, expectedDrip, 10, "LP collects the whole drip"
        );

        // ---- 6. The protocol fee is claimable by its recipient ----
        uint256 recipBefore = token1.balanceOf(protocolFeeRecipient);
        vm.prank(protocolFeeRecipient);
        auctionController.claimProtocolFees(currency1, protocolFeeRecipient);
        assertEq(
            token1.balanceOf(protocolFeeRecipient) - recipBefore, expectedProtocolFee, "protocol fee claimed"
        );

        // ---- 7. Conservation: everything taken in (A's + B's bids) has left the controller ----
        // A's bid refunded, B's bid -> LP drip + protocol fee, all now claimed/donated.
        assertApproxEqAbs(token1.balanceOf(address(auctionController)), 0, 5, "controller fully settled");
    }

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

    function testSetNormalLpFeeFrozenWhileBidsOutstanding() public {
        // a queued next-epoch bid freezes the baseline fee
        _bid(bidderA, address(winnerSwapper), 1e18);
        vm.expectRevert(HookAuctionController.BidsOutstanding.selector);
        auctionController.setNormalLpFee(auctionPoolKey, 100);

        // still frozen once that bid is the active winner
        _warpToEpoch(1);
        auctionController.drip(auctionPoolKey); // sync promotes the bid to active
        vm.expectRevert(HookAuctionController.BidsOutstanding.selector);
        auctionController.setNormalLpFee(auctionPoolKey, 100);

        // once the epoch ends and no bid is active or queued, the owner can move the baseline again
        _warpToEpoch(2);
        auctionController.drip(auctionPoolKey); // rollover clears the spent winner
        auctionController.setNormalLpFee(auctionPoolKey, 100);
        (,,, uint24 lpFee) = poolManager.getSlot0(auctionPoolId);
        assertEq(lpFee, 100, "baseline changeable once bids are settled");
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

        // (a reserve above MAX_BID_AMOUNT is impossible by construction: uint96 < int128.max)
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

        // sweeping credits the refund escrow (so it also works for a token whose transfers from
        // the controller currently revert); the recipient pulls it via claimRefund
        assertEq(auctionController.refunds(currency1, sink), pending);
        vm.prank(sink);
        auctionController.claimRefund(currency1, sink);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(sink), pending);

        // pending cleared, so the pool can be reconfigured
        (,, uint256 pendingAfter) = auctionController.getPoolAuctionState(auctionPoolId);
        assertEq(pendingAfter, 0);
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.epochStartTime = uint64(block.timestamp);
        auctionController.configurePool(auctionPoolKey, config); // no longer reverts PoolStateNotClean
    }

    function testSweepBlockedWhileWinnerActive() public {
        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1); // winner active for epoch 1

        // remove liquidity, then drip mid-epoch so the active epoch's vested proceeds park into pending
        uint256 liquidity = positionManager.getPositionLiquidity(fullRangeTokenId);
        positionManager.decreaseLiquidity(
            fullRangeTokenId, liquidity, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        vm.warp(uint256(startTime) + EPOCH_LENGTH + EPOCH_LENGTH / 2);
        auctionController.drip(auctionPoolKey);
        (,, uint256 pending) = auctionController.getPoolAuctionState(auctionPoolId);
        assertGt(pending, 0, "active-epoch vesting parked while empty");

        // disabling bidding does not let the owner sweep an in-flight winner's proceeds
        auctionController.setBiddingEnabled(auctionPoolKey, false);
        vm.expectRevert(HookAuctionController.BidsOutstanding.selector);
        auctionController.sweepPendingDonation(auctionPoolKey, makeAddr("sink"));

        // only once the active epoch ends and the winner rolls off is the sweep allowed
        _warpToEpoch(2);
        uint256 swept = auctionController.sweepPendingDonation(auctionPoolKey, makeAddr("sink"));
        assertGt(swept, 0, "sweep allowed after the winner's epoch ends");
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

        // wind down and let the final active epoch end; then the whole aggregate is recoverable
        auctionController.setBiddingEnabled(auctionPoolKey, false);
        _warpToEpoch(4);
        uint256 swept = auctionController.sweepPendingDonation(auctionPoolKey, makeAddr("sink"));
        assertGt(swept, pending, "final active epoch also settles into the sweep");
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

    function testGetActiveWinnerIsRolloverAware() public {
        _bid(bidderA, address(winnerSwapper), 1e18);

        // still epoch 0: the queued bid is not the active winner yet
        (, address executor0,,) = auctionController.getActiveWinner(auctionPoolId);
        assertEq(executor0, address(0), "no winner before the won epoch");

        // epoch 1 with NO pool touch: the raw slot is stale, the view is not
        _warpToEpoch(1);
        (,, uint256 rawActiveBid,,,,) = auctionController.getEpochAuction(auctionPoolId, false);
        assertEq(rawActiveBid, 0, "raw storage not yet synced");
        (address bidder, address executor, uint256 bid, uint24 lpFee) =
            auctionController.getActiveWinner(auctionPoolId);
        assertEq(bidder, bidderA);
        assertEq(executor, address(winnerSwapper), "view promotes the queued winner across the boundary");
        assertEq(bid, 1e18);
        assertEq(lpFee, 0, "full discount");

        // a multi-epoch skip means the queued bid gets refunded: nobody is the winner
        _warpToEpoch(3);
        (, executor,,) = auctionController.getActiveWinner(auctionPoolId);
        assertEq(executor, address(0), "no winner after a skipped epoch");
    }

    /// @notice Pins the auction's hot-path gas so regressions surface in CI. The recorded
    ///         numbers land in snapshots/ via forge's native gas snapshots; the assertions are
    ///         generous ceilings that fail on gross regressions (e.g. an accidental extra
    ///         cold-storage pass or an unconditional donate attempt per swap).
    function testGas_HookSwapOverhead() public {
        // hooked pool WITHOUT an auction configuration: the controller must exit on one slot load
        PoolKey memory plainHooked = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolManager.initialize(plainHooked, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            plainHooked, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        otherSwapper.swapExactIn(plainHooked, true, 1e18); // warm pool + token slots
        uint256 gasBefore = gasleft();
        otherSwapper.swapExactIn(plainHooked, true, 1e18);
        uint256 unconfiguredSwapGas = gasBefore - gasleft();
        vm.snapshotGasLastCall("HookAuction", "swap_unconfiguredPool");

        // configured pool, non-winner swap (includes epoch sync + drip bookkeeping)
        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1);
        otherSwapper.swapExactIn(auctionPoolKey, true, 1e18); // warm + first drip/materialize
        gasBefore = gasleft();
        otherSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        uint256 configuredSwapGas = gasBefore - gasleft();
        vm.snapshotGasLastCall("HookAuction", "swap_configuredPool_nonWinner");

        // ceilings with headroom; a regression like an unconditional 3-slot config copy or a
        // failed-donate retry per swap blows through these
        assertLt(unconfiguredSwapGas, 60_000, "unconfigured-pool swap gas regressed");
        assertLt(configuredSwapGas, 70_000, "configured-pool swap gas regressed");
    }

    // ==================== Vault integration ====================

    /// @notice End-to-end: a position in an auctioned pool serves as V4Vault collateral - the
    ///         auction (bid -> winner discount -> drip) runs while the position is collateralized,
    ///         and liquidation still works mid-epoch (the liquidation's liquidity removal routes
    ///         through beforeRemoveLiquidity and the controller's drip without interference).
    function testVaultCollateralInAuctionedPoolEndToEnd() public {
        IERC20 asset = IERC20(Currency.unwrap(currency1));

        // ---- vault stack on top of the auction environment ----
        InterestRateModel interestRateModel = new InterestRateModel(0, uint256(2 ** 64) * 5 / 100, uint256(2 ** 64) * 109 / 100, uint256(2 ** 64) * 80 / 100);
        V4Vault vault = new V4Vault(
            "Revert Lend t1", "rlT1", address(asset), positionManager, interestRateModel, v4Oracle, IWETH9(address(0))
        );
        vault.setTokenConfig(Currency.unwrap(currency0), uint32(uint256(2 ** 32) * 9 / 10), type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), uint32(uint256(2 ** 32) * 9 / 10), type(uint32).max);
        vault.setLimits(0, 1_000e18, 1_000e18, 1_000e18, 1_000e18);
        vault.setReserveFactor(0);
        vault.setHookAllowList(address(hook), true);
        hook.setVault(address(vault));

        // ---- lend + collateralize the position living in the auctioned pool ----
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, address(this));

        IERC721(address(positionManager)).approve(address(vault), fullRangeTokenId);
        vault.create(fullRangeTokenId, address(this));

        // MockV4Oracle values the position at 1e18 asset; borrow against it
        vault.borrow(fullRangeTokenId, 0.5e18);
        (uint256 debt,, uint256 collateralValue,,) = vault.loanInfo(fullRangeTokenId);
        assertEq(debt, 0.5e18);
        assertGt(collateralValue, debt, "healthy after borrow");

        // ---- the auction runs while the position is vault collateral ----
        _bid(bidderA, address(winnerSwapper), 1e18);
        _warpToEpoch(1);

        uint256 snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(auctionPoolKey, true, 1e18);
        vm.revertToState(snap);
        assertGt(outWinner, outOther, "winner discount active on the collateralized pool");

        // drips flow to the (vault-held) in-range position
        vm.warp(block.timestamp + EPOCH_LENGTH / 2);
        auctionController.drip(auctionPoolKey);
        (,,,, uint256 donated,,) = auctionController.getEpochAuction(auctionPoolId, false);
        assertGt(donated, 0, "auction proceeds drip while collateralized");

        // a second (non-collateral) LP so the pool keeps liquidity after the full liquidation
        positionManager.mint(
            auctionPoolKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        // ---- liquidation still works mid-epoch on the auctioned pool ----
        v4Oracle.setMockPositionValue(0.4e18); // 0.5 debt > 0.4 value -> underwater, full liquidation
        (,,,, uint256 liquidationValue) = vault.loanInfo(fullRangeTokenId);
        assertGt(liquidationValue, 0, "liquidatable");

        vm.startPrank(bidderB);
        asset.approve(address(vault), type(uint256).max);
        (uint256 amount0, uint256 amount1) = vault.liquidate(
            IVault.LiquidateParams({
                tokenId: fullRangeTokenId,
                amount0Min: 0,
                amount1Min: 0,
                recipient: bidderB,
                deadline: block.timestamp,
                decreaseLiquidityHookData: ""
            })
        );
        vm.stopPrank();
        assertTrue(amount0 > 0 || amount1 > 0, "liquidator received position tokens");

        (uint256 debtAfter,,,,) = vault.loanInfo(fullRangeTokenId);
        assertEq(debtAfter, 0, "loan cleared by liquidation");

        // the pool remains fully functional afterwards
        uint256 outAfter = otherSwapper.swapExactIn(auctionPoolKey, true, 1e17);
        assertGt(outAfter, 0, "pool swappable after liquidation");
    }

    // ==================== Fail-open glue ====================

    event DonateFailed(PoolId indexed poolId, uint256 amount);

    function testDonateFailureIsIsolatedAndDoesNotBrickPool() public {
        // The safety property that makes removing the hook's fail-open wrapper OK: a misbehaving
        // auction currency (here one that blacklists the controller) makes the controller's donate
        // leg revert, but that revert is isolated inside the controller (DonateFailed) - the swap
        // still succeeds and the winner still receives the discount they paid for.
        BlacklistingToken bt = new BlacklistingToken();
        bt.mint(address(this), 10_000_000 ether);
        bt.approve(address(permit2), type(uint256).max);
        bt.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(bt), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(bt), address(poolManager), type(uint160).max, type(uint48).max);
        MockERC20 partner = deployToken();

        (Currency c0, Currency c1) = address(bt) < address(partner)
            ? (Currency.wrap(address(bt)), Currency.wrap(address(partner)))
            : (Currency.wrap(address(partner)), Currency.wrap(address(bt)));
        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId pid = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        // configure the auction with the blacklisting token as the auction currency
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.auctionCurrency = Currency.wrap(address(bt));
        config.feeDiscountPpm = 500_000;
        auctionController.configurePool(key, config);
        uint64 s = uint64(block.timestamp);

        // bidderA wins with winnerSwapper as executor
        bt.mint(bidderA, 10e18);
        vm.prank(bidderA);
        bt.approve(address(auctionController), type(uint256).max);
        vm.prank(bidderA);
        auctionController.bidNext(key, address(winnerSwapper), 1e18);

        // fund the swappers to trade on this pool
        bt.mint(address(winnerSwapper), 100e18);
        partner.mint(address(winnerSwapper), 100e18);
        bt.mint(address(otherSwapper), 100e18);
        partner.mint(address(otherSwapper), 100e18);

        // into the won epoch, then blacklist the controller so its donate() transfer reverts
        vm.warp(uint256(s) + EPOCH_LENGTH + EPOCH_LENGTH / 2);
        bt.setBlockedSender(address(auctionController));

        bool zeroForOne = Currency.unwrap(c0) != address(bt); // swap so bt is the input? either works
        // winner vs non-winner rate (each self-syncs in a snapshot)
        uint256 snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(key, zeroForOne, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(key, zeroForOne, 1e18);
        vm.revertToState(snap);
        assertGt(outWinner, 0, "swap succeeds despite the donate failure");
        assertGt(outWinner, outOther, "winner still gets the discount despite the donate failure");

        // the donate failure is surfaced (isolated), not reverted up into the swap
        vm.expectEmit(true, false, false, false, address(auctionController));
        emit DonateFailed(pid, 0);
        winnerSwapper.swapExactIn(key, zeroForOne, 1e18);
    }

    function testFeeOnTransferDonateIsIsolatedAndDoesNotBrickPool() public {
        // Codex P1: a currency that begins charging a transfer fee AFTER a bid is escrowed makes
        // the donate under-settle the PoolManager. donateExternal must detect the shortfall and
        // revert inside the isolation (rolling the donation back), NOT return success and leave a
        // dangling delta that reverts the whole unlock (bricking every swap that attempts a drip).
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 10_000_000 ether);
        fot.approve(address(permit2), type(uint256).max);
        fot.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(fot), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(fot), address(poolManager), type(uint160).max, type(uint48).max);
        MockERC20 partner = deployToken();

        (Currency c0, Currency c1) = address(fot) < address(partner)
            ? (Currency.wrap(address(fot)), Currency.wrap(address(partner)))
            : (Currency.wrap(address(partner)), Currency.wrap(address(fot)));
        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId pid = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.auctionCurrency = Currency.wrap(address(fot));
        config.feeDiscountPpm = 500_000;
        auctionController.configurePool(key, config);
        uint64 s = uint64(block.timestamp);

        // bid while the token is still fee-free (the exact-transfer check passes)
        fot.mint(bidderA, 10e18);
        vm.prank(bidderA);
        fot.approve(address(auctionController), type(uint256).max);
        vm.prank(bidderA);
        auctionController.bidNext(key, address(winnerSwapper), 1e18);

        fot.mint(address(otherSwapper), 100e18);
        partner.mint(address(otherSwapper), 100e18);
        fot.mint(address(winnerSwapper), 100e18);
        partner.mint(address(winnerSwapper), 100e18);

        // into the won epoch, then the token turns on a 1% transfer fee
        vm.warp(uint256(s) + EPOCH_LENGTH + EPOCH_LENGTH / 2);
        fot.setFeeBps(100);

        // the drip attempt under-settles -> must be isolated as DonateFailed, and the swap and
        // the winner's discount must be unaffected
        bool zeroForOne = true;
        vm.expectEmit(true, false, false, false, address(auctionController));
        emit DonateFailed(pid, 0);
        uint256 outFirst = otherSwapper.swapExactIn(key, zeroForOne, 1e18);
        assertGt(outFirst, 0, "swap succeeds despite the under-settling donate");

        uint256 snap = vm.snapshotState();
        uint256 outWinner = winnerSwapper.swapExactIn(key, zeroForOne, 1e18);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 outOther = otherSwapper.swapExactIn(key, zeroForOne, 1e18);
        vm.revertToState(snap);
        assertGt(outWinner, outOther, "winner keeps the discount despite the broken currency");
    }

    function testSenderSurchargeDonateIsIsolatedAndSolvencyHolds() public {
        // Codex P2: a token that debits the SENDER amount + fee while crediting the PoolManager
        // exactly `amount` passes the settle check but would silently consume funds backing
        // refunds/protocol fees. donateExternal must verify the controller's own debit and revert
        // (isolated), keeping the controller solvent.
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 10_000_000 ether);
        fot.approve(address(permit2), type(uint256).max);
        fot.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(fot), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(fot), address(poolManager), type(uint160).max, type(uint48).max);
        MockERC20 partner = deployToken();

        (Currency c0, Currency c1) = address(fot) < address(partner)
            ? (Currency.wrap(address(fot)), Currency.wrap(address(partner)))
            : (Currency.wrap(address(partner)), Currency.wrap(address(fot)));
        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId pid = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.auctionCurrency = Currency.wrap(address(fot));
        auctionController.configurePool(key, config);
        uint64 s = uint64(block.timestamp);

        fot.mint(bidderA, 10e18);
        vm.prank(bidderA);
        fot.approve(address(auctionController), type(uint256).max);
        vm.prank(bidderA);
        auctionController.bidNext(key, address(winnerSwapper), 1e18);
        fot.mint(address(otherSwapper), 100e18);
        partner.mint(address(otherSwapper), 100e18);

        // surcharge turns on after the bid was escrowed
        vm.warp(uint256(s) + EPOCH_LENGTH + EPOCH_LENGTH / 2);
        fot.setSenderFeeBps(100);

        vm.expectEmit(true, false, false, false, address(auctionController));
        emit DonateFailed(pid, 0);
        uint256 amountOut = otherSwapper.swapExactIn(key, true, 1e18);
        assertGt(amountOut, 0, "swap succeeds; over-debiting donation rolled back");

        // solvency: nothing was consumed - the controller still holds the full escrowed bid
        assertEq(
            IERC20(address(fot)).balanceOf(address(auctionController)), 1e18, "controller balance fully backs the bid"
        );

        // a claim under a sender-side surcharge also reverts rather than consuming others' backing
        auctionController.setBiddingEnabled(key, false); // refunds the... (no queued bid; winner active)
        vm.prank(bidderB);
        vm.expectRevert(HookAuctionController.NothingToClaim.selector);
        auctionController.claimRefund(Currency.wrap(address(fot)), bidderB);
    }

    function testClaimRevertsOnSenderSurcharge() public {
        // outbid escrow with the standard token, then verify the sender-side guard on claims via
        // a surcharge token pool
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 10_000_000 ether);
        fot.approve(address(permit2), type(uint256).max);
        permit2.approve(address(fot), address(positionManager), type(uint160).max, type(uint48).max);
        MockERC20 partner = deployToken();
        (Currency c0, Currency c1) = address(fot) < address(partner)
            ? (Currency.wrap(address(fot)), Currency.wrap(address(partner)))
            : (Currency.wrap(address(partner)), Currency.wrap(address(fot)));
        PoolKey memory key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10e18,
            type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        HookAuctionController.PoolAuctionConfig memory config = _defaultConfig();
        config.auctionCurrency = Currency.wrap(address(fot));
        auctionController.configurePool(key, config);

        // A bids, B outbids -> A has an escrowed refund in the fot currency
        fot.mint(bidderA, 10e18);
        fot.mint(bidderB, 10e18);
        vm.prank(bidderA);
        fot.approve(address(auctionController), type(uint256).max);
        vm.prank(bidderB);
        fot.approve(address(auctionController), type(uint256).max);
        vm.prank(bidderA);
        auctionController.bidNext(key, address(winnerSwapper), RESERVE);
        vm.prank(bidderB);
        auctionController.bidNext(key, address(otherSwapper), RESERVE * 2);

        // surcharge on: the claim must revert (protecting other claimants' backing), and succeed
        // again once the surcharge is off - the claim is preserved, not consumed
        fot.setSenderFeeBps(100);
        vm.prank(bidderA);
        vm.expectRevert(HookAuctionController.ExactTransferFailed.selector);
        auctionController.claimRefund(Currency.wrap(address(fot)), bidderA);

        fot.setSenderFeeBps(0);
        vm.prank(bidderA);
        auctionController.claimRefund(Currency.wrap(address(fot)), bidderA);
        assertEq(IERC20(address(fot)).balanceOf(bidderA), 10e18, "refund recovered in full");
    }

    function testRevertingControllerRevertsHookOps() public {
        // The fail-open wrapper is intentionally gone: the controller is immutable + audited, so a
        // reverting controller is NOT masked - it reverts the hook op. (Token-level failures on the
        // donate path are still isolated inside the controller; that is what makes this safe.)
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

        // a liquidity op runs beforeAddLiquidity -> beforeLiquidityChange -> the controller reverts.
        // Wrapped in a single external call so expectRevert binds to the whole mint, not the token
        // approvals EasyPosm makes first.
        vm.expectRevert();
        this.mintFullRange(key);
    }

    /// @dev External wrapper so a whole mint can be asserted to revert.
    function mintFullRange(PoolKey calldata key) external {
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
        deployRevertHookStackWithController(flags, v4Oracle, protocolFeeRecipient, controller);
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
