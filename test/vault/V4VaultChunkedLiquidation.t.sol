// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {V4VaultLocalBase} from "test/vault/support/V4VaultLocalBase.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";

/// @notice V4LE-98 / V4LE-156: when the oracle reports that one v4 decrease settles less than the removal,
///         the vault splits the removal into decreases of that size inside one batch and the liquidation is
///         still total: full cost, all collateral, loan closed, one transaction.
contract V4VaultChunkedLiquidationTest is V4VaultLocalBase {
    function setUp() public override {
        super.setUp();
        _deposit(lender, 1000e18);
    }

    function testV4LE156_RemovalBeyondOneDecreaseIsSettledWholeInOneLiquidation() public {
        oracle.setMockPositionValue(1000e18);
        uint256 id = _createLoan(10e18);
        _borrow(id, 800e18);
        oracle.setMockPositionValue(850e18);
        (,,, uint256 quotedCost, uint256 quotedValue) = vault.loanInfo(id);
        assertEq(quotedValue, 850e18, "the whole position is liquidated");

        // one decrease settles at most 3e18 of the 10e18 liquidity: four decreases in one batch
        oracle.setSettlementLiquidityCap(3e18);
        asset.mint(liquidator, quotedCost);
        vm.startPrank(liquidator);
        asset.approve(address(vault), quotedCost);
        (uint256 amount0, uint256 amount1) =
            vault.liquidate(IVault.LiquidateParams(id, 0, 0, liquidator, block.timestamp, ""));
        vm.stopPrank();

        assertEq(asset.balanceOf(liquidator), 0, "the full cost was charged");
        assertGt(amount0 + amount1, 0, "collateral paid out");
        assertEq(positionManager.getPositionLiquidity(id), 0, "all liquidity removed");
        assertEq(vault.loans(id), 0, "loan closed");
        assertEq(vault.debtSharesTotal(), 0);
    }

    function testV4LE156_TooManyDecreasesIsRefused() public {
        oracle.setMockPositionValue(1000e18);
        uint256 id = _createLoan(10e18);
        _borrow(id, 800e18);
        oracle.setMockPositionValue(850e18);
        (,,, uint256 quotedCost,) = vault.loanInfo(id);
        // 10e18 / 1e17 = 100 decreases, above the 64 the helper allows
        oracle.setSettlementLiquidityCap(1e17);
        asset.mint(liquidator, quotedCost);
        vm.startPrank(liquidator);
        asset.approve(address(vault), quotedCost);
        vm.expectRevert(abi.encodeWithSignature("TooManyDecreaseChunks()"));
        vault.liquidate(IVault.LiquidateParams(id, 0, 0, liquidator, block.timestamp, ""));
        vm.stopPrank();
    }
}
