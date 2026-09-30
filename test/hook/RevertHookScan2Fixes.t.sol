// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";

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

    // ==================== helpers ====================

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
