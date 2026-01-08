// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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

/// @title RevertHookFunctions2
/// @notice Contains leverage and auto-lend related functions for RevertHook (called via delegatecall)
contract RevertHookFunctions2 is RevertHookState {
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

    // ==================== Auto Leverage ====================

    function autoLeverage(PoolKey memory poolKey, PoolId, uint256 tokenId, bool isUp) public {
        _requireAuth(tokenId);
        IVault v = IVault(msg.sender);
        (uint256 debt,, uint256 cVal,,) = v.loanInfo(tokenId);
        uint16 target = positionConfigs[tokenId].autoLeverageTargetBps;
        uint256 ratio = cVal > 0 ? debt * 10000 / cVal : 0;
        if (ratio < target) {
            _leverageUp(poolKey, tokenId, v, debt, cVal, target);
        } else if (ratio > target) {
            _leverageDown(poolKey, tokenId, v, debt, cVal, target);
        }
        _removeTriggers(tokenId, poolKey);
        positionStates[tokenId].autoLeverageBaseTick =
            (_tickLower(_tick(poolKey.toId()), poolKey.tickSpacing) / poolKey.tickSpacing) * poolKey.tickSpacing;
        _addTriggers(tokenId, poolKey);
        (uint256 newDebt,,,,) = v.loanInfo(tokenId);
        emit AutoLeverage(tokenId, isUp, debt, newDebt);
    }

    function _leverageUp(
        PoolKey memory pk,
        uint256 id,
        IVault v,
        uint256 debt,
        uint256 cVal,
        uint16 target
    ) internal {
        if (debt * 10000 >= cVal * target) return;
        uint256 d = 10000 - uint256(target);
        if (d == 0) return;
        uint256 borrowAmt = (uint256(target) * cVal - debt * 10000) / d;
        if (borrowAmt == 0) return;
        Currency lendToken = Currency.wrap(v.asset());
        v.borrow(id, borrowAmt);
        (, PositionInfo pi) = positionManager.getPoolAndPositionInfo(id);
        (uint256 a0, uint256 a1) = _optSwap(
            id, pk, pi.tickLower(), pi.tickUpper(), lendToken == pk.currency0 ? borrowAmt : 0, lendToken == pk.currency1 ? borrowAmt : 0
        );
        _approve(pk.currency0, a0);
        _approve(pk.currency1, a1);
        _incLiq(id, pk, pi, uint128(a0), uint128(a1));
        _sendLeftover(id, pk.currency0, pk.currency1, _owner(id, true));
    }

    function _leverageDown(
        PoolKey memory pk,
        uint256 id,
        IVault v,
        uint256 debt,
        uint256 cVal,
        uint16 target
    ) internal {
        if (debt * 10000 <= cVal * target) return;
        uint256 d = 10000 - uint256(target);
        if (d == 0) return;
        uint256 repayAmt = (debt * 10000 - uint256(target) * cVal) / d;
        Currency lendToken = Currency.wrap(v.asset());
        uint128 liq = positionManager.getPositionLiquidity(id);
        (uint256 fullVal,,,) = v4Oracle.getValue(id, v.asset());
        if (fullVal == 0 || liq == 0) return;
        uint128 removeLiq = uint128(uint256(liq) * repayAmt / fullVal);
        if (removeLiq > liq) removeLiq = liq;
        if (removeLiq == 0) return;
        (Currency c0, Currency c1, uint256 a0, uint256 a1) = _decreaseLiqPartial(id, removeLiq);
        uint256 lendAmt = _swapToLendToken(id, pk, lendToken, c0, c1, a0, a1);
        if (lendAmt > 0) {
            if (lendAmt > debt) lendAmt = debt;
            SafeERC20.forceApprove(IERC20(Currency.unwrap(lendToken)), msg.sender, lendAmt);
            v.repay(id, lendAmt, false);
        }
        _sendLeftover(id, c0, c1, _owner(id, true));
    }

    // ==================== Auto Lend ====================

    function autoLendForceExit(uint256 tokenId) external {
        address o = _owner(tokenId, true);
        if (msg.sender != o) revert Unauthorized();
        (PoolKey memory pk,) = positionManager.getPoolAndPositionInfo(tokenId);
        _removeTriggers(tokenId, pk);
        PositionState storage ps = positionStates[tokenId];
        if (ps.autoLendShares > 0) {
            uint256 amt = IERC4626(ps.autoLendVault).redeem(ps.autoLendShares, address(this), address(this));
            _handleLendGain(tokenId, pk, Currency.wrap(ps.autoLendToken), amt, ps.autoLendAmount);
            _sendLeftover(tokenId, pk.currency0, pk.currency1, o);
            emit AutoLendForceExit(tokenId, Currency.wrap(ps.autoLendToken), amt, ps.autoLendShares);
        }
        _resetLendState(tokenId);
        _disable(tokenId);
    }

    function autoLendDeposit(PoolKey memory pk, PoolId, uint256 tokenId, bool isUp) external {
        _removeTriggers(tokenId, pk);
        (Currency c0, Currency c1, uint256 a0, uint256 a1) = _decreaseLiq(tokenId, false);
        Currency c = isUp ? c1 : c0;
        address addr = Currency.unwrap(c);
        uint256 amt = isUp ? a1 : a0;
        IERC4626 vault = autoLendVaults[addr];
        if (address(vault) == address(0)) return;
        SafeERC20.forceApprove(IERC20(addr), address(vault), amt);
        try vault.deposit(amt, address(this)) returns (uint256 sh) {
            positionStates[tokenId].autoLendShares = sh;
            positionStates[tokenId].autoLendToken = addr;
            positionStates[tokenId].autoLendAmount = amt;
            positionStates[tokenId].autoLendVault = address(vault);
            _sendLeftover(tokenId, c0, c1, _owner(tokenId, true));
            _addTriggers(tokenId, pk);
            emit AutoLendDeposit(tokenId, c, amt, sh);
        } catch (bytes memory r) {
            emit HookAutoLendFailed(address(vault), c, r);
        }
        SafeERC20.forceApprove(IERC20(addr), address(vault), 0);
    }

    function autoLendWithdraw(PoolKey memory pk, uint256 tokenId, uint256 shares) external {
        PositionState storage ps = positionStates[tokenId];
        try IERC4626(ps.autoLendVault).redeem(shares, address(this), address(this)) returns (uint256 amt) {
            _processLendWithdraw(pk, tokenId, ps.autoLendToken, amt, ps.autoLendAmount);
        } catch (bytes memory r) {
            emit HookAutoLendFailed(address(autoLendVaults[ps.autoLendToken]), Currency.wrap(ps.autoLendToken), r);
        }
    }

    function _processLendWithdraw(
        PoolKey memory pk,
        uint256 tokenId,
        address tok,
        uint256 amt,
        uint256 lendAmt
    ) internal {
        _handleLendGain(tokenId, pk, Currency.wrap(tok), amt, lendAmt);
        (, PositionInfo pi) = positionManager.getPoolAndPositionInfo(tokenId);
        _approve(Currency.wrap(tok), amt);
        uint256 newId;
        int24 base = _tickLower(_tick(pk.toId()), pk.tickSpacing);
        if (tok == Currency.unwrap(pk.currency0)) {
            if (base < pi.tickLower()) {
                _incLiq(tokenId, pk, pi, uint128(amt), 0);
            } else {
                (newId,,) = _mint(
                    pk, base + pk.tickSpacing, base + pk.tickSpacing + (pi.tickUpper() - pi.tickLower()), uint128(amt), 0, _owner(tokenId, false)
                );
            }
        } else {
            if (base >= pi.tickUpper()) {
                _incLiq(tokenId, pk, pi, 0, uint128(amt));
            } else {
                (newId,,) = _mint(pk, base - (pi.tickUpper() - pi.tickLower()), base, 0, uint128(amt), _owner(tokenId, false));
            }
        }
        _resetLendState(tokenId);
        _sendLeftover(tokenId, pk.currency0, pk.currency1, _owner(tokenId, true));
        if (newId > 0) {
            _copyConfig(newId, positionConfigs[tokenId]);
            _disable(tokenId);
        } else {
            _addTriggers(tokenId, pk);
        }
        emit AutoLendWithdraw(tokenId, Currency.wrap(tok), amt, positionStates[tokenId].autoLendShares);
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

    function _handleLendGain(uint256 id, PoolKey memory pk, Currency c, uint256 amt, uint256 lendAmt) internal {
        uint256 gain = amt > lendAmt ? amt - lendAmt : 0;
        if (gain > 0) {
            bool is0 = pk.currency0 == c;
            c.transfer(protocolFeeRecipient, gain * protocolFeeBps / 10000);
            emit SendProtocolFee(id, pk.currency0, pk.currency1, is0 ? gain : 0, is0 ? 0 : gain, protocolFeeRecipient);
        }
    }

    function _resetLendState(uint256 id) internal {
        PositionState storage s = positionStates[id];
        s.autoLendShares = 0;
        s.autoLendToken = address(0);
        s.autoLendAmount = 0;
        s.autoLendVault = address(0);
    }

    function _swapToLendToken(
        uint256 id,
        PoolKey memory pk,
        Currency lendToken,
        Currency c0,
        Currency c1,
        uint256 a0,
        uint256 a1
    ) internal returns (uint256) {
        PoolKey memory sp = _getSwapPool(id, pk);
        if (lendToken == c0) {
            if (a1 > 0) _swap(sp, false, a1, id);
            return c0.balanceOfSelf();
        } else {
            if (a0 > 0) _swap(sp, true, a0, id);
            return c1.balanceOfSelf();
        }
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

    function _removeTriggers(uint256 id, PoolKey memory pk) internal {
        PoolId pid = pk.toId();
        (, PositionInfo pi) = positionManager.getPoolAndPositionInfo(id);
        int24[4] memory t = _triggerTicks(id, pk, pi.tickLower(), pi.tickUpper());
        TickLinkedList.List storage ll = lowerTriggerAfterSwap[pid];
        TickLinkedList.List storage ul = upperTriggerAfterSwap[pid];
        if (t[0] != type(int24).min) ll.remove(t[0], id);
        if (t[1] != type(int24).min) ll.remove(t[1], id);
        if (t[2] != type(int24).max) ul.remove(t[2], id);
        if (t[3] != type(int24).max) ul.remove(t[3], id);
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

    function _decreaseLiqPartial(uint256 id, uint128 rem) internal returns (Currency c0, Currency c1, uint256 a0, uint256 a1) {
        (PoolKey memory pk,) = positionManager.getPoolAndPositionInfo(id);
        c0 = pk.currency0;
        c1 = pk.currency1;
        bytes memory act = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(id, rem, 0, 0, bytes(""));
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
