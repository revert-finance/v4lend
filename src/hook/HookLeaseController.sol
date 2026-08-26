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
import {IRevertHookDynamicFee} from "./HookAuctionController.sol";

/// @title HookLeaseController
/// @notice Harberger-lease alternative to HookAuctionController: instead of fixed epochs won by
///         English auction, ONE lessee holds the discounted-LP-fee executor slot continuously.
///         The lessee self-assesses a price (escrowed as a deposit), pays rent on that price at
///         a per-second tax rate, and anyone can take the slot at any time by outbidding the
///         self-assessed price (the classic Harberger buyout). Rent - minus a protocol fee - is
///         dripped to in-range LPs via PoolManager.donate().
/// @dev Implements the same hook-facing IHookAuctionController interface as the epoch-auction
///      controller, so a deployment chooses the mechanism by wiring ONE of the two as the hook's
///      immutable auction controller. Design notes (shared with HookAuctionController):
///      - All accounting uses block.timestamp (Arbitrum block.number tracks L1 blocks).
///      - The lessee is recognized as the address that calls PoolManager.swap directly (its
///        registered executor). Shared routers must never be registered as executors.
///      - Refunds of bought-out lessees are escrowed (pull-based) so a reverting token transfer
///        can never block a buyout.
///      - Hook-facing entry points (beforeSwap / beforeLiquidityChange) are non-reverting by
///        construction: they early-return for configured-but-idle pools, and the only
///        externally-dependent step - donating to LPs in the config-chosen auction currency -
///        is isolated inside this contract's own donate try/catch.
///      - The auction currency must be an ERC20 side of the pool. Pools with a native
///        currency0 are supported by leasing in the ERC20 currency1.
contract HookLeaseController is HookOwnedControllerBase, IHookAuctionController, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ==================== Constants ====================

    uint32 internal constant PPM = 1_000_000;
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 2_000;
    uint32 internal constant MAX_DRIP_HORIZON_SECONDS = 30 days;
    uint256 internal constant MAX_ESCROW_AMOUNT = uint256(uint128(type(int128).max));
    uint256 internal constant Q64 = 1 << 64;

    // Salt for the per-pool same-TRANSACTION memo slot (EIP-1153, cleared per transaction).
    // Accrual and dripping are idempotent within a timestamp, so once a pool was accrued+dripped
    // in this transaction, later touches skip straight to the discount check.
    bytes32 internal constant _TX_MEMO_SALT = keccak256("HookLeaseController.txMemo");

    // ==================== Structs ====================

    /// @dev Field order is gas-deliberate: slot 0 carries everything the swap hot path needs
    ///      (configured-gate, drip throttle horizon, discount fee), read as a single cold SLOAD.
    struct PoolLeaseConfig {
        // slot 0 - swap hot path
        uint64 startTime; // unix seconds; leases and discounts start here
        uint32 minDripSeconds; // drip throttle; nonzero doubles as the "configured" flag
        uint32 dripHorizonSeconds; // pending rent drains to LPs over roughly this horizon (anti-JIT)
        uint24 normalLpFee; // baseline LP fee, mirrored into the pool's stored dynamic fee
        uint32 feeDiscountPpm; // lessee discount on normalLpFee; 1_000_000 = zero-fee lessee
        bool leasingEnabled; // false = deactivated: no new lease/buyout/top-up, running lease honored
        // slot 1 - lease-action time
        Currency auctionCurrency; // ERC20 side of the pool used for deposits, rent and fees
        uint32 minBuyoutBumpPpm; // relative price increment a buyout must offer
        uint16 protocolFeeBps; // share of accrued rent sent to protocolFeeRecipient
        uint32 minRentDepositSeconds; // a (re)starting lease must prepay at least this much rent
        // slot 2
        address protocolFeeRecipient;
        uint64 taxRatePerSecondX64; // rent per second as a Q64 fraction of the self-assessed price
    }

    /// @dev Slot 0 packs everything beforeSwap needs after the config gate: the discount check
    ///      (executor + paidThrough) and both drip gates (lastDripTime throttle + hasPending)
    ///      resolve from ONE cold SLOAD. executor and paidThrough are canonical here (not
    ///      mirrors); hasPending mirrors pendingDonation != 0.
    struct PoolLeaseState {
        // slot 0 - swap hot path
        address executor; // zero = no active lease
        uint40 paidThrough; // rent covers [start, paidThrough); discount active STRICTLY while now < this
        uint40 lastDripTime; // shared throttle clock for accrual + pending release
        bool hasPending; // mirror of pendingDonation != 0
        // slot 1 - accrual time
        address lessee;
        uint64 lastAccrualTime;
        // sub-bps protocol-fee remainder (wei * bps units, < BPS_DENOMINATOR) carried across
        // accruals so per-second rent slices cannot round the protocol fee to zero forever
        uint16 feeCarry;
        // slot 2 - accrual time
        uint128 price; // self-assessed price, escrowed as the lease deposit
        uint128 rentBalance; // prepaid rent not yet accrued
        // Accrued rent that could not be delivered directly (zero-liquidity periods, failed
        // donates, lease-action accruals); released gradually. uint256 so a long-lived lease
        // can never overflow the accumulator.
        uint256 pendingDonation;
    }

    // ==================== State ====================

    IPoolManager public immutable poolManager;

    // Owner-managed executor denylist - same rationale as HookAuctionController: a lessee
    // registering a shared router would give every trader routing through it the discount.
    mapping(address executor => bool denied) public executorDenied;

    mapping(PoolId poolId => PoolLeaseConfig config) internal _poolConfigs;
    mapping(PoolId poolId => PoolLeaseState state) internal _poolStates;
    mapping(Currency currency => mapping(address account => uint256 amount)) public refunds;
    mapping(Currency currency => mapping(address account => uint256 amount)) public protocolFeesAccrued;

    // ==================== Events ====================

    event PoolLeaseConfigured(PoolId indexed poolId, PoolLeaseConfig config);
    event LeasingEnabledSet(PoolId indexed poolId, bool enabled);
    event LeaseStarted(
        PoolId indexed poolId, address indexed lessee, address indexed executor, uint256 price, uint256 rentDeposit
    );
    event LeaseBought(
        PoolId indexed poolId,
        address indexed oldLessee,
        address indexed newLessee,
        address executor,
        uint256 newPrice,
        uint256 rentDeposit,
        uint256 oldRefund
    );
    event LeasePriceChanged(PoolId indexed poolId, address indexed lessee, uint256 oldPrice, uint256 newPrice);
    event LeaseRentFunded(PoolId indexed poolId, address indexed lessee, uint256 amount);
    event LeaseExited(PoolId indexed poolId, address indexed lessee, uint256 refund);
    event LeaseEvicted(PoolId indexed poolId, address indexed lessee, uint256 refund);
    event RentAccrued(PoolId indexed poolId, uint256 amount, uint256 protocolFee, uint256 remainingRentBalance);
    event RentDripped(PoolId indexed poolId, uint256 amount);
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
    error LeasingDisabled();
    error LeasingNotStarted();
    error LeaseAlreadyActive();
    error NoActiveLease();
    error NotLessee();
    error LeaseStillSolvent();
    error InvalidPrice();
    error InvalidRentDeposit();
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
        _checkHook();
        _;
    }

    function _checkHook() internal view {
        if (msg.sender != hook) {
            revert Unauthorized();
        }
    }

    // ==================== Hook-facing entry points ====================

    /// @inheritdoc IHookAuctionController
    /// @dev Non-reverting by construction (the hook calls it directly): early-returns for idle
    ///      pools, and the donate leg is isolated in _donate's own try/catch. Runs inside the
    ///      hook's beforeSwap, i.e. while the PoolManager is unlocked, so donations settle directly.
    function beforeSwap(PoolKey calldata key, address sender) external onlyHook returns (uint24 lpFeeOverride) {
        PoolId poolId = key.toId();
        // single cold SLOAD to skip the many pools that never run a lease
        if (_poolConfigs[poolId].minDripSeconds == 0 || block.timestamp < _poolConfigs[poolId].startTime) {
            return 0;
        }
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        PoolLeaseState storage state = _poolStates[poolId];

        // The delivered obligation (the lessee's fee override) is decided from state slot 0
        // alone, BEFORE the best-effort drip: it must survive a drip/token failure - the lessee
        // paid rent for it. now < paidThrough encodes rent solvency without any math; the
        // comparison is STRICT so a deposit covering k seconds grants exactly [start, start+k) -
        // a zero-duration top-up (sub-second dust that floors to paidThrough == now) activates
        // nothing, otherwise 1 wei per block would rent the slot.
        if (state.executor != address(0) && sender == state.executor && block.timestamp < state.paidThrough) {
            lpFeeOverride = _discountedLpFee(config) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        // same-transaction memo: accrual + drip are idempotent per timestamp
        bytes32 memoSlot = PoolId.unwrap(poolId) ^ _TX_MEMO_SALT;
        bool memoHit;
        assembly ("memory-safe") {
            memoHit := eq(tload(memoSlot), timestamp())
        }
        if (memoHit) {
            return lpFeeOverride;
        }

        _accrueAndDrip(key, poolId, config, state);
        assembly ("memory-safe") {
            tstore(memoSlot, timestamp())
        }
    }

    /// @inheritdoc IHookAuctionController
    function beforeLiquidityChange(PoolKey calldata key) external onlyHook {
        PoolId poolId = key.toId();
        if (_poolConfigs[poolId].minDripSeconds == 0 || block.timestamp < _poolConfigs[poolId].startTime) {
            return;
        }
        bytes32 memoSlot = PoolId.unwrap(poolId) ^ _TX_MEMO_SALT;
        bool memoHit;
        assembly ("memory-safe") {
            memoHit := eq(tload(memoSlot), timestamp())
        }
        if (memoHit) {
            return; // already accrued + dripped at this timestamp in this transaction
        }
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        _accrueAndDrip(key, poolId, config, _poolStates[poolId]);
        assembly ("memory-safe") {
            tstore(memoSlot, timestamp())
        }
    }

    // ==================== Lease actions ====================

    /// @notice Starts a lease on a vacant pool: escrows the self-assessed `price` as a deposit
    ///         and prepays `rentDeposit` of rent. The registered executor gets the fee discount
    ///         while the rent balance covers the current time.
    function startLease(PoolKey calldata key, address executor, uint256 price, uint256 rentDeposit)
        external
        nonReentrant
    {
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        _checkLeaseActionAllowed(config);
        _checkExecutor(executor);

        PoolLeaseState storage state = _poolStates[poolId];
        if (state.lessee != address(0)) {
            revert LeaseAlreadyActive();
        }
        _installLease(config, state, executor, price, rentDeposit);
        emit LeaseStarted(poolId, msg.sender, executor, price, rentDeposit);
    }

    /// @notice Takes over an active lease Harberger-style: pay a price at least minBuyoutBumpPpm
    ///         above the current self-assessed price (escrowed as the new deposit) plus a fresh
    ///         rent deposit. The old lessee's deposit and unused rent go to pull-refund escrow.
    function buyout(PoolKey calldata key, address executor, uint256 newPrice, uint256 rentDeposit)
        external
        nonReentrant
    {
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        _checkLeaseActionAllowed(config);
        _checkExecutor(executor);

        PoolLeaseState storage state = _poolStates[poolId];
        address oldLessee = state.lessee;
        if (oldLessee == address(0)) {
            revert NoActiveLease();
        }
        _addPending(state, _accrue(poolId, config, state));

        if (newPrice < minBuyoutPrice(poolId)) {
            revert InvalidPrice();
        }

        uint256 oldRefund = uint256(state.price) + state.rentBalance;
        _installLease(config, state, executor, newPrice, rentDeposit);
        if (oldRefund != 0) {
            refunds[config.auctionCurrency][oldLessee] += oldRefund;
            emit RefundEscrowed(poolId, config.auctionCurrency, oldLessee, oldRefund);
        }
        emit LeaseBought(poolId, oldLessee, msg.sender, executor, newPrice, rentDeposit, oldRefund);
    }

    /// @dev Shared start/buyout tail: validates price and deposit, pulls the funds exactly and
    ///      writes the new lease (including the slot-0 hot-path fields).
    function _installLease(
        PoolLeaseConfig storage config,
        PoolLeaseState storage state,
        address executor,
        uint256 price,
        uint256 rentDeposit
    ) internal {
        _checkPrice(price);
        uint256 rps = _rentPerSecond(config, price);
        if (rentDeposit < rps * config.minRentDepositSeconds || rentDeposit > MAX_ESCROW_AMOUNT) {
            revert InvalidRentDeposit();
        }

        state.lessee = msg.sender;
        state.lastAccrualTime = uint64(block.timestamp);
        state.price = uint128(price);
        state.rentBalance = uint128(rentDeposit);
        state.executor = executor;
        state.paidThrough = _paidThrough(block.timestamp, rentDeposit, rps);

        _pullExact(config.auctionCurrency, price + rentDeposit);
    }

    /// @notice Tops up the prepaid rent of the caller's lease.
    function fundRent(PoolKey calldata key, uint256 amount) external nonReentrant {
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        _checkLeaseActionAllowed(config);
        PoolLeaseState storage state = _requireLessee(poolId);
        if (amount == 0 || uint256(state.rentBalance) + amount > MAX_ESCROW_AMOUNT) {
            revert InvalidRentDeposit();
        }

        _addPending(state, _accrue(poolId, config, state));
        state.rentBalance += uint128(amount);
        state.paidThrough = _paidThrough(state.lastAccrualTime, state.rentBalance, _rentPerSecond(config, state.price));
        _pullExact(config.auctionCurrency, amount);
        emit LeaseRentFunded(poolId, msg.sender, amount);
    }

    /// @notice Changes the caller's self-assessed price. Raising it pulls the difference into
    ///         escrow (and raises the rent); lowering it refunds the difference (and lowers the
    ///         rent, but also the buyout threshold - the Harberger honesty incentive).
    /// @dev Lowering stays allowed while leasing is disabled (it only reduces the lessee's
    ///      exposure); raising requires leasing to be enabled.
    function setPrice(PoolKey calldata key, uint256 newPrice) external nonReentrant {
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isRunning(config)) {
            revert PoolNotConfigured();
        }
        PoolLeaseState storage state = _requireLessee(poolId);
        uint256 oldPrice = state.price;
        if (newPrice == oldPrice) {
            revert InvalidPrice();
        }
        _checkPrice(newPrice);

        _addPending(state, _accrue(poolId, config, state));
        state.price = uint128(newPrice);
        state.paidThrough = _paidThrough(state.lastAccrualTime, state.rentBalance, _rentPerSecond(config, newPrice));

        if (newPrice > oldPrice) {
            if (!config.leasingEnabled) {
                revert LeasingDisabled();
            }
            _pullExact(config.auctionCurrency, newPrice - oldPrice);
        } else {
            _transferOutExact(config.auctionCurrency, msg.sender, oldPrice - newPrice);
        }
        emit LeasePriceChanged(poolId, msg.sender, oldPrice, newPrice);
    }

    /// @notice Ends the caller's lease and returns the price deposit plus unaccrued rent.
    ///         Always allowed, including while leasing is disabled.
    function exitLease(PoolKey calldata key) external nonReentrant returns (uint256 refund) {
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        PoolLeaseState storage state = _requireLessee(poolId);

        // a lease can only exist once startTime has passed, so accrual is always safe here
        _addPending(state, _accrue(poolId, config, state));
        refund = uint256(state.price) + state.rentBalance;
        _clearLease(state);
        if (refund != 0) {
            _transferOutExact(config.auctionCurrency, msg.sender, refund);
        }
        emit LeaseExited(poolId, msg.sender, refund);
    }

    /// @notice Drips any accrued rent of a pool to its in-range LPs.
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
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isRunning(config)) {
            return abi.encode(uint256(0));
        }
        uint256 amountDonated = _accrueAndDrip(key, poolId, config, _poolStates[poolId]);
        return abi.encode(amountDonated);
    }

    // ==================== Claims ====================

    /// @notice Claims escrowed refunds of bought-out or evicted leases.
    /// @dev Recipient-side transfer fees are deliberately NOT checked (the claimant bears the
    ///      token's own fee; claims are voluntary and deferrable), while the CONTROLLER's debit
    ///      must be exact - same policy as HookAuctionController.
    function claimRefund(Currency currency, address recipient) external nonReentrant returns (uint256 amount) {
        amount = refunds[currency][msg.sender];
        if (amount == 0) {
            revert NothingToClaim();
        }
        refunds[currency][msg.sender] = 0;
        _transferOutExact(currency, recipient, amount);
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
        _transferOutExact(currency, recipient, amount);
        emit ProtocolFeesClaimed(currency, msg.sender, recipient, amount);
    }

    // ==================== Owner configuration ====================

    /// @notice Configures (or reconfigures) the lease for a pool. The pool must be initialized,
    ///         use the dynamic fee flag and this controller's hook.
    /// @dev Reconfiguration requires a clean state: no active lease and no undistributed
    ///      donations. Use setLeasingEnabled(false) first to wind down (and evictLease once the
    ///      running lease is rent-insolvent, if the lessee never exits).
    function configurePool(PoolKey calldata key, PoolLeaseConfig memory config) external {
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
            config.minDripSeconds == 0 || config.dripHorizonSeconds < config.minDripSeconds
                || config.dripHorizonSeconds > MAX_DRIP_HORIZON_SECONDS || config.minBuyoutBumpPpm == 0
                || config.minBuyoutBumpPpm > PPM || config.minRentDepositSeconds == 0
                || config.taxRatePerSecondX64 == 0
        ) {
            revert InvalidConfig();
        }
        // The mandatory rent deposit must be escrowable at EVERY installable price (rps is
        // monotonic in price, so checking the cap covers all): otherwise an incumbent could
        // raise their price to one whose buyout deposit exceeds MAX_ESCROW_AMOUNT, making the
        // slot un-buyoutable. Economically this bounds the mandatory prepay to at most ~100%
        // of the self-assessed price - any config demanding more is nonsensical anyway.
        if (
            FullMath.mulDivRoundingUp(MAX_ESCROW_AMOUNT, config.taxRatePerSecondX64, Q64)
                * config.minRentDepositSeconds > MAX_ESCROW_AMOUNT
        ) {
            revert InvalidConfig();
        }
        if (config.startTime == 0) {
            config.startTime = uint64(block.timestamp);
        }
        if (config.startTime < block.timestamp) {
            revert InvalidConfig();
        }

        PoolLeaseState storage state = _poolStates[poolId];
        if (state.lessee != address(0) || state.pendingDonation != 0) {
            revert PoolStateNotClean();
        }
        delete _poolStates[poolId];

        _poolConfigs[poolId] = config;

        // mirror the baseline fee into the pool's stored dynamic fee so all non-lessee swaps use it
        IRevertHookDynamicFee(hook).updateDynamicLPFee(key, config.normalLpFee);

        emit PoolLeaseConfigured(poolId, config);
    }

    /// @notice Enables or disables leasing for a pool. Disabling stops new leases, buyouts,
    ///         rent top-ups and price raises immediately; the running lease is honored until
    ///         its prepaid rent runs out (or the lessee exits) and accrued rent keeps dripping.
    function setLeasingEnabled(PoolKey calldata key, bool enabled) external {
        _checkOwner();
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        config.leasingEnabled = enabled;
        emit LeasingEnabledSet(poolId, enabled);
    }

    /// @notice Denies (or re-allows) an executor. A denied executor can never be registered via
    ///         startLease/buyout. Use it to block known shared routers.
    function setExecutorDenied(address executor, bool denied) external {
        _checkOwner();
        executorDenied[executor] = denied;
        emit ExecutorDeniedSet(executor, denied);
    }

    /// @notice Updates the baseline LP fee of a configured pool and re-mirrors it into the
    ///         pool's stored dynamic fee.
    /// @dev Frozen while a lease is active: the lessee priced their rent against the current
    ///      baseline and discount - moving normalLpFee mid-lease would erode or invert the
    ///      advantage they are paying for.
    function setNormalLpFee(PoolKey calldata key, uint24 newNormalLpFee) external {
        _checkOwner();
        if (newNormalLpFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidConfig();
        }
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (_poolStates[poolId].lessee != address(0)) {
            revert LeaseAlreadyActive();
        }
        config.normalLpFee = newNormalLpFee;
        IRevertHookDynamicFee(hook).updateDynamicLPFee(key, newNormalLpFee);
        emit NormalLpFeeSet(poolId, newNormalLpFee);
    }

    /// @notice Owner wind-down step for a lease whose prepaid rent has run out but whose lessee
    ///         never exits: refunds the price deposit (plus any rent dust) to the lessee's
    ///         pull-refund escrow and frees the slot. Only once leasing is disabled and the
    ///         lease is rent-insolvent, so an actively paying lessee can never be evicted.
    function evictLease(PoolKey calldata key) external nonReentrant returns (uint256 refund) {
        _checkOwner();
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (config.leasingEnabled) {
            revert LeasingDisabled();
        }
        PoolLeaseState storage state = _poolStates[poolId];
        address lessee = state.lessee;
        if (lessee == address(0)) {
            revert NoActiveLease();
        }
        _addPending(state, _accrue(poolId, config, state));
        // same strict boundary as the discount: at paidThrough the lease no longer covers rent
        if (block.timestamp < state.paidThrough) {
            revert LeaseStillSolvent();
        }

        refund = uint256(state.price) + state.rentBalance;
        _clearLease(state);
        if (refund != 0) {
            refunds[config.auctionCurrency][lessee] += refund;
            emit RefundEscrowed(poolId, config.auctionCurrency, lessee, refund);
        }
        emit LeaseEvicted(poolId, lessee, refund);
    }

    /// @notice Owner rescue for pending-donation value that can no longer be delivered (e.g. a
    ///         zero-liquidity pool or a broken auction currency). Credits the refund escrow of
    ///         `recipient` instead of transferring - same policy as HookAuctionController. Only
    ///         once leasing is wound down and no lease is active, so it cannot pre-empt normal
    ///         dripping to LPs.
    function sweepPendingDonation(PoolKey calldata key, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _checkOwner();
        if (recipient == address(0)) {
            revert InvalidConfig();
        }
        PoolId poolId = key.toId();
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (config.leasingEnabled) {
            revert LeasingDisabled();
        }
        PoolLeaseState storage state = _poolStates[poolId];
        if (state.lessee != address(0)) {
            revert LeaseAlreadyActive();
        }

        amount = state.pendingDonation;
        if (amount == 0) {
            revert NothingToClaim();
        }
        state.pendingDonation = 0;
        state.hasPending = false;
        refunds[config.auctionCurrency][recipient] += amount;
        emit PendingDonationSwept(poolId, config.auctionCurrency, recipient, amount);
    }

    // ==================== Views ====================

    function getPoolLeaseConfig(PoolId poolId) external view returns (PoolLeaseConfig memory) {
        return _poolConfigs[poolId];
    }

    function getPoolLeaseState(PoolId poolId)
        external
        view
        returns (
            address lessee,
            address executor,
            uint256 price,
            uint256 rentBalance,
            uint64 lastAccrualTime,
            uint40 paidThrough,
            uint256 pendingDonation
        )
    {
        PoolLeaseState storage state = _poolStates[poolId];
        return (
            state.lessee,
            state.executor,
            state.price,
            state.rentBalance,
            state.lastAccrualTime,
            state.paidThrough,
            state.pendingDonation
        );
    }

    /// @notice Whether a pool has a lease configuration (independent of any activity).
    function isConfigured(PoolId poolId) external view returns (bool) {
        return _isConfigured(_poolConfigs[poolId]);
    }

    /// @notice The slot-0 hot-path fields (see PoolLeaseState). Exposed so the invariant suite
    ///         and off-chain monitoring can verify them against the rest of the state.
    function getHotPathState(PoolId poolId)
        external
        view
        returns (address executor, uint40 paidThrough, uint40 lastDripTime, bool hasPending)
    {
        PoolLeaseState storage state = _poolStates[poolId];
        return (state.executor, state.paidThrough, state.lastDripTime, state.hasPending);
    }

    /// @notice The lessee whose executor receives the fee discount RIGHT NOW (rent-solvency
    ///         aware), matching what beforeSwap applies.
    function getActiveLessee(PoolId poolId)
        external
        view
        returns (address lessee, address executor, uint256 price, uint24 lpFee)
    {
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        PoolLeaseState storage state = _poolStates[poolId];
        if (!_isRunning(config) || state.executor == address(0) || block.timestamp >= state.paidThrough) {
            return (address(0), address(0), 0, 0);
        }
        return (state.lessee, state.executor, state.price, _discountedLpFee(config));
    }

    /// @notice Minimum accepted buyout price for a pool's active lease.
    function minBuyoutPrice(PoolId poolId) public view returns (uint256) {
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        PoolLeaseState storage state = _poolStates[poolId];
        if (state.lessee == address(0)) {
            revert NoActiveLease();
        }
        // saturate at the escrow cap: an incumbent at (or bumped past) the cap is contestable
        // at the cap itself - equal price - so no price makes the slot un-buyoutable
        uint256 required = uint256(state.price) + _buyoutBump(config, state.price);
        return required > MAX_ESCROW_AMOUNT ? MAX_ESCROW_AMOUNT : required;
    }

    /// @notice Current rent per second of a pool's active lease.
    function rentPerSecond(PoolId poolId) external view returns (uint256) {
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        return _rentPerSecond(config, _poolStates[poolId].price);
    }

    /// @notice The LP fee the lessee's executor pays on this pool.
    function discountedLpFee(PoolId poolId) external view returns (uint24) {
        PoolLeaseConfig storage config = _poolConfigs[poolId];
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        return _discountedLpFee(config);
    }

    // ==================== Internal: lease machine ====================

    function _isConfigured(PoolLeaseConfig storage config) internal view returns (bool) {
        return config.minDripSeconds != 0;
    }

    function _isRunning(PoolLeaseConfig storage config) internal view returns (bool) {
        return _isConfigured(config) && block.timestamp >= config.startTime;
    }

    function _checkLeaseActionAllowed(PoolLeaseConfig storage config) internal view {
        if (!_isConfigured(config)) {
            revert PoolNotConfigured();
        }
        if (!config.leasingEnabled) {
            revert LeasingDisabled();
        }
        if (block.timestamp < config.startTime) {
            revert LeasingNotStarted();
        }
    }

    function _checkExecutor(address executor) internal view {
        if (
            executor == address(0) || executor == address(poolManager) || executor == address(this)
                || executor == hook || executorDenied[executor]
        ) {
            revert InvalidExecutor();
        }
    }

    function _requireLessee(PoolId poolId) internal view returns (PoolLeaseState storage state) {
        state = _poolStates[poolId];
        if (state.lessee != msg.sender) {
            revert NotLessee();
        }
    }

    function _discountedLpFee(PoolLeaseConfig storage config) internal view returns (uint24) {
        return uint24(uint256(config.normalLpFee) - uint256(config.normalLpFee) * config.feeDiscountPpm / PPM);
    }

    /// @dev Self-assessed prices are capped at MAX_ESCROW_AMOUNT; minBuyoutPrice saturates at
    ///      the same cap (a bump-headroom requirement here would only move the un-buyoutable
    ///      price one level down - any finite cap has a top), so the top price stays contestable.
    function _checkPrice(uint256 price) internal pure {
        if (price == 0 || price > MAX_ESCROW_AMOUNT) {
            revert InvalidPrice();
        }
    }

    function _buyoutBump(PoolLeaseConfig storage config, uint256 price) internal view returns (uint256) {
        uint256 bump = price * config.minBuyoutBumpPpm / PPM;
        return bump > 0 ? bump : 1;
    }

    /// @dev Rent per second, rounded UP so a nonzero price always burns rent (paidThrough stays
    ///      finite) and the lessee can never hold the slot for free.
    function _rentPerSecond(PoolLeaseConfig storage config, uint256 price) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(price, config.taxRatePerSecondX64, Q64);
    }

    /// @dev The timestamp through which `rentBalance` covers rent starting at `fromTime`.
    ///      Invariant under accrual (accruing k seconds consumes exactly k*rps), so it is only
    ///      recomputed when rentBalance, price or the tax base change. Saturates at uint40 max.
    function _paidThrough(uint256 fromTime, uint256 rentBalance, uint256 rps) internal pure returns (uint40) {
        uint256 through = fromTime + rentBalance / rps;
        return through > type(uint40).max ? type(uint40).max : uint40(through);
    }

    function _clearLease(PoolLeaseState storage state) internal {
        // slot 0: clear only the lease fields - lastDripTime and hasPending keep governing the
        // pending bucket, which may still be dripping after the lease is gone
        state.executor = address(0);
        state.paidThrough = 0;
        state.lessee = address(0);
        state.lastAccrualTime = 0;
        state.price = 0;
        state.rentBalance = 0;
    }

    /// @dev Moves rent owed since lastAccrualTime out of the lease: the protocol-fee share to
    ///      protocolFeesAccrued, the rest RETURNED for the caller to deliver - _accrueAndDrip
    ///      donates it directly to the in-range LPs who earned it, lease actions park it into
    ///      the pending bucket (`_addPending(state, _accrue(...))`).
    function _accrue(PoolId poolId, PoolLeaseConfig storage config, PoolLeaseState storage state)
        internal
        returns (uint256 netAccrued)
    {
        if (state.lessee == address(0)) {
            return 0;
        }
        uint256 elapsed = block.timestamp - state.lastAccrualTime;
        if (elapsed == 0) {
            return 0;
        }
        state.lastAccrualTime = uint64(block.timestamp);

        uint256 rentBalance = state.rentBalance;
        if (rentBalance == 0) {
            return 0;
        }
        uint256 owed = _rentPerSecond(config, state.price) * elapsed;
        if (owed > rentBalance) {
            owed = rentBalance;
        }
        state.rentBalance = uint128(rentBalance - owed);

        // carry the sub-bps remainder across accruals: fundRent-forced per-second slices would
        // otherwise floor every slice's fee to zero, starving the protocol of its share
        uint256 feeUnits = owed * config.protocolFeeBps + state.feeCarry;
        uint256 protocolFee = feeUnits / BPS_DENOMINATOR;
        state.feeCarry = uint16(feeUnits % BPS_DENOMINATOR);
        if (protocolFee != 0) {
            protocolFeesAccrued[config.auctionCurrency][config.protocolFeeRecipient] += protocolFee;
        }
        emit RentAccrued(poolId, owed, protocolFee, state.rentBalance);
        // protocolFee <= owed always (bps <= 2000, carry < 10000: even owed == 1 yields fee <= 1)
        return owed - protocolFee;
    }

    /// @dev Adds to the pending bucket, maintaining the hasPending slot-0 mirror and
    ///      (re)initializing the drip clock whenever the bucket transitions from empty to
    ///      non-empty. Without this, a lastDripTime left stale by a long-drained previous
    ///      bucket would let the first drip of a fresh bucket compute a full-horizon elapsed
    ///      interval and release the entire new bucket to a same-block JIT position.
    function _addPending(PoolLeaseState storage state, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        if (state.pendingDonation == 0) {
            state.hasPending = true;
            state.lastDripTime = uint40(block.timestamp);
        }
        state.pendingDonation += amount;
    }

    // ==================== Internal: dripping ====================

    /// @dev Two delivery streams, mirroring HookAuctionController's design:
    ///      1) FRESH rent (accrued since the last touch) donates DIRECTLY to the current
    ///         in-range LPs - they are exactly who earned it: every liquidity change is itself
    ///         a touch, so the set was constant over the accrual window, and a JIT's own mint
    ///         touch pays the incumbents before its liquidity registers. This is what lets a
    ///         departing LP (beforeRemoveLiquidity) collect the rent of its own tenure.
    ///      2) The PENDING bucket - value that could not be delivered (zero liquidity, failed
    ///         donates, lease-action accruals) - releases gradually: throttled by
    ///         minDripSeconds, bounded to (elapsed / dripHorizonSeconds) per release, clock
    ///         (re)initialized on every empty-to-nonempty transition and advanced over
    ///         zero-liquidity stretches, so no stale interval can dump the bucket to a JIT.
    ///      The shared throttle runs FIRST, from state slot 0 alone, so throttled touches skip
    ///      the accrual math and every further storage read; accrual is time-based, so deferring
    ///      it to the next unthrottled touch loses nothing (a topology change inside a throttle
    ///      window shifts at most minDripSeconds of rent - the slice granularity everywhere).
    function _accrueAndDrip(
        PoolKey memory key,
        PoolId poolId,
        PoolLeaseConfig storage config,
        PoolLeaseState storage state
    ) internal returns (uint256 amountToDonate) {
        uint40 last = state.lastDripTime;
        if (last != 0 && block.timestamp < uint256(last) + config.minDripSeconds) {
            return 0;
        }

        uint256 fresh;
        if (state.executor != address(0)) {
            fresh = _accrue(poolId, config, state);
        }

        bool zeroLiquidity = StateLibrary.getLiquidity(poolManager, poolId) == 0;

        // 1) old bucket first (so the fresh rent cannot inflate this release), measured from
        //    the pre-touch clock; hasPending implies last != 0 and, since this touch passed the
        //    throttle, elapsed >= minDripSeconds
        if (state.hasPending && !zeroLiquidity) {
            uint256 pending = state.pendingDonation;
            uint256 elapsed = block.timestamp - uint256(last);
            if (elapsed > config.dripHorizonSeconds) {
                elapsed = config.dripHorizonSeconds; // cap the catch-up at one horizon's worth
            }
            // round UP so every release moves at least one base unit - the bucket self-drains
            // without a flush-on-zero branch, which for a small bucket against a long horizon
            // (e.g. low-decimal currencies) would dump the whole bucket to the first LP
            uint256 release = FullMath.mulDivRoundingUp(pending, elapsed, config.dripHorizonSeconds);
            if (release > pending) {
                release = pending;
            }
            if (release > MAX_ESCROW_AMOUNT) {
                release = MAX_ESCROW_AMOUNT; // keep each donate within int128 range
            }
            uint256 released = _donate(key, poolId, config, release);
            if (released != 0) {
                uint256 pendingRemaining = pending - released;
                state.pendingDonation = pendingRemaining;
                if (pendingRemaining == 0) {
                    state.hasPending = false;
                }
                amountToDonate = released;
                emit PendingDonationDripped(poolId, released, pendingRemaining);
            }
            // on a failed release the value stays pending; the clock update below backs off
            // for minDripSeconds instead of re-paying the failed transfer on every touch
        }

        // 2) fresh rent: straight to the LPs who were in range while it accrued; park it only
        //    when it cannot be delivered
        if (fresh != 0) {
            uint256 freshDonated;
            if (!zeroLiquidity) {
                freshDonated = _donate(key, poolId, config, fresh);
                if (freshDonated != 0) {
                    amountToDonate += freshDonated;
                    emit RentDripped(poolId, freshDonated);
                }
            }
            if (freshDonated != fresh) {
                _addPending(state, fresh - freshDonated);
            }
        }

        // one shared clock update: throttles the next touch, backs off after failed donates,
        // and advances over zero-liquidity stretches (so they never become catch-up slices)
        if (fresh != 0 || state.hasPending) {
            state.lastDripTime = uint40(block.timestamp);
        }
    }

    /// @dev Donates `amount` of the auction currency to the pool's in-range liquidity.
    ///      Returns 0 - without reverting - if the donate/settle leg reverts (e.g. a
    ///      blacklisting or fee-on-transfer auction currency); the undonated value stays pending.
    function _donate(PoolKey memory key, PoolId poolId, PoolLeaseConfig storage config, uint256 amount)
        internal
        returns (uint256 amountToDonate)
    {
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
    ///      Runs inside the same PoolManager unlock as the caller. Verifies BOTH sides of the
    ///      transfer exactly - see HookAuctionController.donateExternal for the full rationale.
    function donateExternal(PoolKey calldata key, Currency currency, uint256 amount) external {
        if (msg.sender != address(this)) {
            revert Unauthorized();
        }
        bool isCurrency0 = currency == key.currency0;
        poolManager.donate(key, isCurrency0 ? amount : 0, isCurrency0 ? 0 : amount, "");

        poolManager.sync(currency);
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount) {
            revert ExactTransferFailed();
        }
        if (balanceBefore - token.balanceOf(address(this)) != amount) {
            revert ExactTransferFailed();
        }
    }

    // ==================== Internal: token movement ====================

    /// @dev Pulls `amount` from msg.sender, reverting unless this contract's balance increases by
    ///      exactly `amount` (fee-on-transfer deposits would corrupt the escrow accounting).
    function _pullExact(Currency currency, uint256 amount) internal {
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - balanceBefore != amount) {
            revert ExactTransferFailed();
        }
    }

    /// @dev Transfers `amount` out, reverting unless this contract's balance decreases by exactly
    ///      `amount` - a sender-side surcharge would silently consume funds backing the other
    ///      escrowed obligations (deposits, refunds, protocol fees, pending donations).
    function _transferOutExact(Currency currency, address recipient, uint256 amount) internal {
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransfer(recipient, amount);
        if (balanceBefore - token.balanceOf(address(this)) != amount) {
            revert ExactTransferFailed();
        }
    }
}
