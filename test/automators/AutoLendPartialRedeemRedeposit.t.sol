// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";
import {AutoLend} from "src/automators/AutoLend.sol";
import {Constants} from "src/shared/Constants.sol";
import {LimitedRedeemERC4626Vault} from "./utils/LimitedRedeemERC4626Vault.sol";

/// @notice V4LE-96 follow-up: when `AutoLend.withdraw` performs a partial redemption (`0 < sharesToRedeem < state.shares`)
///         with `addToExisting == true`, the partially redeemed liquidity is restored onto `params.tokenId` while
///         residual shares remain recorded on `lendStates[params.tokenId]`. If the pool price later moves back into
///         the out-of-range deposit zone before the vault's withdrawal limit lifts, `withdraw` is `NotReady()`, so
///         `deposit` must allow re-lending the restored LP liquidity onto the existing `LendState` rather than
///         reverting with `InvalidConfig()` and stranding the LP liquidity out of range.
contract AutoLendPartialRedeemRedepositTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;
    MockV4Oracle internal v4Oracle;
    AutoLend internal autoLend;
    LimitedRedeemERC4626Vault internal limitedVault0;
    LimitedRedeemERC4626Vault internal limitedVault1;
    address internal operator = makeAddr("operator");
    address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        v4Oracle = new MockV4Oracle(positionManager);
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), poolKey);

        // Full-range depth so swaps move ticks predictably
        positionManager.mint(
            poolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            V4Constants.ZERO_BYTES
        );

        autoLend = new AutoLend(
            positionManager,
            address(swapRouter),
            address(0),
            permit2,
            IV4Oracle(address(v4Oracle)),
            operator,
            protocolFeeRecipient
        );

        limitedVault0 = new LimitedRedeemERC4626Vault(IERC20(Currency.unwrap(currency0)), "Limited 0", "lim0");
        limitedVault1 = new LimitedRedeemERC4626Vault(IERC20(Currency.unwrap(currency1)), "Limited 1", "lim1");

        autoLend.setAutoLendVault(Currency.unwrap(currency0), IERC4626(address(limitedVault0)));
        autoLend.setAutoLendVault(Currency.unwrap(currency1), IERC4626(address(limitedVault1)));

        IERC721(address(positionManager)).setApprovalForAll(address(autoLend), true);
    }

    function _depositParams(uint256 id) internal view returns (AutoLend.DepositParams memory) {
        return AutoLend.DepositParams({
            tokenId: id,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: "",
            rewardX64: 0
        });
    }

    function _withdrawParams(uint256 id) internal view returns (AutoLend.WithdrawParams memory) {
        return AutoLend.WithdrawParams({
            tokenId: id,
            deadline: block.timestamp,
            hookData: "",
            rewardX64: 0
        });
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolKey.toId());
    }

    function testPartialWithdrawAddToExistingAllowsRedepositWhenPriceMovesBackOutOfRange() public {
        (uint256 posId,) = positionManager.mint(
            poolKey,
            -60,
            60,
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            V4Constants.ZERO_BYTES
        );

        // Deposit when tick < -60 - 120 = -180; withdraw when tick >= -60 - 60 = -120
        autoLend.configToken(
            posId,
            AutoLend.PositionConfig({
                isActive: true,
                lowerTickZone: 120,
                upperTickZone: 120,
                lowerTickZoneWithdraw: 60,
                upperTickZoneWithdraw: 60,
                maxRewardX64: 0
            })
        );

        // 1. Move tick below -180 and deposit full liquidity into limitedVault0
        swapRouter.swapExactTokensForTokens({
            amountIn: 2e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        assertLt(_currentTick(), -180, "tick below deposit threshold");

        vm.prank(operator);
        autoLend.deposit(_depositParams(posId));

        (, uint256 initialShares, uint256 initialPrincipal, address vaultAddr) = autoLend.lendStates(posId);
        assertGt(initialShares, 0, "initial deposit minted shares");
        assertEq(vaultAddr, address(limitedVault0), "lent into limitedVault0");
        assertEq(positionManager.getPositionLiquidity(posId), 0, "all LP liquidity removed on deposit");

        // 2. Move tick into [-120, -60) so withdraw is ready AND addToExisting == true
        swapRouter.swapExactTokensForTokens({
            amountIn: 1.5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        assertGe(_currentTick(), -120, "tick inside withdraw threshold");
        assertLt(_currentTick(), -60, "tick below tickLower so addToExisting is true");

        uint256 cap = initialShares / 3;
        limitedVault0.setRedeemLimit(cap);

        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(posId));

        (, uint256 residualShares, uint256 residualAmount,) = autoLend.lendStates(posId);
        assertEq(residualShares, initialShares - cap, "residual shares remain recorded");
        assertGt(positionManager.getPositionLiquidity(posId), 0, "partial liquidity restored to posId");
        assertEq(autoLend.vaultPositionCount(address(limitedVault0)), 1, "single vault reference");

        // 3. Price drops back below -180 before the vault redemption cap lifts:
        //    withdraw is NotReady(), and deposit must re-lend the restored LP liquidity onto the existing LendState
        swapRouter.swapExactTokensForTokens({
            amountIn: 1.5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        assertLt(_currentTick(), -180, "tick back below deposit threshold");

        vm.prank(operator);
        vm.expectRevert(Constants.NotReady.selector);
        autoLend.withdraw(_withdrawParams(posId));

        vm.prank(operator);
        autoLend.deposit(_depositParams(posId));

        (, uint256 accumulatedShares, uint256 accumulatedAmount,) = autoLend.lendStates(posId);
        assertGt(accumulatedShares, residualShares, "redeposit accumulated onto residual shares");
        assertGt(accumulatedAmount, residualAmount, "redeposit accumulated onto residual principal");
        assertEq(positionManager.getPositionLiquidity(posId), 0, "restored LP liquidity re-deposited");
        assertEq(autoLend.custodiedShares(address(limitedVault0)), accumulatedShares, "custodied shares match");
        assertEq(autoLend.vaultPositionCount(address(limitedVault0)), 1, "vaultPositionCount not double-incremented");

        // 4. When the vault limit lifts and price returns to [-120, -60), full withdraw clears the accumulated state
        swapRouter.swapExactTokensForTokens({
            amountIn: 1.5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });

        limitedVault0.setRedeemLimit(type(uint256).max);
        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(posId));

        (, uint256 finalShares,,) = autoLend.lendStates(posId);
        assertEq(finalShares, 0, "all shares redeemed");
        assertEq(autoLend.custodiedShares(address(limitedVault0)), 0, "custody cleared");
        assertEq(autoLend.vaultPositionCount(address(limitedVault0)), 0, "vaultPositionCount cleared");
        assertGt(positionManager.getPositionLiquidity(posId), 0, "full liquidity back in position");
        assertApproxEqAbs(accumulatedAmount, initialPrincipal, 10, "principal accounting consistent");
    }

    function testPartialWithdrawRedepositRevertsOnOppositeSideTokenMismatch() public {
        (uint256 posId,) = positionManager.mint(
            poolKey,
            -60,
            60,
            10e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            V4Constants.ZERO_BYTES
        );

        autoLend.configToken(
            posId,
            AutoLend.PositionConfig({
                isActive: true,
                lowerTickZone: 120,
                upperTickZone: 120,
                lowerTickZoneWithdraw: 60,
                upperTickZoneWithdraw: 60,
                maxRewardX64: 0
            })
        );

        // 1. Deposit token0 below range
        swapRouter.swapExactTokensForTokens({
            amountIn: 2e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        vm.prank(operator);
        autoLend.deposit(_depositParams(posId));

        (, uint256 initialShares,,) = autoLend.lendStates(posId);
        limitedVault0.setRedeemLimit(initialShares / 3);

        // 2. Partial withdraw with addToExisting == true
        swapRouter.swapExactTokensForTokens({
            amountIn: 1.5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(posId));

        // 3. Price crosses above tickUpper + upperTickZone (+180), converting restored LP liquidity to token1:
        //    deposit into token1's vault while token0 shares are still recorded on posId must revert InvalidConfig()
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
        assertGe(_currentTick(), 180, "tick above upper deposit threshold");

        vm.prank(operator);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoLend.deposit(_depositParams(posId));
    }
}
