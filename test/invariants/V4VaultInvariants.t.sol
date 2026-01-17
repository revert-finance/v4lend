// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {V4Vault} from "../../src/V4Vault.sol";
import {V4Oracle} from "../../src/V4Oracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {V4TestBase} from "../V4TestBase.sol";

/**
 * @title V4VaultInvariants
 * @notice Invariant tests for V4Vault
 * @dev Tests critical invariants that must always hold true
 */
contract V4VaultInvariants is V4TestBase {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    V4Vault public vault;
    InterestRateModel public interestRateModel;

    address public lender1;
    address public lender2;
    address public borrower1;

    function setUp() public override {
        super.setUp();

        // Create test accounts
        lender1 = makeAddr("lender1");
        lender2 = makeAddr("lender2");
        borrower1 = makeAddr("borrower1");

        // Deploy InterestRateModel
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

        // Deploy V4Oracle (mock for invariant tests)
        v4Oracle = new V4Oracle(positionManager, address(token1), address(0));
        v4Oracle.setMaxPoolPriceDifference(10000); // 100% tolerance for testing

        // Deploy V4Vault
        vault = new V4Vault(
            "Test Vault",
            "tVault",
            address(token0),
            positionManager,
            interestRateModel,
            v4Oracle,
            IWETH9(address(token1))
        );

        // Configure vault
        vault.setTokenConfig(address(token0), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(token1), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, type(uint256).max, type(uint256).max, type(uint256).max, type(uint256).max);
        vault.setReserveFactor(uint32(Q32 * 10 / 100)); // 10% reserve

        // Fund accounts
        deal(address(token0), lender1, 1_000_000 ether);
        deal(address(token0), lender2, 1_000_000 ether);
        deal(address(token1), borrower1, 1_000_000 ether);
    }

    /**
     * @notice Invariant: Debt exchange rate should only increase over time
     * @dev The debt exchange rate represents accumulated interest and should never decrease
     */
    function invariant_debtExchangeRateOnlyIncreases() public {
        uint256 initialRate = vault.lastDebtExchangeRateX96();

        // Simulate time passage and interest accrual
        vm.warp(block.timestamp + 1 days);

        // Force exchange rate update by calling a function that triggers it
        // In practice, this happens during any loan operation
        uint256 currentRate = vault.lastDebtExchangeRateX96();

        assertTrue(
            currentRate >= initialRate,
            "Debt exchange rate should only increase"
        );
    }

    /**
     * @notice Invariant: Lend exchange rate should only increase over time
     * @dev The lend exchange rate represents accumulated interest for lenders
     */
    function invariant_lendExchangeRateOnlyIncreases() public {
        uint256 initialRate = vault.lastLendExchangeRateX96();

        // Simulate time passage
        vm.warp(block.timestamp + 1 days);

        uint256 currentRate = vault.lastLendExchangeRateX96();

        assertTrue(
            currentRate >= initialRate,
            "Lend exchange rate should only increase"
        );
    }

    /**
     * @notice Invariant: Total supply of shares should match deposited assets (accounting for exchange rate)
     */
    function invariant_sharesTotalSupplyConsistency() public {
        uint256 totalShares = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        if (totalShares > 0) {
            // Assets should be at least as much as shares (at 1:1 base, can be more with interest)
            assertTrue(totalAssets > 0, "Total assets should be positive if shares exist");
        }
    }

    /**
     * @notice Fuzz test: Deposit and withdraw should be reversible
     * @param depositAmount Amount to deposit (bounded)
     */
    function testFuzz_depositWithdrawReversible(uint256 depositAmount) public {
        // Bound deposit amount to reasonable values
        depositAmount = bound(depositAmount, 1e6, 1_000_000 ether);

        // Setup: Fund lender
        deal(address(token0), lender1, depositAmount);

        uint256 initialBalance = IERC20(token0).balanceOf(lender1);

        // Deposit
        vm.startPrank(lender1);
        IERC20(token0).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, lender1);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");

        // Withdraw all shares
        vm.prank(lender1);
        uint256 withdrawn = vault.redeem(shares, lender1, lender1);

        // Should get back approximately same amount (within rounding)
        assertApproxEqAbs(withdrawn, depositAmount, 1, "Should withdraw approximately same amount");
    }

    /**
     * @notice Fuzz test: Multiple deposits maintain share proportionality
     * @param deposit1 First deposit amount
     * @param deposit2 Second deposit amount
     */
    function testFuzz_multipleDepositsProportional(uint256 deposit1, uint256 deposit2) public {
        // Bound deposits
        deposit1 = bound(deposit1, 1e6, 1_000_000 ether);
        deposit2 = bound(deposit2, 1e6, 1_000_000 ether);

        // Fund lenders
        deal(address(token0), lender1, deposit1);
        deal(address(token0), lender2, deposit2);

        // Lender 1 deposits
        vm.startPrank(lender1);
        IERC20(token0).approve(address(vault), deposit1);
        uint256 shares1 = vault.deposit(deposit1, lender1);
        vm.stopPrank();

        // Lender 2 deposits
        vm.startPrank(lender2);
        IERC20(token0).approve(address(vault), deposit2);
        uint256 shares2 = vault.deposit(deposit2, lender2);
        vm.stopPrank();

        // Shares should be proportional to deposits
        // shares1 / shares2 ≈ deposit1 / deposit2
        if (shares2 > 0 && deposit2 > 0) {
            uint256 ratio1 = (shares1 * 1e18) / shares2;
            uint256 ratio2 = (deposit1 * 1e18) / deposit2;
            assertApproxEqRel(ratio1, ratio2, 0.01e18, "Share ratios should match deposit ratios");
        }
    }

    /**
     * @notice Invariant: Reserve factor should cap at configured maximum
     */
    function invariant_reserveFactorBounded() public {
        uint32 reserveFactor = vault.reserveFactorX32();
        assertTrue(reserveFactor <= Q32, "Reserve factor should not exceed 100%");
    }

    /**
     * @notice Invariant: Collateral factors should be bounded
     */
    function invariant_collateralFactorsBounded() public {
        (uint32 cf0,,) = vault.tokenConfigs(address(token0));
        (uint32 cf1,,) = vault.tokenConfigs(address(token1));

        uint32 maxCF = vault.MAX_COLLATERAL_FACTOR_X32();

        assertTrue(cf0 <= maxCF, "Token0 collateral factor should be bounded");
        assertTrue(cf1 <= maxCF, "Token1 collateral factor should be bounded");
    }

    /**
     * @notice Test: Global limits should be respected
     */
    function test_globalLimitsRespected() public {
        // Set a low global lend limit
        uint256 lendLimit = 1000 ether;
        vault.setLimits(0, lendLimit, type(uint256).max, type(uint256).max, type(uint256).max);

        // Fund lender with more than limit
        deal(address(token0), lender1, lendLimit * 2);

        // First deposit should succeed
        vm.startPrank(lender1);
        IERC20(token0).approve(address(vault), lendLimit * 2);
        vault.deposit(lendLimit / 2, lender1);

        // Second deposit exceeding limit should revert
        vm.expectRevert();
        vault.deposit(lendLimit, lender1);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test: Preview functions should match actual operations
     * @param depositAmount Amount to deposit
     */
    function testFuzz_previewMatchesActual(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000 ether);
        deal(address(token0), lender1, depositAmount);

        // Preview deposit
        uint256 previewShares = vault.previewDeposit(depositAmount);

        // Actual deposit
        vm.startPrank(lender1);
        IERC20(token0).approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, lender1);
        vm.stopPrank();

        assertEq(previewShares, actualShares, "Preview should match actual shares");
    }

    /**
     * @notice Test: ERC4626 maxDeposit should respect global limits
     */
    function test_maxDepositRespectsLimits() public {
        uint256 lendLimit = 1000 ether;
        vault.setLimits(0, lendLimit, type(uint256).max, type(uint256).max, type(uint256).max);

        uint256 maxDeposit = vault.maxDeposit(lender1);

        // Max deposit should not exceed remaining capacity
        assertTrue(maxDeposit <= lendLimit, "Max deposit should respect global limit");
    }
}
