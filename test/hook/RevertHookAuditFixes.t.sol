// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @dev Stand-in for a registered lending vault. `transform` forwards borrower-chosen calldata
///      exactly like V4Vault.transform does (the C-01 entry point); with `spoof` set it ignores
///      the hook's calldata and calls autoExit with a foreign pool key instead, modelling a
///      transformer call that is not the one the hook encoded.
contract MockTransformVault {
    address public loanOwner;
    address public asset;
    uint256 public transformedTokenId;
    bool public spoof;
    PoolKey internal spoofKey;

    constructor(address loanOwner_, address asset_) {
        loanOwner = loanOwner_;
        asset = asset_;
    }

    function setSpoof(PoolKey memory key) external {
        spoof = true;
        spoofKey = key;
    }

    function ownerOf(uint256) external view returns (address) {
        return loanOwner;
    }

    function loanInfo(uint256) external pure returns (uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0);
    }

    function loans(uint256) external pure returns (uint256) {
        return 0;
    }

    function transform(uint256 tokenId, address transformer, bytes calldata data) external returns (uint256) {
        transformedTokenId = tokenId;
        bytes memory call = spoof
            ? abi.encodeWithSignature(
                "autoExit((address,address,uint24,int24,address),uint256,bool)", spoofKey, tokenId, false
            )
            : data;
        (bool ok, bytes memory ret) = transformer.call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        transformedTokenId = 0;
        return tokenId;
    }
}

/// @notice Regression tests for the 2026-09 audit-readiness fixes (docs/audit-readiness-review.md).
contract RevertHookAuditFixesTest is RevertHookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _autoExitConfig(int24 lower, int24 upper) internal pure returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: lower,
            autoExitTickUpper: upper,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    /// @dev A pool key over the auto-lend share token: the currency the C-01 attack targets.
    function _shareTokenPoolKey(IHooks hooks) internal view returns (PoolKey memory key) {
        address a = address(vault0);
        address b = Currency.unwrap(currency1);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, hooks);
    }

    // ==================== C-01: hook action entry points via vault.transform ====================

    /// @dev A registered vault forwarding a borrower's calldata (V4Vault.transform) reaches the
    ///      hook's action entry points with msg.sender == vault and transformedTokenId == tokenId.
    ///      Without the transient marker the hook sets for its own transforms this must be refused.
    function testVaultCallerOutsideHookTransformIsRefused() public {
        MockTransformVault vault = new MockTransformVault(address(this), Currency.unwrap(currency0));
        hook.setVault(address(vault));
        IERC721(address(positionManager)).transferFrom(address(this), address(vault), token3Id);

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vault.transform(token3Id, address(hook), abi.encodeCall(hook.autoExit, (poolKey, token3Id, false)));

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vault.transform(token3Id, address(hook), abi.encodeCall(hook.autoRange, (poolKey, token3Id)));

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vault.transform(token3Id, address(hook), abi.encodeCall(hook.autoLeverage, (poolKey, token3Id, false)));

        assertGt(positionManager.getPositionLiquidity(token3Id), 0, "position must be untouched");
    }

    /// @dev The original C-01 attack: a borrower's own transform naming a pool key whose currency
    ///      is the ERC4626 share token the hook custodies for auto-lend users. The whole-balance
    ///      sweep would have paid those shares to the borrower.
    function testBorrowerTransformWithSpoofedPoolKeyCannotSweepCustodiedShares() public {
        _createActiveAutoLendPosition();
        uint256 custodied = vault0.balanceOf(address(hook));
        assertGt(custodied, 0, "hook must custody shares for the lent position");

        MockTransformVault vault = new MockTransformVault(address(this), Currency.unwrap(currency0));
        hook.setVault(address(vault));
        IERC721(address(positionManager)).transferFrom(address(this), address(vault), token3Id);

        PoolKey memory fakeKey = _shareTokenPoolKey(IHooks(address(0)));
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vault.transform(token3Id, address(hook), abi.encodeCall(hook.autoExit, (fakeKey, token3Id, false)));

        assertEq(vault0.balanceOf(address(hook)), custodied, "custodied shares must not move");
        assertEq(vault0.balanceOf(address(this)), 0, "attacker must receive nothing");
    }

    /// @dev Control for the marker path: a hook-initiated transform on a vault-held position still
    ///      runs the action.
    function testHookInitiatedVaultTransformStillExecutesAutoExit() public {
        MockTransformVault vault = new MockTransformVault(address(this), Currency.unwrap(currency0));
        hook.setVault(address(vault));
        IERC721(address(positionManager)).transferFrom(address(this), address(vault), token2Id);
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        vm.prank(address(vault));
        IERC721(address(positionManager)).approve(address(hook), token2Id);

        _swap(poolKey, true, 7e17);

        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "auto-exit must run through the vault");
        assertEq(currency0.balanceOf(address(hook)), 0, "hook flat in token0");
        assertEq(currency1.balanceOf(address(hook)), 0, "hook flat in token1");
    }

    /// @dev Inside a hook-initiated transform the marker is set, so the pool key binding is what
    ///      stops a transformer call that names a foreign pool.
    function testSpoofedPoolKeyInsideHookTransformIsRefused() public {
        _createActiveAutoLendPosition();
        uint256 custodied = vault0.balanceOf(address(hook));

        MockTransformVault vault = new MockTransformVault(address(this), Currency.unwrap(currency0));
        hook.setVault(address(vault));
        IERC721(address(positionManager)).transferFrom(address(this), address(vault), token2Id);
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        vm.prank(address(vault));
        IERC721(address(positionManager)).approve(address(hook), token2Id);
        vault.setSpoof(_shareTokenPoolKey(IHooks(address(0))));

        uint128 liquidityBefore = positionManager.getPositionLiquidity(token2Id);
        // the action fails (HookActionFailed) instead of running against the foreign key
        _swap(poolKey, true, 7e17);

        assertEq(positionManager.getPositionLiquidity(token2Id), liquidityBefore, "spoofed action must not run");
        assertEq(vault0.balanceOf(address(hook)), custodied, "custodied shares must not move");
    }

    // ==================== M-02: migrateVaultPosition binds oldTokenId ====================

    function _mintReplacement() internal returns (uint256 newTokenId) {
        (newTokenId,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            1e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _fakeVaultHolding(uint256 oldTokenId, uint256 newTokenId, address oldOwner, address newOwner)
        internal
        returns (address fakeVault)
    {
        fakeVault = makeAddr("fakeVault");
        hook.setVault(fakeVault);
        IERC721(address(positionManager)).transferFrom(address(this), fakeVault, oldTokenId);
        IERC721(address(positionManager)).transferFrom(address(this), fakeVault, newTokenId);
        vm.mockCall(fakeVault, abi.encodeWithSignature("transformedTokenId()"), abi.encode(newTokenId));
        vm.mockCall(fakeVault, abi.encodeWithSignature("transformOriginTokenId()"), abi.encode(oldTokenId));
        vm.mockCall(fakeVault, abi.encodeWithSignature("ownerOf(uint256)", oldTokenId), abi.encode(oldOwner));
        vm.mockCall(fakeVault, abi.encodeWithSignature("ownerOf(uint256)", newTokenId), abi.encode(newOwner));
    }

    /// @dev A borrower names another borrower's live position as `oldTokenId`: its loan owner is
    ///      not the account that owns the replacement.
    function testMigrateVaultPositionRefusesForeignLiveOldToken() public {
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        uint256 newTokenId = _mintReplacement();
        address fakeVault = _fakeVaultHolding(token2Id, newTokenId, makeAddr("victim"), address(this));

        vm.prank(fakeVault);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.migrateVaultPosition(token2Id, newTokenId);

        (uint8 modeFlags,,,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_EXIT, "victim automation must stay configured");
        (uint8 newFlags,,,,,,,,,,,,) = hook.positionConfigs(newTokenId);
        assertEq(newFlags, 0, "attacker token must not receive the config");
        vm.clearMockedCalls();
    }

    /// @dev A drained old token is no different: only the same loan owner may receive the config.
    function testMigrateVaultPositionRefusesForeignDrainedOldToken() public {
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        positionManager.decreaseLiquidity(
            token2Id,
            positionManager.getPositionLiquidity(token2Id),
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        uint256 newTokenId = _mintReplacement();
        address fakeVault = _fakeVaultHolding(token2Id, newTokenId, makeAddr("victim"), address(this));

        vm.prank(fakeVault);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        hook.migrateVaultPosition(token2Id, newTokenId);
        vm.clearMockedCalls();
    }

    /// @dev The legitimate remint shape - same loan owner - still migrates.
    function testMigrateVaultPositionAcceptsSameOwnerRemint() public {
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        positionManager.decreaseLiquidity(
            token2Id,
            positionManager.getPositionLiquidity(token2Id),
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        uint256 newTokenId = _mintReplacement();
        address fakeVault = _fakeVaultHolding(token2Id, newTokenId, address(this), address(this));

        vm.prank(fakeVault);
        hook.migrateVaultPosition(token2Id, newTokenId);

        (uint8 newFlags,,,,,,,,,,,,) = hook.positionConfigs(newTokenId);
        assertEq(newFlags, PositionModeFlags.MODE_AUTO_EXIT, "config follows the remint");
        vm.clearMockedCalls();
    }

    /// @dev V4LE-28: the vault forwards borrower calldata to any allowlisted transformer, the hook
    ///      included. A borrower who owns two vault positions A and B could run
    ///      `vault.transform(A, hook, migrateVaultPosition(B, A))`: A is the transformed token, both
    ///      NFTs sit in the vault and share a loan owner, so every guard passed and B's automation,
    ///      swap protection and carried fee were rewritten onto A while B was silently disabled.
    ///      The retired token must be the one the transform started with.
    function testMigrateVaultPositionRefusesTokenOtherThanTransformOrigin() public {
        InterestRateModel irm = new InterestRateModel(0, 0, 0, 0);
        V4Vault lendVault = new V4Vault(
            "Local lending vault",
            "lLOCAL",
            Currency.unwrap(currency0),
            positionManager,
            irm,
            v4Oracle,
            NativeWrapper(payable(address(positionManager))).WETH9()
        );
        uint32 collateralFactor = uint32(uint256(2 ** 32) * 9 / 10);
        lendVault.setTokenConfig(Currency.unwrap(currency0), collateralFactor, type(uint32).max);
        lendVault.setTokenConfig(Currency.unwrap(currency1), collateralFactor, type(uint32).max);
        lendVault.setHookAllowList(address(hook), true);
        lendVault.setTransformer(address(hook), true);
        lendVault.setLimits(0, 10e18, 10e18, 10e18, 10e18);
        hook.setVault(address(lendVault));

        // B carries automation, A is a plain second position of the same borrower
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        IERC721(address(positionManager)).approve(address(lendVault), token2Id);
        lendVault.create(token2Id, address(this));
        IERC721(address(positionManager)).approve(address(lendVault), token3Id);
        lendVault.create(token3Id, address(this));

        vm.expectRevert(abi.encodeWithSignature("TransformFailed()"));
        lendVault.transform(
            token3Id, address(hook), abi.encodeCall(hook.migrateVaultPosition, (token2Id, token3Id))
        );

        (uint8 bFlags,,,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(bFlags, PositionModeFlags.MODE_AUTO_EXIT, "B keeps its automation");
        (uint8 aFlags,,,,,,,,,,,,) = hook.positionConfigs(token3Id);
        assertEq(aFlags, 0, "A receives nothing");
    }

    // ==================== M-03: no dispatch while the pool is outside the oracle window ====================

    function testTriggerWaitsWhilePoolIsOutsideOracleWindow() public {
        // exit trigger at the position's own lower edge (inside the +-100 tick window around the oracle)
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2, tickUpper2 + poolKey.tickSpacing));
        IERC721(address(positionManager)).approve(address(hook), token2Id);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token2Id);

        // oracle pinned to the hookless twin (tick 0) so the hooked pool can be moved on its own
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), nonHookedPoolKey);

        // one swap that overshoots the window: the trigger tick is crossed, the price is not bounded
        _swap(poolKey, true, 25e18);
        assertLt(_currentTick(poolKey), -100, "pool must be outside the oracle window");
        assertEq(positionManager.getPositionLiquidity(token2Id), liquidityBefore, "exit must not run off-oracle");

        // back inside the window above the trigger
        _swap(poolKey, false, 25e18);
        assertGt(_currentTick(poolKey), -100, "pool back inside the window");

        // walk down in small steps: the exit fires on the first swap that ends at or below the
        // trigger while still inside the window
        for (uint256 i; i < 400 && positionManager.getPositionLiquidity(token2Id) != 0; i++) {
            _swap(poolKey, true, 5e16);
            assertGe(_currentTick(poolKey), -100, "walk must stay inside the window");
        }
        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "exit runs once the price is bounded");
        assertEq(currency0.balanceOf(address(hook)), 0, "hook flat in token0");
        assertEq(currency1.balanceOf(address(hook)), 0, "hook flat in token1");
    }

    /// @dev While dispatch is deferred the cursor lags the live bucket. A trigger registered then
    ///      would sit on the far side of the pending walk and be missed by the direction the next
    ///      in-window swap infers, so registration is refused until the pool has caught up.
    function testSetPositionConfigRefusedWhileTriggerCursorIsStale() public {
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2, tickUpper2 + poolKey.tickSpacing));
        IERC721(address(positionManager)).approve(address(hook), token2Id);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), nonHookedPoolKey);

        _swap(poolKey, true, 25e18); // off-window: nothing dispatched, cursor left behind
        assertLt(_currentTick(poolKey), -100, "pool must be outside the oracle window");

        vm.expectRevert(abi.encodeWithSignature("TriggerCursorStale()"));
        hook.setPositionConfig(token3Id, _autoExitConfig(tickLower3 - poolKey.tickSpacing * 100, tickUpper3));

        // configs without triggers are unaffected
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );

        // back inside the window the pending walk runs (exiting token2) and registration works again
        _swap(poolKey, false, 25e18);
        for (uint256 i; i < 400 && positionManager.getPositionLiquidity(token2Id) != 0; i++) {
            _swap(poolKey, true, 5e16);
        }
        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "deferred exit runs in-window");
        hook.setPositionConfig(token3Id, _autoExitConfig(tickLower3 - poolKey.tickSpacing * 100, tickUpper3));
    }

    /// @dev Two positions share a trigger tick. The first exit's own swap carries the pool past the
    ///      oracle bound, so the second must be put back rather than executed at that price, and it
    ///      runs on the next swap that ends inside the window.
    function testSecondActionAtSameTickIsRequeuedWhenFirstLeavesOracleWindow() public {
        uint128 bigLiquidity = 1500e18;
        (uint256 a,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            bigLiquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        (uint256 b,) = positionManager.mint(
            poolKey,
            tickLower2,
            tickUpper2,
            bigLiquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        // trigger one spacing below the range: when it fires both positions are out of range and
        // only the 100e18 full-range liquidity absorbs the exit swaps
        hook.setPositionConfig(a, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        hook.setPositionConfig(b, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), nonHookedPoolKey);
        // window wide enough that the crossing step (which overshoots once the big positions leave
        // range) still lands inside it, while one exit's ~4.5e18 swap into the 100e18 full-range
        // liquidity does not
        hook.setMaxTicksFromOracle(300);

        // walk down until the shared trigger fires (bucket -120, i.e. price below the range)
        for (uint256 i; i < 400 && _currentTick(poolKey) > tickLower2 - 1; i++) {
            _swap(poolKey, true, 5e17);
        }
        assertLt(_currentTick(poolKey), -300, "first exit must have carried the pool out of the window");
        uint128 liqA = positionManager.getPositionLiquidity(a);
        uint128 liqB = positionManager.getPositionLiquidity(b);
        assertTrue((liqA == 0) != (liqB == 0), "exactly one of the two exits must have run");
        uint256 pending = liqA == 0 ? b : a;

        // bring the pool back inside the window (still below the trigger): the requeued exit runs
        for (uint256 i; i < 400 && _currentTick(poolKey) < -300; i++) {
            _swap(poolKey, false, 5e17);
        }
        assertLt(_currentTick(poolKey), tickLower2, "pool must still be below the trigger");
        assertEq(positionManager.getPositionLiquidity(pending), 0, "requeued exit runs once the price is bounded");
    }

    // ==================== M-01: custodied auto-lend shares are never swept ====================

    function testCustodiedSharesSurviveActionsInShareTokenPool() public {
        uint256 lentId = _createActiveAutoLendPosition();
        uint256 custodied = vault0.balanceOf(address(hook));
        assertGt(custodied, 0, "hook must custody shares for the lent position");

        // a hooked pool whose currency is the share token itself
        IERC20(Currency.unwrap(currency0)).approve(address(vault0), 40e18);
        vault0.deposit(40e18, address(this));
        vault0.approve(address(permit2), type(uint256).max);
        vault0.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault0), address(positionManager), type(uint160).max, type(uint48).max);

        PoolKey memory shareKey = _shareTokenPoolKey(IHooks(hook));
        poolManager.initialize(shareKey, Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(Currency.unwrap(shareKey.currency0), Currency.unwrap(shareKey.currency1), shareKey);
        (uint256 shareId,) = positionManager.mint(
            shareKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        hook.setPositionConfig(
            shareId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COLLECT,
                autoCollectMode: RevertHookState.AutoCollectMode.AUTO_COLLECT,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        IERC721(address(positionManager)).approve(address(hook), shareId);

        // generate fees in the share-token pool
        _swap(shareKey, true, 1e17);
        _swap(shareKey, false, 1e17);
        _swap(shareKey, false, 1e17);
        vm.warp(block.timestamp + 600);

        uint128 shareLiquidity = positionManager.getPositionLiquidity(shareId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = shareId;
        hook.autoCollect(ids);

        assertGt(positionManager.getPositionLiquidity(shareId), shareLiquidity, "fees compound normally");
        assertEq(vault0.balanceOf(address(hook)), custodied, "custodied shares are not treated as fees");
        assertEq(currency1.balanceOf(address(hook)), 0, "hook flat in the other currency");

        // and the lent position can still redeem every share it is owed
        hook.autoLendForceExit(lentId);
        assertEq(vault0.balanceOf(address(hook)), 0, "force exit redeems the custodied shares");
    }

    // ==================== V4LE-4: the oracle window is exact, not bucket-rounded ====================

    PoolKey internal wideTwin;

    /// @dev Deploys a spacing-200 hooked pool plus a hookless twin the oracle is pinned to, both at
    ///      `sqrtPrice` with full-range liquidity, and returns the hooked key.
    function _wideSpacingPoolPinnedToTwin(uint160 sqrtPrice) internal returns (PoolKey memory wide) {
        wide = PoolKey(currency0, currency1, 3000, 200, IHooks(hook));
        wideTwin = PoolKey(currency0, currency1, 3000, 200, IHooks(address(0)));
        poolManager.initialize(wide, sqrtPrice);
        poolManager.initialize(wideTwin, sqrtPrice);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), wideTwin);
        _mintFullRange(wide, 100e18);
        _mintFullRange(wideTwin, 100e18);
    }

    function _mintFullRange(PoolKey memory key, uint128 liquidity) internal returns (uint256 id) {
        (id,) = positionManager.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    /// @dev Swaps `key` in 1e17 steps (about 20 ticks against the 100e18 full-range liquidity)
    ///      until its tick is at or past `target` in the direction of travel.
    function _movePastTick(PoolKey memory key, int24 target) internal {
        bool down = _currentTick(key) > target;
        for (uint256 i; i < 200 && (down ? _currentTick(key) > target : _currentTick(key) < target); i++) {
            _swap(key, down, 1e17);
        }
        assertTrue(down ? _currentTick(key) <= target : _currentTick(key) >= target, "target tick not reached");
    }

    /// @dev With tickSpacing 200 and maxTicksFromOracle 100 the old bound floored the oracle tick
    ///      (190 -> 0), floored 0 - 100 to -200 and compared it with the live bucket, so a live tick
    ///      anywhere in [-200, -1] passed although the exact window is [90, 290]. An AUTO_EXIT armed
    ///      at bucket -200 therefore ran ~210 ticks off-oracle; it must wait until the oracle window
    ///      covers the price.
    function testOracleWindowLowerSideIsExactAtWideTickSpacing() public {
        assertEq(hook.maxTicksFromOracle(), 100, "fixture assumes the deployed 100-tick window");
        PoolKey memory wide = _wideSpacingPoolPinnedToTwin(Constants.SQRT_PRICE_1_1);
        (uint256 exitId,) = positionManager.mint(
            wide, -2000, 2000, 1e18, type(uint256).max, type(uint256).max, address(this), block.timestamp, ""
        );
        IERC721(address(positionManager)).approve(address(hook), exitId);
        hook.setPositionConfig(exitId, _autoExitConfig(-200, type(int24).max));
        uint128 liquidityBefore = positionManager.getPositionLiquidity(exitId);

        // oracle near the top of bucket 0: the old floor put its lower bound at -200
        _movePastTick(wideTwin, 185);
        assertLt(_currentTick(wideTwin), 200, "oracle stays inside bucket 0");

        // one small swap puts the hooked pool into bucket -200: the trigger bucket, ~210 ticks off-oracle
        _swap(wide, true, 1e17);
        int24 offWindowTick = _currentTick(wide);
        assertGe(offWindowTick, -200, "hooked pool sits in bucket -200");
        assertLt(offWindowTick, 0, "hooked pool sits in bucket -200");
        assertEq(positionManager.getPositionLiquidity(exitId), liquidityBefore, "exit must not run off-oracle");

        // the oracle comes down to the price: the deferred exit runs on the next hooked swap
        _movePastTick(wideTwin, -20);
        assertGt(_currentTick(wideTwin), -60, "oracle within 100 ticks of the hooked pool");
        _swap(wide, true, 1e15);
        assertEq(positionManager.getPositionLiquidity(exitId), 0, "deferred exit runs once the price is bounded");
        assertEq(currency0.balanceOf(address(hook)), 0, "hook flat in token0");
        assertEq(currency1.balanceOf(address(hook)), 0, "hook flat in token1");
    }

    /// @dev Mirror image: an oracle tick anywhere in bucket -200 gave an old upper bound of
    ///      floor(-200 + 100) = -200, so a live tick in [-200, -1] passed even when the oracle sat at
    ///      -195 and the exact window was [-295, -95]. An upper AUTO_EXIT at bucket -200 ran ~145
    ///      ticks off-oracle.
    function testOracleWindowUpperSideIsExactAtWideTickSpacing() public {
        PoolKey memory wide = _wideSpacingPoolPinnedToTwin(TickMath.getSqrtPriceAtTick(-300));
        (uint256 exitId,) = positionManager.mint(
            wide, -2000, 2000, 1e18, type(uint256).max, type(uint256).max, address(this), block.timestamp, ""
        );
        IERC721(address(positionManager)).approve(address(hook), exitId);
        hook.setPositionConfig(exitId, _autoExitConfig(type(int24).min, -200));
        uint128 liquidityBefore = positionManager.getPositionLiquidity(exitId);

        // oracle near the bottom of bucket -200
        _movePastTick(wideTwin, -195);
        assertLt(_currentTick(wideTwin), -170, "oracle stays near the bottom of bucket -200");

        // walk the hooked pool up to just below the trigger bucket, then cross it in one swap that
        // lands in the top half of the bucket, more than 100 ticks above the oracle
        _movePastTick(wide, -230);
        _swap(wide, false, 9e17);
        int24 offWindowTick = _currentTick(wide);
        assertGt(offWindowTick, -65, "hooked pool lands more than 100 ticks above the oracle");
        assertLt(offWindowTick, 0, "hooked pool still in bucket -200");
        assertEq(positionManager.getPositionLiquidity(exitId), liquidityBefore, "exit must not run off-oracle");

        // the oracle catches up: the deferred exit runs on the next hooked swap
        _movePastTick(wideTwin, -60);
        _swap(wide, false, 1e15);
        assertEq(positionManager.getPositionLiquidity(exitId), 0, "deferred exit runs once the price is bounded");
    }

    // ==================== L-01: remove callback fails open on oracle failure ====================

    function testRemoveLiquidityFromActivatedPositionSucceedsWhenOracleReverts() public {
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        uint128 liquidity = positionManager.getPositionLiquidity(token2Id);

        vm.mockCallRevert(address(v4Oracle), abi.encodeWithSelector(v4Oracle.getValue.selector), "oracle down");
        positionManager.decreaseLiquidity(
            token2Id, liquidity / 2, 0, 0, address(this), block.timestamp, Constants.ZERO_BYTES
        );
        vm.clearMockedCalls();

        assertEq(positionManager.getPositionLiquidity(token2Id), liquidity - liquidity / 2, "withdrawal went through");
        (uint8 modeFlags,,,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_EXIT, "automation stays configured");
    }
}
