// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {NativeAssetLib} from "../shared/NativeAssetLib.sol";
import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {RevertHookLookupBase} from "./RevertHookLookupBase.sol";
import {RevertHookSwapActions} from "./RevertHookSwapActions.sol";

/// @title RevertHookActionBase
/// @notice Base contract with shared helper functions for RevertHook action targets
/// @dev Inherits from RevertHookLookupBase for shared state access and trigger management
abstract contract RevertHookActionBase is RevertHookLookupBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error SwapPoolPriceOutOfBounds(int24 swapTick, int24 oracleTick);
    error RemovalConsumedByFees();

    struct SwapPlan {
        PoolKey poolKey;
        bool zeroForOne;
        uint256 amountIn;
        bool isExternalRoute;
    }

    IPermit2 internal immutable permit2;
    IPositionManager internal immutable positionManager;
    IWETH9 internal immutable weth;
    IV4Oracle internal immutable v4Oracle;
    ILiquidityCalculator internal immutable liquidityCalculator;
    IPoolManager internal immutable poolManager;
    IHookRouteController internal immutable hookRouteController;
    RevertHookSwapActions internal immutable swapActions;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookRouteController _hookRouteController,
        RevertHookSwapActions _swapActions
    ) {
        positionManager = _v4Oracle.positionManager();
        weth = NativeWrapper(payable(address(positionManager))).WETH9();
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;
        poolManager = _v4Oracle.poolManager();
        hookRouteController = _hookRouteController;
        swapActions = _swapActions;
    }

    function _positionManagerRef() internal view override returns (IPositionManager) {
        return positionManager;
    }

    function _poolManagerRef() internal view override returns (IPoolManager) {
        return poolManager;
    }

    // ==================== Auth Helpers ====================

    /// @notice Validates that the caller may run an action on the position with the supplied pool key
    /// @dev Two callers exist. The hook's own delegatecalls arrive with the PoolManager as msg.sender
    ///      (afterSwap or unlockCallback) and a key taken from the position's own trigger list. A
    ///      registered vault arrives while executing the transform the hook started for this token
    ///      (RevertHookExecution._transformViaVault); the transient marker set there is required, so
    ///      a borrower's own `vault.transform` with the hook as transformer is refused, and the
    ///      caller-supplied key is bound to the position, so the whole-balance sweeps that follow can
    ///      only ever touch the position's own currencies (C-01).
    function _requireAuthorization(PoolKey memory poolKey, uint256 tokenId) internal view {
        if (msg.sender == address(poolManager)) {
            return;
        }
        if (!_vaults[msg.sender] || _hookTransformToken() != tokenId) {
            revert Unauthorized();
        }
        _validateCaller(positionManager, tokenId);
        (PoolKey memory positionKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(positionKey.toId()) != PoolId.unwrap(poolKey.toId())) {
            revert Unauthorized();
        }
    }

    // ==================== Pool Key Helpers ====================

    /// @notice Resolves the protocol-managed swap pool for a direction and reports whether it matches the source pool
    function _resolveSwapPool(PoolKey memory poolKey, bool zeroForOne)
        internal
        view
        returns (PoolKey memory swapPool, bool isSamePool)
    {
        address tokenIn = Currency.unwrap(zeroForOne ? poolKey.currency0 : poolKey.currency1);
        address tokenOut = Currency.unwrap(zeroForOne ? poolKey.currency1 : poolKey.currency0);
        (bool hasRoute, uint24 fee, int24 tickSpacing, IHooks hooks) = hookRouteController.route(tokenIn, tokenOut);
        if (!hasRoute) {
            return (poolKey, true);
        }
        swapPool = PoolKey({
            currency0: poolKey.currency0, currency1: poolKey.currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks
        });
        isSamePool = _isSamePoolConfig(poolKey, swapPool);
    }

    function _isSamePoolConfig(PoolKey memory lhs, PoolKey memory rhs) internal pure returns (bool) {
        return lhs.hooks == rhs.hooks && lhs.fee == rhs.fee && lhs.tickSpacing == rhs.tickSpacing;
    }

    // ==================== Position Config Helpers ====================

    /// @notice Copies configuration from one position to a new position
    function _copyPositionConfig(uint256 newTokenId, PositionConfig storage oldConfig) internal {
        _positionConfigs[newTokenId] = oldConfig;
        if (_positionStates[newTokenId].lastActivated == 0) {
            _positionStates[newTokenId].lastActivated = uint32(block.timestamp);
        }
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(newTokenId);
        if (PositionModeFlags.hasAutoLeverage(oldConfig.modeFlags)) {
            int24 currentTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);
            _positionStates[newTokenId].autoLeverageBaseTick = currentTick;
        }
        _addPositionTriggers(newTokenId, poolKey);
        emit SetPositionConfig(newTokenId, _positionConfigs[newTokenId]);
    }

    /// @notice Migrates configuration from an old position to its reminted replacement
    /// @dev No live-tick trigger check here, unlike the vault remint path: an AUTO_RANGE
    ///      replacement whose trigger would already be satisfied in the bucket it fired from is
    ///      refused at configuration time (_validateRangeConfig, V4LE-16), and a trigger the
    ///      action's own swap carried the price past sits strictly beyond the fired bucket, where the
    ///      continued walk consumes it in the same swap. The AUTO_LEND re-entry mint places its
    ///      deposit trigger by construction one spacing away from the price and is left as is.
    function _migrateRemintedPosition(uint256 tokenId, uint256 newTokenId) internal {
        // auto-lend accounting never follows a remint (see migrateVaultPosition); callers reset or
        // never hold shares here, so this only guards against a future path stranding them
        if (_positionStates[tokenId].autoLendShares != 0) {
            revert SharesOutstanding();
        }
        _swapProtectionConfigs[newTokenId] = _swapProtectionConfigs[tokenId];
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(newTokenId);
        _migratePendingProtocolFee(poolKey, tokenId, newTokenId);
        _copyPositionConfig(newTokenId, _positionConfigs[tokenId]);
        _disablePosition(tokenId);
    }

    // ==================== Swap Helpers ====================

    /// @notice Calculates optimal swap and executes it for liquidity provision
    function _calculateAndSwap(
        uint256 tokenId,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        Mode mode
    ) internal returns (uint256, uint256) {
        SwapPlan memory swapPlan = _buildSwapPlan(poolKey, tickLower, tickUpper, amount0, amount1, mode);
        if (swapPlan.amountIn > 0) {
            return _applyBalanceDelta(
                _executeSwapResolved(
                    swapPlan.poolKey, swapPlan.zeroForOne, swapPlan.amountIn, tokenId, mode, swapPlan.isExternalRoute
                ),
                amount0,
                amount1
            );
        }
        return (amount0, amount1);
    }

    function _buildSwapPlan(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        Mode mode
    ) internal view returns (SwapPlan memory plan) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());

        plan.zeroForOne = _determineSwapDirection(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        bool isSamePool;
        (plan.poolKey, isSamePool) = _resolveSwapPool(poolKey, plan.zeroForOne);
        plan.isExternalRoute = !isSamePool;

        // Sized against the route's depth and net of the hook's output fee; see
        // RevertHookSwapActions.planExternalRoute.
        (plan.amountIn, plan.zeroForOne) = swapActions.planExternalRoute(
            liquidityCalculator, sqrtPriceX96, plan.poolKey, tickLower, tickUpper, amount0, amount1, mode, isSamePool
        );
    }

    function _determineSwapDirection(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (bool) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtPriceX96 <= sqrtLower) {
            return false;
        }
        if (sqrtPriceX96 >= sqrtUpper) {
            return true;
        }

        return FullMath.mulDiv(
            FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96 - sqrtLower, FixedPoint96.Q96
        ) > FullMath.mulDiv(amount1, sqrtUpper - sqrtPriceX96, sqrtUpper);
    }

    /// @notice Executes a swap on the pool manager
    function _executeSwap(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn, uint256 tokenId, Mode mode)
        internal
        returns (BalanceDelta delta)
    {
        (PoolKey memory swapPool, bool isSamePool) = _resolveSwapPool(poolKey, zeroForOne);
        return _executeSwapResolved(swapPool, zeroForOne, amountIn, tokenId, mode, !isSamePool);
    }

    function _executeSwapResolved(
        PoolKey memory swapPool,
        bool zeroForOne,
        uint256 amountIn,
        uint256 tokenId,
        Mode mode,
        bool validateOracle
    ) internal returns (BalanceDelta delta) {
        // AUTO_COLLECT is the one mode that never arms a trigger (PositionModeFlags.hasTriggers
        // ignores it), so its swaps are only ever reached through the permissionless `autoCollect`
        // entry point, outside the oracle-bounded traversal in _afterSwap. Price-check them here
        // too - both the same-pool ratio swap and the HARVEST single-side swap - so a caller cannot
        // manipulate the pool first and force a position's collected fees through it.
        if (validateOracle || mode == Mode.AUTO_COLLECT) _validateSwapPoolPrice(swapPool);
        (bool success, bytes memory returndata) = address(swapActions)
            .delegatecall(
                abi.encodeCall(RevertHookSwapActions.executeSwap, (swapPool, zeroForOne, amountIn, tokenId, mode))
            );
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        delta = abi.decode(returndata, (BalanceDelta));
    }

    /// @dev Trigger traversal bounds the position pool against the oracle, but a configured external
    ///      route is a different pool and is not covered by that check, and permissionless
    ///      `autoCollect` swaps never pass through traversal at all. Validate the execution pool's
    ///      spot price immediately before use in both cases.
    function _validateSwapPoolPrice(PoolKey memory swapPool) internal view {
        (uint160 swapSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, swapPool.toId());
        if (swapSqrtPriceX96 == 0) revert ILiquidityCalculator.Invalid_Pool();

        uint160 oracleSqrtPriceX96 =
            v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(swapPool.currency0), Currency.unwrap(swapPool.currency1));
        int24 swapTick = TickMath.getTickAtSqrtPrice(swapSqrtPriceX96);
        int24 oracleTick = TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96);
        int256 tickDifference = int256(swapTick) - int256(oracleTick);
        if (tickDifference < 0) tickDifference = -tickDifference;
        if (_maxTicksFromOracle < 0 || tickDifference > int256(_maxTicksFromOracle)) {
            revert SwapPoolPriceOutOfBounds(swapTick, oracleTick);
        }
    }

    // ==================== Liquidity Helpers ====================

    function _calculateLiquidityForRange(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal view returns (uint128) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
    }

    function _modifyLiquiditiesWithPair(
        bytes memory actions,
        bytes memory primaryParams,
        Currency currency0,
        Currency currency1,
        uint256 nativeValue
    ) internal returns (bool success) {
        (bool ok, bytes memory result) = address(swapActions).delegatecall(abi.encodeCall(
            swapActions.modifyLiquiditiesWithPair,
            (positionManager, actions, primaryParams, currency0, currency1, nativeValue)
        ));
        if (!ok) {
            assembly ("memory-safe") { revert(add(result,32),mload(result)) }
        }
        return abi.decode(result,(bool));
    }

    /// @notice Increases liquidity for a position
    function _increaseLiquidity(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal returns (uint256, uint256) {
        uint128 liquidity = _calculateLiquidityForRange(
            poolKey, positionInfo.tickLower(), positionInfo.tickUpper(), amount0Max, amount1Max
        );

        if (liquidity == 0) return (0, 0);

        uint256 balance0Before = _sweepableBalance(poolKey.currency0);
        uint256 balance1Before = _sweepableBalance(poolKey.currency1);
        uint256 nativeValue = NativeAssetLib.nativeValue(poolKey.currency0, poolKey.currency1, amount0Max, amount1Max);

        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        if (_modifyLiquiditiesWithPair(
                actions,
                abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, bytes("")),
                poolKey.currency0,
                poolKey.currency1,
                nativeValue
            )) {
            return (
                balance0Before - _sweepableBalance(poolKey.currency0),
                balance1Before - _sweepableBalance(poolKey.currency1)
            );
        }
        return (0, 0);
    }

    /// @notice Mints a new position
    function _mintPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) internal returns (uint256 newTokenId, uint256 amount0Used, uint256 amount1Used) {
        newTokenId = positionManager.nextTokenId();
        amount0Used = _sweepableBalance(poolKey.currency0);
        amount1Used = _sweepableBalance(poolKey.currency1);

        uint128 liquidity = _calculateLiquidityForRange(poolKey, tickLower, tickUpper, amount0Max, amount1Max);
        if (liquidity == 0) {
            return (0, 0, 0);
        }

        uint256 nativeValue = NativeAssetLib.nativeValue(poolKey.currency0, poolKey.currency1, amount0Max, amount1Max);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        if (_modifyLiquiditiesWithPair(
                actions,
                abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, bytes("")),
                poolKey.currency0,
                poolKey.currency1,
                nativeValue
            )) {
            amount0Used -= _sweepableBalance(poolKey.currency0);
            amount1Used -= _sweepableBalance(poolKey.currency1);
            if (_vaults[recipient]) {
                IVault(recipient).notifyERC721Received(newTokenId, recipient);
            }
        } else {
            newTokenId = 0;
            amount0Used = 0;
            amount1Used = 0;
        }
    }

    /// @notice Decreases liquidity from a position (optionally only fees)
    /// @dev Hook action accounting intentionally works on whole self-balances after TAKE_PAIR.
    ///      Successful flows are expected to drain the hook back to zero, so the returned amounts
    ///      represent all balances currently attributable to the action. If unsolicited balances
    ///      are present, they will be swept by the next execution by design.
    /// @dev A full removal that succeeds but credits nothing in either currency means the
    ///      position's legacy carried protocol fee consumed the
    ///      whole principal inside the remove callback. Every caller treats `(0, 0)` as a soft
    ///      failure and returns, which is right when the removal itself failed (nothing changed)
    ///      but would otherwise leave an emptied NFT behind with no shares, no remint and no exit
    ///      proceeds (V4LE-41). Revert instead so the action rolls back: direct actions run under
    ///      a caught delegatecall, vault-backed ones inside a caught vault transform, so this only
    ///      fails the action (HookActionFailed); the owner can settle fees with a fee-paying INCREASE(0).
    function _decreaseLiquidity(PoolKey memory poolKey, uint256 tokenId, bool feesOnly)
        internal
        returns (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = feesOnly ? 0 : positionManager.getPositionLiquidity(tokenId);
        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;

        bytes memory actions = abi.encodePacked(
            feesOnly ? uint8(Actions.INCREASE_LIQUIDITY) : uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)
        );
        if (_modifyLiquiditiesWithPair(
                actions,
                abi.encode(
                    tokenId, liquidity, feesOnly ? type(uint128).max : 0, feesOnly ? type(uint128).max : 0, bytes("")
                ),
                currency0,
                currency1,
                0
            )) {
            amount0 = _sweepableBalance(currency0);
            amount1 = _sweepableBalance(currency1);
            if (liquidity != 0 && amount0 == 0 && amount1 == 0) {
                revert RemovalConsumedByFees();
            }
        }
    }

    /// @notice Decreases a partial amount of liquidity from a position
    function _decreaseLiquidityPartial(PoolKey memory poolKey, uint256 tokenId, uint128 liquidityToRemove)
        internal
        returns (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1)
    {
        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        if (_modifyLiquiditiesWithPair(
                actions, abi.encode(tokenId, liquidityToRemove, 0, 0, bytes("")), currency0, currency1, 0
            )) {
            amount0 = _sweepableBalance(currency0);
            amount1 = _sweepableBalance(currency1);
        }
    }

    // ==================== Token Transfer Helpers ====================

    /// @notice Balance of `currency` the running action may treat as its own
    /// @dev Whole-balance accounting (see the sweep helpers below) minus the ERC4626 shares the
    ///      hook custodies for auto-lend positions when `currency` is such a share token. A pool
    ///      whose currency is a registered lend vault's share token can therefore never pay another
    ///      position's shares out as fees or leftovers (M-01).
    function _sweepableBalance(Currency currency) internal view returns (uint256 amount) {
        amount = currency.balanceOfSelf();
        uint256 custodied = _custodiedShares[Currency.unwrap(currency)];
        if (custodied != 0) {
            amount = amount > custodied ? amount - custodied : 0;
        }
    }

    /// @notice Sends leftover tokens to the recipient
    /// @dev Intentionally sweeps the entire remaining balance for each pool token. The hook's
    ///      accounting model assumes successful executions leave no residual balances behind.
    function _sendLeftoverTokens(uint256 tokenId, Currency currency0, Currency currency1, address recipient) internal {
        uint256 amount0 = _sweepableBalance(currency0);
        uint256 amount1 = _sweepableBalance(currency1);
        if (amount0 > 0) currency0.transfer(recipient, amount0);
        if (amount1 > 0) currency1.transfer(recipient, amount1);
        emit SendLeftoverTokens(tokenId, currency0, currency1, amount0, amount1, recipient);
    }

    /// @notice Approves tokens for the position manager via permit2
    function _approveToken(Currency currency, uint256 amount) internal {
        if (amount > 0 && !currency.isAddressZero()) {
            address tokenAddress = Currency.unwrap(currency);
            if (!_permit2Approved[tokenAddress]) {
                SafeERC20.forceApprove(IERC20(tokenAddress), address(permit2), type(uint256).max);
                permit2.approve(tokenAddress, address(positionManager), type(uint160).max, type(uint48).max);
                _permit2Approved[tokenAddress] = true;
            }
        }
    }

    function _approvePair(Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) internal {
        _approveToken(currency0, amount0);
        _approveToken(currency1, amount1);
    }

    /// @notice Swaps tokens to the lend token
    /// @dev Returns the full lend-token balance after the swap. This is intentional so later
    ///      repayment/leftover handling operates on the hook's complete transient balance for
    ///      the position rather than tracking per-step deltas inside the action flow.
    function _swapToLendToken(
        uint256 tokenId,
        PoolKey memory poolKey,
        Currency lendToken,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        Mode mode
    ) internal returns (uint256) {
        if (lendToken == currency0) {
            if (amount1 > 0) {
                _executeSwap(poolKey, false, amount1, tokenId, mode);
            }
            return _sweepableBalance(currency0);
        } else {
            if (amount0 > 0) {
                _executeSwap(poolKey, true, amount0, tokenId, mode);
            }
            return _sweepableBalance(currency1);
        }
    }

    /// @notice Resolves the pool currency a vault's asset is held as inside this pool
    /// @dev The oracle, the vaults and NativeAssetLib treat WETH as the alias of native ETH, so a
    ///      WETH-asset vault position in a native pool is a supported shape: the lend currency is the
    ///      pool's native side and the borrow/repay legs wrap and unwrap at the vault boundary
    ///      (V4LE-49). Native always sorts as currency0. `inPool` is false when the asset is neither
    ///      pool currency nor that alias; the returned currency is then the raw asset.
    function _lendCurrency(PoolKey memory poolKey, address lendAsset)
        internal
        view
        returns (Currency lendCurrency, bool inPool)
    {
        if (lendAsset == Currency.unwrap(poolKey.currency0)) return (poolKey.currency0, true);
        if (lendAsset == Currency.unwrap(poolKey.currency1)) return (poolKey.currency1, true);
        if (lendAsset == address(weth) && poolKey.currency0.isAddressZero()) return (poolKey.currency0, true);
        return (Currency.wrap(lendAsset), false);
    }

    /// @notice Repays debt to a vault up to the available amount
    /// @param tokenId The position token ID
    /// @param vault The vault to repay to
    /// @param lendCurrency The pool currency the repayment is held as (native for a WETH vault
    ///        in a native pool; wrapped here before the vault pulls WETH)
    /// @param lendAsset The vault's asset
    /// @param availableAmount The amount available for repayment
    /// @param currentDebt The current debt amount
    /// @return repaidAmount The amount that was actually repaid
    function _repayDebtToVault(
        uint256 tokenId,
        IVault vault,
        Currency lendCurrency,
        address lendAsset,
        uint256 availableAmount,
        uint256 currentDebt
    ) internal returns (uint256 repaidAmount) {
        if (availableAmount > 0 && currentDebt > 0) {
            repaidAmount = availableAmount > currentDebt ? currentDebt : availableAmount;
            if (lendCurrency.isAddressZero()) {
                weth.deposit{value: repaidAmount}();
            }
            SafeERC20.forceApprove(IERC20(lendAsset), address(vault), repaidAmount);
            vault.repay(tokenId, repaidAmount, false);
        }
    }

    // ==================== Balance Delta Helpers ====================

    /// @notice Applies a balance delta to amounts
    function _applyBalanceDelta(BalanceDelta delta, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256, uint256)
    {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        return (
            // forge-lint: disable-next-line(unsafe-typecast)
            delta0 < 0 ? amount0 - uint256(int256(-delta0)) : amount0 + uint256(int256(delta0)),
            // forge-lint: disable-next-line(unsafe-typecast)
            delta1 < 0 ? amount1 - uint256(int256(-delta1)) : amount1 + uint256(int256(delta1))
        );
    }
}
