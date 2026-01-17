// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4BaseForkTestBase} from "./V4BaseForkTestBase.sol";

/**
 * @title V4BaseVault
 * @notice Integration tests for V4Vault on Base network
 * @dev Tests collateralization, borrowing, and repayment functionality
 */
contract V4BaseVault is V4BaseForkTestBase {
    /**
     * @notice Test basic vault deposit and withdrawal
     */
    function test_DepositAndWithdraw() public {
        console.log("\n=== Test: Deposit and Withdraw on Base ===");

        uint256 depositAmount = 1_000_000_000; // 1000 USDC

        // Record initial balance
        uint256 initialBalance = usdc.balanceOf(whaleAccount);
        console.log("Initial USDC balance:", initialBalance);

        // Deposit
        vm.startPrank(whaleAccount);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, whaleAccount);
        vm.stopPrank();

        console.log("Deposited USDC:", depositAmount);
        console.log("Received shares:", shares);

        // Verify deposit
        assertEq(vault.balanceOf(whaleAccount), shares, "Should have received shares");
        assertGt(shares, 0, "Should have non-zero shares");

        // Withdraw
        vm.prank(whaleAccount);
        uint256 assets = vault.redeem(shares, whaleAccount, whaleAccount);

        console.log("Redeemed shares:", shares);
        console.log("Received USDC:", assets);

        // Verify withdrawal (should get back same amount minus any rounding)
        assertApproxEqAbs(assets, depositAmount, 1, "Should receive approximately deposited amount");
        assertEq(vault.balanceOf(whaleAccount), 0, "Should have no shares after full redeem");

        console.log("=== Deposit and Withdraw Test Passed ===\n");
    }

    /**
     * @notice Test creating a loan with V4 position as collateral
     */
    function test_CreateLoanWithCollateral() public {
        console.log("\n=== Test: Create Loan with Collateral on Base ===");

        // Create hooked pool and position
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 tokenId = _createPositionInHookedPool(hookedPoolKey);
        console.log("Created position:", tokenId);

        // Deposit liquidity to vault
        _deposit(1_000_000_000, whaleAccount); // 1000 USDC

        // Add position as collateral
        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        // Verify position is now owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault), "Vault should own position");

        // Check loan info
        (uint256 debt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        console.log("Full value:", fullValue);
        console.log("Collateral value:", collateralValue);
        console.log("Initial debt:", debt);

        assertEq(debt, 0, "Initial debt should be zero");
        assertGt(fullValue, 0, "Position should have value");
        assertGt(collateralValue, 0, "Collateral value should be non-zero");

        console.log("=== Create Loan Test Passed ===\n");
    }

    /**
     * @notice Test borrowing against collateral
     */
    function test_BorrowAgainstCollateral() public {
        console.log("\n=== Test: Borrow Against Collateral on Base ===");

        // Setup: Create position and add as collateral
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 tokenId = _createPositionInHookedPool(hookedPoolKey);

        _deposit(1_000_000_000, whaleAccount);

        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        // Get collateral value
        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        console.log("Collateral value:", collateralValue);

        // Borrow 50% of collateral value
        uint256 borrowAmount = collateralValue / 2;
        console.log("Borrowing:", borrowAmount);

        uint256 usdcBefore = usdc.balanceOf(whaleAccount);

        vm.prank(whaleAccount);
        vault.borrow(tokenId, borrowAmount);

        uint256 usdcAfter = usdc.balanceOf(whaleAccount);

        // Verify borrow
        assertEq(usdcAfter - usdcBefore, borrowAmount, "Should receive borrowed amount");

        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        assertEq(debt, borrowAmount, "Debt should equal borrowed amount");
        console.log("New debt:", debt);

        console.log("=== Borrow Test Passed ===\n");
    }

    /**
     * @notice Test repaying a loan
     */
    function test_RepayLoan() public {
        console.log("\n=== Test: Repay Loan on Base ===");

        // Setup: Create collateralized position with debt
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 tokenId = _createPositionInHookedPool(hookedPoolKey);

        _deposit(1_000_000_000, whaleAccount);

        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue / 2;

        vm.prank(whaleAccount);
        vault.borrow(tokenId, borrowAmount);

        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        console.log("Debt before repay:", debtBefore);

        // Repay half the debt
        uint256 repayAmount = debtBefore / 2;
        console.log("Repaying:", repayAmount);

        vm.prank(whaleAccount);
        usdc.approve(address(vault), repayAmount);
        vm.prank(whaleAccount);
        vault.repay(tokenId, repayAmount, false);

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        console.log("Debt after repay:", debtAfter);

        assertApproxEqAbs(debtAfter, debtBefore - repayAmount, 1, "Debt should decrease by repay amount");

        console.log("=== Repay Loan Test Passed ===\n");
    }

    /**
     * @notice Test full loan repayment and position retrieval
     */
    function test_FullRepayAndRetrievePosition() public {
        console.log("\n=== Test: Full Repay and Retrieve Position on Base ===");

        // Setup
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 tokenId = _createPositionInHookedPool(hookedPoolKey);

        _deposit(1_000_000_000, whaleAccount);

        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = collateralValue / 4; // Borrow 25%

        vm.prank(whaleAccount);
        vault.borrow(tokenId, borrowAmount);

        // Fully repay
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        console.log("Repaying full debt:", debt);

        vm.prank(whaleAccount);
        usdc.approve(address(vault), debt);
        vm.prank(whaleAccount);
        vault.repay(tokenId, debt, false);

        // Verify zero debt
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0, "Debt should be zero after full repay");

        // Remove position from vault
        vm.prank(whaleAccount);
        vault.remove(tokenId, whaleAccount, bytes(""));

        // Verify position returned to owner
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whaleAccount, "Position should be returned");

        console.log("=== Full Repay and Retrieve Test Passed ===\n");
    }

    /**
     * @notice Test that borrowing beyond collateral limit reverts
     */
    function test_CannotBorrowBeyondLimit() public {
        console.log("\n=== Test: Cannot Borrow Beyond Limit on Base ===");

        // Setup
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 tokenId = _createPositionInHookedPool(hookedPoolKey);

        _deposit(10_000_000_000, whaleAccount); // 10000 USDC

        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        console.log("Collateral value:", collateralValue);

        // Try to borrow more than collateral allows
        uint256 excessiveAmount = collateralValue + 1;
        console.log("Attempting to borrow:", excessiveAmount);

        vm.prank(whaleAccount);
        vm.expectRevert();
        vault.borrow(tokenId, excessiveAmount);

        console.log("Correctly reverted on excessive borrow");
        console.log("=== Cannot Borrow Beyond Limit Test Passed ===\n");
    }
}
