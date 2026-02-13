// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

// base contracts
import {V4Vault} from "../../src/V4Vault.sol";
import {V4Oracle, AggregatorV3Interface} from "../../src/V4Oracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

// transformers
import {LeverageTransformer} from "../../src/transformers/LeverageTransformer.sol";
import {V4Utils} from "../../src/transformers/V4Utils.sol";
import {FlashloanLiquidator} from "../../src/utils/FlashloanLiquidator.sol";
import {IUniswapV3Pool} from "../../src/utils/FlashloanLiquidator.sol";

import {Constants} from "../../src/utils/Constants.sol";
import {Swapper} from "../../src/utils/Swapper.sol";

import {V4ForkTestBase} from "./V4ForkTestBase.sol";

contract V4VaultTest is V4ForkTestBase {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    uint256 constant YEAR_SECS = 31557600; // taking into account leap years

    address WHALE_ACCOUNT = 0x4CD83180d9b62405d1178ed8Dcef6D251F31Fc40;

    V4Vault vault;

    InterestRateModel interestRateModel;

    function setUp() public override {
        super.setUp(); // Call V4ForkTestBase setUp first

        // 0% base rate - 5% multiplier - after 80% - 109% jump multiplier (like in compound v2 deployed)  (-> max rate 25.8% per year)
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

        vault = new V4Vault(
            "Revert Lend usdc", 
            "rlusdc", 
            address(usdc), 
            positionManager, 
            interestRateModel, 
            v4Oracle,
            weth
        );
        
        vault.setTokenConfig(address(usdc), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(dai), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(weth), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(wbtc), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(0), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value

        // limits 1000 usdc each
        vault.setLimits(0, 1000000000, 1000000000, 1000000000, 1000000000);

        // without reserve for now
        vault.setReserveFactor(0);

        // allow positions without hooks (address(0))
        vault.setHookAllowList(address(0), true);

        vault.setTransformer(address(v4Utils), true);
        v4Utils.setVault(address(vault));
    }


    function _setupBasicLoan(bool borrowMax) internal {
        // lend 200 usdc
        _deposit(200000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(nft1Owner);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);
        vm.prank(nft1Owner);
        vault.create(nft1TokenId, nft1Owner);

        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        assertEq(collateralValue, 126342057);
        assertEq(fullValue, 140380064);

        if (borrowMax) {
            // borrow max
            uint256 buffer = vault.BORROW_SAFETY_BUFFER_X32();
            vm.prank(nft1Owner);
            vault.borrow(nft1TokenId, collateralValue * buffer / Q32);
        }
    }

    function _setupBasicLoanWithETH(bool borrowMax) internal {
        // lend 500 usdc
        _deposit(500000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(nft2Owner);
        IERC721(address(positionManager)).approve(address(vault), nft2TokenId);
        vm.prank(nft2Owner);
        vault.create(nft2TokenId, nft2Owner);

        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        assertEq(collateralValue, 126342057);
        assertEq(fullValue, 140380064);

        if (borrowMax) {
            // borrow max
            uint256 buffer = vault.BORROW_SAFETY_BUFFER_X32();
            vm.prank(nft2Owner);
            vault.borrow(nft2TokenId, collateralValue * buffer / Q32);
        }
    }

    function _repay(uint256 amount, address account, uint256 tokenId, bool complete) internal {
        vm.prank(account);
        usdc.approve(address(vault), amount);
        if (complete) {
            (uint256 debtShares) = vault.loans(tokenId);
            vm.prank(account);
            vault.repay(tokenId, debtShares, true);
        } else {
            vm.prank(account);
            vault.repay(tokenId, amount, false);
        }
    }

    function _deposit(uint256 amount, address account) internal {
        vm.prank(account);
        usdc.approve(address(vault), amount);
        console.log("Balance of usdc before deposit:", usdc.balanceOf(account));
        console.log("Address of account:", account);
        vm.prank(account);
        vault.deposit(amount, account);
        console.log("Balance of usdc after deposit:", usdc.balanceOf(account));
    }

    function _createAndBorrow(uint256 tokenId, address account, uint256 amount) internal {
        vm.prank(account);
        IERC721(address(positionManager)).approve(address(vault), tokenId);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(V4Vault.create, (tokenId, account));
        calls[1] = abi.encodeCall(V4Vault.borrow, (tokenId, amount));

        vm.prank(account);
        vault.multicall(calls);
    }

    function test_HooklessPoolBlockedWhenZeroHookIsNotAllowlisted() external {
        vault.setHookAllowList(address(0), false);

        vm.prank(nft1Owner);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);
        vm.expectRevert(Constants.HookNotAllowed.selector);
        vm.prank(nft1Owner);
        vault.create(nft1TokenId, nft1Owner);
    }

    function testMinLoanSize() external {
        uint256 minLoanSize = 1000000;

        vault.setLimits(1000000, 1000000000, 1000000000, 1000000000, 1000000000);

        // lend 10 usdc
        _deposit(20000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(nft1Owner);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);
        vm.prank(nft1Owner);
        vault.create(nft1TokenId, nft1Owner);

        vm.expectRevert(Constants.MinLoanSize.selector);
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, minLoanSize - 1);

        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, minLoanSize);

        vm.prank(nft1Owner);
        usdc.approve(address(vault), minLoanSize);

        vm.expectRevert(Constants.MinLoanSize.selector);
        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, 1, false);

        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, minLoanSize, false);
    }


    function testERC20() external {

        _setupBasicLoan(false);

        uint256 assets = vault.balanceOf(WHALE_ACCOUNT);

        assertEq(vault.balanceOf(WHALE_ACCOUNT), assets);
        assertEq(vault.lendInfo(WHALE_ACCOUNT), assets);

        vm.prank(WHALE_ACCOUNT);
        vault.transfer(nft1Owner, assets);

        assertEq(vault.balanceOf(WHALE_ACCOUNT), 0);
        assertEq(vault.lendInfo(WHALE_ACCOUNT), 0);
        assertEq(vault.balanceOf(nft1Owner), assets);
        assertEq(vault.lendInfo(nft1Owner), assets);
    }



    // fuzz testing deposit amount
    function testDeposit(uint256 amount) external {
        uint256 balance = usdc.balanceOf(WHALE_ACCOUNT);
        vm.assume(amount <= balance * 10);

        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), amount);

        uint256 lendLimit = vault.globalLendLimit();
        uint256 dailyDepositLimit = vault.dailyLendIncreaseLimitMin();

        if (amount > lendLimit) {
            vm.expectRevert(Constants.GlobalLendLimit.selector);
        } else if (amount > dailyDepositLimit) {
            vm.expectRevert(Constants.DailyLendIncreaseLimit.selector);
        } else if (amount > balance) {
            vm.expectRevert("ERC20: transfer amount exceeds balance");
        }

        vm.prank(WHALE_ACCOUNT);
        vault.deposit(amount, WHALE_ACCOUNT);
    }

    // fuzz testing withdraw amount
    function testWithdraw(uint256 amount) external {

        // 0 borrow loan
        _setupBasicLoan(false);

        // borrow half
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 100000000);

        uint256 lent = vault.lendInfo(WHALE_ACCOUNT);

        vm.assume(amount <= lent * 2);

        if (amount > 100000000) {
            vm.expectRevert(Constants.InsufficientLiquidity.selector);
        }

        vm.prank(WHALE_ACCOUNT);
        vault.withdraw(amount, WHALE_ACCOUNT, WHALE_ACCOUNT);
    }


    // fuzz testing borrow amount
    function testBorrow(uint256 amount) external {
        // 0 borrow loan
        _setupBasicLoan(false);

        (,, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);

        vm.assume(amount <= collateralValue * 100);

        uint256 debtLimit = vault.globalDebtLimit();
        uint256 increaseLimit = vault.dailyDebtIncreaseLimitMin();

        uint256 buffer = vault.BORROW_SAFETY_BUFFER_X32();

        if (amount > debtLimit) {
            vm.expectRevert(Constants.GlobalDebtLimit.selector);
        } else if (amount > increaseLimit) {
            vm.expectRevert(Constants.DailyDebtIncreaseLimit.selector);
        } else if (amount > collateralValue * buffer / Q32) {
            vm.expectRevert(Constants.CollateralFail.selector);
        }

        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, amount);
    }


   // fuzz testing borrow amount
    function testBorrowETH(uint256 amount) external {
        // 0 borrow loan
        _setupBasicLoanWithETH(false);

        (,, uint256 collateralValue,,) = vault.loanInfo(nft2TokenId);

        vm.assume(amount <= collateralValue * 100);

        uint256 debtLimit = vault.globalDebtLimit();
        uint256 increaseLimit = vault.dailyDebtIncreaseLimitMin();

        uint256 buffer = vault.BORROW_SAFETY_BUFFER_X32();

        if (amount > debtLimit) {
            vm.expectRevert(Constants.GlobalDebtLimit.selector);
        } else if (amount > increaseLimit) {
            vm.expectRevert(Constants.DailyDebtIncreaseLimit.selector);
        } else if (amount > collateralValue * buffer / Q32) {
            vm.expectRevert(Constants.CollateralFail.selector);
        }

        vm.prank(nft2Owner);
        vault.borrow(nft2TokenId, amount);
    }

    function testBorrowUnauthorized() external {
        // 0 borrow loan
        uint256 amount = 1e6;
        _setupBasicLoan(false);

        (,, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);

        vm.assume(amount <= collateralValue * 100);

        uint256 debtLimit = vault.globalDebtLimit();
        uint256 increaseLimit = vault.dailyDebtIncreaseLimitMin();

        if (amount > debtLimit) {
            vm.expectRevert(Constants.GlobalDebtLimit.selector);
        } else if (amount > increaseLimit) {
            vm.expectRevert(Constants.DailyDebtIncreaseLimit.selector);
        } else if (amount > collateralValue) {
            vm.expectRevert(Constants.CollateralFail.selector);
        }

        vm.prank(nft1Owner);
        vm.expectRevert(Constants.Unauthorized.selector);
        vault.borrow(0, amount); //NFT id hardcoded to 0 to make the function fail
    }

    // fuzz testing repay amount
    function testRepay(uint256 amount, bool isShare) external {
        // maximized collateral loan
        _setupBasicLoan(true);

        (uint256 debt,,,,) = vault.loanInfo(nft1TokenId);
        (uint256 debtShares) = vault.loans(nft1TokenId);

        if (isShare) {
            vm.assume(amount <= debtShares * 10);
        } else {
            vm.assume(amount <= debt * 10);
        }

        vm.prank(nft1Owner);
        usdc.approve(address(vault), debt);

        if (amount == 0) {
            vm.expectRevert(Constants.NoSharesRepayed.selector);
        }

        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, amount, isShare);
    }

    function testTransformWithdrawCollect() external {
        _setupBasicLoan(false);

        // test transforming with v4utils
        // withdraw fees - as an example
        V4Utils.Instructions memory inst = V4Utils.Instructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            Currency.wrap(address(0)),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            block.timestamp,
            nft1Owner,
            nft1Owner,
            "",
            "",
            address(0),
            "",
            ""
        );

        // Record initial state before transform
        (uint256 initialDebt, uint256 initialFullValue, uint256 initialCollateralValue,,) = vault.loanInfo(nft1TokenId);
        uint128 initialLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        uint256 initialOwnerBalance0 = usdc.balanceOf(nft1Owner);
        uint256 initialOwnerBalance1 = weth.balanceOf(nft1Owner);
        
        console.log("Initial debt:", initialDebt);
        console.log("Initial full value:", initialFullValue);
        console.log("Initial collateral value:", initialCollateralValue);
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Initial owner USDC balance:", initialOwnerBalance0);
        console.log("Initial owner WETH balance:", initialOwnerBalance1);

        // Verify NFT is owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), address(vault));
        assertEq(vault.ownerOf(nft1TokenId), nft1Owner);

        vm.prank(nft1Owner);
        vault.transform(nft1TokenId, address(v4Utils), abi.encodeCall(V4Utils.execute, (nft1TokenId, inst)));

        // Verify final state after transform
        (uint256 finalDebt, uint256 finalFullValue, uint256 finalCollateralValue,,) = vault.loanInfo(nft1TokenId);
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        uint256 finalOwnerBalance0 = usdc.balanceOf(nft1Owner);
        uint256 finalOwnerBalance1 = weth.balanceOf(nft1Owner);
        
        console.log("Final debt:", finalDebt);
        console.log("Final full value:", finalFullValue);
        console.log("Final collateral value:", finalCollateralValue);
        console.log("Final liquidity:", finalLiquidity);
        console.log("Final owner USDC balance:", finalOwnerBalance0);
        console.log("Final owner WETH balance:", finalOwnerBalance1);

        // Assertions to verify the transform worked correctly
        // 1. NFT should still be owned by vault and user
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), address(vault));
        assertEq(vault.ownerOf(nft1TokenId), nft1Owner);

        // 2. Loan should still exist (no debt was borrowed in this test)
        assertEq(finalDebt, initialDebt); // Should remain 0 since no borrowing occurred

        // 3. Position should still exist but may have changed
        assertGt(finalLiquidity, 0, "Position should still have liquidity");
        
        // 4. Collateral and full values should be reasonable
        assertGt(finalCollateralValue, 0, "Collateral value should be positive");
        assertGt(finalFullValue, 0, "Full value should be positive");
        assertGe(finalFullValue, finalCollateralValue, "Full value should be >= collateral value");

        // 5. Owner should have received some tokens (fees collected)
        // Note: The exact amounts depend on the position's fee accumulation
        assertGe(finalOwnerBalance0, initialOwnerBalance0, "Owner should have received USDC (fees)");
        assertGe(finalOwnerBalance1, initialOwnerBalance1, "Owner should have received WETH (fees)");

        // 6. Verify the transform operation completed successfully
        // (If it failed, the transaction would have reverted)
        console.log("Transform operation completed successfully");
        
        // 7. Verify vault state is still consistent
        assertEq(vault.loanCount(nft1Owner), 1, "User should still have 1 loan");
        assertEq(vault.loanAtIndex(nft1Owner, 0), nft1TokenId, "Loan should still be the same NFT");
    }

    function testTransformWithdrawCollectETH() external {
        _setupBasicLoanWithETH(false);

        // test transforming with v4utils
        // withdraw fees - as an example
        V4Utils.Instructions memory inst = V4Utils.Instructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            Currency.wrap(address(0)),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            block.timestamp,
            nft2Owner,
            nft2Owner,
            "",
            "",
            address(0),
            "",
            ""
        );

        // Record initial state before transform
        (uint256 initialDebt, uint256 initialFullValue, uint256 initialCollateralValue,,) = vault.loanInfo(nft2TokenId);
        uint128 initialLiquidity = positionManager.getPositionLiquidity(nft2TokenId);
        uint256 initialOwnerBalance0 = usdc.balanceOf(nft2Owner);
        uint256 initialOwnerBalance1 = weth.balanceOf(nft2Owner);
        
        console.log("Initial debt:", initialDebt);
        console.log("Initial full value:", initialFullValue);
        console.log("Initial collateral value:", initialCollateralValue);
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Initial owner USDC balance:", initialOwnerBalance0);
        console.log("Initial owner WETH balance:", initialOwnerBalance1);

        // Verify NFT is owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(nft2TokenId), address(vault));
        assertEq(vault.ownerOf(nft2TokenId), nft2Owner);

        vm.prank(nft2Owner);
        vault.transform(nft2TokenId, address(v4Utils), abi.encodeCall(V4Utils.execute, (nft2TokenId, inst)));

        // Verify final state after transform
        (uint256 finalDebt, uint256 finalFullValue, uint256 finalCollateralValue,,) = vault.loanInfo(nft2TokenId);
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft2TokenId);
        uint256 finalOwnerBalance0 = usdc.balanceOf(nft2Owner);
        uint256 finalOwnerBalance1 = weth.balanceOf(nft2Owner);
        
        console.log("Final debt:", finalDebt);
        console.log("Final full value:", finalFullValue);
        console.log("Final collateral value:", finalCollateralValue);
        console.log("Final liquidity:", finalLiquidity);
        console.log("Final owner USDC balance:", finalOwnerBalance0);
        console.log("Final owner WETH balance:", finalOwnerBalance1);

        // Assertions to verify the transform worked correctly
        // 1. NFT should still be owned by vault and user
        assertEq(IERC721(address(positionManager)).ownerOf(nft2TokenId), address(vault));
        assertEq(vault.ownerOf(nft2TokenId), nft2Owner);

        // 2. Loan should still exist (no debt was borrowed in this test)
        assertEq(finalDebt, initialDebt); // Should remain 0 since no borrowing occurred

        // 3. Position should still exist but may have changed
        assertGt(finalLiquidity, 0, "Position should still have liquidity");
        
        // 4. Collateral and full values should be reasonable
        assertGt(finalCollateralValue, 0, "Collateral value should be positive");
        assertGt(finalFullValue, 0, "Full value should be positive");
        assertGe(finalFullValue, finalCollateralValue, "Full value should be >= collateral value");

        // 5. Owner should have received some tokens (fees collected)
        // Note: The exact amounts depend on the position's fee accumulation
        assertGe(finalOwnerBalance0, initialOwnerBalance0, "Owner should have received USDC (fees)");
        assertGe(finalOwnerBalance1, initialOwnerBalance1, "Owner should have received WETH (fees)");

        // 6. Verify the transform operation completed successfully
        // (If it failed, the transaction would have reverted)
        console.log("Transform operation completed successfully");
        
        // 7. Verify vault state is still consistent
        assertEq(vault.loanCount(nft2Owner), 1, "User should still have 1 loan");
        assertEq(vault.loanAtIndex(nft2Owner, 0), nft2TokenId, "Loan should still be the same NFT");
    }

     function testMainScenario() external {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.debtSharesTotal(), 0);
        assertEq(vault.loanCount(nft1Owner), 0);

        // lending 2 usdc
        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), 2000000);

        vm.prank(WHALE_ACCOUNT);
        vault.deposit(2000000, WHALE_ACCOUNT);
        assertEq(vault.totalSupply(), 2000000);

        // withdrawing 1 usdc
        vm.prank(WHALE_ACCOUNT);
        vault.withdraw(1000000, WHALE_ACCOUNT, WHALE_ACCOUNT);

        assertEq(vault.totalSupply(), 1000000);

        // borrowing 1 usdc

        uint balance = usdc.balanceOf(nft1Owner);
        _createAndBorrow(nft1TokenId, nft1Owner, 1000000);
        assertEq(usdc.balanceOf(nft1Owner) - balance, 1000000);

        assertEq(vault.loanCount(nft1Owner), 1);
        assertEq(vault.loanAtIndex(nft1Owner, 0), nft1TokenId);
        assertEq(vault.ownerOf(nft1TokenId), nft1Owner);

        // gift some usdc so later he may repay all
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(nft1Owner, 4946);

        assertEq(vault.debtSharesTotal(), 1000000);

        // wait 7 days
        vm.warp(block.timestamp + 7 days);

        // verify to date values
        (uint256 debt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        console.log("Debt after 7 days:", debt);
        console.log("Full value after 7 days:", fullValue);
        console.log("Collateral value after 7 days:", collateralValue);
        uint256 lent = vault.lendInfo(WHALE_ACCOUNT);
        console.log("Lent after 7 days:", lent);

        vm.prank(nft1Owner);
        usdc.approve(address(vault), 1004946);

        // repay partially
        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, 1000000, false);
        (debt,,,,) = vault.loanInfo(nft1TokenId);
        (uint256 debtShares) = vault.loans(nft1TokenId);
        console.log("Remaining debt shares:", debtShares);
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), address(vault));
        console.log("Remaining debt:", debt);

        // repay full
        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, debtShares, true);

        (debt,,,,) = vault.loanInfo(nft1TokenId);
        assertEq(debt, 0);

        // still in vault
        assertEq(vault.loanCount(nft1Owner), 1);
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), address(vault));
        assertEq(vault.ownerOf(nft1TokenId), nft1Owner);

        vm.prank(nft1Owner);
        vault.remove(nft1TokenId, nft1Owner, "");

        assertEq(vault.loanCount(nft1Owner), 0);
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), nft1Owner);
        assertEq(vault.ownerOf(nft1TokenId), address(0));
    }


    function testTransformChangeRange() external {
        _setupBasicLoan(true);

        // Get position info for V4
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(nft1TokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(nft1TokenId);
        console.log("Initial liquidity:", liquidity);
        uint256 swapAmountIn = 12707757619098052 / 2;
        uint256 swapAmountMinOut = 1000000;

        bytes memory swapData = _createSwapData(swapAmountIn, swapAmountMinOut, address(weth), address(usdc), address(v4Utils));

        // test transforming with v4utils - changing range
        V4Utils.Instructions memory inst = V4Utils.Instructions(
            V4Utils.WhatToDo.CHANGE_RANGE,
            Currency.wrap(address(usdc)),
            0,
            0,
            0,
            0, 
            "",
            swapAmountIn,
            swapAmountMinOut,
            swapData,
            poolKey.fee,
            poolKey.tickSpacing,
            positionInfo.tickLower(),
            positionInfo.tickUpper(),
            liquidity,
            0,
            0,
            block.timestamp,
            nft1Owner,
            address(vault),
            "",
            "",
            address(0),
            "",
            ""
        );

        (uint256 oldDebt,,,,) = vault.loanInfo(nft1TokenId);

        vm.prank(nft1Owner);
        uint256 tokenId = vault.transform(nft1TokenId, address(v4Utils), abi.encodeCall(V4Utils.execute, (nft1TokenId, inst)));

        assertGt(tokenId, nft1TokenId);

        // old loan has been removed
        (poolKey, positionInfo) = positionManager.getPoolAndPositionInfo(nft1TokenId);
        assertEq(positionManager.getPositionLiquidity(nft1TokenId), 0);
        (uint256 debt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        assertEq(debt, 0);
        assertEq(collateralValue, 0);
        assertEq(fullValue, 0);

        // new loan has been created
        (poolKey, positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        console.log("New liquidity:", positionManager.getPositionLiquidity(tokenId));
        (debt, fullValue, collateralValue,,) = vault.loanInfo(tokenId);

        // debt with new NFT as collateral must be the same amount as before
        assertEq(debt, oldDebt);

        console.log("New collateral value:", collateralValue);
        console.log("New full value:", fullValue);
    }

    function testLiquidationTimeBased() external {
        _testLiquidation(LiquidationType.TimeBased);
    }

    function testLiquidationValueBased() external {
        _testLiquidation(LiquidationType.ValueBased);
    }

    function testLiquidationConfigBased() external {
        _testLiquidation(LiquidationType.ConfigBased);
    }

    enum LiquidationType {
        TimeBased,
        ValueBased,
        ConfigBased
    }

    function _testLiquidation(LiquidationType lType) internal {
        _setupBasicLoan(true);

        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        console.log("Initial collateral value:", collateralValue);
        console.log("Initial full value:", fullValue);

        // debt is equal collateral value
        (uint256 debt,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfo(nft1TokenId);
        console.log("Initial debt:", debt);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        if (lType == LiquidationType.TimeBased) {
            // wait 15 days - interest growing
            interestRateModel.setValues(Q64 / 10, Q64 * 2, Q64 * 2, 0);
            vm.warp(block.timestamp + 15 days);
        } else if (lType == LiquidationType.ValueBased) {
            // add a bit of time as well
            interestRateModel.setValues(Q64 / 10, Q64 * 2, Q64 * 2, 0);
            vm.warp(block.timestamp + 3 days);

            // collateral USDC value change -50%
            vm.mockCall(
                CHAINLINK_USDC_USD,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(0), int256(200000000), block.timestamp, block.timestamp, uint80(0))
            );
        } else {
            vault.setTokenConfig(address(usdc), uint32(Q32 * 2 / 10), type(uint32).max); // 20% collateral factor
        }

        if (lType == LiquidationType.ValueBased) {
            // should revert because oracle and pool price are different
            vm.expectRevert(Constants.PriceDifferenceExceeded.selector);
            (debt, fullValue, collateralValue, liquidationCost, liquidationValue) = vault.loanInfo(nft1TokenId);

            // ignore difference - now it will work
            v4Oracle.setMaxPoolPriceDifference(type(uint16).max);
        }

        // debt is greater than collateral value
        (debt, fullValue, collateralValue, liquidationCost, liquidationValue) = vault.loanInfo(nft1TokenId);

        console.log("Final debt:", debt);
        console.log("Final collateral value:", collateralValue);
        console.log("Final full value:", fullValue);
        console.log("Liquidation cost:", liquidationCost);
        console.log("Liquidation value:", liquidationValue);

        assertGt(debt, collateralValue);

        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), liquidationCost - 1);

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vault.liquidate(IVault.LiquidateParams(nft1TokenId, 0, 0, WHALE_ACCOUNT, block.timestamp, ""));

        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), liquidationCost);

        uint256 wethBalance = weth.balanceOf(WHALE_ACCOUNT);
        uint256 usdcBalance = usdc.balanceOf(WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        vault.liquidate(IVault.LiquidateParams(nft1TokenId, 0, 0, WHALE_ACCOUNT, block.timestamp, ""));

        // weth and usdc were sent to liquidator
        console.log("weth balance change:", int256(weth.balanceOf(WHALE_ACCOUNT)) - int256(wethBalance));
        console.log("usdc balance change:", int256(usdc.balanceOf(WHALE_ACCOUNT)) + int256(liquidationCost) - int256(usdcBalance));

        // all debt is payed
        assertEq(vault.debtSharesTotal(), 0);

        // protocol is solvent
        console.log("Vault usdc balance:", usdc.balanceOf(address(vault)));
        (, uint256 lent, uint256 balance,,,) = vault.vaultInfo();
        console.log("Vault lent:", lent);
        console.log("Vault balance:", balance);
    }


    function testFreeLiquidation() external {
        // lend 10 usdc
        _deposit(20000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(nft7Owner);
        IERC721(address(positionManager)).approve(address(vault), nft7TokenId);
        vm.prank(nft7Owner);
        vault.create(nft7TokenId, nft7Owner);

        (uint256 debt, uint256 fullValue, uint256 collateralValue, uint256 liquidationCost, uint256 liquidationValue) =
            vault.loanInfo(nft7TokenId);

        assertEq(debt, 0);
        console.log("usdc/weth collateral value:", collateralValue);
        console.log("usdc/weth full value:", fullValue);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        // borrow max
        vm.prank(nft7Owner);
        vault.borrow(nft7TokenId, 20000000);

        v4Oracle.setMaxPoolPriceDifference(type(uint16).max);

        // make it (almost) worthless
        vm.mockCall(
            CHAINLINK_BTC_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), int256(1), block.timestamp, block.timestamp, uint80(0))
        );

        vm.mockCall(
            CHAINLINK_ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), int256(1), block.timestamp, block.timestamp, uint80(0))
        );

        (debt, fullValue, collateralValue, liquidationCost, liquidationValue) = vault.loanInfo(nft7TokenId);
        assertEq(debt, 20000000);
        assertEq(collateralValue, 0);
        assertEq(fullValue, 0);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        vm.prank(WHALE_ACCOUNT);
        vault.liquidate(IVault.LiquidateParams(nft7TokenId, 0, 0, WHALE_ACCOUNT, block.timestamp, ""));

        // all debt is payed
        assertEq(vault.loans(nft7TokenId), 0);
        assertEq(vault.debtSharesTotal(), 0);
    }

    function testLiquidationWithZeroCollateralFactor() external {
        // lend 10 usdc
        _deposit(20000000, WHALE_ACCOUNT);

        // add collateral
        vm.prank(nft1Owner);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);
        vm.prank(nft1Owner);
        vault.create(nft1TokenId, nft1Owner);

        (uint256 debt, uint256 fullValue, uint256 collateralValue, uint256 liquidationCost, uint256 liquidationValue) =
            vault.loanInfo(nft1TokenId);

        assertEq(debt, 0);
        console.log("dai/weth collateral value:", collateralValue);
        console.log("dai/weth full value:", fullValue);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        // borrow max
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 20000000);

        // set collateral factor to 0
        vault.setTokenConfig(address(weth), 0, type(uint32).max); // 0% collateral factor / max 100% collateral value

        (debt, fullValue, collateralValue, liquidationCost, liquidationValue) = vault.loanInfo(nft1TokenId);
        assertEq(debt, 20000000);
        assertEq(collateralValue, 0);
        assertEq(fullValue, 140380064);
        assertEq(liquidationCost, 20000000);
        assertEq(liquidationValue, 21999999);

        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), liquidationCost);

        vm.prank(WHALE_ACCOUNT);
        vault.liquidate(IVault.LiquidateParams(nft1TokenId, 0, 0, WHALE_ACCOUNT, block.timestamp, ""));

        // all debt is payed
        assertEq(vault.loans(nft1TokenId), 0);
        assertEq(vault.debtSharesTotal(), 0);
    }

    function testLiquidationWithZeroCollateralFactorNFT2() external {
        // lend 10 usdc
        _deposit(20000000, WHALE_ACCOUNT);

        // add collateral (NFT2 is USDC/ETH position)
        vm.prank(nft2Owner);
        IERC721(address(positionManager)).approve(address(vault), nft2TokenId);
        vm.prank(nft2Owner);
        vault.create(nft2TokenId, nft2Owner);

        (uint256 debt, uint256 fullValue, uint256 collateralValue, uint256 liquidationCost, uint256 liquidationValue) =
            vault.loanInfo(nft2TokenId);

        assertEq(debt, 0);
        console.log("usdc/eth collateral value:", collateralValue);
        console.log("usdc/eth full value:", fullValue);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        // borrow max
        vm.prank(nft2Owner);
        vault.borrow(nft2TokenId, 20000000);

        // set collateral factor to 0 for native ETH (address 0)
        vault.setTokenConfig(address(0), 0, type(uint32).max); // 0% collateral factor / max 100% collateral value

        (debt, fullValue, collateralValue, liquidationCost, liquidationValue) = vault.loanInfo(nft2TokenId);
        assertEq(debt, 20000000);
        assertEq(collateralValue, 0);
        assertEq(fullValue, 42537606);
        assertEq(liquidationCost, 20000000);
        assertEq(liquidationValue, 21999999);

        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), liquidationCost);

        // Record balances before liquidation
        uint256 wethBalanceBefore = weth.balanceOf(WHALE_ACCOUNT);
        uint256 usdcBalanceBefore = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 ethBalanceBefore = WHALE_ACCOUNT.balance;

        vm.prank(WHALE_ACCOUNT);
        vault.liquidate(IVault.LiquidateParams(nft2TokenId, 1, 1, WHALE_ACCOUNT, block.timestamp, ""));

        // Record balances after liquidation
        uint256 wethBalanceAfter = weth.balanceOf(WHALE_ACCOUNT);
        uint256 usdcBalanceAfter = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 ethBalanceAfter = WHALE_ACCOUNT.balance;

        // Calculate balance changes
        int256 wethBalanceChange = int256(wethBalanceAfter) - int256(wethBalanceBefore);
        int256 usdcBalanceChange = int256(usdcBalanceAfter) + int256(liquidationCost) - int256(usdcBalanceBefore);
        int256 ethBalanceChange = int256(ethBalanceAfter) - int256(ethBalanceBefore);

        console.log("WETH balance change:", wethBalanceChange);
        console.log("USDC balance change:", usdcBalanceChange);
        console.log("ETH balance change:", ethBalanceChange);

        // Assert that liquidator received assets
        // For USDC/ETH position, liquidator should receive native ETH and USDC (not WETH)
        assertEq(wethBalanceChange, 0, "Liquidator should not receive WETH for USDC/ETH position");
        assertGt(ethBalanceChange, 0, "Liquidator should receive native ETH");
        
        // USDC balance change should account for the liquidation cost paid
        // The net USDC received should be positive (liquidation value > liquidation cost)
        assertGt(usdcBalanceChange, 0, "Liquidator should receive net USDC");

        // all debt is payed
        assertEq(vault.loans(nft2TokenId), 0);
        assertEq(vault.debtSharesTotal(), 0);
    }


    function testLiquidationWithFlashloan() external {
        _setupBasicLoan(true);

        // wait 15 days - interest growing
        interestRateModel.setValues(Q64 / 10, Q64 * 2, Q64 * 2, 0);
        vm.warp(block.timestamp + 15 days);

        // debt is greater than collateral value
        (uint256 debt,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfo(nft1TokenId);

        assertEq(debt, 126434088);
        assertEq(liquidationCost, 126434088);
        assertEq(liquidationValue, 129699012);

        (Currency token0, Currency token1,,,,,,) = v4Oracle.getPositionBreakdown(nft1TokenId);

        console.log("token0:", Currency.unwrap(token0));
        console.log("token1:", Currency.unwrap(token1));

        uint256 token0Before = IERC20(Currency.unwrap(token0)).balanceOf(address(this));
        uint256 token1Before = IERC20(Currency.unwrap(token1)).balanceOf(address(this));

        // For V3 flashloan, we need a V3 pool address
        // This would typically be a USDC/WETH pool address on mainnet
        address v3PoolAddress = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05% pool on mainnet
        FlashloanLiquidator liquidator = new FlashloanLiquidator(positionManager, address(swapRouter), EX0x);

        // WETH amount available from liquidation (from static call to liquidate())
        uint256 amount1 = 21362433248179720;

        // universalrouter swap data (single swap command) - swap available DAI to USDC - and sweep
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(liquidator), amount1, 0, abi.encodePacked(token1, uint24(3000), token0), false);
        inputs[1] = abi.encode(token1, address(liquidator), 0);
        bytes memory swapData1 =
            abi.encode(swapRouter, abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp)));

        vm.expectRevert(Constants.NotEnoughReward.selector);
        liquidator.liquidate(
            FlashloanLiquidator.LiquidateParams(
                nft1TokenId, vault, IUniswapV3Pool(v3PoolAddress), 0, "", amount1, swapData1, 129699012, block.timestamp, ""
            )
        );

        liquidator.liquidate(
            FlashloanLiquidator.LiquidateParams(
                nft1TokenId, vault, IUniswapV3Pool(v3PoolAddress), 0, "", amount1, swapData1, 3160994, block.timestamp, ""
            )
        );

        vm.expectRevert(Constants.NotLiquidatable.selector);
        liquidator.liquidate(
            FlashloanLiquidator.LiquidateParams(
                nft1TokenId, vault, IUniswapV3Pool(v3PoolAddress), 0, "", 0, "", 0, block.timestamp, ""
            )
        );

        assertEq(liquidationValue - liquidationCost, 3264924); // promised liquidation premium

        assertEq(token0.balanceOf(address(this)) - token0Before, 3160994);
        assertEq(token1.balanceOf(address(this)) - token1Before, 0); // actual liquidation premium (less because of swap)

        (debt,,,,) = vault.loanInfo(nft1TokenId);
        assertEq(debt, 0);

        // remove liquidated NFT
        vm.prank(nft1Owner);
        vault.remove(nft1TokenId, nft1Owner, "");

        //  NFT was returned to owner
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), nft1Owner);
    }


    function testCollateralValueLimit() external {
        _setupBasicLoan(false);
        vault.setTokenConfig(address(weth), uint32(Q32 * 9 / 10), uint32(Q32 / 10)); // max 10% debt for weth

        (,, uint192 totalDebtShares) = vault.tokenConfigs(address(weth));
        assertEq(totalDebtShares, 0);
        (,, totalDebtShares) = vault.tokenConfigs(address(usdc));
        assertEq(totalDebtShares, 0);

        // borrow certain amount works
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 19000000);

        (,, totalDebtShares) = vault.tokenConfigs(address(weth));
        assertEq(totalDebtShares, 19000000);
        (,, totalDebtShares) = vault.tokenConfigs(address(usdc));
        assertEq(totalDebtShares, 19000000);

        // borrow more doesnt work anymore - because more than max value of collateral is used
        vm.expectRevert(Constants.CollateralValueLimit.selector);
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 10000000);

        // repay all
        vm.prank(nft1Owner);
        usdc.approve(address(vault), 19000000);

        // get debt shares
        (uint256 debtShares) = vault.loans(nft1TokenId);
        assertEq(debtShares, 19000000);

        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, debtShares, true);

        // collateral is removed
        (,, totalDebtShares) = vault.tokenConfigs(address(weth));
        assertEq(totalDebtShares, 0);
        (,, totalDebtShares) = vault.tokenConfigs(address(usdc));
        assertEq(totalDebtShares, 0);
    }


    function testMultiLendLoan() external {


        _deposit(2000000, WHALE_ACCOUNT);
        _deposit(1000000, nft2Owner);

        _createAndBorrow(nft1TokenId, nft1Owner, 1000000);
        _createAndBorrow(nft2TokenId, nft2Owner, 2000000);

        assertEq(vault.balanceOf(WHALE_ACCOUNT), 2000000);
        assertEq(vault.balanceOf(nft2Owner), 1000000);

        // wait 7 days (should generate around 0.49%)
        vm.warp(block.timestamp + 7 days);

        _deposit(1000000, nft2Owner);
        assertEq(vault.balanceOf(nft2Owner), 1995079); // less shares because more valuable

        // whale won double interest
        assertEq(vault.lendInfo(WHALE_ACCOUNT), 2009889);
        assertEq(vault.lendInfo(nft2Owner), 2004943);

        // repay debts
        (uint256 debt,,,,) = vault.loanInfo(nft1TokenId);
        console.log("Debt for nft1TokenId:", debt);
        _repay(debt, nft1Owner, nft1TokenId, true);

        (debt,,,,) = vault.loanInfo(nft2TokenId);
        console.log("Debt for nft2TokenId:", debt);
        _repay(debt, nft2Owner, nft2TokenId, true);

        // withdraw shares
        uint256 shares = vault.balanceOf(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.redeem(shares, WHALE_ACCOUNT, WHALE_ACCOUNT);

        shares = vault.balanceOf(nft2Owner);
        vm.prank(nft2Owner);
        vault.redeem(shares, nft2Owner, nft2Owner);

        // check remaining
        console.log("Remaining vault usdc balance:", usdc.balanceOf(address(vault)));

        uint256 lent;
        uint256 balance;
        uint256 reserves;
        (debt, lent, balance, reserves,,) = vault.vaultInfo();
        console.log("Final debt:", debt);
        console.log("Final lent:", lent);
        console.log("Final balance:", balance);
        console.log("Final reserves:", reserves);
    }

    function testEmergencyAdmin() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(WHALE_ACCOUNT);
        vault.setLimits(0, 0, 0, 0, 0);

        vault.setEmergencyAdmin(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.setLimits(0, 0, 0, 0, 0);
    }

    function testReserves() external {
        vault.setReserveFactor(uint32(Q32 / 10)); // 10%
        vault.setReserveProtectionFactor(uint32(Q32 / 100)); // 1%

        _setupBasicLoan(true);

        (uint256 debt, uint256 lent,, uint256 reserves,,) = vault.vaultInfo();

        console.log("Initial debt:", debt);
        console.log("Initial lent:", lent);
        console.log("Initial reserves:", reserves);

        // wait 30 days - interest growing
        vm.warp(block.timestamp + 30 days);

        (debt, lent,, reserves,,) = vault.vaultInfo();
        console.log("Debt after 30 days:", debt);
        console.log("Lent after 30 days:", lent);
        console.log("Reserves after 30 days:", reserves);

        // not enough reserve generated to be above protection factor
        vm.expectRevert(Constants.InsufficientLiquidity.selector);
        vault.withdrawReserves(1, address(this));

        // gift some extra coins - to be able to repay all
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(nft1Owner, 1000000);

        // repay all
        _repay(debt, nft1Owner, nft1TokenId, true);

        (debt, lent,, reserves,,) = vault.vaultInfo();
        assertEq(debt, 0);
        console.log("Lent after repayment:", lent);

        // not enough reserve generated to be above protection factor
        vm.expectRevert(Constants.InsufficientLiquidity.selector);
        vault.withdrawReserves(1, address(this));

        // get 99% out
        uint256 balance = vault.balanceOf(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.redeem(balance * 99 / 100, WHALE_ACCOUNT, WHALE_ACCOUNT);

        (, lent,, reserves,,) = vault.vaultInfo();
        console.log("Lent after 99% withdrawal:", lent);
        console.log("Reserves after 99% withdrawal:", reserves);

        // now everything until 1 percent can be removed
        vm.expectRevert(Constants.InsufficientLiquidity.selector);
        vault.withdrawReserves(reserves - lent / 100 + 1, address(this));

        // now everything until 1 percent can be removed
        vault.withdrawReserves(reserves - lent / 100, address(this));
    }

    /// forge-config: default.fuzz.runs = 1024
    function testBasicsFuzz(uint256 lent, uint256 debt, uint256 repay, uint256 withdraw) external {
        uint256 dailyDebtIncreaseLimitMin = vault.dailyDebtIncreaseLimitMin();
        uint256 dailyLendIncreaseLimitMin = vault.dailyLendIncreaseLimitMin();
        uint256 globalDebtLimit = vault.globalDebtLimit();
        uint256 globalLendLimit = vault.globalLendLimit();

        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(vault), lent);

        uint256 whaleBalance = usdc.balanceOf(WHALE_ACCOUNT);

        if (lent > globalLendLimit) {
            vm.expectRevert(Constants.GlobalLendLimit.selector);
        } else if (lent > dailyLendIncreaseLimitMin) {
            vm.expectRevert(Constants.DailyLendIncreaseLimit.selector);
        } else if (whaleBalance < lent) {
            vm.expectRevert("ERC20: transfer amount exceeds balance");
        }

        vm.prank(WHALE_ACCOUNT);
        vault.deposit(lent, WHALE_ACCOUNT);

        // add collateral
        vm.prank(nft1Owner);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);
        vm.prank(nft1Owner);
        vault.create(nft1TokenId, nft1Owner);

        (,, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        uint256 buffer = vault.BORROW_SAFETY_BUFFER_X32();

        uint256 vaultBalance = usdc.balanceOf(address(vault));

        if (debt > globalDebtLimit) {
            vm.expectRevert(Constants.GlobalDebtLimit.selector);
        } else if (debt > dailyDebtIncreaseLimitMin) {
            vm.expectRevert(Constants.DailyDebtIncreaseLimit.selector);
        } else if (collateralValue * buffer / Q32 < debt) {
            vm.expectRevert(Constants.CollateralFail.selector);
        } else if (vaultBalance < debt) {
            vm.expectRevert("ERC20: transfer amount exceeds balance");
        }

        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, debt);

        uint256 liquidationCost;
        uint256 liquidationValue;

        (debt,,, liquidationCost, liquidationValue) = vault.loanInfo(nft1TokenId);

        vm.prank(nft1Owner);
        usdc.approve(address(vault), repay);

        whaleBalance = usdc.balanceOf(WHALE_ACCOUNT);
        if (whaleBalance < repay && debt >= whaleBalance) {
            vm.expectRevert("ERC20: transfer amount exceeds balance");
        } else if (repay == 0) {
            vm.expectRevert(Constants.NoSharesRepayed.selector);
        }

        vm.prank(nft1Owner);
        (repay,) = vault.repay(nft1TokenId, repay, false);

        vaultBalance = usdc.balanceOf(address(vault));
        lent = vault.lendInfo(WHALE_ACCOUNT);
        
        if (lent > vaultBalance && withdraw > vaultBalance && lent > 0) {
            vm.expectRevert(Constants.InsufficientLiquidity.selector);
        }
        vm.prank(WHALE_ACCOUNT);
        vault.withdraw(withdraw, WHALE_ACCOUNT, WHALE_ACCOUNT);
    }

    // leverage tests
    function test_LeverageDown() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, address(swapRouter), EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        _deposit(10000000, WHALE_ACCOUNT);

        vm.startPrank(nft1Owner);
        IERC721(address(positionManager)).approve(address(positionManager), nft1TokenId);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);

        vault.create(nft1TokenId, nft1Owner);

        // Record initial state
        uint256 initialDebtShares = vault.loans(nft1TokenId);
        (uint256 initialDebt,,,,) = vault.loanInfo(nft1TokenId);
        uint128 initialLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        uint256 initialUsdcBalance = usdc.balanceOf(nft1Owner);
        uint256 initialWethBalance = weth.balanceOf(nft1Owner);

        console.log("=== LEVERAGE DOWN TEST ===");
        console.log("Initial debt shares:", initialDebtShares);
        console.log("Initial debt amount:", initialDebt);
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial WETH balance:", initialWethBalance);

        vault.borrow(nft1TokenId, 1);

        // Record state after borrowing
        uint256 debtSharesAfterBorrow = vault.loans(nft1TokenId);
        (uint256 debtAfterBorrow,,,,) = vault.loanInfo(nft1TokenId);
        
        console.log("Debt shares after borrow:", debtSharesAfterBorrow);
        console.log("Debt amount after borrow:", debtAfterBorrow);

        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams({
            tokenId: nft1TokenId,
            liquidity: 1,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            recipient: nft1Owner,
            deadline: block.timestamp,
            decreaseLiquidityHookData: ""
        });

        vault.transform(
            nft1TokenId,
            address(leverageTransformer),
            abi.encodeWithSelector(LeverageTransformer.leverageDown.selector, params)
        );

        // Record final state
        uint256 finalDebtShares = vault.loans(nft1TokenId);
        (uint256 finalDebt,,,,) = vault.loanInfo(nft1TokenId);
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft1TokenId);

        console.log("Final debt shares:", finalDebtShares);
        console.log("Final debt amount:", finalDebt);
        console.log("Final liquidity:", finalLiquidity);

        // Assertions
        // 1. Position ownership should remain with vault
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), address(vault), "Position should still be owned by vault");
        
        // 2. Debt should be reduced (leverage down means reducing debt)
        assertLt(finalDebtShares, debtSharesAfterBorrow, "Debt shares should decrease after leverage down");
        assertLt(finalDebt, debtAfterBorrow, "Debt amount should decrease after leverage down");
        
        // 3. Position liquidity should be reduced
        assertLt(finalLiquidity, initialLiquidity, "Position liquidity should decrease after leverage down");
        
        // 4. Loan should still be healthy
        (uint256 debtCheck, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        assertTrue(collateralValue > debtCheck, "Loan should remain healthy after leverage down");

        vault.remove(nft1TokenId, nft1Owner, "");
        vm.stopPrank();
    }

    // leverage tests
    function test_LeverageUp() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, address(swapRouter), EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        _deposit(10000000, WHALE_ACCOUNT);

        vm.startPrank(nft1Owner);
        IERC721(address(positionManager)).approve(address(positionManager), nft1TokenId);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);

        vault.create(nft1TokenId, nft1Owner);

        // Record initial state
        uint256 initialDebtShares = vault.loans(nft1TokenId);
        (uint256 initialDebt,,,,) = vault.loanInfo(nft1TokenId);
        uint128 initialLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        uint256 initialUsdcBalance = usdc.balanceOf(nft1Owner);
        uint256 initialWethBalance = weth.balanceOf(nft1Owner);

        console.log("=== LEVERAGE UP TEST ===");
        console.log("Initial debt shares:", initialDebtShares);
        console.log("Initial debt amount:", initialDebt);
        console.log("Initial liquidity:", initialLiquidity);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial WETH balance:", initialWethBalance);

        vault.borrow(nft1TokenId, 1000000);

        // Record state after initial borrow
        uint256 debtSharesAfterBorrow = vault.loans(nft1TokenId);
        (uint256 debtAfterBorrow,,,,) = vault.loanInfo(nft1TokenId);
        uint128 liquidityAfterBorrow = positionManager.getPositionLiquidity(nft1TokenId);
        
        console.log("Debt shares after initial borrow:", debtSharesAfterBorrow);
        console.log("Debt amount after initial borrow:", debtAfterBorrow);
        console.log("Liquidity after initial borrow:", liquidityAfterBorrow);

        bytes memory swapData = _createSwapData(500000, 1, address(usdc), address(weth), address(leverageTransformer));

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            tokenId: nft1TokenId,
            borrowAmount: 1000000,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 500000,
            amountOut1Min: 1,
            swapData1: swapData,
            amountAddMin0: 1,
            amountAddMin1: 1,
            recipient: nft1Owner,
            deadline: block.timestamp,
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: ""
        });

        vault.transform(
            nft1TokenId,
            address(leverageTransformer),
            abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params)
        );

        // Record final state
        uint256 finalDebtShares = vault.loans(nft1TokenId);
        (uint256 finalDebt,,,,) = vault.loanInfo(nft1TokenId);
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft1TokenId);

        console.log("Final debt shares:", finalDebtShares);
        console.log("Final debt amount:", finalDebt);
        console.log("Final liquidity:", finalLiquidity);

        // Assertions
        // 1. Position ownership should remain with vault
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), address(vault), "Position should still be owned by vault");
        
        // 2. Debt should increase (leverage up means increasing debt)
        assertGt(finalDebtShares, debtSharesAfterBorrow, "Debt shares should increase after leverage up");
        assertGt(finalDebt, debtAfterBorrow, "Debt amount should increase after leverage up");
        
        // 3. Position liquidity should increase (more tokens added to position)
        assertGt(finalLiquidity, liquidityAfterBorrow, "Position liquidity should increase after leverage up");
        
        // 4. Loan should still be healthy
        (uint256 debtCheck, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(nft1TokenId);
        assertTrue(collateralValue > debtCheck, "Loan should remain healthy after leverage up");
        
        // 5. Total debt increase should be approximately the borrow amount
        assertApproxEqRel(finalDebt - debtAfterBorrow, 1000000, 0.01e18, "Debt increase should be approximately the borrow amount");
        
        // 6. Liquidity increase should be significant (more tokens added to position)
        assertGt(finalLiquidity - liquidityAfterBorrow, 0, "Liquidity should increase significantly");

        vm.stopPrank();
    }

    // leverage in tests
    function test_LeverageIn() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, address(swapRouter), EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        // Deposit USDC to the vault so there's liquidity to borrow
        _deposit(100000000, WHALE_ACCOUNT); // 100 USDC

        // Get pool info from existing position to reuse pool key parameters
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(nft1TokenId);

        // User starts with WETH and wants to create a leveraged position
        address user = address(0x1234567890123456789012345678901234567890);
        uint256 initialWethAmount = 0.01 ether;

        // Give user some WETH
        deal(address(weth), user, initialWethAmount);

        console.log("=== LEVERAGE IN TEST ===");
        console.log("Pool token0:", Currency.unwrap(poolKey.currency0));
        console.log("Pool token1:", Currency.unwrap(poolKey.currency1));
        console.log("Pool fee:", poolKey.fee);
        console.log("Pool tickSpacing:", poolKey.tickSpacing);
        console.log("User initial WETH:", initialWethAmount);

        vm.startPrank(user);

        // Approve WETH for the leverage transformer
        weth.approve(address(leverageTransformer), initialWethAmount);

        // Use reasonable tick ranges (not the full range from existing position)
        // For USDC/WETH pool with tickSpacing=10, use a range around current price
        int24 tickLower = -200000; // reasonable lower bound
        int24 tickUpper = -190000; // reasonable upper bound

        // Create swap data to swap some borrowed USDC to WETH
        uint256 borrowAmount = 10000000; // 10 USDC
        uint256 swapAmount = 5000000; // 5 USDC to swap to WETH
        bytes memory swapData = _createSwapData(swapAmount, 1, address(usdc), address(weth), address(leverageTransformer));

        LeverageTransformer.LeverageInParams memory params = LeverageTransformer.LeverageInParams({
            vault: address(vault),
            token0: poolKey.currency0,
            token1: poolKey.currency1,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hook: address(poolKey.hooks),
            tickLower: tickLower,
            tickUpper: tickUpper,
            initialAmount: initialWethAmount,
            borrowAmount: borrowAmount,
            amountIn: swapAmount,
            amountOutMin: 1,
            swapData: swapData,
            swapDirection: true, // swap USDC (lend token) to WETH (other token)
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: user,
            deadline: block.timestamp,
            mintHookData: "",
            mintFinalHookData: "",
            decreaseLiquidityHookData: ""
        });

        // Execute leverage in
        uint256 newTokenId = leverageTransformer.leverageIn(params);

        console.log("New token ID:", newTokenId);

        // Verify the position was created and is owned by the vault
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(vault), "Position should be owned by vault");

        // Verify the loan owner is the user
        assertEq(vault.ownerOf(newTokenId), user, "Loan should be owned by user");

        // Verify the loan has debt
        uint256 debtShares = vault.loans(newTokenId);
        assertGt(debtShares, 0, "Loan should have debt shares");

        (uint256 debt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(newTokenId);
        console.log("Debt:", debt);
        console.log("Full value:", fullValue);
        console.log("Collateral value:", collateralValue);

        assertGt(debt, 0, "Loan should have debt");
        assertGt(collateralValue, debt, "Loan should be healthy (collateral > debt)");

        // Verify the new position has liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(newTokenId);
        assertGt(liquidity, 0, "Position should have liquidity");
        console.log("Position liquidity:", liquidity);

        vm.stopPrank();
    }

    // Test leverageIn with pool where token0 is the lend token (USDC)
    function test_LeverageIn_Token0IsLendToken() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, address(swapRouter), EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        // Deposit USDC to the vault so there's liquidity to borrow
        _deposit(100000000, WHALE_ACCOUNT); // 100 USDC

        // Get pool info from existing position
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(nft1TokenId);

        // Verify USDC is token0 in this pool
        assertEq(Currency.unwrap(poolKey.currency0), address(usdc), "USDC should be token0");

        // User starts with WETH (token1) and wants to create a leveraged position
        address user = address(0x1234567890123456789012345678901234567890);
        uint256 initialWethAmount = 0.01 ether;

        // Give user some WETH
        deal(address(weth), user, initialWethAmount);

        console.log("=== LEVERAGE IN TEST (Token0 is lend token) ===");

        vm.startPrank(user);
        weth.approve(address(leverageTransformer), initialWethAmount);

        // Use reasonable tick ranges
        int24 tickLower = -200000;
        int24 tickUpper = -190000;

        uint256 borrowAmount = 10000000; // 10 USDC
        uint256 swapAmount = 5000000; // 5 USDC to swap to WETH
        bytes memory swapData = _createSwapData(swapAmount, 1, address(usdc), address(weth), address(leverageTransformer));

        LeverageTransformer.LeverageInParams memory params = LeverageTransformer.LeverageInParams({
            vault: address(vault),
            token0: poolKey.currency0,
            token1: poolKey.currency1,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hook: address(poolKey.hooks),
            tickLower: tickLower,
            tickUpper: tickUpper,
            initialAmount: initialWethAmount,
            borrowAmount: borrowAmount,
            amountIn: swapAmount,
            amountOutMin: 1,
            swapData: swapData,
            swapDirection: true, // swap lend token (USDC) to other token (WETH)
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: user,
            deadline: block.timestamp,
            mintHookData: "",
            mintFinalHookData: "",
            decreaseLiquidityHookData: ""
        });

        uint256 newTokenId = leverageTransformer.leverageIn(params);

        // Verify position and loan
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(vault), "Position should be owned by vault");
        assertEq(vault.ownerOf(newTokenId), user, "Loan should be owned by user");

        (uint256 debt,, uint256 collateralValue,,) = vault.loanInfo(newTokenId);
        assertGt(collateralValue, debt, "Loan should be healthy");

        vm.stopPrank();
    }

    // Test that leverageIn reverts when neither token is the lend token
    function test_LeverageIn_InvalidToken() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, address(swapRouter), EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        address user = address(0x1234567890123456789012345678901234567890);

        vm.startPrank(user);

        // Try to create position with DAI/WETH pool (neither is USDC which is the lend token)
        LeverageTransformer.LeverageInParams memory params = LeverageTransformer.LeverageInParams({
            vault: address(vault),
            token0: Currency.wrap(address(dai)),
            token1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hook: address(0),
            tickLower: -887220,
            tickUpper: 887220,
            initialAmount: 1 ether,
            borrowAmount: 10000000,
            amountIn: 0,
            amountOutMin: 0,
            swapData: "",
            swapDirection: true,
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: user,
            deadline: block.timestamp,
            mintHookData: "",
            mintFinalHookData: "",
            decreaseLiquidityHookData: ""
        });

        vm.expectRevert(Constants.InvalidToken.selector);
        leverageTransformer.leverageIn(params);

        vm.stopPrank();
    }

    // Test leverageIn with full range position
    function test_LeverageIn_FullRange() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, address(swapRouter), EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        // Increase limits for this test (need ~5000 USDC)
        vault.setLimits(0, 10000000000, 10000000000, 10000000000, 10000000000); // 10000 USDC limits

        // Deposit USDC to the vault so there's liquidity to borrow
        // For full range with 1 ETH (~$4318), we need ~$4318 USDC to balance
        _deposit(5000000000, WHALE_ACCOUNT); // 5000 USDC

        // Get pool info from existing position to reuse pool key parameters
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(nft1TokenId);

        // User starts with WETH and wants to create a full range leveraged position
        address user = address(0x1234567890123456789012345678901234567890);
        uint256 initialWethAmount = 1 ether; // ~$4318 at current prices

        // Give user some WETH
        deal(address(weth), user, initialWethAmount);

        console.log("=== LEVERAGE IN FULL RANGE TEST ===");
        console.log("Pool token0:", Currency.unwrap(poolKey.currency0));
        console.log("Pool token1:", Currency.unwrap(poolKey.currency1));
        console.log("Pool fee:", poolKey.fee);
        console.log("Pool tickSpacing:", poolKey.tickSpacing);
        console.log("User initial WETH:", initialWethAmount);

        vm.startPrank(user);

        // Approve WETH for the leverage transformer
        weth.approve(address(leverageTransformer), initialWethAmount);

        // Use full range tick values (aligned to tick spacing)
        // TickMath.MIN_TICK = -887272, TickMath.MAX_TICK = 887272
        // For tickSpacing = 10, we need to round to nearest multiple of 10
        int24 tickLower = -887270; // -887272 rounded up to multiple of 10
        int24 tickUpper = 887270;  // 887272 rounded down to multiple of 10

        // For full range positions, borrow USDC equivalent in value to the initial WETH (~$4318)
        // No swapping needed - both tokens go directly into the position
        uint256 borrowAmount = 4300000000; // 4300 USDC (~$4318 worth)

        LeverageTransformer.LeverageInParams memory params = LeverageTransformer.LeverageInParams({
            vault: address(vault),
            token0: poolKey.currency0,
            token1: poolKey.currency1,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hook: address(poolKey.hooks),
            tickLower: tickLower,
            tickUpper: tickUpper,
            initialAmount: initialWethAmount,
            borrowAmount: borrowAmount,
            amountIn: 0, // no swap
            amountOutMin: 0,
            swapData: bytes(""),
            swapDirection: true,
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: user,
            deadline: block.timestamp,
            mintHookData: "",
            mintFinalHookData: "",
            decreaseLiquidityHookData: ""
        });

        // Execute leverage in
        uint256 newTokenId = leverageTransformer.leverageIn(params);

        console.log("New token ID:", newTokenId);

        // Verify the position was created and is owned by the vault
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(vault), "Position should be owned by vault");

        // Verify the loan owner is the user
        assertEq(vault.ownerOf(newTokenId), user, "Loan should be owned by user");

        // Verify the loan has debt
        uint256 debtShares = vault.loans(newTokenId);
        assertGt(debtShares, 0, "Loan should have debt shares");

        (uint256 debt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(newTokenId);
        console.log("Debt:", debt);
        console.log("Full value:", fullValue);
        console.log("Collateral value:", collateralValue);

        assertGt(debt, 0, "Loan should have debt");
        assertGt(collateralValue, debt, "Loan should be healthy (collateral > debt)");

        // Verify the new position has liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(newTokenId);
        assertGt(liquidity, 0, "Position should have liquidity");
        console.log("Position liquidity:", liquidity);

        // Verify position tick range is full range
        (, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        assertEq(positionInfo.tickLower(), tickLower, "Position should have full range tickLower");
        assertEq(positionInfo.tickUpper(), tickUpper, "Position should have full range tickUpper");
        console.log("Position tickLower:", positionInfo.tickLower());
        console.log("Position tickUpper:", positionInfo.tickUpper());

        vm.stopPrank();
    }

    // ============ transferLoan Tests ============

    function test_TransferLoan() public {
        _setupBasicLoan(true);

        address newOwner = address(0x9999);

        // Verify initial owner
        assertEq(vault.ownerOf(nft1TokenId), nft1Owner, "Initial owner should be nft1Owner");

        // Transfer the loan
        vm.prank(nft1Owner);
        vault.transferLoan(nft1TokenId, newOwner);

        // Verify new owner
        assertEq(vault.ownerOf(nft1TokenId), newOwner, "New owner should be set");

        // Verify old owner no longer owns it
        assertEq(vault.loanCount(nft1Owner), 0, "Old owner should have no tokens");

        // Verify new owner has the token
        assertEq(vault.loanCount(newOwner), 1, "New owner should have one token");
        assertEq(vault.loanAtIndex(newOwner, 0), nft1TokenId, "New owner should have the transferred token");
    }

    function test_TransferLoan_Unauthorized() public {
        _setupBasicLoan(true);

        address notOwner = address(0x8888);
        address newOwner = address(0x9999);

        // Try to transfer from non-owner - should fail
        vm.prank(notOwner);
        vm.expectRevert(Constants.Unauthorized.selector);
        vault.transferLoan(nft1TokenId, newOwner);
    }

    function test_TransferLoan_ToZeroAddress() public {
        _setupBasicLoan(true);

        // Try to transfer to zero address - should fail
        vm.prank(nft1Owner);
        vm.expectRevert(Constants.Unauthorized.selector);
        vault.transferLoan(nft1TokenId, address(0));
    }

    function test_TransferLoan_PreservesDebt() public {
        _setupBasicLoan(true);

        address newOwner = address(0x9999);

        // Get debt before transfer
        (uint256 debtBefore,,,,) = vault.loanInfo(nft1TokenId);
        assertGt(debtBefore, 0, "Should have debt before transfer");

        // Transfer the loan
        vm.prank(nft1Owner);
        vault.transferLoan(nft1TokenId, newOwner);

        // Verify debt is preserved
        (uint256 debtAfter,,,,) = vault.loanInfo(nft1TokenId);
        assertEq(debtAfter, debtBefore, "Debt should be preserved after transfer");
    }

    function test_TransferLoan_NewOwnerCanRepay() public {
        _setupBasicLoan(true);

        address newOwner = address(0x9999);

        // Transfer the loan
        vm.prank(nft1Owner);
        vault.transferLoan(nft1TokenId, newOwner);

        // Give new owner some USDC to repay
        deal(address(usdc), newOwner, 200000000); // 200 USDC

        // Get debt amount
        (uint256 debt,,,,) = vault.loanInfo(nft1TokenId);

        // New owner repays the debt
        vm.startPrank(newOwner);
        usdc.approve(address(vault), debt);
        vault.repay(nft1TokenId, debt, false);
        vm.stopPrank();

        // Verify debt is repaid
        (uint256 debtAfter,,,,) = vault.loanInfo(nft1TokenId);
        assertEq(debtAfter, 0, "Debt should be zero after repayment");
    }

}
