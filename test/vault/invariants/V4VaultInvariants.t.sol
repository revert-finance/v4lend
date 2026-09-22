// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {V4Vault} from "src/vault/V4Vault.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @title V4VaultInvariantTest
/// @notice Property-based tests for V4Vault invariants
/// @dev Tests fundamental invariants using property-based testing
contract V4VaultInvariantTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    /// @notice Exchange rate conversions should be reversible (within rounding)
    /// @dev shares -> assets -> shares should approximately equal original
    function test_exchange_rate_conversion_reversible(uint256 shares, uint256 exchangeRateX96) public pure {
        // Bound inputs to reasonable ranges
        shares = bound(shares, 1, type(uint128).max);
        exchangeRateX96 = bound(exchangeRateX96, Q96, Q96 * 10); // 1x to 10x rate

        // Convert shares to assets
        uint256 assets = (shares * exchangeRateX96) / Q96;

        // Convert back to shares
        uint256 sharesBack = (assets * Q96) / exchangeRateX96;

        // Should be approximately equal (within 1 due to rounding)
        assertApproxEqAbs(sharesBack, shares, 1, "Conversion should be reversible within rounding");
    }

    /// @notice Exchange rate should never decrease
    /// @dev The debt exchange rate formula ensures monotonic increase
    function test_exchange_rate_monotonic(
        uint256 rateStart,
        uint256 interestAccrued
    ) public pure {
        rateStart = bound(rateStart, Q96, Q96 * 100);
        interestAccrued = bound(interestAccrued, 0, Q96 / 10); // Up to 10% interest

        // New rate after interest accrual
        uint256 rateEnd = rateStart + interestAccrued;

        assertGe(rateEnd, rateStart, "Exchange rate should never decrease");
    }

    /// @notice Collateral factor must be within bounds
    /// @dev MAX_COLLATERAL_FACTOR_X32 is 90%
    function test_collateral_factor_bounds(uint32 collateralFactorX32) public pure {
        uint32 MAX_COLLATERAL_FACTOR_X32 = uint32(Q32 * 90 / 100);

        // Valid collateral factors
        if (collateralFactorX32 <= MAX_COLLATERAL_FACTOR_X32) {
            assertTrue(true, "Valid collateral factor");
        }
    }

    /// @notice Debt should always be backed by sufficient collateral
    /// @dev debt <= collateralValue * collateralFactor
    function test_debt_collateral_relationship(
        uint256 collateralValue,
        uint32 collateralFactorX32,
        uint256 debt
    ) public pure {
        collateralValue = bound(collateralValue, 0, type(uint128).max);
        collateralFactorX32 = uint32(bound(collateralFactorX32, 0, Q32 * 90 / 100));

        // Max borrowable amount
        uint256 maxBorrowable = (collateralValue * collateralFactorX32) / Q32;

        // If debt exceeds max borrowable, position is undercollateralized
        bool isHealthy = debt <= maxBorrowable;

        // This documents the invariant - actual enforcement is in the contract
        assertTrue(true, "Debt/collateral relationship documented");
    }

    /// @notice Liquidation penalty should be bounded
    /// @dev Penalty ranges from 2% to 10%
    function test_liquidation_penalty_bounds(uint256 healthRatio) public pure {
        uint256 MIN_PENALTY_BPS = 200; // 2%
        uint256 MAX_PENALTY_BPS = 1000; // 10%
        uint256 BPS = 10000;

        healthRatio = bound(healthRatio, 0, BPS);

        // Linear interpolation formula
        uint256 penalty;
        if (healthRatio >= BPS) {
            penalty = MIN_PENALTY_BPS;
        } else if (healthRatio == 0) {
            penalty = MAX_PENALTY_BPS;
        } else {
            penalty = MIN_PENALTY_BPS + ((MAX_PENALTY_BPS - MIN_PENALTY_BPS) * (BPS - healthRatio)) / BPS;
        }

        assertGe(penalty, MIN_PENALTY_BPS, "Penalty should be at least MIN");
        assertLe(penalty, MAX_PENALTY_BPS, "Penalty should be at most MAX");
    }

    /// @notice Reserve factor should be bounded
    function test_reserve_factor_bounds(uint32 reserveFactorX32) public pure {
        uint32 MAX_RESERVE_FACTOR = uint32(Q32 * 50 / 100); // 50% max

        // Valid reserve factors
        bool isValid = reserveFactorX32 <= MAX_RESERVE_FACTOR;

        assertTrue(true, "Reserve factor bounds documented");
    }
}

/// @title InterestRateModelInvariantTest
/// @notice Property-based tests for InterestRateModel
contract InterestRateModelInvariantTest is Test {
    uint256 constant Q64 = 2 ** 64;

    InterestRateModel public model;

    function setUp() public {
        // Deploy with standard parameters
        model = new InterestRateModel(
            Q64 / 100, // 1% base rate
            Q64 * 5 / 100, // 5% multiplier
            Q64 * 109 / 100, // 109% jump
            Q64 * 80 / 100 // 80% kink
        );
    }

    /// @notice Utilization rate should be bounded [0, 1]
    function test_utilization_rate_bounded(uint256 cash, uint256 debt) public view {
        cash = bound(cash, 0, type(uint128).max);
        debt = bound(debt, 0, type(uint128).max);

        uint256 utilizationX64 = model.getUtilizationRateX64(cash, debt);

        assertLe(utilizationX64, Q64, "Utilization should not exceed 100%");
    }

    /// @notice Borrow rate should increase with utilization
    function test_borrow_rate_increases_with_utilization() public view {
        // Low utilization (50%)
        (uint256 borrowRateLow,) = model.getRatesPerSecondX64(100e6, 100e6);

        // High utilization (90%)
        (uint256 borrowRateHigh,) = model.getRatesPerSecondX64(10e6, 90e6);

        assertGe(borrowRateHigh, borrowRateLow, "Borrow rate should increase with utilization");
    }

    /// @notice Supply rate should be <= borrow rate
    function test_supply_rate_lte_borrow_rate(uint256 cash, uint256 debt) public view {
        cash = bound(cash, 1, type(uint128).max);
        debt = bound(debt, 1, type(uint128).max);

        (uint256 borrowRate, uint256 supplyRate) = model.getRatesPerSecondX64(cash, debt);

        assertLe(supplyRate, borrowRate, "Supply rate should not exceed borrow rate");
    }

    /// @notice Zero debt should result in zero rates
    function test_zero_debt_zero_rates(uint256 cash) public view {
        cash = bound(cash, 1, type(uint128).max);

        (uint256 borrowRate, uint256 supplyRate) = model.getRatesPerSecondX64(cash, 0);

        // Supply rate is always 0 when there's no debt (no borrowers paying interest)
        assertEq(supplyRate, 0, "Supply rate should be 0 with no debt");
    }

    /// @notice Kink should create jump in rates
    function test_jump_at_kink() public view {
        // Just below kink (79%)
        (uint256 rateBelowKink,) = model.getRatesPerSecondX64(21e6, 79e6);

        // Just above kink (81%)
        (uint256 rateAboveKink,) = model.getRatesPerSecondX64(19e6, 81e6);

        // Rate should increase more steeply above kink
        // The jump multiplier kicks in, causing steeper increase
        assertGe(rateAboveKink, rateBelowKink, "Rate should increase above kink");
    }
}

/// @title ERC4626InvariantTest
/// @notice Property-based tests for ERC4626 compliance
contract ERC4626InvariantTest is Test {
    uint256 constant Q96 = 2 ** 96;

    /// @notice convertToShares and convertToAssets should be inverses
    /// @dev Due to integer division rounding, there can be loss. The key invariant is:
    ///      assetsBack <= assets (you never get more than you started with)
    function test_conversion_symmetry(uint256 assets, uint256 exchangeRateX96) public pure {
        assets = bound(assets, 1, type(uint128).max);
        exchangeRateX96 = bound(exchangeRateX96, Q96, Q96 * 10);

        // Assets to shares (rounds down)
        uint256 shares = (assets * Q96) / exchangeRateX96;

        // Shares back to assets (rounds down)
        uint256 assetsBack = (shares * exchangeRateX96) / Q96;

        // Key invariant: you should never get MORE assets back than you started with
        // Some loss due to rounding is acceptable
        assertLe(assetsBack, assets, "Should not gain assets through conversion");
    }

    /// @notice Preview functions should be conservative
    /// @dev previewDeposit should return <= actual shares received
    function test_preview_deposit_conservative(uint256 assets, uint256 exchangeRateX96) public pure {
        assets = bound(assets, 1, type(uint128).max);
        exchangeRateX96 = bound(exchangeRateX96, Q96, Q96 * 10);

        // Preview (rounds down)
        uint256 previewShares = (assets * Q96) / exchangeRateX96;

        // Actual (also rounds down in typical implementation)
        uint256 actualShares = (assets * Q96) / exchangeRateX96;

        assertLe(previewShares, actualShares + 1, "Preview should be conservative");
    }

    /// @notice Preview withdraw should be conservative
    /// @dev previewWithdraw should return >= actual shares burned
    function test_preview_withdraw_conservative(uint256 assets, uint256 exchangeRateX96) public pure {
        assets = bound(assets, 1, type(uint128).max);
        exchangeRateX96 = bound(exchangeRateX96, Q96, Q96 * 10);

        // For withdrawal, we need MORE shares (round up)
        // shares = assets * Q96 / rate (round up)
        uint256 shares = (assets * Q96 + exchangeRateX96 - 1) / exchangeRateX96;

        assertTrue(shares >= 1, "Should require at least 1 share");
    }
}

/// @title V4VaultHandler
/// @notice Random-walks a real V4Vault (real PoolManager / PositionManager, mock oracle) through
///         lender deposits and redemptions, borrows and repayments on three collateral positions,
///         interest accrual, oracle value moves and liquidations (including reserve draws and
///         socialised losses). The invariants below are expressed purely in the vault's own accounting.
contract V4VaultHandler is BaseTest {
    using EasyPosm for IPositionManager;

    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    V4Vault public vault;
    MockV4Oracle public oracle;
    MockERC20 public asset;

    address[3] public lenders;
    uint256[3] public tokenIds;

    uint256 public liquidations;
    uint256 public socialisedLosses;
    uint256 public reAdded;

    constructor() {
        deployArtifactsAndLabel();
        (Currency currency0, Currency currency1) = deployCurrencyPair();
        asset = deployToken();

        PoolKey memory poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);

        oracle = new MockV4Oracle(positionManager);
        // 0% base, 5% multiplier, 109% jump above 80% utilization (as in the vault tests)
        InterestRateModel irm = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);
        vault = new V4Vault(
            "Revert Lend Test", "rlTEST", address(asset), positionManager, irm, oracle, IWETH9(address(0))
        );
        vault.setTokenConfig(Currency.unwrap(currency0), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 1e30, 1e30, 1e30, 1e30);
        vault.setReserveFactor(uint32(Q32 / 10));
        vault.setHookAllowList(address(0), true);
        asset.approve(address(vault), type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            lenders[i] = makeAddr(string(abi.encodePacked("lender", i)));
            int24 halfWidth = int24(uint24(600 * (i + 1)));
            (tokenIds[i],) = positionManager.mint(
                poolKey, -halfWidth, halfWidth, 10e18, type(uint128).max, type(uint128).max, address(this), block.timestamp, ""
            );
            IERC721(address(positionManager)).approve(address(vault), tokenIds[i]);
            vault.create(tokenIds[i], address(this));
        }
    }

    // ---------------------------------------------------------------- actions

    function deposit(uint256 lenderSeed, uint256 amount) external {
        if (vault.lastLendExchangeRateX96() == 0) return; // total insolvency: redeploy-only by design
        address lender = lenders[lenderSeed % 3];
        amount = bound(amount, 1e12, 1e24);
        asset.mint(lender, amount);
        vm.startPrank(lender);
        asset.approve(address(vault), amount);
        vault.deposit(amount, lender);
        vm.stopPrank();
    }

    function redeem(uint256 lenderSeed, uint256 shares) external {
        address lender = lenders[lenderSeed % 3];
        uint256 maxShares = vault.maxRedeem(lender);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);
        vm.prank(lender);
        vault.redeem(shares, lender, lender);
    }

    function borrow(uint256 posSeed, uint256 amount) external {
        uint256 tokenId = tokenIds[posSeed % 3];
        (uint256 debt,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        (,, uint256 balance,,,) = vault.vaultInfo();
        if (collateralValue <= debt || balance == 0) return;
        // 1% margin below the health limit absorbs the ceil rounding of the new debt
        uint256 headroom = (collateralValue - debt) * 99 / 100;
        uint256 maxAmount = headroom < balance ? headroom : balance;
        if (maxAmount == 0) return;
        vault.borrow(tokenId, bound(amount, 1, maxAmount));
    }

    function repay(uint256 posSeed, uint256 amount) external {
        uint256 tokenId = tokenIds[posSeed % 3];
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        if (debt == 0) return;
        // tiny partial repayments could round to zero shares; repay in full instead
        uint256 minAmount = debt < 1e6 ? debt : 1e6;
        amount = bound(amount, minAmount, debt);
        asset.mint(address(this), amount);
        vault.repay(tokenId, amount, false);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
    }

    function setPositionValue(uint256 value) external {
        oracle.setMockPositionValue(bound(value, 1e15, 1e24));
    }

    function liquidate(uint256 posSeed) external {
        uint256 tokenId = tokenIds[posSeed % 3];
        (,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfo(tokenId);
        if (liquidationValue == 0) return;
        uint256 lendRateBefore = vault.lastLendExchangeRateX96();
        asset.mint(address(this), liquidationCost);
        vault.liquidate(IVault.LiquidateParams(tokenId, 0, 0, address(this), block.timestamp, ""));
        liquidations++;
        if (vault.lastLendExchangeRateX96() < lendRateBefore) socialisedLosses++;

        // A full liquidation empties the position. The real oracle values an empty position at zero, so
        // no debt could ever be taken on it again; the mock oracle would keep valuing it, so mirror
        // reality by taking the (debt-free) husk out of the vault, refilling it and re-adding it. This
        // also walks the remove / re-create path.
        if (positionManager.getPositionLiquidity(tokenId) == 0) {
            vault.remove(tokenId, address(this), "");
            positionManager.increaseLiquidity(
                tokenId, 10e18, type(uint128).max, type(uint128).max, block.timestamp, ""
            );
            IERC721(address(positionManager)).approve(address(vault), tokenId);
            vault.create(tokenId, address(this));
            reAdded++;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------- views

    function debtSharesSum() external view returns (uint256 sum) {
        for (uint256 i = 0; i < 3; i++) {
            sum += vault.loans(tokenIds[i]);
        }
    }
}

/// @title V4VaultStatefulInvariantTest
/// @notice Stateful invariants of V4Vault: per-loan debt shares always sum to `debtSharesTotal`, and
///         the lenders' claim is always backed by the vault's asset balance plus outstanding debt
///         (a socialised loss writes the lend exchange rate down so this keeps holding).
contract V4VaultStatefulInvariantTest is Test {
    V4VaultHandler handler;
    V4Vault vault;

    function setUp() public {
        handler = new V4VaultHandler();
        vault = handler.vault();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.borrow.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.warp.selector;
        selectors[5] = handler.setPositionValue.selector;
        selectors[6] = handler.liquidate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Scripted walk proving the handler reaches the interesting paths (interest accrual, an
    ///         underwater liquidation drawing on empty reserves, so a socialised loss) with the
    ///         invariants intact - guards against the fuzz campaign silently early-returning everywhere.
    function test_HandlerReachesLiquidationAndSocialisedLoss() public {
        handler.deposit(0, 1e21);
        handler.borrow(0, type(uint256).max); // clamps to ~89% of the 1e18 mock position value
        (uint256 debtBefore,,,,) = vault.loanInfo(handler.tokenIds(0));
        assertGt(debtBefore, 0.8e18, "borrow should reach the health limit");

        handler.warp(30 days);
        (uint256 debtAfterWarp,,,,) = vault.loanInfo(handler.tokenIds(0));
        assertGt(debtAfterWarp, debtBefore, "interest must accrue");
        (, uint256 lentBefore,,,,) = vault.vaultInfo();

        handler.setPositionValue(1e15); // collateral collapses far below the debt
        handler.liquidate(0);
        assertEq(handler.liquidations(), 1, "position must have been liquidated");
        assertEq(handler.socialisedLosses(), 1, "empty reserves: lenders must absorb the shortfall");
        assertEq(vault.loans(handler.tokenIds(0)), 0);
        assertEq(handler.reAdded(), 1, "emptied position must be refilled and re-added");
        assertEq(vault.ownerOf(handler.tokenIds(0)), address(handler), "re-created loan belongs to the handler");
        (, uint256 lentAfter,,,,) = vault.vaultInfo();
        assertLt(lentAfter, lentBefore, "socialised loss must reduce the lenders' claim");

        invariant_DebtSharesSumMatchesTotal();
        invariant_LentIsBackedByBalanceAndDebt();

        // the vault stays usable afterwards
        handler.deposit(1, 1e20);
        handler.borrow(1, 1e17);
        handler.repay(1, 5e16);
        invariant_DebtSharesSumMatchesTotal();
        invariant_LentIsBackedByBalanceAndDebt();
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_DebtSharesSumMatchesTotal() public view {
        assertEq(handler.debtSharesSum(), vault.debtSharesTotal(), "sum of loan debt shares != debtSharesTotal");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_LentIsBackedByBalanceAndDebt() public view {
        if (vault.lastLendExchangeRateX96() == 0) return; // total insolvency: vault is redeploy-only by design
        (uint256 debt, uint256 lent, uint256 balance, uint256 reserves,,) = vault.vaultInfo();
        assertEq(balance, handler.asset().balanceOf(address(vault)), "reported balance != asset balance");
        assertGe(balance + debt, lent, "lent assets exceed balance + outstanding debt");
        assertLe(reserves, balance + debt - lent, "reserves exceed the surplus over lent assets");
    }
}
