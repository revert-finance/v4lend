// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {HookOwnedControllerBase} from "./HookOwnedControllerBase.sol";
import {IHookAuctionController} from "./interfaces/IHookAuctionController.sol";

/// @notice Hook entrypoint used to mirror the configured baseline fee into the pool's
///         stored dynamic LP fee (PoolManager only accepts fee updates from the pool's hook).
interface IRevertHookDynamicFee {
    function updateDynamicLPFee(PoolKey calldata key, uint24 newDynamicLPFee) external payable;
}

/// @title HookAuctionController
/// @notice Fixed-period auction that sells a discounted-LP-fee executor slot per epoch.
///         Bids placed during epoch N buy the discount for epoch N + 1. The winning bid
///         (minus a protocol fee) is dripped to in-range LPs via PoolManager.donate(),
///         vested linearly over the epoch.
/// @dev Design notes:
///      - All epoch accounting uses block.timestamp (Arbitrum block.number tracks L1 blocks).
///      - The winner is recognized as the address that calls PoolManager.swap directly
///        (its registered executor). Shared routers must never be registered as executors.
///      - Refunds of outbid bids are escrowed (pull-based) so a reverting token transfer
///        can never block the auction.
///      - Hook-facing entry points never revert for configured-but-idle pools and are
///        additionally wrapped in try/catch by the hook (fail-open): a broken controller
///        can never block swaps, liquidity changes, or liquidations.
///      - The auction currency must be an ERC20 side of the pool. Pools with a native
///        currency0 are supported by auctioning in the ERC20 currency1.
contract HookAuctionController is HookOwnedControllerBase, IHookAuctionController, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ==================== Constants ====================

    uint32 internal constant PPM = 1_000_000;
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 2_000;
    uint32 internal constant MIN_EPOCH_SECONDS = 300;
    uint32 internal constant MAX_EPOCH_SECONDS = 30 days;
    uint256 internal constant MAX_BID_AMOUNT = uint256(uint128(type(int128).max));

    // ==================== Structs ====================

    struct PoolAuctionConfig {
        Currency auctionCurrency; // ERC20 side of the pool used for bids, drips and protocol fees
        uint24 normalLpFee; // baseline LP fee, mirrored into the pool's stored dynamic fee
        uint32 feeDiscountPpm; // winner discount on normalLpFee; 1_000_000 = zero-fee winner
        uint64 epochStartTime; // unix seconds
        uint32 epochLengthSeconds;
        uint32 minDripSeconds; // drip throttle inside an epoch
        uint128 openingBidReserve; // minimum first bid of an epoch
        uint32 minBidBumpPpm; // relative outbid increment
        uint16 protocolFeeBps; // share of the winning bid sent to protocolFeeRecipient
        address protocolFeeRecipient;
        bool biddingEnabled; // false = deactivated: no new bids, running epoch is honored
    }

    struct EpochAuction {
        address bidder;
        address executor;
        uint128 bid;
        uint128 totalDrip;
        uint128 donated;
        uint64 lastDripTime;
        bool materialized;
    }

    struct PoolAuctionState {
        bool initialized;
        uint64 activeEpoch;
        EpochAuction active;
        EpochAuction next;
        // Vested value not yet donated (e.g. zero-liquidity periods). uint256 so carrying many
        // near-MAX_BID_AMOUNT epochs can never overflow and brick _syncPool.
        uint256 pendingDonation;
        uint64 pendingLastDripTime; // throttles gradual release of the pending bucket
    }

    // ==================== State ====================

    IPoolManager public immutable poolManager;

    bool public bidsPaused;

    // Owner-managed executor denylist: blocks a bidder from handing the discount to a shared
    // router (which would give every trader routing through it the discounted fee for the whole
    // epoch). Bidding stays permissionless; the owner blocks the known shared routers (Universal
    // Router, aggregators, ...). A denylist is inherently incomplete - a custom or unknown shared
    // executor bypasses it - but the vector is economically self-limiting: the bidder pays the
    // bid, which is dripped to LPs, so registering a shared router subsidizes traffic at the
    // bidder's own expense.
    mapping(address executor => bool denied) public executorDenied;

    mapping(PoolId poolId => PoolAuctionConfig config) internal _poolConfigs;
    mapping(PoolId poolId => PoolAuctionState state) internal _poolStates;
    mapping(Currency currency => mapping(address account => uint256 amount)) public refunds;
    mapping(Currency currency => mapping(address account => uint256 amount)) public protocolFeesAccrued;

    // ==================== Events ====================

    event PoolAuctionConfigured(PoolId indexed poolId, PoolAuctionConfig config);
    event BiddingEnabledSet(PoolId indexed poolId, bool enabled);
    event BidsPausedSet(bool paused);
    event BidPlaced(
        PoolId indexed poolId,
        uint64 indexed epoch,
        address indexed bidder,
        address executor,
        uint256 amount,
        address previousBidder,
        uint256 previousAmount
    );
    event EpochMaterialized(
        PoolId indexed poolId, uint64 indexed epoch, address indexed executor, uint256 bid, uint256 protocolFee
    );
    event EpochDripped(PoolId indexed poolId, uint64 indexed epoch, uint256 amount, uint256 totalDonated);
    event PendingDonationDripped(PoolId indexed poolId, uint256 amount, uint256 pendingRemaining);
    event RefundEscrowed(PoolId indexed poolId, Currency indexed currency, address indexed account, uint256 amount);
    event RefundClaimed(Currency indexed currency, address indexed account, address recipient, uint256 amount);
    event ProtocolFeesClaimed(Currency indexed currency, address indexed account, address recipient, uint256 amount);
    event NormalLpFeeSet(PoolId indexed poolId, uint24 normalLpFee);
    event PendingDonationSwept(PoolId indexed poolId, Currency indexed currency, address recipient, uint256 amount);
    event DonateFailed(PoolId indexed poolId, uint256 amount);
    event ExecutorDeniedSet(address indexed executor, bool denied);

    // ==================== Errors ====================

    error InvalidConfig();
    error PoolNotConfigured();
    error PoolStateNotClean();
    error AuctionNotStarted();
    error BiddingDisabled();
    error InvalidBid();
    error InvalidExecutor();
    error ExactTransferFailed();
    error NothingToClaim();
    error OnlyPoolManager();

    constructor(address hook_, IPoolManager poolManager_) HookOwnedControllerBase(hook_) {
        if (address(poolManager_) == address(0)) {
            revert InvalidConfig();
        }
        poolManager = poolManager_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) {
            revert Unauthorized();
        }
        _;
    }

    // ==================== Hook-facing entry points ====================

    /// @inheritdoc IHookAuctionController
    /// @dev Never reverts for configured pools in normal operation; the hook additionally
    ///      wraps this call in try/catch. Runs inside the hook's beforeSwap, i.e. while the
    ///      PoolManager is unlocked, so donations settle directly.
    function beforeSwap(PoolKey calldata key, address sender) external onlyHook returns (uint24 lpFeeOverride) {
        PoolId poolId = key.toId();
        // single cold SLOAD to skip the full struct copy on the many pools that never run an auction
        if (_poolConfigs[poolId].epochLengthSeconds == 0 || block.timestamp < _poolConfigs[poolId].epochStartTime) {
            return 0;
        }
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        PoolAuctionState storage state = _syncPool(poolId, config);

        // Compute the delivered obligation (the winner's fee override) from state alone, BEFORE
        // the best-effort drip. The override must survive a drip/token failure - the winner paid
        // for it. Warm slot (auction.bid) is tested before the cold bidsPaused slot.
        EpochAuction storage auction = state.active;
        if (auction.bid != 0 && sender == auction.executor && !bidsPaused) {
            lpFeeOverride = _winnerLpFee(config) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        _dripAvailable(key, poolId, config, state);
    }

    /// @inheritdoc IHookAuctionController
    function beforeLiquidityChange(PoolKey calldata key) external onlyHook {
        PoolId poolId = key.toId();
        if (_poolConfigs[poolId].epochLengthSeconds == 0 || block.timestamp < _poolConfigs[poolId].epochStartTime) {
            return;
        }
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        PoolAuctionState storage state = _syncPool(poolId, config);
        _dripAvailable(key, poolId, config, state);
    }

    // ==================== Bidding ====================

    /// @notice Places a bid for the next epoch of a pool. Outbid bids are escrowed and
    ///         claimable via claimRefund.
    /// @param key The pool key
    /// @param executor The contract that will call PoolManager.swap and receive the fee
    ///        discount if this bid wins. Must not be a shared router (denied executors are
    ///        rejected).
    /// @param amount The bid amount in the pool's auction currency
    function bidNext(PoolKey calldata key, address executor, uint256 amount) external nonReentrant {
        if (bidsPaused) {
            revert BiddingDisabled();
        }
        if (
            executor == address(0) || executor == address(poolManager) || executor == address(this)
                || executor == hook || executorDenied[executor]
        ) {
            revert InvalidExecutor();
        }

        PoolId poolId = key.toId();
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (!config.biddingEnabled) {
            revert BiddingDisabled();
        }
        if (block.timestamp < config.epochStartTime) {
            revert AuctionNotStarted();
        }

        PoolAuctionState storage state = _syncPool(poolId, config);
        EpochAuction storage auction = state.next;

        uint256 minBid = _minNextBid(config, auction.bid);
        if (amount < minBid || amount > MAX_BID_AMOUNT) {
            revert InvalidBid();
        }

        address previousBidder = auction.bidder;
        uint256 previousAmount = auction.bid;

        // effects before the token pull; the previous bid stays escrowed for pull-based claims
        auction.bidder = msg.sender;
        auction.executor = executor;
        auction.bid = uint128(amount);
        if (previousBidder != address(0)) {
            refunds[config.auctionCurrency][previousBidder] += previousAmount;
            emit RefundEscrowed(poolId, config.auctionCurrency, previousBidder, previousAmount);
        }

        IERC20 token = IERC20(Currency.unwrap(config.auctionCurrency));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - balanceBefore != amount) {
            revert ExactTransferFailed();
        }

        emit BidPlaced(poolId, state.activeEpoch + 1, msg.sender, executor, amount, previousBidder, previousAmount);
    }

    /// @notice Drips any vested auction proceeds of a pool to its in-range LPs.
    /// @dev Also runs lazily on every swap and liquidity change of the pool.
    function drip(PoolKey calldata key) external nonReentrant returns (uint256 amountDonated) {
        bytes memory result = poolManager.unlock(abi.encode(key));
        amountDonated = abi.decode(result, (uint256));
    }

    /// @dev Unlock callback for drip().
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert OnlyPoolManager();
        }
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId poolId = key.toId();
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isRunning(config)) {
            return abi.encode(uint256(0));
        }
        PoolAuctionState storage state = _syncPool(poolId, config);
        uint256 amountDonated = _dripAvailable(key, poolId, config, state);
        return abi.encode(amountDonated);
    }

    // ==================== Claims ====================

    /// @notice Claims escrowed refunds of outbid or deactivated bids.
    function claimRefund(Currency currency, address recipient) external nonReentrant returns (uint256 amount) {
        amount = refunds[currency][msg.sender];
        if (amount == 0) {
            revert NothingToClaim();
        }
        refunds[currency][msg.sender] = 0;
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
        emit RefundClaimed(currency, msg.sender, recipient, amount);
    }

    /// @notice Claims accrued protocol fees. Callable by the configured recipient account.
    function claimProtocolFees(Currency currency, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = protocolFeesAccrued[currency][msg.sender];
        if (amount == 0) {
            revert NothingToClaim();
        }
        protocolFeesAccrued[currency][msg.sender] = 0;
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
        emit ProtocolFeesClaimed(currency, msg.sender, recipient, amount);
    }

    // ==================== Owner configuration ====================

    /// @notice Configures (or reconfigures) the auction for a pool. The pool must be
    ///         initialized, use the dynamic fee flag and this controller's hook.
    /// @dev Reconfiguration requires a clean state: no active or pending bids and no
    ///      undistributed donations. Use setBiddingEnabled(false) first to wind down.
    function configurePool(PoolKey calldata key, PoolAuctionConfig memory config) external {
        _checkOwner();

        PoolId poolId = key.toId();
        if (address(key.hooks) != hook || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            revert InvalidConfig();
        }
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) {
            revert InvalidConfig();
        }
        if (
            config.auctionCurrency.isAddressZero()
                || (!(config.auctionCurrency == key.currency0) && !(config.auctionCurrency == key.currency1))
        ) {
            revert InvalidConfig();
        }
        if (
            config.normalLpFee > LPFeeLibrary.MAX_LP_FEE || config.feeDiscountPpm > PPM
                || config.protocolFeeBps > MAX_PROTOCOL_FEE_BPS || config.protocolFeeRecipient == address(0)
        ) {
            revert InvalidConfig();
        }
        if (
            config.epochLengthSeconds < MIN_EPOCH_SECONDS || config.epochLengthSeconds > MAX_EPOCH_SECONDS
                || config.minDripSeconds == 0 || config.minDripSeconds > config.epochLengthSeconds
                || config.minBidBumpPpm == 0 || config.minBidBumpPpm > PPM || config.openingBidReserve == 0
        ) {
            // a zero reserve or zero bump would let a 1-wei bid win, so both have a positive floor
            revert InvalidConfig();
        }
        if (config.epochStartTime == 0) {
            config.epochStartTime = uint64(block.timestamp);
        }
        if (config.epochStartTime < block.timestamp) {
            revert InvalidConfig();
        }

        PoolAuctionState storage state = _poolStates[poolId];
        if (state.active.bid != 0 || state.next.bid != 0 || state.pendingDonation != 0) {
            revert PoolStateNotClean();
        }
        delete _poolStates[poolId];

        _poolConfigs[poolId] = config;

        // mirror the baseline fee into the pool's stored dynamic fee so all non-winner
        // swaps (and any fail-open fallback in the hook) use it
        IRevertHookDynamicFee(hook).updateDynamicLPFee(key, config.normalLpFee);

        emit PoolAuctionConfigured(poolId, config);
    }

    /// @notice Enables or disables bidding for a pool. Disabling refunds any standing
    ///         next-epoch bid to escrow and stops new bids immediately; the running epoch
    ///         is honored until its end and vested proceeds continue to drip.
    function setBiddingEnabled(PoolKey calldata key, bool enabled) external {
        _checkOwner();

        PoolId poolId = key.toId();
        PoolAuctionConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }

        if (!enabled) {
            PoolAuctionState storage state = block.timestamp >= config.epochStartTime
                ? _syncPool(poolId, config)
                : _poolStates[poolId];
            EpochAuction storage auction = state.next;
            if (auction.bidder != address(0)) {
                refunds[config.auctionCurrency][auction.bidder] += auction.bid;
                emit RefundEscrowed(poolId, config.auctionCurrency, auction.bidder, auction.bid);
                delete state.next;
            }
        }

        config.biddingEnabled = enabled;
        emit BiddingEnabledSet(poolId, enabled);
    }

    /// @notice Emergency stop: blocks new bids on all pools and suspends the winner fee
    ///         discount. Dripping and claims stay available.
    /// @dev This is a heavy-handed brake: a winner whose epoch is paused mid-flight keeps
    ///      paying the baseline fee for the rest of that epoch and is NOT refunded (their bid
    ///      is already materialized). For a graceful, refunding wind-down of a single pool use
    ///      setBiddingEnabled(false) instead, which honors the running epoch.
    function setBidsPaused(bool paused_) external {
        _checkOwner();
        bidsPaused = paused_;
        emit BidsPausedSet(paused_);
    }

    /// @notice Denies (or re-allows) an executor. A denied executor can never be registered via
    ///         bidNext. Use it to block known shared routers while keeping bidding permissionless.
    function setExecutorDenied(address executor, bool denied) external {
        _checkOwner();
        executorDenied[executor] = denied;
        emit ExecutorDeniedSet(executor, denied);
    }

    /// @notice Updates the baseline LP fee of a configured pool and re-mirrors it into the
    ///         pool's stored dynamic fee so the stored fee and _winnerLpFee cannot drift apart.
    /// @dev The owner must change the baseline through here rather than calling the hook's
    ///      updateDynamicLPFee directly (which is controller-only) - otherwise the winner, who
    ///      pays _winnerLpFee(normalLpFee), could end up quoted a different fee than everyone else.
    function setNormalLpFee(PoolKey calldata key, uint24 newNormalLpFee) external {
        _checkOwner();
        if (newNormalLpFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidConfig();
        }
        PoolId poolId = key.toId();
        PoolAuctionConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        config.normalLpFee = newNormalLpFee;
        IRevertHookDynamicFee(hook).updateDynamicLPFee(key, newNormalLpFee);
        emit NormalLpFeeSet(poolId, newNormalLpFee);
    }

    /// @notice Owner rescue for pending-donation value that can no longer be delivered - e.g.
    ///         a pool that sat at zero in-range liquidity so donate() never fired, or a bucket
    ///         stuck behind a now-broken auction currency. Only callable once the pool's
    ///         bidding has been wound down, so it cannot pre-empt normal dripping to LPs.
    /// @dev Also the only way to clear a stuck bucket so configurePool (which requires
    ///      pendingDonation == 0) can restart the pool.
    function sweepPendingDonation(PoolKey calldata key, address recipient) external returns (uint256 amount) {
        _checkOwner();
        if (recipient == address(0)) {
            revert InvalidConfig();
        }
        PoolId poolId = key.toId();
        PoolAuctionConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (config.biddingEnabled) {
            revert BiddingDisabled();
        }
        amount = _poolStates[poolId].pendingDonation;
        if (amount == 0) {
            revert NothingToClaim();
        }
        _poolStates[poolId].pendingDonation = 0;
        IERC20(Currency.unwrap(config.auctionCurrency)).safeTransfer(recipient, amount);
        emit PendingDonationSwept(poolId, config.auctionCurrency, recipient, amount);
    }

    // ==================== Views ====================

    function getPoolAuctionConfig(PoolId poolId) external view returns (PoolAuctionConfig memory) {
        return _poolConfigs[poolId];
    }

    function getPoolAuctionState(PoolId poolId)
        external
        view
        returns (bool initialized, uint64 activeEpoch, uint256 pendingDonation)
    {
        PoolAuctionState storage state = _poolStates[poolId];
        return (state.initialized, state.activeEpoch, state.pendingDonation);
    }

    /// @notice Returns the auction slot of the currently active or the next epoch.
    /// @dev Values reflect stored state; call drip() or wait for a pool action to sync epochs.
    function getEpochAuction(PoolId poolId, bool nextEpoch)
        external
        view
        returns (
            address bidder,
            address executor,
            uint256 bid,
            uint256 totalDrip,
            uint256 donated,
            uint64 lastDripTime,
            bool materialized
        )
    {
        PoolAuctionState storage state = _poolStates[poolId];
        EpochAuction storage auction = nextEpoch ? state.next : state.active;
        return (
            auction.bidder,
            auction.executor,
            auction.bid,
            auction.totalDrip,
            auction.donated,
            auction.lastDripTime,
            auction.materialized
        );
    }

    function currentEpoch(PoolId poolId) external view returns (uint64) {
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (block.timestamp < config.epochStartTime) {
            revert AuctionNotStarted();
        }
        return _currentEpoch(config);
    }

    /// @notice Minimum accepted bid for the next epoch of a pool.
    /// @dev Accounts for a not-yet-synced epoch rollover: once the current epoch has advanced
    ///      past the stored one, bidNext will reset the next slot, so the effective current bid
    ///      to beat is 0 (the opening reserve). Reading the raw stored next.bid here would quote
    ///      the previous epoch's winning bid and make a keeper overpay.
    function minNextBid(PoolId poolId) external view returns (uint256) {
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        PoolAuctionState storage state = _poolStates[poolId];
        uint128 effectiveNextBid = _rolloverPending(config, state) ? 0 : state.next.bid;
        return _minNextBid(config, effectiveNextBid);
    }

    /// @dev True when a bidNext call would sync the pool to a later epoch, resetting the next slot.
    function _rolloverPending(PoolAuctionConfig memory config, PoolAuctionState storage state)
        internal
        view
        returns (bool)
    {
        return state.initialized && block.timestamp >= config.epochStartTime
            && _currentEpoch(config) > state.activeEpoch;
    }

    /// @notice The LP fee the epoch winner's executor pays on this pool.
    function winnerLpFee(PoolId poolId) external view returns (uint24) {
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        return _winnerLpFee(config);
    }

    // ==================== Internal: epoch machine ====================

    function _isConfigured(PoolAuctionConfig memory config) internal pure returns (bool) {
        return config.epochLengthSeconds != 0;
    }

    function _isRunning(PoolAuctionConfig memory config) internal view returns (bool) {
        return _isConfigured(config) && block.timestamp >= config.epochStartTime;
    }

    function _currentEpoch(PoolAuctionConfig memory config) internal view returns (uint64) {
        return uint64((block.timestamp - config.epochStartTime) / config.epochLengthSeconds);
    }

    function _epochBounds(PoolAuctionConfig memory config, uint64 epoch)
        internal
        pure
        returns (uint256 start, uint256 end)
    {
        start = uint256(config.epochStartTime) + uint256(epoch) * uint256(config.epochLengthSeconds);
        end = start + config.epochLengthSeconds;
    }

    function _winnerLpFee(PoolAuctionConfig memory config) internal pure returns (uint24) {
        return uint24(uint256(config.normalLpFee) - uint256(config.normalLpFee) * config.feeDiscountPpm / PPM);
    }

    function _minNextBid(PoolAuctionConfig memory config, uint128 currentBid) internal pure returns (uint256) {
        if (currentBid == 0) {
            return config.openingBidReserve > 0 ? config.openingBidReserve : 1;
        }
        uint256 bump = uint256(currentBid) * config.minBidBumpPpm / PPM;
        return uint256(currentBid) + (bump > 0 ? bump : 1);
    }

    /// @dev Rolls the stored epoch state forward to the current epoch. Fully vests and
    ///      carries skipped epochs into the pending-donation bucket.
    function _syncPool(PoolId poolId, PoolAuctionConfig memory config)
        internal
        returns (PoolAuctionState storage state)
    {
        state = _poolStates[poolId];
        uint64 current = _currentEpoch(config);
        if (!state.initialized) {
            state.initialized = true;
            state.activeEpoch = current;
            return state;
        }
        if (current <= state.activeEpoch) {
            return state;
        }

        _carryEpoch(poolId, config, state, state.activeEpoch, state.active);
        if (current == state.activeEpoch + 1) {
            state.active = state.next;
            delete state.next;
        } else {
            // More than one epoch skipped: the epoch-N+1 winner was never promoted to active
            // and never received a single discounted swap, so refund its bid to escrow rather
            // than confiscate it.
            EpochAuction storage skipped = state.next;
            if (skipped.bidder != address(0)) {
                refunds[config.auctionCurrency][skipped.bidder] += skipped.bid;
                emit RefundEscrowed(poolId, config.auctionCurrency, skipped.bidder, skipped.bid);
            }
            delete state.active;
            delete state.next;
        }
        state.activeEpoch = current;
    }

    function _carryEpoch(
        PoolId poolId,
        PoolAuctionConfig memory config,
        PoolAuctionState storage state,
        uint64 epoch,
        EpochAuction storage auction
    ) internal {
        if (auction.bid == 0) {
            return;
        }
        _materializeEpoch(poolId, config, epoch, auction);

        uint128 remaining = auction.totalDrip - auction.donated;
        if (remaining == 0) {
            return;
        }
        auction.donated = auction.totalDrip;
        state.pendingDonation += remaining;
    }

    /// @dev Splits the winning bid into protocol fee and drip amount, exactly once per epoch.
    function _materializeEpoch(
        PoolId poolId,
        PoolAuctionConfig memory config,
        uint64 epoch,
        EpochAuction storage auction
    ) internal {
        if (auction.materialized) {
            return;
        }
        auction.materialized = true;

        uint256 protocolFee;
        if (auction.bid != 0) {
            protocolFee = uint256(auction.bid) * config.protocolFeeBps / BPS_DENOMINATOR;
            auction.totalDrip = auction.bid - uint128(protocolFee);
            if (protocolFee != 0) {
                protocolFeesAccrued[config.auctionCurrency][config.protocolFeeRecipient] += protocolFee;
            }
        }
        emit EpochMaterialized(poolId, epoch, auction.executor, auction.bid, protocolFee);
    }

    // ==================== Internal: dripping ====================

    function _dripAvailable(
        PoolKey memory key,
        PoolId poolId,
        PoolAuctionConfig memory config,
        PoolAuctionState storage state
    ) internal returns (uint256 amountDonated) {
        amountDonated = _dripPending(key, poolId, config, state);
        amountDonated += _dripActiveEpoch(key, poolId, config, state);
    }

    /// @dev Releases the pending-donation bucket gradually rather than in one lump. donate()
    ///      credits whoever is in range at that instant, so dumping the whole bucket at once
    ///      lets a single-block JIT position capture all of it. Each release is throttled by
    ///      minDripSeconds and bounded to (elapsed / epochLength) of the bucket, with the
    ///      catch-up window capped at one epoch. Crucially, whenever the pool has no in-range
    ///      liquidity the throttle clock is advanced, so an idle zero-liquidity stretch is NOT
    ///      later paid out as one large catch-up slice to the first LP that reappears (which
    ///      would be the sole in-range recipient of the whole accrued bucket). A JIT therefore
    ///      has to hold liquidity for at least minDripSeconds to receive even one bounded slice.
    ///      This bounds, but does not fully eliminate, point-in-time JIT exposure - a known
    ///      tradeoff of donate-based distribution.
    function _dripPending(
        PoolKey memory key,
        PoolId poolId,
        PoolAuctionConfig memory config,
        PoolAuctionState storage state
    ) internal returns (uint256 amountToDonate) {
        uint256 pending = state.pendingDonation;
        if (pending == 0) {
            return 0;
        }

        // Cannot donate without in-range liquidity; advance the clock so the gap cannot become a
        // giant catch-up slice once liquidity returns.
        if (StateLibrary.getLiquidity(poolManager, poolId) == 0) {
            state.pendingLastDripTime = uint64(block.timestamp);
            return 0;
        }

        uint64 last = state.pendingLastDripTime;
        if (last != 0 && block.timestamp < uint256(last) + config.minDripSeconds) {
            return 0;
        }

        uint256 elapsed = last == 0 ? config.minDripSeconds : block.timestamp - last;
        if (elapsed > config.epochLengthSeconds) {
            elapsed = config.epochLengthSeconds; // cap the catch-up at one epoch's worth
        }
        uint256 release = FullMath.mulDiv(pending, elapsed, config.epochLengthSeconds);
        // release rounds to 0 only for sub-slice dust (pending < epochLength / minDripSeconds,
        // e.g. < a few dozen wei); clear it so the bucket cannot get permanently stuck.
        if (release == 0 || release > pending) {
            release = pending;
        }
        if (release > MAX_BID_AMOUNT) {
            release = MAX_BID_AMOUNT; // keep each donate within int128 range
        }

        amountToDonate = _donate(key, poolId, config, release);
        if (amountToDonate == 0) {
            return 0;
        }
        state.pendingDonation = pending - amountToDonate;
        state.pendingLastDripTime = uint64(block.timestamp);
        emit PendingDonationDripped(poolId, amountToDonate, state.pendingDonation);
    }

    function _dripActiveEpoch(
        PoolKey memory key,
        PoolId poolId,
        PoolAuctionConfig memory config,
        PoolAuctionState storage state
    ) internal returns (uint256 amountToDonate) {
        EpochAuction storage auction = state.active;
        if (auction.bid == 0) {
            return 0;
        }

        uint64 epoch = state.activeEpoch;
        (uint256 epochStart, uint256 epochEnd) = _epochBounds(config, epoch);

        _materializeEpoch(poolId, config, epoch, auction);

        uint128 totalDrip = auction.totalDrip;
        if (totalDrip == 0 || auction.donated >= totalDrip) {
            return 0;
        }

        uint256 effectiveTime = block.timestamp < epochEnd ? block.timestamp : epochEnd;
        if (effectiveTime <= epochStart) {
            return 0;
        }

        uint256 vested = uint256(totalDrip) * (effectiveTime - epochStart) / config.epochLengthSeconds;
        uint256 claimable = vested - auction.donated;
        if (claimable == 0) {
            return 0;
        }

        // No in-range liquidity: park the newly-vested slice into the pending bucket (anti-JIT
        // gradual release) instead of letting it dump to the first LP that reappears, and mark
        // it donated so it is not counted twice. Mirrors _dripPending's zero-liquidity handling.
        if (StateLibrary.getLiquidity(poolManager, poolId) == 0) {
            auction.donated += uint128(claimable);
            state.pendingDonation += claimable;
            return 0;
        }

        if (
            auction.lastDripTime != 0 && block.timestamp < uint256(auction.lastDripTime) + config.minDripSeconds
                && block.timestamp < epochEnd
        ) {
            return 0;
        }

        amountToDonate = _donate(key, poolId, config, claimable);
        if (amountToDonate == 0) {
            return 0;
        }

        auction.donated += uint128(amountToDonate);
        auction.lastDripTime = uint64(block.timestamp);
        emit EpochDripped(poolId, epoch, amountToDonate, auction.donated);
    }

    /// @dev Donates `amount` of the auction currency to the pool's in-range liquidity.
    ///      Returns 0 (keeping the value pending) while the pool has no active liquidity, and
    ///      also returns 0 - without reverting - if the donate/settle leg reverts (e.g. a
    ///      blacklisting or fee-on-transfer auction currency). Isolating the failure this way
    ///      guarantees a misbehaving currency can neither brick pool swaps/liquidity ops nor
    ///      void a winner's fee override; the undonated value simply stays pending.
    function _donate(PoolKey memory key, PoolId poolId, PoolAuctionConfig memory config, uint256 amount)
        internal
        returns (uint256 amountToDonate)
    {
        if (amount == 0 || amount > MAX_BID_AMOUNT || StateLibrary.getLiquidity(poolManager, poolId) == 0) {
            return 0;
        }

        // External self-call so a revert in donate/sync/transfer/settle is caught here and
        // rolls back only this donation (the delta it created is undone with it).
        try this.donateExternal(key, config.auctionCurrency, amount) {
            amountToDonate = amount;
        } catch {
            emit DonateFailed(poolId, amount);
            return 0;
        }
    }

    /// @dev Self-only executor for a single donation, so `_donate` can wrap it in try/catch.
    ///      Runs inside the same PoolManager unlock as the caller.
    function donateExternal(PoolKey calldata key, Currency currency, uint256 amount) external {
        if (msg.sender != address(this)) {
            revert Unauthorized();
        }
        bool isCurrency0 = currency == key.currency0;
        poolManager.donate(key, isCurrency0 ? amount : 0, isCurrency0 ? 0 : amount, "");
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}
