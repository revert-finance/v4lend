// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @notice External audit: a hook-driven deleverage removes liquidity first and only then learns
///         what it can repay. When the position carries deferred protocol fees (from earlier
///         fee-only collections) at least as large as the removed principal in BOTH currencies,
///         the whole TAKE_PAIR credit goes to the fee recipient, `_decreaseLeverage` saw `(0, 0)`
///         and soft-failed without restoring anything, and the vault transform committed reduced
///         collateral against unchanged debt because it only checks loan health. The action must
///         roll back instead.
/// @dev Fork-free (local PoolManager, real hook + V4Vault). The carried fee is written directly into
///      the hook's per-position pending slot: reaching it organically needs LP protocol fees larger
///      than the planner's removal, which is exactly the "carried fees larger than the principal
///      delta" precondition the finding names, only slower to set up.
contract RevertHookDeleverageCarriedFeesTest is RevertHookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using stdStorage for StdStorage;

    StdStorage internal stdstore_;

    function testDeleverageRollsBackWhenCarriedFeesConsumeTheRemoval() public {
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), key);

        positionManager.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            40e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        // Collateral sits BELOW the current price and the trigger swap moves the price up, so the
        // position earns no LP fees during the swap: the only credit a removal can produce is
        // principal, which is exactly what the carried fee consumes.
        (uint256 leveredTokenId,) = positionManager.mint(
            key,
            -12 * key.tickSpacing,
            -6 * key.tickSpacing,
            18000e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // lend currency0; the position is levered slightly above target so the trigger deleverages
        V4Vault lendVault = _deployLendVault(currency0);
        IERC20(Currency.unwrap(currency0)).approve(address(lendVault), 2e18);
        lendVault.deposit(2e18, address(this));
        IERC721(address(positionManager)).approve(address(lendVault), leveredTokenId);
        lendVault.create(leveredTokenId, address(this));
        lendVault.approveTransform(leveredTokenId, address(hook), true);

        (,, uint256 collateralValue,,) = lendVault.loanInfo(leveredTokenId);
        lendVault.borrow(leveredTokenId, collateralValue * 7490 / 10000);
        hook.setPositionConfig(leveredTokenId, _autoLeverageConfig(7490));
        lendVault.borrow(leveredTokenId, collateralValue / 1000);

        // carried protocol fees larger than any partial removal, in both currencies
        uint128 carried = type(uint128).max / 4;
        uint256 slot = stdstore_.target(address(hook)).sig(hook.pendingProtocolFees.selector).with_key(leveredTokenId)
            .find();
        vm.store(address(hook), bytes32(slot), bytes32((uint256(carried) << 128) | uint256(carried)));
        (uint128 pending0, uint128 pending1) = hook.pendingProtocolFees(leveredTokenId);
        assertEq(pending0, carried);
        assertEq(pending1, carried);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(leveredTokenId);
        (uint256 debtBefore,, uint256 collateralBefore,,) = lendVault.loanInfo(leveredTokenId);
        uint256 recipient0Before = IERC20(Currency.unwrap(currency0)).balanceOf(protocolFeeRecipient);
        uint256 recipient1Before = IERC20(Currency.unwrap(currency1)).balanceOf(protocolFeeRecipient);

        // the public swap crosses the auto-leverage trigger and fires the deleverage
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 5431e16,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_sawActionFailed(logs, leveredTokenId), "the action fails instead of committing");
        assertFalse(_sawAutoLeverageExecuted(logs, leveredTokenId), "no deleverage is recorded as executed");
        assertEq(
            positionManager.getPositionLiquidity(leveredTokenId), liquidityBefore, "no liquidity leaves the position"
        );
        (uint256 debtAfter,, uint256 collateralAfter,,) = lendVault.loanInfo(leveredTokenId);
        assertEq(debtAfter, debtBefore, "debt untouched");
        assertGe(collateralAfter, collateralBefore, "collateral not reduced by a failed deleverage");
        assertEq(
            IERC20(Currency.unwrap(currency0)).balanceOf(protocolFeeRecipient),
            recipient0Before,
            "no principal paid out as carried fee"
        );
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(protocolFeeRecipient), recipient1Before);
        (pending0, pending1) = hook.pendingProtocolFees(leveredTokenId);
        assertEq(pending0, carried, "carried fee still owed, not settled from removed collateral");
        assertEq(pending1, carried);
    }

    function testCombinedRangeAndLeverageFallsBackToAutoRangeAfterFailedLeverageTrigger() public {
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), key);
        hook.setMaxTicksFromOracle(1000);
        positionManager.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        (uint256 levId,) = positionManager.mint(
            key, -150, 150, 100, type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        V4Vault lendVault = _deployLendVault(currency0);
        IERC20(Currency.unwrap(currency0)).approve(address(lendVault), 2e18);
        lendVault.deposit(2e18, address(this));
        IERC721(address(positionManager)).approve(address(lendVault), levId);
        lendVault.create(levId, address(this));
        lendVault.approveTransform(levId, address(hook), true);
        (,, uint256 collateralValue,,) = lendVault.loanInfo(levId);
        lendVault.borrow(levId, collateralValue * 5000 / 10000);

        RevertHookState.PositionConfig memory config = _autoLeverageConfig(5000);
        config.modeFlags = PositionModeFlags.MODE_AUTO_RANGE | PositionModeFlags.MODE_AUTO_LEVERAGE;
        config.autoRangeLowerDelta = -100;
        config.autoRangeUpperDelta = 100;
        hook.setPositionConfig(levId, config);

        // Push loan slightly above target so the tiny-liquidity deleverage soft-fails at +100
        lendVault.borrow(levId, collateralValue / 1000);

        // Step 1: cross upper leverage trigger (+100) without crossing upper range trigger (+150)
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 6e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        assertTrue(_sawActionFailed(logs1, levId), "leverage failed at +100");
        assertTrue(hook.autoLeverageNeedsAttention(levId), "attention flag set");

        vm.prank(address(lendVault));
        IERC721(address(positionManager)).approve(address(this), levId);
        positionManager.increaseLiquidity(
            levId, 1e18, type(uint256).max, type(uint256).max, block.timestamp, Constants.ZERO_BYTES
        );
        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        // Step 2: cross upper range trigger (+150); AUTO_RANGE must fire and remint
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 6e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        assertTrue(_sawAutoRangeExecuted(logs2, levId), "autoRange executed at +150");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "replacement position minted");
        assertGt(positionManager.getPositionLiquidity(nextTokenIdBefore), 0, "replacement has liquidity");
        assertFalse(hook.autoLeverageNeedsAttention(nextTokenIdBefore), "replacement starts with clean attention state");
    }

    function testCombinedRangeAndLeverageSingleSwapCrossingBothTriggersFallsBackToAutoRange() public {
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), key);
        hook.setMaxTicksFromOracle(1000);
        positionManager.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        (uint256 levId,) = positionManager.mint(
            key, -150, 150, 1e18, type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        V4Vault lendVault = _deployLendVault(currency0);
        uint256 initialDeposit = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(lendVault), initialDeposit);
        lendVault.deposit(initialDeposit, address(this));
        IERC721(address(positionManager)).approve(address(lendVault), levId);
        lendVault.create(levId, address(this));
        lendVault.approveTransform(levId, address(hook), true);
        (,, uint256 collateralValue,,) = lendVault.loanInfo(levId);
        uint256 initialBorrow = collateralValue * 5000 / 10000;
        lendVault.borrow(levId, initialBorrow);

        RevertHookState.PositionConfig memory config = _autoLeverageConfig(5000);
        config.modeFlags = PositionModeFlags.MODE_AUTO_RANGE | PositionModeFlags.MODE_AUTO_LEVERAGE;
        config.autoRangeLowerDelta = -100;
        config.autoRangeUpperDelta = 100;
        hook.setPositionConfig(levId, config);

        // Drain remaining vault cash and lower debt below target so _increaseLeverage reverts in vault.borrow
        IERC20(Currency.unwrap(currency0)).approve(address(lendVault), type(uint256).max);
        lendVault.repay(levId, initialBorrow / 5, false);
        uint256 maxWithdrawable = lendVault.maxWithdraw(address(this));
        if (maxWithdrawable > 0) {
            lendVault.withdraw(maxWithdrawable, address(this), address(this));
        }

        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        // Single swap crosses both leverageUpper (+100) and rangeUpper (+150)
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 18e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_sawActionFailed(logs, levId), "leverage failed at +100");
        assertTrue(_sawAutoRangeExecuted(logs, levId), "autoRange executed at +150");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "replacement position minted");
        assertGt(positionManager.getPositionLiquidity(nextTokenIdBefore), 0, "replacement has liquidity");
    }

    function _sawAutoRangeExecuted(Vm.Log[] memory logs, uint256 forTokenId) internal pure returns (bool) {
        bytes32 topic = RevertHookState.AutoRange.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == forTokenId) {
                return true;
            }
        }
        return false;
    }

    function _deployLendVault(Currency lendCurrency) internal returns (V4Vault lendVault) {
        InterestRateModel interestRateModel = new InterestRateModel(0, 0, 0, 0);
        lendVault = new V4Vault(
            "Local lending vault",
            "lLOCAL",
            Currency.unwrap(lendCurrency),
            positionManager,
            interestRateModel,
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
    }

    function _autoLeverageConfig(uint16 targetBps) internal pure returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_LEVERAGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
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
            autoLeverageTargetBps: targetBps
        });
    }

    function _sawActionFailed(Vm.Log[] memory logs, uint256 forTokenId) internal pure returns (bool) {
        bytes32 topic = RevertHookState.HookActionFailed.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == forTokenId) {
                return true;
            }
        }
        return false;
    }

    function _sawAutoLeverageExecuted(Vm.Log[] memory logs, uint256 forTokenId) internal pure returns (bool) {
        bytes32 topic = RevertHookState.AutoLeverage.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == forTokenId) {
                return true;
            }
        }
        return false;
    }
}
