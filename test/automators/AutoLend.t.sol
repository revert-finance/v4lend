// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoLend} from "../../src/automators/AutoLend.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {MockERC4626Vault} from "../utils/MockERC4626Vault.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoLendTest is AutomatorTestBase {
    AutoLend public autoLend;
    MockERC4626Vault public usdcLendVault;
    MockERC4626Vault public wethLendVault;

    function setUp() public override {
        super.setUp();

        autoLend = new AutoLend(positionManager, address(swapRouter), EX0x, permit2, operator, withdrawer);

        // Deploy ERC4626 lending vaults
        usdcLendVault = new MockERC4626Vault(usdc, "Lend USDC", "lUSDC");
        wethLendVault = new MockERC4626Vault(IERC20(address(weth)), "Lend WETH", "lWETH");

        // Owner configures available lending vaults
        autoLend.setAutoLendVault(address(usdc), IERC4626(address(usdcLendVault)));
        autoLend.setAutoLendVault(address(weth), IERC4626(address(wethLendVault)));
    }

    // --- Access Control ---

    function test_RevertWhenNonOperatorCallsDeposit() public {
        AutoLend.DepositParams memory params = AutoLend.DepositParams({
            tokenId: 1,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLend.deposit(params);
    }

    function test_RevertWhenNonOwnerSetsAutoLendVault() public {
        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert();
        autoLend.setAutoLendVault(address(usdc), IERC4626(address(usdcLendVault)));
    }

    // --- Config Tests ---

    function test_ConfigToken() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 120,
            upperTickZone: 120,
            lowerTickZoneWithdraw: 60,
            upperTickZoneWithdraw: 60,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        (bool isActive,,,,,,) = autoLend.positionConfigs(tokenId);
        assertTrue(isActive);
    }

    function test_RevertWhenVaultOwnedPositionConfigured() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        // Add to vault
        autoLend.setVault(address(vault));
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 120,
            upperTickZone: 120,
            lowerTickZoneWithdraw: 60,
            upperTickZoneWithdraw: 60,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLend.configToken(tokenId, config);
    }

    // --- Deposit Tests ---

    function test_Deposit() public {
        PoolKey memory poolKey = _createPool();
        // Need full range for swap liquidity
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure auto-lend
        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: 0,
            upperTickZoneWithdraw: 0,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        // Approve NFT
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoLend), tokenId);

        // Move price below range (sell USDC for WETH - large swap to move tick far enough)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        int24 newTick = _getCurrentTick(poolKey);
        console.log("Tick after swap:", newTick);
        console.log("Position tickLower:", posInfo.tickLower());

        // Execute deposit
        AutoLend.DepositParams memory params = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLend.deposit(params);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after lend deposit");

        // Lend state should be set
        (address lentToken, uint256 shares, uint256 amount, address lendVault) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "Should have lending shares");
        assertGt(amount, 0, "Should have lending amount");
        assertTrue(lentToken != address(0), "Lent token should be set");
    }

    function test_RevertDepositWhenInRange() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey); // Full range = always in range

        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: 0,
            upperTickZoneWithdraw: 0,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoLend), tokenId);

        AutoLend.DepositParams memory params = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.NotReady.selector);
        autoLend.deposit(params);
    }

    function test_RevertDepositWhenVaultOwned() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        // Add to vault
        autoLend.setVault(address(vault));
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoLend.DepositParams memory params = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(); // NotConfigured because can't config vault-owned positions
        autoLend.deposit(params);
    }

    // --- Native ETH Pool Tests ---

    function test_DepositAndWithdrawNativeETH() public {
        PoolKey memory poolKey = _createETHPool();
        // Need full range for swap liquidity
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure WETH lending vault for native ETH (address(0))
        autoLend.setAutoLendVault(address(0), IERC4626(address(wethLendVault)));

        // Configure auto-lend with wide withdrawal zone
        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: 10000,
            upperTickZoneWithdraw: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoLend), true);

        // Move price below range (sell ETH for USDC → tick decreases)
        // When tick is below position range, idle token = currency0 = native ETH
        _swapExactInputSingleETH(poolKey, true, 10 ether, 0);

        int24 newTick = _getCurrentTick(poolKey);
        console.log("ETH pool tick after swap:", newTick);
        console.log("Position tickLower:", posInfo.tickLower());
        assertTrue(newTick < posInfo.tickLower(), "Tick should be below position range");

        // Execute deposit - this should wrap ETH to WETH and deposit to ERC4626
        AutoLend.DepositParams memory depositParams = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLend.deposit(depositParams);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after lend deposit");

        // Lend state should be set with address(0) as lent token
        (address lentToken, uint256 shares, uint256 amount, address lendVault) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "Should have lending shares");
        assertGt(amount, 0, "Should have lending amount");
        assertEq(lentToken, address(0), "Lent token should be native ETH (address(0))");
        assertEq(lendVault, address(wethLendVault), "Lend vault should be WETH vault");

        // WETH vault should have received WETH
        assertGt(IERC20(address(weth)).balanceOf(address(wethLendVault)), 0, "WETH vault should hold WETH");

        // Move price back towards range (buy ETH with USDC → tick increases)
        // Small swap to bring tick near position range without overshooting
        _swapExactInputSingleETH(poolKey, false, 5000e6, 0);

        // Withdraw - this should redeem WETH from ERC4626, unwrap to ETH, add liquidity
        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});

        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        // Lend state should be cleared
        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "Shares should be 0 after withdraw");
    }

    // --- Deposit + Withdraw Flow ---

    function test_DepositAndWithdraw() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure auto-lend with wide withdrawal zone
        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: 10000, // very wide
            upperTickZoneWithdraw: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoLend), true);

        // Move price below range (large swap)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Deposit
        AutoLend.DepositParams memory depositParams = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoLend.deposit(depositParams);

        // Verify deposit state
        (address lentToken, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "Should have shares after deposit");

        // Move price back towards range (moderate swap - don't overshoot)
        _swapExactInputSingle(poolKey, false, 2e18, 0);

        // Withdraw
        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});

        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        // Lend state should be cleared
        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "Shares should be 0 after withdraw");
    }
}
