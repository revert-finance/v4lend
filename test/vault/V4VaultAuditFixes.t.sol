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
}
