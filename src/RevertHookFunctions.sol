// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IVault} from "./interfaces/IVault.sol";
import {V4Oracle} from "./V4Oracle.sol";
import {RevertHookState} from "./RevertHookState.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";

/// @title RevertHookFunctions
/// @notice Contains auto-exit, auto-range, and auto-compound functions for RevertHook (called via delegatecall)
contract RevertHookFunctions is RevertHookState {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;

    IPermit2 public immutable permit2;
    IPositionManager public immutable positionManager;
    V4Oracle public immutable v4Oracle;
    ILiquidityCalculator public immutable liquidityCalculator;
    IPoolManager public immutable poolManager;

    constructor(IPermit2 _permit2, V4Oracle _v4Oracle, ILiquidityCalculator _liquidityCalculator) Ownable(address(1)) {
        positionManager = _v4Oracle.positionManager();
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
        liquidityCalculator = _liquidityCalculator;
        poolManager = _v4Oracle.poolManager();
    }

    // ==================== Auto Exit ====================

    function autoExit(PoolKey memory poolKey, PoolId, uint256 tokenId, bool isUpper) public {
        _requireAuth(tokenId);
        (Currency c0, Currency c1, uint256 a0, uint256 a1) = _decreaseLiq(tokenId, false);
        BalanceDelta d = _swap(_getSwapPool(tokenId, poolKey), !isUpper, !isUpper ? a0 : a1, tokenId);
        (a0, a1) = _applyDelta(d, a0, a1);
        _sendLeftover(tokenId, c0, c1, _owner(tokenId, true));
        _disable(tokenId);
        emit AutoExit(tokenId, c0, c1, a0, a1);
    }

    // ==================== Auto Range ====================

    function autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) public {
        _requireAuth(tokenId);
        int24 baseTick = _tickLower(_tick(poolId), poolKey.tickSpacing);
        (Currency c0, Currency c1, uint256 a0, uint256 a1) = _decreaseLiq(tokenId, false);
        int24 tL = baseTick + positionConfigs[tokenId].autoRangeLowerDelta;
        int24 tU = baseTick + positionConfigs[tokenId].autoRangeUpperDelta;
        (a0, a1) = _optSwap(tokenId, poolKey, tL, tU, a0, a1);
        _approve(c0, a0);
        _approve(c1, a1);
        (uint256 newId,,) = _mint(poolKey, tL, tU, uint128(a0), uint128(a1), _owner(tokenId, false));
        _sendLeftover(tokenId, c0, c1, _owner(tokenId, true));
        _copyConfig(newId, positionConfigs[tokenId]);
        _disable(tokenId);
        emit AutoRange(tokenId, newId, c0, c1, a0, a1);
    }

    // ==================== Auto Compound ====================

    function autoCompound(uint256[] memory ids) external {
        for (uint256 i; i < ids.length;) {
            address o = _owner(ids[i], false);
            if (vaults[o]) {
                IVault(o).transform(ids[i], address(this), abi.encodeCall(this.autoCompoundForVault, (ids[i], msg.sender)));
            } else {
                poolManager.unlock(abi.encode(ids[i], msg.sender));
            }
            unchecked {
                ++i;
            }
        }
    }

    function autoCompoundForVault(uint256 tokenId, address caller) external {
        if (!vaults[msg.sender]) revert Unauthorized();
        _validateCaller(positionManager, tokenId);
        poolManager.unlock(abi.encode(tokenId, caller));
    }

    function executeAutoCompound(uint256 tokenId, address caller) external {
        PositionConfig storage cfg = positionConfigs[tokenId];
        AutoCompoundMode m = cfg.autoCompoundMode;
        if (m == AutoCompoundMode.NONE || cfg.mode == PositionMode.NONE) return;
        (PoolKey memory pk, PositionInfo pi) = positionManager.getPoolAndPositionInfo(tokenId);
        (,, uint256 f0, uint256 f1) = _decreaseLiq(tokenId, true);
        if (f0 == 0 && f1 == 0) return;
        if (m == AutoCompoundMode.AUTO_COMPOUND) {
            (f0, f1) = _optSwap(tokenId, pk, pi.tickLower(), pi.tickUpper(), f0, f1);
        } else if (m == AutoCompoundMode.HARVEST_TOKEN_0) {
            (f0, f1) = _applyDelta(_swap(pk, false, f1, tokenId), f0, f1);
        } else if (m == AutoCompoundMode.HARVEST_TOKEN_1) {
            (f0, f1) = _applyDelta(_swap(pk, true, f0, tokenId), f0, f1);
        }
        (f0, f1) = _rewards(tokenId, pk.currency0, pk.currency1, f0, f1, autoCompoundRewardBps, caller);
        _approve(pk.currency0, f0);
        _approve(pk.currency1, f1);
        if (m == AutoCompoundMode.AUTO_COMPOUND) {
            _incLiq(tokenId, pk, pi, uint128(f0), uint128(f1));
        }
        _sendLeftover(tokenId, pk.currency0, pk.currency1, _owner(tokenId, true));
    }

    // ==================== Helper Functions ====================

    function _owner(uint256 id, bool real) internal view returns (address) {
        address o = IERC721(address(positionManager)).ownerOf(id);
        return (real && vaults[o]) ? IVault(o).ownerOf(id) : o;
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = StateLibrary.getSlot0(poolManager, id);
    }

    function _tickLower(int24 t, int24 sp) internal pure returns (int24) {
        int24 c = t / sp;
        if (t < 0 && t % sp != 0) c--;
        return c * sp;
    }

    function _getSwapPool(uint256 id, PoolKey memory pk) internal view returns (PoolKey memory) {
        GeneralConfig storage c = generalConfigs[id];
        if (c.swapPoolFee == 0 || c.swapPoolTickSpacing == 0) return pk;
        return PoolKey({
            currency0: pk.currency0,
            currency1: pk.currency1,
            fee: c.swapPoolFee,
            tickSpacing: c.swapPoolTickSpacing,
            hooks: c.swapPoolHooks
        });
    }

    function _disable(uint256 id) internal {
        positionConfigs[id].mode = PositionMode.NONE;
        positionConfigs[id].autoCompoundMode = AutoCompoundMode.NONE;
        uint32 la = positionStates[id].lastActivated;
        if (la > 0) {
            positionStates[id].acumulatedActiveTime += uint32(block.timestamp) - la;
            positionStates[id].lastActivated = 0;
        }
        emit SetPositionConfig(id, positionConfigs[id]);
    }

    function _copyConfig(uint256 newId, PositionConfig storage old) internal {
        positionConfigs[newId] = old;
        if (positionStates[newId].lastActivated == 0) {
            positionStates[newId].lastActivated = uint32(block.timestamp);
        }
        (PoolKey memory pk,) = positionManager.getPoolAndPositionInfo(newId);
        _addTriggers(newId, pk);
        emit SetPositionConfig(newId, positionConfigs[newId]);
    }

    function _addTriggers(uint256 id, PoolKey memory pk) internal {
        PoolId pid = pk.toId();
        (, PositionInfo pi) = positionManager.getPoolAndPositionInfo(id);
        int24[4] memory t = _triggerTicks(id, pk, pi.tickLower(), pi.tickUpper());
        TickLinkedList.List storage ll = lowerTriggerAfterSwap[pid];
        TickLinkedList.List storage ul = upperTriggerAfterSwap[pid];
        if (!ul.increasing) ul.increasing = true;
        if (t[0] != type(int24).min) ll.insert(t[0], id);
        if (t[1] != type(int24).min) ll.insert(t[1], id);
        if (t[2] != type(int24).max) ul.insert(t[2], id);
        if (t[3] != type(int24).max) ul.insert(t[3], id);
    }

    function _triggerTicks(uint256 id, PoolKey memory pk, int24 tL, int24 tU) internal view returns (int24[4] memory t) {
        t[0] = type(int24).min;
        t[1] = type(int24).min;
        t[2] = type(int24).max;
        t[3] = type(int24).max;
        PositionConfig storage c = positionConfigs[id];
        PositionMode m = c.mode;
        if (m == PositionMode.NONE || m == PositionMode.AUTO_COMPOUND_ONLY) return t;
        if (m == PositionMode.AUTO_RANGE || m == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            if (c.autoRangeLowerLimit != type(int24).min) t[0] = tL - c.autoRangeLowerLimit;
            if (c.autoRangeUpperLimit != type(int24).max) t[2] = tU + c.autoRangeUpperLimit;
        }
        if (m == PositionMode.AUTO_EXIT || m == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            int24 eL = c.autoExitIsRelative
                ? (c.autoExitTickLower != type(int24).min ? tL - c.autoExitTickLower : type(int24).min)
                : c.autoExitTickLower;
            int24 eU = c.autoExitIsRelative
                ? (c.autoExitTickUpper != type(int24).max ? tU + c.autoExitTickUpper : type(int24).max)
                : c.autoExitTickUpper;
            if (t[0] != type(int24).min) t[1] = eL;
            else t[0] = eL;
            if (t[2] != type(int24).max) t[3] = eU;
            else t[2] = eU;
        }
        if (m == PositionMode.AUTO_LEND) {
            PositionState storage s = positionStates[id];
            if (s.autoLendShares > 0) {
                if (Currency.unwrap(pk.currency0) == s.autoLendToken) {
                    t[2] = tL - c.autoLendToleranceTick - pk.tickSpacing;
                } else {
                    t[0] = tU + c.autoLendToleranceTick;
                }
            } else {
                t[0] = tL - c.autoLendToleranceTick * 2 - pk.tickSpacing;
                t[2] = tU + c.autoLendToleranceTick * 2;
            }
        }
        if (m == PositionMode.AUTO_LEVERAGE) {
            int24 b = positionStates[id].autoLeverageBaseTick;
            t[0] = b - 10 * pk.tickSpacing;
            t[2] = b + 10 * pk.tickSpacing;
        }
    }

    function _optSwap(
        uint256 id,
        PoolKey memory pk,
        int24 tL,
        int24 tU,
        uint256 a0,
        uint256 a1
    ) internal returns (uint256, uint256) {
        PoolKey memory sp = _getSwapPool(id, pk);
        uint256 inp;
        bool dir;
        if (sp.hooks == pk.hooks && sp.fee == pk.fee && sp.tickSpacing == pk.tickSpacing) {
            (inp,, dir,) = liquidityCalculator.calculateSamePool(
                ILiquidityCalculator.V4PoolInfo({poolMgr: poolManager, poolIdentifier: pk.toId(), tickSpacing: pk.tickSpacing}),
                tL,
                tU,
                a0,
                a1
            );
        } else {
            (uint160 sq,,,) = StateLibrary.getSlot0(poolManager, pk.toId());
            (inp,, dir) = liquidityCalculator.calculateSimple(sq, tL, tU, a0, a1, sp.fee);
        }
        if (inp > 0) return _applyDelta(_swap(sp, dir, inp, id), a0, a1);
        return (a0, a1);
    }

    function _incLiq(
        uint256 id,
        PoolKey memory pk,
        PositionInfo pi,
        uint128 av0,
        uint128 av1
    ) internal returns (uint256, uint256) {
        uint256 b0 = pk.currency0.balanceOfSelf();
        uint256 b1 = pk.currency1.balanceOfSelf();
        (uint160 sq,,,) = StateLibrary.getSlot0(poolManager, pk.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sq, TickMath.getSqrtPriceAtTick(pi.tickLower()), TickMath.getSqrtPriceAtTick(pi.tickUpper()), av0, av1
        );
        if (liq == 0) return (0, 0);
        bytes memory act = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(id, liq, type(uint128).max, type(uint128).max, bytes(""));
        p[1] = abi.encode(pk.currency0, pk.currency1, address(this));
        try positionManager.modifyLiquiditiesWithoutUnlock(act, p) {
            return (b0 - pk.currency0.balanceOfSelf(), b1 - pk.currency1.balanceOfSelf());
        } catch (bytes memory r) {
            emit HookModifyLiquiditiesFailed(act, p, r);
            return (0, 0);
        }
    }

    function _mint(
        PoolKey memory pk,
        int24 tL,
        int24 tU,
        uint128 av0,
        uint128 av1,
        address rec
    ) internal returns (uint256 newId, uint256 a0, uint256 a1) {
        newId = positionManager.nextTokenId();
        a0 = pk.currency0.balanceOfSelf();
        a1 = pk.currency1.balanceOfSelf();
        (uint160 sq,,,) = StateLibrary.getSlot0(poolManager, pk.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sq, TickMath.getSqrtPriceAtTick(tL), TickMath.getSqrtPriceAtTick(tU), av0, av1
        );
        bytes memory act = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(pk, tL, tU, liq, av0, av1, rec, bytes(""));
        p[1] = abi.encode(pk.currency0, pk.currency1, address(this));
        try positionManager.modifyLiquiditiesWithoutUnlock(act, p) {
            a0 -= pk.currency0.balanceOfSelf();
            a1 -= pk.currency1.balanceOfSelf();
            if (vaults[rec]) IVault(rec).notifyERC721Received(newId, rec);
        } catch (bytes memory r) {
            emit HookModifyLiquiditiesFailed(act, p, r);
            a0 = 0;
            a1 = 0;
        }
    }

    function _decreaseLiq(uint256 id, bool feesOnly) internal returns (Currency c0, Currency c1, uint256 a0, uint256 a1) {
        (PoolKey memory pk,) = positionManager.getPoolAndPositionInfo(id);
        uint128 liq = feesOnly ? 0 : positionManager.getPositionLiquidity(id);
        c0 = pk.currency0;
        c1 = pk.currency1;
        bytes memory act =
            abi.encodePacked(feesOnly ? uint8(Actions.INCREASE_LIQUIDITY) : uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(id, liq, feesOnly ? type(uint128).max : 0, feesOnly ? type(uint128).max : 0, bytes(""));
        p[1] = abi.encode(c0, c1, address(this));
        try positionManager.modifyLiquiditiesWithoutUnlock(act, p) {
            a0 = c0.balanceOfSelf();
            a1 = c1.balanceOfSelf();
        } catch (bytes memory r) {
            emit HookModifyLiquiditiesFailed(act, p, r);
        }
    }

    function _swap(PoolKey memory pk, bool z2o, uint256 amt, uint256 id) internal returns (BalanceDelta d) {
        GeneralConfig storage c = generalConfigs[id];
        uint128 mul = z2o ? c.sqrtPriceMultiplier0 : c.sqrtPriceMultiplier1;
        uint160 lim;
        if (mul == 0) {
            lim = z2o ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            (uint160 sq,,,) = StateLibrary.getSlot0(poolManager, pk.toId());
            lim = uint160(FullMath.mulDiv(sq, mul, Q64));
            if (z2o && lim <= TickMath.MIN_SQRT_PRICE) lim = TickMath.MIN_SQRT_PRICE + 1;
            if (!z2o && lim >= TickMath.MAX_SQRT_PRICE) lim = TickMath.MAX_SQRT_PRICE - 1;
        }
        SwapParams memory sp = SwapParams({zeroForOne: z2o, amountSpecified: -int256(amt), sqrtPriceLimitX96: lim});
        try poolManager.swap(pk, sp, "") returns (BalanceDelta r) {
            d = r;
            _settleDeltas(pk, d);
            uint256 swapped = uint256(int256(-(z2o ? r.amount0() : r.amount1())));
            if (swapped < amt) emit HookSwapPartial(id, z2o, amt, swapped);
        } catch (bytes memory r) {
            emit HookSwapFailed(pk, sp, r);
        }
    }

    function _settleDeltas(PoolKey memory pk, BalanceDelta d) internal {
        _settleDelta(pk.currency0, d.amount0());
        _settleDelta(pk.currency1, d.amount1());
    }

    function _settleDelta(Currency c, int256 d) internal {
        if (d < 0) {
            uint256 a = uint256(-d);
            poolManager.sync(c);
            if (c.isAddressZero()) {
                poolManager.settle{value: a}();
            } else {
                c.transfer(address(poolManager), a);
                poolManager.settle();
            }
        } else if (d > 0) {
            poolManager.take(c, address(this), uint256(d));
        }
    }

    function _rewards(
        uint256 id,
        Currency c0,
        Currency c1,
        uint256 a0,
        uint256 a1,
        uint16 bps,
        address rec
    ) internal returns (uint256, uint256) {
        uint256 f0 = a0 * bps / 10000;
        uint256 f1 = a1 * bps / 10000;
        if (f0 != 0) c0.transfer(rec, f0);
        if (f1 != 0) c1.transfer(rec, f1);
        emit SendRewards(id, c0, c1, f0, f1, rec);
        return (a0 - f0, a1 - f1);
    }

    function _sendLeftover(uint256 id, Currency c0, Currency c1, address rec) internal {
        uint256 a0 = c0.balanceOfSelf();
        uint256 a1 = c1.balanceOfSelf();
        if (a0 != 0) c0.transfer(rec, a0);
        if (a1 != 0) c1.transfer(rec, a1);
        emit SendLeftoverTokens(id, c0, c1, a0, a1, rec);
    }

    function _approve(Currency t, uint256 a) internal {
        if (a != 0 && !t.isAddressZero()) {
            address addr = Currency.unwrap(t);
            if (!permit2Approved[addr]) {
                SafeERC20.forceApprove(IERC20(addr), address(permit2), type(uint256).max);
                permit2Approved[addr] = true;
            }
            permit2.approve(addr, address(positionManager), uint160(a), uint48(block.timestamp));
        }
    }

    function _requireAuth(uint256 id) internal view {
        if (msg.sender != address(poolManager)) {
            if (vaults[msg.sender]) {
                _validateCaller(positionManager, id);
            } else {
                revert Unauthorized();
            }
        }
    }

    function _applyDelta(BalanceDelta d, uint256 a0, uint256 a1) internal pure returns (uint256, uint256) {
        int128 d0 = d.amount0();
        int128 d1 = d.amount1();
        return (
            d0 < 0 ? a0 - uint256(int256(-d0)) : a0 + uint256(int256(d0)),
            d1 < 0 ? a1 - uint256(int256(-d1)) : a1 + uint256(int256(d1))
        );
    }
}
