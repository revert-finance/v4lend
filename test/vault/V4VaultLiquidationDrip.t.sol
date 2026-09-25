// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {V4VaultOracleLiquidationBase} from "test/vault/support/V4VaultOracleLiquidationBase.sol";

/// @dev Stand-in for the RevertHook / HookAuctionController pair: in beforeRemoveLiquidity it donates a fixed
///      amount of both currencies to the pool's in-range liquidity (the auction drip), which the removal that
///      follows then credits to the departing position as fees.
contract DrippingHook {
    IPoolManager internal immutable poolManager;
    uint256 public drip0;
    uint256 public drip1;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function setDrip(uint256 _drip0, uint256 _drip1) external {
        drip0 = _drip0;
        drip1 = _drip1;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeRemoveLiquidity = true;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        if (drip0 > 0 || drip1 > 0) {
            poolManager.donate(key, drip0, drip1, "");
            _pay(key.currency0, drip0);
            _pay(key.currency1, drip1);
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _pay(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        poolManager.settle();
    }
}

/// @notice External audit V4LE-63: liquidate() quotes the position before the removal, but the pool hook's
///         beforeRemoveLiquidity can credit new fees to the position (the auction drip donates to in-range
///         liquidity), so the removal paid the liquidator the quote plus the drip. The payout must stay
///         within the pre-hook liquidationValue; the drip belongs to the owner.
contract V4VaultLiquidationDripTest is V4VaultOracleLiquidationBase {
    DrippingHook internal hook;
    PoolKey internal hookedKey;

    function setUp() public override {
        super.setUp();
        address flags = address(uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) ^ (0x5555 << 144));
        deployCodeTo("V4VaultLiquidationDrip.t.sol:DrippingHook", abi.encode(poolManager), flags);
        hook = DrippingHook(flags);
        vault.setHookAllowList(address(hook), true);

        hookedKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(hookedKey, V4Constants.SQRT_PRICE_1_1);
        // thin full-range liquidity so the borrower's position collects almost the whole drip
        _mint(hookedKey, -887220, 887220, 1e18);
        IERC20(Currency.unwrap(currency0)).transfer(address(hook), 100e18);
        IERC20(Currency.unwrap(currency1)).transfer(address(hook), 100e18);
    }

    /// @dev Partial liquidation through the liquidity path: 85% borrowed, collateral factor lowered to 80%.
    function testDripDuringLiquidationDoesNotRaiseTheLiquidatorPayout() public {
        uint256 tokenId = _createLoan(hookedKey, -600, 600, 1e22);
        (, uint256 fullValue,,,) = vault.loanInfo(tokenId);
        vm.prank(borrower);
        vault.borrow(tokenId, fullValue * 85 / 100);
        _setCollateralFactor(uint32(Q32 * 8 / 10));
        hook.setDrip(5e18, 5e18);

        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        (,, uint256 price0X96, uint256 price1X96) = oracle.getValue(tokenId, asset);
        assertGt(liquidationValue, 0, "liquidatable");
        assertLt(liquidationValue, fullValue, "partial liquidation");

        uint256 owner0Before = currency0.balanceOf(borrower);
        uint256 owner1Before = currency1.balanceOf(borrower);
        (uint256 amount0, uint256 amount1) = _liquidateAs(liquidator, tokenId);

        uint256 received = _oracleValue(amount0, amount1, price0X96, price1X96);
        assertLe(received, liquidationValue, "the drip must not raise the liquidator's payout above the quote");
        assertGt(received, liquidationValue * 999 / 1000, "the quote itself is paid");
        uint256 ownerGot = _oracleValue(
            currency0.balanceOf(borrower) - owner0Before,
            currency1.balanceOf(borrower) - owner1Before,
            price0X96,
            price1X96
        );
        assertGt(ownerGot, 9e18, "the dripped fees reach the owner");
    }

    /// @dev Fee-only liquidation: a small debt against a position whose uncollected fees exceed it, so no
    ///      liquidity is removed and only the collected fees are split.
    function testDripDuringFeeOnlyLiquidationDoesNotRaiseTheLiquidatorPayout() public {
        uint256 tokenId = _createLoan(hookedKey, -600, 600, 1e22);
        vm.prank(borrower);
        vault.borrow(tokenId, 1e18);
        // trading fees: back-and-forth swaps that leave the pool near the oracle price
        for (uint256 i = 0; i < 4; i++) {
            _swap(hookedKey, true, 1e20);
            _swap(hookedKey, false, 1e20);
        }
        (, uint256 feeValue,,) = oracle.getValue(tokenId, asset);
        assertGt(feeValue, 1.2e18, "fees cover the debt with the maximum penalty");
        // collateral factor 0 makes the loan unhealthy; the quote is debt plus the maximum penalty
        _setCollateralFactor(0);
        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertLe(liquidationValue, feeValue, "fee-only liquidation");
        hook.setDrip(2e18, 2e18);

        (,, uint256 price0X96, uint256 price1X96) = oracle.getValue(tokenId, asset);
        uint256 owner0Before = currency0.balanceOf(borrower);
        uint256 owner1Before = currency1.balanceOf(borrower);
        (uint256 amount0, uint256 amount1) = _liquidateAs(liquidator, tokenId);

        uint256 received = _oracleValue(amount0, amount1, price0X96, price1X96);
        assertLe(received, liquidationValue, "the drip must not raise the liquidator's fee share above the quote");
        assertGt(received, liquidationValue * 999 / 1000, "the quote itself is paid");
        uint256 ownerGot = _oracleValue(
            currency0.balanceOf(borrower) - owner0Before,
            currency1.balanceOf(borrower) - owner1Before,
            price0X96,
            price1X96
        );
        assertGt(ownerGot, 3.9e18, "the dripped fees reach the owner");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "no liquidity removed");
    }

    function testDripSurplusRemainsWithBlockedOwner() public {
        uint256 tokenId = _createLoan(hookedKey, -600, 600, 1e22);
        (, uint256 fullValue,,,) = vault.loanInfo(tokenId);
        vm.prank(borrower);
        vault.borrow(tokenId, fullValue * 85 / 100);
        _setCollateralFactor(uint32(Q32 * 8 / 10));
        hook.setDrip(5e18, 5e18);
        (,,,, uint256 quote) = vault.loanInfo(tokenId);
        (,, uint256 p0, uint256 p1) = oracle.getValue(tokenId, asset);
        vm.mockCallRevert(
            Currency.unwrap(currency0), abi.encodeWithSelector(IERC20.transfer.selector, borrower), "blocked"
        );
        vm.mockCallRevert(
            Currency.unwrap(currency1), abi.encodeWithSelector(IERC20.transfer.selector, borrower), "blocked"
        );
        (uint256 a0, uint256 a1) = _liquidateAs(liquidator, tokenId);
        assertEq(currency0.balanceOf(liquidator), a0);
        assertEq(currency1.balanceOf(liquidator), a1);
        assertLe(_oracleValue(a0, a1, p0, p1), quote);
        uint256 credit0 = vault.liquidationEscrow().claimable(Currency.unwrap(currency0), borrower);
        uint256 credit1 = vault.liquidationEscrow().claimable(Currency.unwrap(currency1), borrower);
        assertGt(_oracleValue(credit0, credit1, p0, p1), 9e18);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: V4Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }
}
