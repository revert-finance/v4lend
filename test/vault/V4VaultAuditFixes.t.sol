// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IVault} from "src/vault/interfaces/IVault.sol";
import {V4VaultLocalBase} from "test/vault/support/V4VaultLocalBase.sol";

/// @notice Regression tests for the external-audit V4Vault findings that need no oracle price model
///         (the mock oracle's position value is set directly).
contract V4VaultAuditFixesTest is V4VaultLocalBase {
    // ==================== V4LE-18: no self-liquidation ====================

    /// @dev Reserve-backed band: debt <= fullValue < debt * 1.10, so the liquidator pays fullValue - 10% of
    ///      debt and reserves (then lenders) cover the rest. Reached with a healthy 800 debt against 1000
    ///      value, then a value move to 850.
    function _reserveBackedLoan() internal returns (uint256 tokenId, uint256 liquidationCost) {
        _deposit(lender, 1000e18);
        oracle.setMockPositionValue(1000e18);
        tokenId = _createLoan(10e18);
        _borrow(tokenId, 800e18);
        oracle.setMockPositionValue(850e18);
        uint256 debt;
        (debt,,, liquidationCost,) = vault.loanInfo(tokenId);
        assertEq(debt, 800e18);
        assertApproxEqRel(liquidationCost, 850e18 - 80e18, 1e12, "liquidator pays fullValue minus the max penalty");
    }

    function testBorrowerCannotLiquidateOwnLoan() public {
        (uint256 tokenId, uint256 liquidationCost) = _reserveBackedLoan();
        // the borrower holds the borrowed asset and can afford the subsidized cost
        vm.startPrank(borrower);
        asset.approve(address(vault), liquidationCost);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vault.liquidate(IVault.LiquidateParams(tokenId, 0, 0, borrower, block.timestamp, ""));
        vm.stopPrank();
        assertEq(vault.loans(tokenId), 800e18, "loan untouched");
    }

    function testBorrowerCannotBeTheLiquidationRecipient() public {
        (uint256 tokenId, uint256 liquidationCost) = _reserveBackedLoan();
        asset.mint(liquidator, liquidationCost);
        vm.startPrank(liquidator);
        asset.approve(address(vault), liquidationCost);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vault.liquidate(IVault.LiquidateParams(tokenId, 0, 0, borrower, block.timestamp, ""));
        vm.stopPrank();
    }

    function testThirdPartyLiquidationStillWorks() public {
        (uint256 tokenId,) = _reserveBackedLoan();
        (uint256 amount0, uint256 amount1) = _liquidateAs(liquidator, tokenId, liquidator);
        assertGt(amount0 + amount1, 0, "collateral paid out");
        assertEq(vault.loans(tokenId), 0, "debt cleared");
    }

    // ==================== V4LE-86: lend allowance after a socialized loss ====================

    /// @dev The daily lend allowance is 10% of the lent amount at the day's first reset. A liquidation
    ///      whose uncovered reserve cost is written off against lenders lowers the lend exchange rate,
    ///      so the allowance snapshot refers to claims that no longer exist and must be recomputed.
    function testLiquidationHaircutShrinksSameDayLendAllowance() public {
        _deposit(lender, 1000e18);
        // nominal minimum lend quota, so today's lend allowance is 10% of the 1000 lent
        vault.setLimits(0, 1e30, 1e30, 1, 1e30);
        uint256 staleAllowance = vault.dailyLendIncreaseLimitLeft();
        assertApproxEqRel(staleAllowance, 100e18, 1e12);

        oracle.setMockPositionValue(1000e18);
        uint256 tokenId = _createLoan(10e18);
        _borrow(tokenId, 500e18);

        // the collateral collapses: 50 comes from the liquidator, reserves are empty, lenders lose 450
        oracle.setMockPositionValue(100e18);
        uint256 lendRateBefore = vault.lastLendExchangeRateX96();
        _liquidateAs(liquidator, tokenId, liquidator);
        assertLt(vault.lastLendExchangeRateX96(), lendRateBefore, "lenders took the haircut");
        (, uint256 lent,,,,) = vault.vaultInfo();
        assertApproxEqRel(lent, 550e18, 1e12, "surviving lender claim");

        uint256 allowance = vault.dailyLendIncreaseLimitLeft();
        assertLe(allowance, lent / 10, "allowance is measured against the surviving claim");
        assertGt(allowance, lent / 10 * 99 / 100, "and not below what a fresh day would grant");

        // a deposit sized on the erased claims is refused, one within the recomputed allowance passes
        asset.mint(lender, staleAllowance);
        vm.startPrank(lender);
        asset.approve(address(vault), staleAllowance);
        vm.expectRevert(abi.encodeWithSignature("DailyLendIncreaseLimit()"));
        vault.deposit(staleAllowance, lender);
        vault.deposit(allowance, lender);
        vm.stopPrank();
    }

    // ==================== V4LE-65: a no-op repay must not pin the daily debt quota ====================

    function testZeroDebtRepayDoesNotResetDailyDebtLimit() public {
        // nominal minimum debt quota: the day's quota is 10% of whatever is lent at its first debt-side action
        vault.setLimits(0, 1e30, 1e30, 1e30, 1);
        uint32 lastReset = vault.dailyDebtIncreaseLimitLastReset();
        uint256 tokenId = _createLoan(10e18); // a debt-free loan
        vm.warp(block.timestamp + 1 days); // fresh UTC day, nothing has touched the debt quota yet

        // anyone can call repay on a loan without debt (or on a token that is no loan at all)
        vm.prank(makeAddr("anyone"));
        (uint256 assets, uint256 shares) = vault.repay(tokenId, 1, false);
        assertEq(assets, 0);
        assertEq(shares, 0);
        vm.prank(makeAddr("anyone"));
        vault.repay(type(uint256).max, 1, false);
        assertEq(vault.dailyDebtIncreaseLimitLastReset(), lastReset, "a no-op repay leaves the daily quota alone");

        // the lender pool is funded afterwards
        _deposit(lender, 1000e18);
        oracle.setMockPositionValue(1000e18);

        // the first real debt-side action of the day sizes the quota from the funded pool (100 of 1000)
        _borrow(tokenId, 60e18);
        assertApproxEqRel(vault.dailyDebtIncreaseLimitLeft(), 40e18, 1e12, "quota sized from the funded pool");
    }
}
