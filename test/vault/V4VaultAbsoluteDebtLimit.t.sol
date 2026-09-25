// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
import {V4VaultLocalBase} from "test/vault/support/V4VaultLocalBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract V4VaultAbsoluteDebtLimitTest is V4VaultLocalBase {
    function testTemporaryDepositCannotRaiseAbsoluteBudget() public {
        _deposit(lender, 1000e18);
        address token = Currency.unwrap(currency0);
        vault.setTokenConfig(token, COLLATERAL_FACTOR_X32, uint32(Q32 / 5));
        vault.setTokenDebtLimit(token, 200e18);
        oracle.setMockPositionValue(1000e18);
        uint256 id = _createLoan(10e18);
        _deposit(borrower, 500e18);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("CollateralValueLimit()"));
        vault.borrow(id, 250e18);
        _borrow(id, 200e18);
        vm.prank(borrower);
        vault.withdraw(500e18, borrower, borrower);
        assertEq(asset.balanceOf(borrower), 700e18);
    }

    function testDefaultBudgetUsesGovernanceLimitNotTemporarySupply() public {
        _deposit(lender, 1000e18);
        vault.setLimits(0, 1e30, 1000e18, 1e30, 1e30);
        vault.setTokenConfig(Currency.unwrap(currency0), COLLATERAL_FACTOR_X32, uint32(Q32 / 5));
        oracle.setMockPositionValue(1000e18);
        uint256 id = _createLoan(10e18);
        _deposit(borrower, 500e18);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("CollateralValueLimit()"));
        vault.borrow(id, 250e18);
    }
}
