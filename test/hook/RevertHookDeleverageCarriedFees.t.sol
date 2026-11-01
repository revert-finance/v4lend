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
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";
import {IRemintMigrationHook} from "src/vault/interfaces/IRemintMigrationHook.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

contract PoolDonator {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        poolManager.unlock(abi.encode(key, amount0, amount1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));
        poolManager.donate(key, amount0, amount1, "");
        if (amount0 > 0) {
            poolManager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), amount0);
            poolManager.settle();
        }
        if (amount1 > 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), amount1);
            poolManager.settle();
        }
        return "";
    }
}

contract FeeAwareProportionalOracle is IV4Oracle {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    error MockPoolPriceUnavailable();

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    uint256 public immutable targetTokenId;
    uint128 public immutable baseLiquidity;
    uint256 public immutable baseValue;

    mapping(address => mapping(address => PoolKey)) public poolKeys;
    uint256 public mockPositionValue = 1 ether;
    bool public revertPoolPrice;

    constructor(IPositionManager _pm, uint256 _targetTokenId, uint128 _baseLiquidity, uint256 _baseValue) {
        positionManager = _pm;
        poolManager = _pm.poolManager();
        targetTokenId = _targetTokenId;
        baseLiquidity = _baseLiquidity;
        baseValue = _baseValue;
    }

    function getLiquidityForValue(uint256 tokenId, address, uint256 target)
        external
        view
        returns (uint128, uint256, uint256, uint256)
    {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        uint128 sized =
            target >= mockPositionValue ? liquidity : uint128(FullMath.mulDiv(target, liquidity, mockPositionValue));
        return (sized, 0, 0, FixedPoint96.Q96);
    }

    function getRiskScore(uint256, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function validateRiskChange(uint256 id, address asset, uint256 debt, uint256) external view {
        if (debt != 0) validateBorrow(id, asset);
    }

    function validateBorrow(uint256 id, address asset) public view {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(id);
        if (address(key.hooks) != address(0)) IRemintMigrationHook(address(key.hooks)).validateVaultPosition(id, asset);
    }

    function setMockPositionValue(uint256 value) external {
        mockPositionValue = value;
    }

    function setRevertPoolPrice(bool shouldRevert) external {
        revertPoolPrice = shouldRevert;
    }

    function setPoolKey(address token0, address token1, PoolKey memory poolKey) external {
        poolKeys[token0][token1] = poolKey;
    }

    function getPoolSqrtPriceX96(address token0, address token1) external view returns (uint160 sqrtPriceX96) {
        if (revertPoolPrice) {
            revert MockPoolPriceUnavailable();
        }
        if (token0 == token1) {
            return uint160(FixedPoint96.Q96);
        }
        PoolKey memory poolKey = poolKeys[token0][token1];
        PoolId poolId = poolKey.toId();
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    function getValue(uint256 tokenId, address) external view returns (uint256, uint256, uint256, uint256) {
        if (tokenId != targetTokenId) {
            return (mockPositionValue, 0, 0, 0);
        }
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        int24 lower = info.tickLower();
        int24 upper = info.tickUpper();
        (uint128 liq, uint256 fg0Last, uint256 fg1Last) =
            StateLibrary.getPositionInfo(poolManager, poolId, address(positionManager), lower, upper, bytes32(tokenId));
        if (liq == 0) return (0, 0, FixedPoint96.Q96, FixedPoint96.Q96);
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, lower, upper);
        uint256 fees0;
        uint256 fees1;
        unchecked {
            fees0 = FullMath.mulDiv(fg0 - fg0Last, liq, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(fg1 - fg1Last, liq, FixedPoint128.Q128);
        }
        uint256 feeValue = fees0 + fees1;
        uint256 principalValue = FullMath.mulDiv(baseValue, liq, baseLiquidity);
        return (principalValue + feeValue, feeValue, FixedPoint96.Q96, FixedPoint96.Q96);
    }

    function getPositionBreakdown(uint256)
        external
        pure
        returns (Currency, Currency, uint24, uint128, uint256, uint256, uint128, uint128)
    {
        return (Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, 0, 0, 0, 0);
    }

    function getLiquidityAndFees(uint256) external pure returns (uint128, uint128, uint128) {
        return (0, 0, 0);
    }
}

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

    function testDeleverageWithAccruedFeesPartialPrincipalRemovalDoesNotOvershoot() public {
        (PoolKey memory key, V4Vault lendVault, uint256 leveredTokenId, address alice) =
            _setupFeeAwareLeveredPosition(30e18, 20e18);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(leveredTokenId);
        (uint256 debtBefore,,,,) = lendVault.loanInfo(leveredTokenId);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 60e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawActionFailed(logs, leveredTokenId), "deleverage with accrued fees must not fail");
        assertTrue(_sawAutoLeverageExecuted(logs, leveredTokenId), "deleverage must execute");
        assertFalse(hook.autoLeverageNeedsAttention(leveredTokenId), "position must not need attention");

        uint128 liquidityAfter = positionManager.getPositionLiquidity(leveredTokenId);
        assertLt(liquidityAfter, liquidityBefore, "partial principal removed for remaining repay need");
        assertGt(liquidityAfter, 0, "position not fully drained");

        (uint256 debtAfter,, uint256 collateralAfter,,) = lendVault.loanInfo(leveredTokenId);
        assertLt(debtAfter, debtBefore, "debt reduced");
        uint256 ratioAfterBps = debtAfter * 10000 / collateralAfter;
        assertGe(ratioAfterBps, 4700, "post-repay ratio must not overshoot below target - tolerance");
        assertLe(ratioAfterBps, 5000, "post-repay ratio must not exceed target");
        assertEq(alice.balance, 0);
    }

    function testDeleverageWithAccruedFeesExceedingRepayAmountCollectsFeesOnlyAndCapsRepay() public {
        (PoolKey memory key, V4Vault lendVault, uint256 leveredTokenId, address alice) =
            _setupFeeAwareLeveredPosition(25e18, 35e18);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(leveredTokenId);
        (uint256 debtBefore,,,,) = lendVault.loanInfo(leveredTokenId);
        uint256 aliceToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 60e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawActionFailed(logs, leveredTokenId), "fee-only deleverage must not fail");
        assertTrue(_sawAutoLeverageExecuted(logs, leveredTokenId), "deleverage must execute");
        assertFalse(hook.autoLeverageNeedsAttention(leveredTokenId), "position must not need attention");

        uint128 liquidityAfter = positionManager.getPositionLiquidity(leveredTokenId);
        assertEq(liquidityAfter, liquidityBefore, "zero principal removed when accrued fees cover repayAmount");

        (uint256 debtAfter,, uint256 collateralAfter,,) = lendVault.loanInfo(leveredTokenId);
        assertLt(debtAfter, debtBefore, "debt reduced by capped fee repayment");
        uint256 ratioAfterBps = debtAfter * 10000 / collateralAfter;
        assertApproxEqAbs(ratioAfterBps, 5000, 1, "capped repayment lands at target ratio");

        uint256 aliceToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(alice);
        assertGt(aliceToken1After, aliceToken1Before, "excess collected fees sent to position owner");
    }

    function testDeleverageWithMinLoanSizeAboveTargetDebtClampsPartialRepaymentToMinLoanSize() public {
        (PoolKey memory key, V4Vault lendVault, uint256 leveredTokenId,) = _setupFeeAwareLeveredPosition(25e18, 35e18);
        uint256 minLoan = 52e18;
        lendVault.setLimits(minLoan, 1000e18, 1000e18, 1000e18, 1000e18);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 60e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawActionFailed(logs, leveredTokenId), "deleverage must not revert on MinLoanSize");
        assertTrue(_sawAutoLeverageExecuted(logs, leveredTokenId), "deleverage must execute");
        (uint256 debtAfter,,,,) = lendVault.loanInfo(leveredTokenId);
        assertEq(debtAfter, minLoan, "remaining debt clamped to minLoanSize when proceeds cannot clear full debt");
    }

    function testDeleverageWithMinLoanSizeAboveTargetDebtAllowsFullRepaymentWhenProceedsCoverDebt() public {
        (PoolKey memory key, V4Vault lendVault, uint256 leveredTokenId,) =
            _setupFeeAwareLeveredPositionWithTarget(2000, 11e18, 35e18);
        lendVault.setLimits(25e18, 1000e18, 1000e18, 1000e18, 1000e18);

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 60e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawActionFailed(logs, leveredTokenId), "full repayment must not be blocked by minLoanSize");
        assertTrue(_sawAutoLeverageExecuted(logs, leveredTokenId), "deleverage must execute");
        (uint256 debtAfter,,,,) = lendVault.loanInfo(leveredTokenId);
        assertEq(debtAfter, 0, "full debt repaid when proceeds cover currentDebt and targetDebt < minLoanSize");
    }

    function _setupFeeAwareLeveredPosition(uint256 extraBorrow, uint256 donatedFees1)
        internal
        returns (PoolKey memory key, V4Vault lendVault, uint256 leveredTokenId, address alice)
    {
        return _setupFeeAwareLeveredPositionWithTarget(5000, extraBorrow, donatedFees1);
    }

    function _setupFeeAwareLeveredPositionWithTarget(uint16 targetBps, uint256 extraBorrow, uint256 donatedFees1)
        internal
        returns (PoolKey memory key, V4Vault lendVault, uint256 leveredTokenId, address alice)
    {
        alice = makeAddr("alice");
        key = PoolKey({
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

        uint128 posLiquidity = 18000e18;
        (leveredTokenId,) = positionManager.mint(
            key,
            -6 * key.tickSpacing,
            6 * key.tickSpacing,
            posLiquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        (, uint256 baseValue) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(6 * key.tickSpacing),
            TickMath.getSqrtPriceAtTick(-6 * key.tickSpacing),
            TickMath.getSqrtPriceAtTick(6 * key.tickSpacing),
            posLiquidity
        );
        FeeAwareProportionalOracle impl =
            new FeeAwareProportionalOracle(positionManager, leveredTokenId, posLiquidity, baseValue);
        vm.etch(address(v4Oracle), address(impl).code);

        lendVault = _deployLendVault(currency1);
        lendVault.setLimits(0, 1000e18, 1000e18, 1000e18, 1000e18);
        IERC20(Currency.unwrap(currency1)).approve(address(lendVault), 500e18);
        lendVault.deposit(500e18, address(this));

        IERC721(address(positionManager)).approve(address(lendVault), leveredTokenId);
        lendVault.create(leveredTokenId, alice);

        vm.startPrank(alice);
        lendVault.approveTransform(leveredTokenId, address(hook), true);
        (,, uint256 collateralValue,,) = lendVault.loanInfo(leveredTokenId);
        lendVault.borrow(leveredTokenId, collateralValue * targetBps / 10000);
        hook.setPositionConfig(leveredTokenId, _autoLeverageConfig(targetBps));
        lendVault.borrow(leveredTokenId, extraBorrow);
        vm.stopPrank();

        PoolDonator donator = new PoolDonator(poolManager);
        IERC20(Currency.unwrap(currency1)).transfer(address(donator), donatedFees1);
        donator.donate(key, 0, donatedFees1);
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
