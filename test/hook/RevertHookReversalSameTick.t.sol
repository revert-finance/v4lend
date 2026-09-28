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

/// @notice External audit: a vault-owned AUTO_LEVERAGE action whose own swap reverses the price
///         direction inside the oracle window made the walk requeue the remaining entries at the
///         fired tick and then park the cursor ON that tick. The next search in the same direction
///         is strictly past the cursor, so a victim AUTO_EXIT registered at the same tick stayed
///         armed and unexecuted until a full down-and-up recross, although the price never left
///         its trigger side. The requeued entries must be consumed by the continued walk.
/// @dev Fork-free (local PoolManager, real hook + V4Vault). The attacker's lend currency is chosen
///      so its deleverage swap trades AGAINST the public swap's direction, producing the reversal.
contract RevertHookReversalSameTickTest is RevertHookTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function testUpperReversalStillExecutesSameTickVictim() public {
        _run(true);
    }

    function testLowerReversalStillExecutesSameTickVictim() public {
        _run(false);
    }

    function _run(bool up) internal {
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
        // The collateral range starts at the trigger and extends 600 ticks past it. The public swap
        // lands inside it, so at the trigger the position still holds the token the deleverage
        // sells, and its swap moves the pool back by a full bucket or more.
        (uint256 attackerId,) = positionManager.mint(
            key,
            up ? int24(6) * key.tickSpacing : -int24(66) * key.tickSpacing,
            up ? int24(66) * key.tickSpacing : -int24(6) * key.tickSpacing,
            40e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Lend the currency the deleverage has to BUY: on an upward move the in-range collateral is
        // mostly currency0, so repaying a currency1 debt sells currency0 and pushes the price back down.
        Currency lendCurrency = up ? currency1 : currency0;
        V4Vault lendVault = _deployLendVault(lendCurrency);
        IERC20(Currency.unwrap(lendCurrency)).approve(address(lendVault), 2e18);
        lendVault.deposit(2e18, address(this));
        IERC721(address(positionManager)).approve(address(lendVault), attackerId);
        lendVault.create(attackerId, address(this));
        lendVault.approveTransform(attackerId, address(hook), true);
        (,, uint256 collateralValue,,) = lendVault.loanInfo(attackerId);
        lendVault.borrow(attackerId, collateralValue * 7490 / 10000);
        hook.setPositionConfig(attackerId, _leverageConfig());
        lendVault.borrow(attackerId, collateralValue * 500 / 10000); // above target: a deleverage of a few buckets

        // the victim registers AFTER the attacker at the attacker's trigger tick
        (,,,,,,, int24 base) = hook.positionStates(attackerId);
        int24 sharedTrigger = base + (up ? int24(10) : -int24(10)) * key.tickSpacing;
        uint256 victimId = _queueExit(key, sharedTrigger, up);
        uint128 victimLiquidityBefore = positionManager.getPositionLiquidity(victimId);
        assertGt(victimLiquidityBefore, 0);
        (uint256 debtBefore,,,,) = lendVault.loanInfo(attackerId);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 64e16,
            amountOutMin: 0,
            zeroForOne: !up,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the scenario: the attacker fired, its swap reversed the direction, the price is still past
        // the shared trigger
        assertTrue(_sawIndexed(logs, RevertHookState.AutoLeverage.selector, attackerId), "attacker action executed");
        (uint256 debtAfter,,,,) = lendVault.loanInfo(attackerId);
        assertLt(debtAfter, debtBefore, "attacker deleveraged");
        int24 publicTick = _outerSwapTick(logs, key);
        (, int24 tickAfter,,) = poolManager.getSlot0(key.toId());
        assertTrue(up ? tickAfter < publicTick : tickAfter > publicTick, "action reversed the price direction");
        assertTrue(up ? tickAfter >= sharedTrigger : tickAfter < sharedTrigger, "price still past the shared trigger");

        // the same-tick victim must have been consumed by the continued walk, not stranded
        assertTrue(_sawIndexed(logs, RevertHookState.AutoExit.selector, victimId), "victim exit executed in same swap");
        assertEq(positionManager.getPositionLiquidity(victimId), 0, "victim exited");
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

    function _sawIndexed(Vm.Log[] memory logs, bytes32 topic, uint256 forTokenId) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == forTokenId) {
                return true;
            }
        }
        return false;
    }

    function _outerSwapTick(Vm.Log[] memory logs, PoolKey memory key) internal view returns (int24) {
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 poolIdHash = PoolId.unwrap(key.toId());
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(poolManager) && logs[i].topics.length >= 3 && logs[i].topics[0] == swapTopic
                    && logs[i].topics[1] == poolIdHash
                    && address(uint160(uint256(logs[i].topics[2]))) == address(swapRouter)
            ) {
                (,,,, int24 tick,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return tick;
            }
        }
        revert("outer swap event missing");
    }
}
