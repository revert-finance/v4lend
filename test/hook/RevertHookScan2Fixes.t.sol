// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @notice Regressions for the external audit's second scan (Cantina Apex, 2026-09-30), hook area.
contract RevertHookScan2FixesTest is RevertHookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ==================== V4LE-131: negative AUTO_LEND tolerance ====================

    /// @notice A negative, spacing-aligned tolerance placed the deposit thresholds inside the LP
    ///         range, where a crossing does not identify the idle token. It must be refused like
    ///         the standalone AutoLend refuses negative zones.
    function testV4LE131_NegativeAutoLendToleranceIsRejected() public {
        RevertHookState.PositionConfig memory config = _autoLendConfig(-int24(poolKey.tickSpacing));
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        hook.setPositionConfig(token3Id, config);

        // zero and positive aligned tolerances stay accepted
        hook.setPositionConfig(token3Id, _autoLendConfig(0));
        hook.setPositionConfig(token3Id, _autoLendConfig(poolKey.tickSpacing));
    }

    // ==================== V4LE-130: relative exit offset overflows int24 on the remint ====================

    /// @notice A valid config whose relative exit offset fits the initial range overflowed int24
    ///         once re-applied to an AUTO_RANGE replacement clamped at the usable tick bound; the
    ///         checked addition failed the arming, the action rolled back and the old triggers were
    ///         already consumed. The offset must saturate (an unreachable threshold = no trigger).
    function testV4LE130_AutoRangeRemintSaturatesRelativeExitOffset() public {
        IERC721(address(positionManager)).approve(address(hook), token3Id);
        int24 maxUsable = TickMath.maxUsableTick(poolKey.tickSpacing);
        int24 exitUpper = 8388540; // aligned; tickUpper3 + exitUpper fits int24, maxUsable + exitUpper does not
        hook.setPositionConfig(
            token3Id,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: true,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: exitUpper,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: maxUsable,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        (, uint32 upperSize,) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperSize, 2, "initial range + exit triggers armed");
        uint256 replacementId = positionManager.nextTokenId();

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawIndexed(logs, RevertHookState.HookActionFailed.selector, token3Id), "remint must not fail");
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "old position drained");
        assertGt(positionManager.getPositionLiquidity(replacementId), 0, "replacement minted");
        (, PositionInfoView memory info) = _positionInfo(replacementId);
        assertEq(info.tickUpper, maxUsable, "replacement clamped at the usable bound");

        // the replacement is armed: config copied, its range trigger sits at the bound and the exit
        // whose threshold lies past every tick is saturated away instead of failing the arming
        (uint8 modeFlags,,,,,,,,,,,,) = hook.positionConfigs(replacementId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_EXIT | PositionModeFlags.MODE_AUTO_RANGE, "config migrated");
        (,, uint32 lastActivated,,,,,) = hook.positionStates(replacementId);
        assertGt(lastActivated, 0, "replacement activated");
        int24 upperHead;
        (, upperSize, upperHead) = hook.upperTriggerAfterSwap(poolId);
        assertEq(upperSize, 1, "one reachable upper trigger on the replacement");
        assertEq(upperHead, maxUsable, "range trigger at the clamped bound");
    }

    // ==================== helpers ====================

    struct PositionInfoView {
        int24 tickLower;
        int24 tickUpper;
    }

    function _positionInfo(uint256 id) internal view returns (PoolKey memory key, PositionInfoView memory info) {
        (PoolKey memory k, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(id);
        key = k;
        info = PositionInfoView({tickLower: posInfo.tickLower(), tickUpper: posInfo.tickUpper()});
    }

    function _absoluteExitConfig(int24 exitLower) internal pure returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: exitLower,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: false,
            autoExitSwapOnUpperTrigger: false,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
    }

    function _leverageConfig() internal pure returns (RevertHookState.PositionConfig memory) {
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
            autoLeverageTargetBps: 7490
        });
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

    function _sawIndexed(Vm.Log[] memory logs, bytes32 topic, uint256 forTokenId) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == forTokenId) {
                return true;
            }
        }
        return false;
    }

    function _autoLendConfig(int24 tolerance) internal pure returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_LEND,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: tolerance,
            autoLeverageTargetBps: 0
        });
    }
}
