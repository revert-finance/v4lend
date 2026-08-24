// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
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
        uint128 pendingDonation; // vested value not yet donated (e.g. zero-liquidity periods)
    }

    // ==================== State ====================

    IPoolManager public immutable poolManager;

    bool public bidsPaused;

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
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isRunning(config)) {
            return 0;
        }

        PoolAuctionState storage state = _syncPool(poolId, config);
        _dripAvailable(key, poolId, config, state);

        EpochAuction storage auction = state.active;
        if (!bidsPaused && auction.materialized && auction.bid != 0 && sender == auction.executor) {
            return _winnerLpFee(config) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }
        return 0;
    }

    /// @inheritdoc IHookAuctionController
    function beforeLiquidityChange(PoolKey calldata key) external onlyHook {
        PoolId poolId = key.toId();
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isRunning(config)) {
            return;
        }

        PoolAuctionState storage state = _syncPool(poolId, config);
        _dripAvailable(key, poolId, config, state);
    }

    // ==================== Bidding ====================

    /// @notice Places a bid for the next epoch of a pool. Outbid bids are escrowed and
    ///         claimable via claimRefund.
    /// @param key The pool key
    /// @param executor The contract that will call PoolManager.swap and receive the fee
    ///        discount if this bid wins. Must not be a shared router.
    /// @param amount The bid amount in the pool's auction currency
    function bidNext(PoolKey calldata key, address executor, uint256 amount) external nonReentrant {
        if (bidsPaused) {
            revert BiddingDisabled();
        }
        if (
            executor == address(0) || executor == address(poolManager) || executor == address(this)
                || executor == hook
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
                || config.minBidBumpPpm > PPM
        ) {
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
    function setBidsPaused(bool paused_) external {
        _checkOwner();
        bidsPaused = paused_;
        emit BidsPausedSet(paused_);
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

    /// @notice Minimum accepted bid for the next epoch of a pool (based on stored state).
    function minNextBid(PoolId poolId) external view returns (uint256) {
        PoolAuctionConfig memory config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        return _minNextBid(config, _poolStates[poolId].next.bid);
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
            _carryEpoch(poolId, config, state, state.activeEpoch + 1, state.next);
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

    function _dripPending(
        PoolKey memory key,
        PoolId poolId,
        PoolAuctionConfig memory config,
        PoolAuctionState storage state
    ) internal returns (uint256 amountToDonate) {
        uint128 pending = state.pendingDonation;
        if (pending == 0) {
            return 0;
        }
        amountToDonate = _donate(key, poolId, config, pending);
        if (amountToDonate == 0) {
            return 0;
        }
        state.pendingDonation = pending - uint128(amountToDonate);
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
        if (
            auction.lastDripTime != 0 && block.timestamp < uint256(auction.lastDripTime) + config.minDripSeconds
                && block.timestamp < epochEnd
        ) {
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

        amountToDonate = _donate(key, poolId, config, claimable);
        if (amountToDonate == 0) {
            return 0;
        }

        auction.donated += uint128(amountToDonate);
        auction.lastDripTime = uint64(block.timestamp);
        emit EpochDripped(poolId, epoch, amountToDonate, auction.donated);
    }

    /// @dev Donates `amount` of the auction currency to the pool's in-range liquidity.
    ///      Returns 0 (keeping the value pending) while the pool has no active liquidity.
    function _donate(PoolKey memory key, PoolId poolId, PoolAuctionConfig memory config, uint256 amount)
        internal
        returns (uint256 amountToDonate)
    {
        if (amount == 0 || StateLibrary.getLiquidity(poolManager, poolId) == 0) {
            return 0;
        }

        amountToDonate = amount;
        bool isCurrency0 = config.auctionCurrency == key.currency0;
        poolManager.donate(key, isCurrency0 ? amountToDonate : 0, isCurrency0 ? 0 : amountToDonate, "");

        poolManager.sync(config.auctionCurrency);
        IERC20(Currency.unwrap(config.auctionCurrency)).safeTransfer(address(poolManager), amountToDonate);
        poolManager.settle();
    }
}
