// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @notice Regression for action-induced oracle overshoot losing rearmed return triggers.
/// @dev Adapted from the external audit's local PoolManager / V4Vault reproduction.
contract RevertHookOracleOvershootTest is RevertHookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q32 = 2 ** 32;

    function testAutoLeverageRearmedLowerTriggerRunsAfterOracleOvershoot() public {
        _testOvershoot(true, false, true);
    }

    function testAutoLeverageRearmedUpperTriggerRunsAfterOracleOvershoot() public {
        _testOvershoot(false, false, true);
    }

    function testAutoLeverageOracleOvershootPreservesQueuedUpperTriggers() public {
        _testOvershoot(true, true, true);
    }

    function testAutoLeverageOracleOvershootPreservesQueuedLowerTriggers() public {
        _testOvershoot(false, true, true);
    }

    function testAutoLeverageOracleOvershootOriginalPocDispatchesReturnTrigger() public {
        _testOvershoot(true, false, false);
    }

    function _testOvershoot(bool up, bool queueExits, bool restoreDebt) internal {
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), key);

        // The narrow collateral is outside its range when the first trigger fires. Only the
        // full-range depth absorbs the action swap, which carries the pool past the oracle bound.
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
        (uint256 tokenId,) = positionManager.mint(
            key,
            -6 * key.tickSpacing,
            6 * key.tickSpacing,
            18000e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        Currency lendCurrency = up ? currency0 : currency1;
        InterestRateModel interestRateModel = new InterestRateModel(0, 0, 0, 0);
        V4Vault vault = new V4Vault(
            "Local lending vault",
            "lLOCAL",
            Currency.unwrap(lendCurrency),
            positionManager,
            interestRateModel,
            v4Oracle,
            NativeWrapper(payable(address(positionManager))).WETH9()
        );
        vault.setTokenConfig(Currency.unwrap(currency0), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setHookAllowList(address(hook), true);
        vault.setTransformer(address(hook), true);
        vault.setLimits(0, 10e18, 10e18, 10e18, 10e18);
        hook.setVault(address(vault));

        IERC20(Currency.unwrap(lendCurrency)).approve(address(vault), 2e18);
        vault.deposit(2e18, address(this));
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vault.create(tokenId, address(this));
        vault.approveTransform(tokenId, address(hook), true);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 targetDebt = collateralValue * 7490 / 10000;
        vault.borrow(tokenId, targetDebt);
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
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
                autoLeverageTargetBps: 7490
            })
        );
        vault.borrow(tokenId, collateralValue / 1000);

        int24 cursorBefore = hook.tickLowerLasts(key.toId());
        (,,,,,,, int24 baseBefore) = hook.positionStates(tokenId);
        int24 firstTrigger = baseBefore + (up ? int24(10) : -int24(10)) * key.tickSpacing;
        uint256 sameTickExit;
        uint256 laterTickExit;
        if (queueExits) {
            sameTickExit = _queueExit(key, firstTrigger, up);
            laterTickExit = _queueExit(key, firstTrigger + (up ? key.tickSpacing : -key.tickSpacing), up);
        }
        assertEq(cursorBefore, baseBefore);
        (uint256 debtBeforeAction,,,,) = vault.loanInfo(tokenId);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 5431e16,
            amountOutMin: 0,
            zeroForOne: !up,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory actionLogs = vm.getRecordedLogs();

        (, int24 tickAfterAction,,) = StateLibrary.getSlot0(poolManager, key.toId());
        (,,,,,,, int24 baseAfter) = hook.positionStates(tokenId);
        int24 publicTick = _outerSwapTick(actionLogs, key);
        int24 oracleBound =
            _bucket(publicTick, key.tickSpacing) + (up ? hook.maxTicksFromOracle() : -hook.maxTicksFromOracle());
        assertTrue(_sawAutoLeverage(actionLogs, tokenId));
        assertGe(up ? publicTick : -publicTick, up ? firstTrigger : -firstTrigger);
        (uint256 debtAfterAction,,,,) = vault.loanInfo(tokenId);
        assertGt(up ? tickAfterAction : -tickAfterAction, up ? oracleBound : -oracleBound);
        assertGt(up ? baseAfter : -baseAfter, up ? firstTrigger : -firstTrigger);
        assertLt(debtAfterAction, debtBeforeAction);
        assertGt(debtAfterAction, 0);

        int24 returnTrigger = baseAfter - (up ? int24(10) : -int24(10)) * key.tickSpacing;
        assertGt(up ? returnTrigger : -returnTrigger, up ? cursorBefore : -cursorBefore);
        (,, int24 returnHead) = up ? hook.lowerTriggerAfterSwap(key.toId()) : hook.upperTriggerAfterSwap(key.toId());
        assertEq(returnHead, returnTrigger);
        if (queueExits) {
            assertGt(positionManager.getPositionLiquidity(sameTickExit), 0, "same-tick exit remains queued");
            assertGt(positionManager.getPositionLiquidity(laterTickExit), 0, "later exit remains queued");
        }

        // Negative control: ordinary externally armed triggers are rejected while stale.
        (uint256 unarmedTokenId,) = positionManager.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            1e16,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        vm.expectRevert(abi.encodeWithSignature("TriggerCursorStale()"));
        hook.setPositionConfig(
            unarmedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: up ? returnTrigger : type(int24).min,
                autoExitTickUpper: up ? type(int24).max : returnTrigger,
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

        // The mock oracle keeps collateral value constant after liquidity removal. Restore the
        // initial debt so the return trigger performs a successful reduction rather than an
        // increase rejected by NoImprovement; this isolates trigger reachability from valuation.
        if (restoreDebt) {
            vault.borrow(tokenId, debtBeforeAction - debtAfterAction);
        }
        (uint256 debtBeforeDown,,,,) = vault.loanInfo(tokenId);
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: queueExits ? 25e16 : 1e18,
            amountOutMin: 0,
            zeroForOne: up,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory downLogs = vm.getRecordedLogs();
        (uint256 debtAfterDown,,,,) = vault.loanInfo(tokenId);
        int24 returnSwapTick = _outerSwapTick(downLogs, key);
        assertLt(up ? returnSwapTick : -returnSwapTick, up ? returnTrigger : -returnTrigger);
        if (restoreDebt) {
            assertTrue(_sawAutoLeverage(downLogs, tokenId), "rearmed return trigger must execute");
            assertLt(debtAfterDown, debtBeforeDown, "crossing the rearmed trigger must reduce debt");
        } else {
            // The exact PoC reaches the action now. Its unchanged mock valuation makes the
            // leverage increase fail NoImprovement, which must emit the normal recovery event.
            assertTrue(_sawIndexedTokenEvent(downLogs, keccak256("HookActionFailed(uint256,uint8)"), tokenId));
            assertEq(debtAfterDown, debtBeforeDown);
        }
        if (queueExits) {
            assertGt(up ? returnSwapTick : -returnSwapTick, up ? firstTrigger : -firstTrigger);
            assertEq(positionManager.getPositionLiquidity(sameTickExit), 0, "same-tick backlog remains reachable");
            assertEq(positionManager.getPositionLiquidity(laterTickExit), 0, "later backlog remains reachable");
        }
    }

    function _queueExit(PoolKey memory key, int24 trigger, bool up) internal returns (uint256 id) {
        (id,) = positionManager.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            1e16,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        IERC721(address(positionManager)).approve(address(hook), id);
        hook.setPositionConfig(
            id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: up ? type(int24).min : trigger,
                autoExitTickUpper: up ? trigger : type(int24).max,
                autoExitSwapOnLowerTrigger: false,
                autoExitSwapOnUpperTrigger: false,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
    }

    function _sawAutoLeverage(Vm.Log[] memory logs, uint256 tokenId) internal pure returns (bool) {
        bytes32 topic = keccak256("AutoLeverage(uint256,bool,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == tokenId) {
                return true;
            }
        }
        return false;
    }

    function _outerSwapTick(Vm.Log[] memory logs, PoolKey memory key) internal view returns (int24) {
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 poolId = PoolId.unwrap(key.toId());
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(poolManager) && logs[i].topics.length >= 3 && logs[i].topics[0] == swapTopic
                    && logs[i].topics[1] == poolId
                    && address(uint160(uint256(logs[i].topics[2]))) == address(swapRouter)
            ) {
                (,,,, int24 tick,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return tick;
            }
        }
        revert("outer swap event missing");
    }

    function _bucket(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }
}
