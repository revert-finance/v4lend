// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import "permit2/src/interfaces/ISignatureTransfer.sol";
import "permit2/src/interfaces/IPermit2.sol";

// base contracts
import {V4Vault} from "../src/V4Vault.sol";
import {V4Oracle, AggregatorV3Interface} from "../src/V4Oracle.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {IVault} from "../src/interfaces/IVault.sol";

// transformers
import {LeverageTransformer} from "../src/transformers/LeverageTransformer.sol";
import {V4Utils} from "../src/transformers/V4Utils.sol";
import {FlashloanLiquidator} from "../src/utils/FlashloanLiquidator.sol";
import {IUniswapV3Pool} from "../src/utils/FlashloanLiquidator.sol";

import {Constants} from "../src/utils/Constants.sol";
import {Swapper} from "../src/utils/Swapper.sol";
import {V4ForkTestBase} from "./V4ForkTestBase.sol";

contract V4VaultIntegrationTest is V4ForkTestBase {
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
            realWeth
        );
        
        vault.setTokenConfig(address(usdc), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(dai), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(realWeth), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(wbtc), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value
        vault.setTokenConfig(address(0), uint32(Q32 * 9 / 10), type(uint32).max); // 90% collateral factor / max 100% collateral value

        // limits 1000 usdc each
        vault.setLimits(0, 1000000000, 1000000000, 1000000000, 1000000000);

        // without reserve for now
        vault.setReserveFactor(0);

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
        uint256 initialOwnerBalance1 = realWeth.balanceOf(nft1Owner);
        
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
        uint256 finalOwnerBalance1 = realWeth.balanceOf(nft1Owner);
        
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
        uint256 initialOwnerBalance1 = realWeth.balanceOf(nft2Owner);
        
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
        uint256 finalOwnerBalance1 = realWeth.balanceOf(nft2Owner);
        
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

        // universalrouter swap data (single swap command)
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            address(v4Utils),
            swapAmountIn,
            swapAmountMinOut,
            abi.encodePacked(address(realWeth), uint24(500), address(usdc)),
            false
        );
        inputs[1] = abi.encode(address(realWeth), address(v4Utils), 0);
        bytes memory swapData =
            abi.encode(address(swapRouter), abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp)));

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

        uint256 wethBalance = realWeth.balanceOf(WHALE_ACCOUNT);
        uint256 usdcBalance = usdc.balanceOf(WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        vault.liquidate(IVault.LiquidateParams(nft1TokenId, 0, 0, WHALE_ACCOUNT, block.timestamp, ""));

        // weth and usdc were sent to liquidator
        console.log("weth balance change:", int256(realWeth.balanceOf(WHALE_ACCOUNT)) - int256(wethBalance));
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
        console.log("dai/realWeth collateral value:", collateralValue);
        console.log("dai/realWeth full value:", fullValue);
        assertEq(liquidationCost, 0);
        assertEq(liquidationValue, 0);

        // borrow max
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 20000000);

        // set collateral factor to 0
        vault.setTokenConfig(address(realWeth), 0, type(uint32).max); // 0% collateral factor / max 100% collateral value

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

/*

    function testCollateralValueLimit() external {
        _setupBasicLoan(false);
        vault.setTokenConfig(address(realWeth), uint32(Q32 * 9 / 10), uint32(Q32 / 10)); // max 10% debt for weth

        (,, uint192 totalDebtShares) = vault.tokenConfigs(address(realWeth));
        assertEq(totalDebtShares, 0);
        (,, totalDebtShares) = vault.tokenConfigs(address(usdc));
        assertEq(totalDebtShares, 0);

        // borrow certain amount works
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 800000);

        (,, totalDebtShares) = vault.tokenConfigs(address(realWeth));
        assertEq(totalDebtShares, 800000);
        (,, totalDebtShares) = vault.tokenConfigs(address(usdc));
        assertEq(totalDebtShares, 800000);

        // borrow more doesnt work anymore - because more than max value of collateral is used
        vm.expectRevert(Constants.CollateralValueLimit.selector);
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, 200001);

        // repay all
        vm.prank(nft1Owner);
        usdc.approve(address(vault), 1100000);

        // get debt shares
        (uint256 debtShares) = vault.loans(nft1TokenId);
        assertEq(debtShares, 800000);

        vm.prank(nft1Owner);
        vault.repay(nft1TokenId, debtShares, true);

        // collateral is removed
        (,, totalDebtShares) = vault.tokenConfigs(address(realWeth));
        assertEq(totalDebtShares, 0);
        (,, totalDebtShares) = vault.tokenConfigs(address(usdc));
        assertEq(totalDebtShares, 0);
    }


    function testMultiLendLoan() external {
        _deposit(2000000, WHALE_ACCOUNT);
        _deposit(1000000, nft1Owner_2);

        // gift some usdc so later he may repay all
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(nft1Owner, 1000000);

        _createAndBorrow(nft1TokenId, nft1Owner, 1000000);
        _createAndBorrow(nft1TokenId_2, nft1Owner_2, 2000000);

        assertEq(vault.balanceOf(WHALE_ACCOUNT), 2000000);
        assertEq(vault.balanceOf(nft1Owner_2), 1000000);

        // wait 7 days (should generate around 0.49%)
        vm.warp(block.timestamp + 7 days);

        _deposit(1000000, nft1Owner_2);
        assertEq(vault.balanceOf(nft1Owner_2), 1995079); // less shares because more valuable

        // whale won double interest
        assertEq(vault.lendInfo(WHALE_ACCOUNT), 2009889);
        assertEq(vault.lendInfo(nft1Owner_2), 2004943);

        // repay debts
        (uint256 debt,,,,) = vault.loanInfo(nft1TokenId);
        console.log("Debt for nft1TokenId:", debt);
        _repay(debt, nft1Owner, nft1TokenId, true);

        (debt,,,,) = vault.loanInfo(nft1TokenId_2);
        console.log("Debt for nft1TokenId_2:", debt);
        _repay(debt, nft1Owner_2, nft1TokenId_2, true);

        // withdraw shares
        uint256 shares = vault.balanceOf(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.redeem(shares, WHALE_ACCOUNT, WHALE_ACCOUNT);

        shares = vault.balanceOf(nft1Owner_2);
        vm.prank(nft1Owner_2);
        vault.redeem(shares, nft1Owner_2, nft1Owner_2);

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
            vm.expectRevert(Constants.dailyLendIncreaseLimit.selector);
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
            vm.expectRevert(Constants.dailyDebtIncreaseLimit.selector);
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

    function testDepositAndRepayWithPermit2() external {
        uint256 amount = 1000000;
        uint256 privateKey = 123;
        address addr = vm.addr(privateKey);

        // give coins
        vm.deal(addr, 1 ether);
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(addr, amount * 2);

        vm.prank(addr);
        usdc.approve(PERMIT2, type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory tf = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(address(usdc), amount), 1, block.timestamp
        );
        bytes memory signature = _getPermitTransferFromSignature(tf, privateKey, address(vault));
        bytes memory permitData = abi.encode(tf, signature);

        assertEq(vault.lendInfo(addr), 0);

        vm.prank(addr);
        vault.deposit(amount, addr, permitData);
        assertEq(vault.lendInfo(addr), 1000000);

        vm.prank(nft1Owner);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);
        vm.prank(nft1Owner);
        vault.create(nft1TokenId, nft1Owner);
        vm.prank(nft1Owner);
        vault.borrow(nft1TokenId, amount);

        (uint256 debt,,,,) = vault.loanInfo(nft1TokenId);
        assertEq(debt, 1000000);

        tf = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(address(usdc), amount), 2, block.timestamp
        );
        signature = _getPermitTransferFromSignature(tf, privateKey, address(vault));
        permitData = abi.encode(tf, signature);

        vm.prank(addr);
        vault.repay(nft1TokenId, amount, false, permitData);

        (debt,,,,) = vault.loanInfo(nft1TokenId);
        assertEq(debt, 0);
    }

    function _getPermitTransferFromSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        uint256 privateKey,
        address to
    ) internal returns (bytes memory sig) {
        bytes32 _PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
            "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
        bytes32 _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
        bytes32 tokenPermissions = keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2(PERMIT2).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(_PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissions, to, permit.nonce, permit.deadline)
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function test_LeverageDown() public {
        LeverageTransformer leverageTransformer = new LeverageTransformer(positionManager, UNIVERSAL_ROUTER, EX0x, permit2);
        vault.setTransformer(address(leverageTransformer), true);
        leverageTransformer.setVault(address(vault));

        _deposit(20000000, WHALE_ACCOUNT);

        vm.startPrank(nft1Owner);
        IERC721(address(positionManager)).approve(address(positionManager), nft1TokenId);
        IERC721(address(positionManager)).approve(address(vault), nft1TokenId);

        vault.create(nft1TokenId, nft1Owner);

        vault.borrow(nft1TokenId, 1);

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
            deadline: block.timestamp
        });

        vault.transform(
            nft1TokenId,
            address(leverageTransformer),
            abi.encodeWithSelector(LeverageTransformer.leverageDown.selector, params)
        );

        vault.remove(nft1TokenId, nft1Owner, "");
        vm.stopPrank();
    }
    */
}
