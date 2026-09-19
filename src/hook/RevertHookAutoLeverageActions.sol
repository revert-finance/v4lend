// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ILiquidityCalculator} from "../shared/math/LiquidityCalculator.sol";
import {IVault} from "../vault/interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoLeverageLib} from "../shared/planning/AutoLeverageLib.sol";
import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookActionBase} from "./RevertHookActionBase.sol";
import {RevertHookSwapActions} from "./RevertHookSwapActions.sol";

/// @title RevertHookAutoLeverageActions
/// @notice Contains auto-leverage functions for RevertHook (called via delegatecall)
contract RevertHookAutoLeverageActions is RevertHookActionBase {
    using PoolIdLibrary for PoolKey;

    error RestoreFailed();
    error NoImprovement();

    /// @dev Address of this sidecar; equal to address(this) only when called directly, which the
    ///      externals below reject so that a direct call cannot touch this contract's own storage.
    address private immutable _selfAddress;

    constructor(
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookRouteController _hookRouteController,
        RevertHookSwapActions _swapActions
    ) RevertHookActionBase(_permit2, _v4Oracle, _liquidityCalculator, _hookRouteController, _swapActions) {
        _selfAddress = address(this);
    }

    // ==================== Remint migration ====================

    /// @notice Moves token-id keyed automation state from a vault position to the position that
    ///         replaced it inside the vault's current transform (e.g. a V4Utils CHANGE_RANGE).
    ///         Reached through the hook via delegatecall, so msg.sender is the calling vault.
    /// @dev Only a registered vault may call this, and only while its `transformedTokenId` is the
    ///      replacement, which binds the call to that transaction; both NFTs must sit in the vault
    ///      and the old position must be in one of this hook's pools. If the replacement is not
    ///      (another hook, no hook, another pair) the old token's automation is retired and nothing
    ///      else happens; otherwise swap protection and the carried fee follow across the pair and
    ///      automation itself only follows a remint inside the same pool. Because pool and owner are
    ///      unchanged, tick alignment and mode-flag validity carry over from when the config was set;
    ///      only the range-dependent auto-range rules are re-checked, and a config that no longer
    ///      fits reverts the whole transform so the owner reconfigures or disables automation before
    ///      moving range instead of ending up unprotected. A position without automation has nothing
    ///      to migrate and is left untouched, so it never starts accruing active time. Old trigger
    ///      nodes are cleared explicitly because a partial removal leaves them armed.
    /// @dev Scope: this entry serves vault-held positions. A direct (non-vault) V4Utils `CHANGE_RANGE`
    ///      reaches the same migration through the mint callback instead, when the caller names the
    ///      old token in the mint hookData (see afterAddLiquidity); without that opt-in the replacement
    ///      starts without automation - see AUDIT-ACCEPTED-NONVAULT-REMINT-AUTOMATION-LOSS in V4Utils.
    function migrateVaultPosition(uint256 oldTokenId, uint256 newTokenId) external {
        if (address(this) == _selfAddress) {
            revert Unauthorized();
        }
        if (!_vaults[msg.sender] || oldTokenId == newTokenId || IVault(msg.sender).transformedTokenId() != newTokenId) {
            revert Unauthorized();
        }
        IERC721 nft = IERC721(address(positionManager));
        if (nft.ownerOf(oldTokenId) != msg.sender || nft.ownerOf(newTokenId) != msg.sender) {
            revert Unauthorized();
        }
        _migratePositionState(oldTokenId, newTokenId);
    }

    /// @dev Mint-callback entry to the shared migration. The minter names the position it is
    ///      replacing in the mint's `hookData` (see afterAddLiquidity) and the claim is checked with
    ///      the same ERC721 authority that let it remove the old liquidity: the locker must own or be
    ///      approved for the old token, and the new token must be in the locker's custody (V4Utils
    ///      mints to itself before forwarding) or already with the old owner. The callback also fires for
    ///      increases, so the target must be a blank slate the way a fresh mint is: no liquidity before
    ///      this add, no config, no swap protection and no carried fee of its own, so nothing of an
    ///      existing position can be overwritten or re-attributed. An address approved for a token can therefore move its config
    ///      onto a position it controls, which is no escalation: such an address can already transfer
    ///      the NFT away entirely. Vault-held positions are skipped here so the vault's own
    ///      notification (migrateVaultPosition, bound to the running transform) handles them once.
    function _migrateMintedPosition(uint256 oldTokenId, uint256 newTokenId, int256 liquidityDelta) internal {
        IERC721 nft = IERC721(address(positionManager));
        address oldOwner = nft.ownerOf(oldTokenId);
        if (_vaults[oldOwner]) {
            return;
        }
        address locker = IMsgSender(address(positionManager)).msgSender();
        bool lockerControlsOld = oldOwner == locker || nft.getApproved(oldTokenId) == locker
            || nft.isApprovedForAll(oldOwner, locker);
        if (oldTokenId == newTokenId || !lockerControlsOld) {
            revert Unauthorized();
        }
        address newOwner = nft.ownerOf(newTokenId);
        if (newOwner != locker && newOwner != oldOwner) {
            revert Unauthorized();
        }
        // Blank-slate target: the position held no liquidity before this add (a mint, or an emptied
        // position) and carries no hook state that a migration would clobber. An increase on a live
        // position is never a "replacement", whoever is authorized for it.
        PendingProtocolFee storage pending = _pendingProtocolFees[newTokenId];
        SwapProtectionConfig storage protection = _swapProtectionConfigs[newTokenId];
        if (
            liquidityDelta <= 0 || positionManager.getPositionLiquidity(newTokenId) != uint128(uint256(liquidityDelta))
                || !PositionModeFlags.isNone(_positionConfigs[newTokenId].modeFlags)
                || protection.sqrtPriceMultiplier0 != 0 || protection.sqrtPriceMultiplier1 != 0 || pending.amount0 != 0
                || pending.amount1 != 0
        ) {
            revert InvalidConfig();
        }
        _migratePositionState(oldTokenId, newTokenId);
    }

    /// @dev Shared remint migration used by the vault path and the mint-callback path once each has
    ///      authorized the pair. Refuses outstanding auto-lend shares, retires the old automation
    ///      when the replacement left this hook's pools, otherwise carries swap protection and the
    ///      deferred fee, re-validates the config for the new range, refuses an already-satisfied
    ///      trigger, disables the old token and arms the replacement above the value minimum.
    function _migratePositionState(uint256 oldTokenId, uint256 newTokenId) internal {
        // Auto-lend accounting (shares, vault, amount) is keyed by token id and every redemption
        // path authorizes through the position's owner. Once the loan has moved, nobody can force
        // the old token's exit, so its ERC4626 shares would be stranded in the hook. Refuse the
        // remint; the owner runs autoLendForceExit first. Migrating the lending state instead would
        // mean redeeming inside the vault's reentrancy-locked transform.
        if (_positionStates[oldTokenId].autoLendShares != 0) {
            revert SharesOutstanding();
        }

        (PoolKey memory oldPoolKey,) = positionManager.getPoolAndPositionInfo(oldTokenId);
        (PoolKey memory newPoolKey, PositionInfo newPositionInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        if (address(oldPoolKey.hooks) != address(this)) {
            revert Unauthorized();
        }

        PositionConfig memory config = _positionConfigs[oldTokenId];
        bool replacementStaysHere = address(newPoolKey.hooks) == address(this)
            && Currency.unwrap(oldPoolKey.currency0) == Currency.unwrap(newPoolKey.currency0)
            && Currency.unwrap(oldPoolKey.currency1) == Currency.unwrap(newPoolKey.currency1);
        if (!replacementStaysHere) {
            // The loan moved to a pool this hook does not serve (another hook, no hook, or another
            // pair), so nothing can follow it. Retire the old token's automation instead of leaving
            // trigger nodes that would only fail authorization and burn the per-swap execution
            // budget. The carried protocol fee stays on the retired token.
            if (!PositionModeFlags.isNone(config.modeFlags)) {
                _removePositionTriggersWithConfig(oldTokenId, oldPoolKey, config);
                _disablePosition(oldTokenId);
            }
            return;
        }

        // Swap protection is set independently of automation and a carried protocol fee is owed
        // regardless of it, so both follow the position even when there is no config to migrate.
        // Both are per currency pair, so they also carry across pools of the same pair.
        _swapProtectionConfigs[newTokenId] = _swapProtectionConfigs[oldTokenId];
        _migratePendingProtocolFee(newPoolKey, oldTokenId, newTokenId);

        if (PositionModeFlags.isNone(config.modeFlags)) {
            return;
        }
        // Triggers are keyed by pool, so automation only follows a remint inside the same pool.
        // A configured position moving to another fee tier must be reconfigured first.
        if (PoolId.unwrap(oldPoolKey.toId()) != PoolId.unwrap(newPoolKey.toId())) {
            revert InvalidConfig();
        }
        _validateRangeConfig(newPoolKey.tickSpacing, newPositionInfo.tickLower(), newPositionInfo.tickUpper(), config);

        // Base tick first: the trigger evaluation below reads it for auto-leverage triggers. The
        // base is recentred on the current tick, so a correction that was about to fire on the
        // old position is not carried over: the replacement waits for a fresh ten-spacing move.
        // That is the regular price-path correction model; rejecting off-target migrations would
        // block legitimate range changes on leveraged positions instead.
        if (PositionModeFlags.hasAutoLeverage(config.modeFlags)) {
            _positionStates[newTokenId].autoLeverageBaseTick =
                _getTickLower(_getCurrentTick(newPoolKey.toId()), newPoolKey.tickSpacing);
        }
        // A trigger that is already satisfied for the new range cannot execute here (the vault's
        // transform holds the reentrancy lock) and would sit behind the swap cursor until the price
        // came back, leaving the replacement unprotected. Refuse the move instead; the owner
        // reconfigures or disables automation before changing range.
        (bool alreadyTriggered,,) = _checkTriggerConditions(
            newTokenId, newPoolKey, config, newPositionInfo.tickLower(), newPositionInfo.tickUpper()
        );
        if (alreadyTriggered) {
            revert InvalidConfig();
        }

        _removePositionTriggersWithConfig(oldTokenId, oldPoolKey, config);
        _disablePosition(oldTokenId);

        _positionConfigs[newTokenId] = config;
        // Same gate as the liquidity callbacks: only positions worth automating get armed.
        (uint256 positionValueNative,,,) = v4Oracle.getValue(newTokenId, address(0));
        if (positionValueNative >= _minPositionValueNative) {
            _addPositionTriggers(newTokenId, newPoolKey);
            _activatePosition(newTokenId);
        }
        emit SetPositionConfig(newTokenId, config);
    }

    /// @notice The hook's after-add-liquidity handling past protocol fee settlement, hosted here to
    ///         keep the hook under the EIP-170 limit: optional remint migration, then activation.
    /// @dev Remint migration protocol: a mint whose `hookData` is `abi.encodePacked(REMINT_MIGRATION_TAG,
    ///      oldTokenId)` (36 bytes) names the token id this position replaces. V4Utils forwards the caller's
    ///      `increaseLiquidityHookData` as the mint hookData, so a direct range change opts in without
    ///      any transformer change; the standalone AutoRange has a `mintHookData` field for the same
    ///      purpose. Authority is checked in _migrateMintedPosition; a claim that cannot be honoured
    ///      reverts the mint, so the owner learns about it instead of minting an unautomated position.
    ///      Any other hookData - including an untagged 32-byte word another integrator may pass for its
    ///      own purposes - is ignored. Hook-internal operations (sender == hook) do nothing
    ///      here: their own flows migrate and activate explicitly.
    /// @dev Delegatecall-only: a direct call (own storage, spoofable events) is rejected.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        uint256 tokenId,
        int256 liquidityDelta,
        bytes calldata hookData
    ) external {
        if (address(this) == _selfAddress) {
            revert Unauthorized();
        }
        // defensive: sender is always the PositionManager today (see _beforeAddLiquidity note);
        // hook-internal operations run the logic below, which is idempotent by design
        if (sender == address(this)) {
            return;
        }
        if (hookData.length == 36 && bytes4(hookData[:4]) == REMINT_MIGRATION_TAG) {
            // The shared migration arms and activates the replacement itself, behind the same
            // value gate as the block below.
            _migrateMintedPosition(uint256(bytes32(hookData[4:])), tokenId, liquidityDelta);
            return;
        }
        // Only a not-yet-active configured position consults the oracle here. Adds only raise a
        // position's value, so below-minimum deactivation belongs to the remove callback; reading
        // the oracle on every add of an active position would make plain deposits depend on feed
        // freshness.
        if (!PositionModeFlags.isNone(_positionConfigs[tokenId].modeFlags) && !_isActivated(tokenId)) {
            (uint256 positionValueNative,,,) = v4Oracle.getValue(tokenId, address(0));
            if (positionValueNative >= _minPositionValueNative) {
                _addPositionTriggers(tokenId, key);
                _activatePosition(tokenId);
            }
        }
    }

    // ==================== Auto Leverage ====================

    /// @notice Adjusts leverage for a vault-owned position based on current vs target debt ratio
    /// @param poolKey The pool key for the position
    /// @param tokenId The token ID of the position
    /// @param isUpperTrigger True if triggered by upper tick
    function autoLeverage(PoolKey calldata poolKey, uint256 tokenId, bool isUpperTrigger) external {
        _requireAuthorization(tokenId);

        IVault vault = IVault(msg.sender);
        (uint256 currentDebt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(tokenId);

        uint16 targetRatioBps = _positionConfigs[tokenId].autoLeverageTargetBps;
        uint256 currentRatio = AutoLeverageLib.currentRatio(currentDebt, collateralValue);
        bool success = true;

        // Adjust leverage based on current vs target ratio
        if (currentRatio < targetRatioBps) {
            success =
                _increaseLeverage(poolKey, tokenId, vault, currentDebt, fullValue, collateralValue, targetRatioBps);
        } else if (currentRatio > targetRatioBps) {
            success =
                _decreaseLeverage(poolKey, tokenId, vault, currentDebt, fullValue, collateralValue, targetRatioBps);
        }

        if (!success) {
            emit HookActionFailed(tokenId, Mode.AUTO_LEVERAGE);
            return;
        }

        (uint256 checkedDebt,, uint256 checkedCollateral,,) = vault.loanInfo(tokenId);
        bool loanUnchanged = checkedDebt == currentDebt && checkedCollateral == collateralValue;
        if (
            !loanUnchanged
                && !AutoLeverageLib.improvesTowardTarget(
                    currentDebt,
                    collateralValue,
                    checkedDebt,
                    checkedCollateral,
                    targetRatioBps,
                    _LEVERAGE_OVERSHOOT_TOLERANCE_BPS
                )
        ) revert NoImprovement();

        // Update triggers for new base tick
        _removePositionTriggers(tokenId, poolKey);
        int24 newBaseTick = _getTickLower(_getCurrentTick(poolKey.toId()), poolKey.tickSpacing);
        _positionStates[tokenId].autoLeverageBaseTick = newBaseTick;
        // The liquidity callback may deactivate a position that fell below the
        // configured minimum. Preserve that decision instead of rearming a dust
        // position after the callback removed its triggers.
        if (_isActivated(tokenId)) {
            _addPositionTriggers(tokenId, poolKey);
        }

        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        emit AutoLeverage(tokenId, isUpperTrigger, currentDebt, newDebt);
    }

    /// @notice Increases leverage by borrowing and adding liquidity
    function _increaseLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        IVault vault,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal returns (bool) {
        uint256 borrowAmount = AutoLeverageLib.borrowAmountToTarget(
            currentDebt, fullValue, collateralValue, targetRatioBps
        );
        if (borrowAmount == 0) return true;

        // Borrow from vault
        Currency lendToken = Currency.wrap(vault.asset());
        vault.borrow(tokenId, borrowAmount);

        // Swap to optimal ratio and add liquidity
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        (uint256 amount0, uint256 amount1) = _calculateAndSwap(
            tokenId,
            poolKey,
            positionInfo.tickLower(),
            positionInfo.tickUpper(),
            lendToken == poolKey.currency0 ? borrowAmount : 0,
            lendToken == poolKey.currency1 ? borrowAmount : 0,
            Mode.AUTO_LEVERAGE
        );

        _approveToken(poolKey.currency0, amount0);
        _approveToken(poolKey.currency1, amount1);
        (uint256 used0, uint256 used1) =
            // forge-lint: disable-next-line(unsafe-typecast)
            _increaseLiquidity(tokenId, poolKey, positionInfo, uint128(amount0), uint128(amount1));
        if (used0 > 0 || used1 > 0) {
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
            return true;
        }

        if (_rollbackFailedIncrease(tokenId, poolKey, vault, lendToken) > currentDebt) {
            revert RestoreFailed();
        }

        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, vault.ownerOf(tokenId));
        return false;
    }

    /// @notice Decreases leverage by removing liquidity and repaying debt
    function _decreaseLeverage(
        PoolKey memory poolKey,
        uint256 tokenId,
        IVault vault,
        uint256 currentDebt,
        uint256 fullValue,
        uint256 collateralValue,
        uint16 targetRatioBps
    ) internal returns (bool) {
        uint256 repayAmount = AutoLeverageLib.repayAmountToTarget(
            currentDebt, fullValue, collateralValue, targetRatioBps
        );

        address lendAsset = vault.asset();
        Currency lendToken = Currency.wrap(lendAsset);
        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        (uint256 positionValue,,,) = v4Oracle.getValue(tokenId, lendAsset);
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        if (positionValue == 0 || currentLiquidity == 0) return true;

        // Calculate liquidity to remove based on value ratio
        uint128 liquidityToRemove = AutoLeverageLib.liquidityToRemove(currentLiquidity, repayAmount, positionValue);
        if (liquidityToRemove == 0) return true;

        // Remove partial liquidity and swap to lend token
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            _decreaseLiquidityPartial(poolKey, tokenId, liquidityToRemove);
        if (amount0 == 0 && amount1 == 0) {
            return false;
        }

        uint256 lendAmount =
            _swapToLendToken(tokenId, poolKey, lendToken, currency0, currency1, amount0, amount1, Mode.AUTO_LEVERAGE);

        // Repay debt
        _repayDebtToVault(tokenId, vault, lendAsset, lendAmount, currentDebt);
        (uint256 newDebt,,,,) = vault.loanInfo(tokenId);
        if (newDebt < currentDebt) {
            _sendLeftoverTokens(tokenId, currency0, currency1, vault.ownerOf(tokenId));
            return true;
        }

        uint256 balance0 = currency0.balanceOfSelf();
        uint256 balance1 = currency1.balanceOfSelf();
        _approveToken(currency0, balance0);
        _approveToken(currency1, balance1);
        _increaseLiquidity(
            tokenId,
            poolKey,
            positionInfo,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(balance0),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(balance1)
        );
        if (positionManager.getPositionLiquidity(tokenId) < currentLiquidity) {
            revert RestoreFailed();
        }

        _sendLeftoverTokens(tokenId, currency0, currency1, vault.ownerOf(tokenId));
        return false;
    }

    function _rollbackFailedIncrease(
        uint256 tokenId,
        PoolKey memory poolKey,
        IVault vault,
        Currency lendToken
    ) internal returns (uint256 debtAfterRollback) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        uint256 lendAmount =
            _swapToLendToken(
                tokenId,
                poolKey,
                lendToken,
                currency0,
                currency1,
                currency0.balanceOfSelf(),
                currency1.balanceOfSelf(),
                Mode.AUTO_LEVERAGE
            );

        (uint256 currentDebt,,,,) = vault.loanInfo(tokenId);
        _repayDebtToVault(tokenId, vault, Currency.unwrap(lendToken), lendAmount, currentDebt);
        (debtAfterRollback,,,,) = vault.loanInfo(tokenId);
    }
}
