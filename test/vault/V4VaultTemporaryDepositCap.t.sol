// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {V4VaultLocalBase} from "test/vault/support/V4VaultLocalBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice V4LE-122 / V4LE-127: a same-day lender deposit beyond the governance minimum daily lend
///         allowance must not widen the supply-relative bounds (per-token debt concentration cap, daily
///         debt quota); it settles into them the next UTC day. Withdrawals of settled supply shrink them
///         at once. The daily lend allowance is max(minimum, 10% of supply), so with a 1000 supply and a
///         10 minimum a same-day deposit is at most 100, of which 90 stays unsettled for the day. The
///         X32 fractions are floored, so 10% / 20% are a hair below their nominal values; amounts are chosen
///         one unit inside the resulting bounds.
contract V4VaultTemporaryDepositCapTest is V4VaultLocalBase {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = Currency.unwrap(currency0);
        // the lender's supply is a day old when the tests start
        _deposit(lender, 1000e18);
        vm.warp(block.timestamp + 1 days);
        // 10 of same-day inflow counts at once (bootstrap allowance), unbounded daily debt quota
        vault.setLimits(0, 1e30, 1e30, 10e18, 1e30);
        // 20% concentration factor, no absolute token budget, global debt limit far above supply
        vault.setTokenConfig(token, COLLATERAL_FACTOR_X32, uint32(Q32 / 5));
        oracle.setMockPositionValue(10_000e18);
    }

    function testV4LE122_SameDayDepositDoesNotRaiseConcentrationCap() public {
        uint256 id = _createLoan(10e18);
        // the borrower adds (almost) the whole daily allowance; only the 10 bootstrap allowance counts today
        _deposit(borrower, 99e18);
        assertEq(vault.dailyLendNetInflow(), 99e18);

        // cap: ~20% of (1000 + 10) = ~202, not ~20% of 1099 = ~219.8
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("CollateralValueLimit()"));
        vault.borrow(id, 202e18);
        _borrow(id, 201e18);

        vm.prank(borrower);
        vault.withdraw(99e18, borrower, borrower);
        assertEq(vault.dailyLendNetInflow(), 0);
        (uint256 debt,,,,) = vault.loanInfo(id);
        assertEq(debt, 201e18);
    }

    function testV4LE122_BootstrapAllowanceCountsAtOnce() public {
        // governance allows 100 of same-day inflow to count immediately (new-vault bootstrap)
        vault.setLimits(0, 1e30, 1e30, 100e18, 1e30);
        uint256 id = _createLoan(10e18);
        _deposit(borrower, 99e18);
        // settled supply: 1099 -> cap ~219.8
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("CollateralValueLimit()"));
        vault.borrow(id, 220e18);
        _borrow(id, 219e18);
    }

    function testV4LE122_WithdrawalOfSettledSupplyShrinksCapAtOnce() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 199e18);
        // a settled lender leaves: the cap follows the smaller supply immediately
        vm.prank(lender);
        vault.withdraw(500e18, lender, lender);
        assertEq(vault.dailyLendNetInflow(), 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("CollateralValueLimit()"));
        vault.borrow(id, 1e18);
    }

    function testV4LE122_NextDayDepositCountsTowardCap() public {
        uint256 id = _createLoan(10e18);
        _deposit(borrower, 99e18);
        vm.warp(block.timestamp + 1 days);
        // any lend-side touch settles yesterday's inflow
        _deposit(lender, 1e18);
        assertEq(vault.dailyLendNetInflow(), 1e18);
        // cap: ~20% of 1100 = ~219.99
        _borrow(id, 219e18);
        (uint256 debt,,,,) = vault.loanInfo(id);
        assertEq(debt, 219e18);
    }

    function testV4LE127_DailyDebtQuotaExcludesSameDayDeposit() public {
        // daily debt quota = 10% of the settled supply, no minimum
        vault.setLimits(0, 1e30, 1e30, 10e18, 0);
        vault.setTokenConfig(token, COLLATERAL_FACTOR_X32, type(uint32).max);
        uint256 id = _createLoan(10e18);
        // setLimits sized today's quota already; the borrow below is the first debt-side action of a new day
        vm.warp(block.timestamp + 1 days);
        _deposit(borrower, 99e18);
        // the first borrow of the day sizes the quota from the settled 1010 (~101), not 1099 (~109.9)
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("DailyDebtIncreaseLimit()"));
        vault.borrow(id, 101e18);
        _borrow(id, 100e18);
    }
}
