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
import {IHookRouteController} from "./interfaces/IHookRouteController.sol";
import {PositionModeFlags} from "./lib/PositionModeFlags.sol";
import {RevertHookActionBase} from "./RevertHookActionBase.sol";
import {RevertHookSwapActions} from "./RevertHookSwapActions.sol";

/// @title RevertHookMigrationActions
/// @notice Delegatecall target for everything that moves token-id keyed automation state from a
///         position to the position that replaced it: the vault-notified remint (`migrateVaultPosition`)
///         and the tagged-mint claim a direct range change can make, plus the after-add-liquidity tail
///         that activates a configured position. Hosted in its own sidecar because neither the
///         auto-lend nor the auto-leverage sidecar has the bytecode room (docs/hook-hierarchy.md).
contract RevertHookMigrationActions is RevertHookActionBase {
    using PoolIdLibrary for PoolKey;

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
    ///      else happens; otherwise swap protection follows across the pair, the carried protocol fee
    ///      follows only once the old position is drained (a partial remint keeps it owed by the
    ///      liquidity that stays behind), and automation itself only follows a remint inside the same pool. Because pool and owner are
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
        // The vault forwards borrower-chosen calldata to any allowlisted transformer, this hook
        // included, so `oldTokenId` must be the token the running transform started with: the
        // vault records it when the transform begins and the remint moves transformedTokenId to
        // the replacement. Otherwise a borrower could name any other position they own and have
        // its automation, swap protection and carried fee rewritten onto the transformed one.
        IVault vault = IVault(msg.sender);
        if (
            !_vaults[msg.sender] || oldTokenId == newTokenId || vault.transformedTokenId() != newTokenId
                || vault.transformOriginTokenId() != oldTokenId
        ) {
            revert Unauthorized();
        }
        IERC721 nft = IERC721(address(positionManager));
        if (nft.ownerOf(oldTokenId) != msg.sender || nft.ownerOf(newTokenId) != msg.sender) {
            revert Unauthorized();
        }
        // The vault forwards borrower-chosen calldata to any allowlisted transformer, so nothing
        // above ties `oldTokenId` to the transform in progress. A remint keeps the vault-side loan
        // owner: the old token's owner record is the account that now owns the replacement. A
        // different owner means a borrower is pointing at someone else's position (M-02). The old
        // token may keep liquidity (partial range changes leave some behind).
        if (vault.ownerOf(oldTokenId) != vault.ownerOf(newTokenId)) {
            revert Unauthorized();
        }
        _migratePositionState(oldTokenId, newTokenId, false);
    }

    /// @notice The hook's after-add-liquidity handling past protocol fee settlement, hosted here to
    ///         keep the hook under the EIP-170 limit: the remint migration a tagged mint names, else
    ///         activation of a configured, not-yet-active position. The hook only delegates here for
    ///         a configured position or a 36-byte hookData, so plain deposits pay nothing extra.
    /// @dev Remint migration protocol: a mint whose hookData is
    ///      `abi.encodePacked(REMINT_MIGRATION_TAG, oldTokenId)` names the token id this position
    ///      replaces. V4Utils forwards the caller's `increaseLiquidityHookData` as the mint hookData,
    ///      so a direct range change opts in without any transformer change; the standalone AutoRange
    ///      has a `mintHookData` field for the same purpose. Any other hookData - including an untagged
    ///      word another integrator may pass for its own purposes - is ignored. A claim that cannot be
    ///      honoured reverts the mint, so the owner learns about it instead of minting an unautomated
    ///      position.
    /// @dev Delegatecall-only: a direct call (own storage, spoofable events) is rejected.
    function afterAddLiquidity(PoolKey calldata key, uint256 tokenId, int256 liquidityDelta, bytes calldata hookData)
        external
    {
        if (address(this) == _selfAddress) {
            revert Unauthorized();
        }
        if (hookData.length == 36 && bytes4(hookData[:4]) == REMINT_MIGRATION_TAG) {
            // The migration arms and activates the replacement itself, behind the same value gate.
            _migrateMintedPosition(uint256(bytes32(hookData[4:])), tokenId, liquidityDelta);
            return;
        }
        // Only a not-yet-active configured position consults the oracle here. Adds only raise a
        // position's value, so below-minimum deactivation belongs to the remove callback; reading
        // the oracle on every add of an active position would make plain deposits depend on feed
        // freshness.
        PositionConfig storage config = _positionConfigs[tokenId];
        if (!PositionModeFlags.isNone(config.modeFlags) && !_isActivated(tokenId)) {
            (uint256 positionValueNative,,,) = v4Oracle.getValue(tokenId, address(0));
            if (positionValueNative >= _minPositionValueNative) {
                // A third party arming a configured position while the trigger cursor lags the live
                // bucket would place its triggers where the resumed walk never visits them
                // (TriggerCursorStale, see RevertHookTriggers._requireTriggerCursorFresh). The hook's
                // own adds inside a walk are exempt: there the stored cursor is stale by construction,
                // and the restore paths re-add liquidity right after the fired trigger emptied the
                // position, so its condition is satisfied by construction and removed again by the
                // caller.
                if (IMsgSender(address(positionManager)).msgSender() != address(this)) {
                    _requireTriggerCursorFresh(key.toId(), key.tickSpacing);
                    // The position was deactivated by a removal (empty, or below the value minimum)
                    // and the price may have crossed its trigger since. A fresh cursor sits on the
                    // live bucket and the walk searches strictly past it, so a trigger that is
                    // already satisfied would be armed on the wrong side of every future walk and
                    // stay dormant until a recross (V4LE-70). It cannot execute here either: the
                    // PositionManager holds its reentrancy lock for the caller's own operation.
                    // Refuse the add; the owner reconfigures (which executes the trigger at once)
                    // or disables automation first. Auto-leverage is re-centred on the live tick
                    // like a remint, so only range, exit and lend triggers can be satisfied.
                    (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
                    if (PositionModeFlags.hasAutoLeverage(config.modeFlags)) {
                        _positionStates[tokenId].autoLeverageBaseTick =
                            _getTickLower(_getCurrentTick(key.toId()), key.tickSpacing);
                    }
                    (bool alreadyTriggered,,) = _checkTriggerConditions(
                        tokenId, key, config, positionInfo.tickLower(), positionInfo.tickUpper()
                    );
                    if (alreadyTriggered) {
                        revert TriggerAlreadySatisfied();
                    }
                }
                _addPositionTriggers(tokenId, key);
                _activatePosition(tokenId);
            }
        }
    }

    /// @dev Mint-callback entry to the shared migration (see afterAddLiquidity for the protocol).
    ///      Authority is the one that let the locker remove the old liquidity: the locker
    ///      (`positionManager.msgSender()`) must own the old token, hold its per-token approval, or be
    ///      an operator for the owner (`isApprovedForAll`, which is how the standalone AutoRange is
    ///      approved), and the new token must be in the locker's custody (V4Utils mints to itself
    ///      before forwarding) or already with the old owner. A shared locker must not lend that
    ///      authority to its callers: V4Utils forwards a tagged claim only when it names the token its
    ///      caller is authorized on and draining in that very call, and refuses one on its
    ///      permissionless mint / increase entries (V4LE-9). A blanket operator could name any of the
    ///      owner's positions here, but the claim only succeeds once that position is drained, so
    ///      misdirecting automation would first require closing a position the operator was already
    ///      trusted with; the cross-position claim adds nothing to what the approval already permits. The callback also fires for
    ///      increases, so the target must be a blank slate the way a fresh mint is - no liquidity
    ///      before this add, no config and no swap protection of its own - and the old position must
    ///      already be drained, so the claim is bound to a real replacement rather than a dust mint
    ///      that would park the old token's owed fee and switch off automation that keeps running.
    ///      Vault-held positions are skipped here so the vault's own notification
    ///      (migrateVaultPosition, bound to the running transform) handles them once.
    function _migrateMintedPosition(uint256 oldTokenId, uint256 newTokenId, int256 liquidityDelta) internal {
        IERC721 nft = IERC721(address(positionManager));
        address oldOwner = nft.ownerOf(oldTokenId);
        if (_vaults[oldOwner]) {
            return;
        }
        address locker = IMsgSender(address(positionManager)).msgSender();
        if (oldOwner != locker && nft.getApproved(oldTokenId) != locker && !nft.isApprovedForAll(oldOwner, locker)) {
            revert Unauthorized();
        }
        address newOwner = nft.ownerOf(newTokenId);
        if (newOwner != locker && newOwner != oldOwner) {
            revert Unauthorized();
        }
        // liquidityDelta is positive here: the pool routes non-positive deltas to the remove callback.
        SwapProtectionConfig storage protection = _swapProtectionConfigs[newTokenId];
        if (
            positionManager.getPositionLiquidity(newTokenId) != uint128(uint256(liquidityDelta))
                || !PositionModeFlags.isNone(_positionConfigs[newTokenId].modeFlags)
                || protection.sqrtPriceMultiplier0 != 0 || protection.sqrtPriceMultiplier1 != 0
        ) {
            revert InvalidConfig();
        }
        _migratePositionState(oldTokenId, newTokenId, true);
    }

    /// @dev Shared remint migration used by the vault path and the mint-callback path once each has
    ///      authorized the pair. Refuses outstanding auto-lend shares, retires the old automation
    ///      when the replacement left this hook's pools, otherwise carries swap protection and - only
    ///      once the old position holds no liquidity - the deferred fee, re-validates the config for the
    ///      new range, refuses an already-satisfied trigger, disables the old token and arms the
    ///      replacement above the value minimum. `requireOldDrained` makes a live old position a
    ///      refusal instead of a partial migration.
    function _migratePositionState(uint256 oldTokenId, uint256 newTokenId, bool requireOldDrained) internal {
        bool oldDrained = positionManager.getPositionLiquidity(oldTokenId) == 0;
        if (requireOldDrained && !oldDrained) {
            revert InvalidConfig();
        }
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
        // Both are per currency pair, so they also carry across pools of the same pair. The fee only
        // moves once nothing is left on the old position to collect it from; while liquidity stays
        // behind it remains owed there and is taken on that position's next removal.
        _swapProtectionConfigs[newTokenId] = _swapProtectionConfigs[oldTokenId];
        if (oldDrained) {
            _migratePendingProtocolFee(newPoolKey, oldTokenId, newTokenId);
        }

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
            _requireTriggerCursorFresh(newPoolKey.toId(), newPoolKey.tickSpacing);
            _addPositionTriggers(newTokenId, newPoolKey);
            _activatePosition(newTokenId);
        }
        emit SetPositionConfig(newTokenId, config);
    }
}
