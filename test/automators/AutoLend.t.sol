// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoLend} from "../../src/automators/AutoLend.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {MockERC4626Vault} from "../utils/MockERC4626Vault.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoLendTest is AutomatorTestBase {
    event BalancesWithdrawn(address[] tokens, address to);

    AutoLend public autoLend;
    MockERC4626Vault public usdcLendVault;
    MockERC4626Vault public wethLendVault;

    function setUp() public override {
        super.setUp();

        autoLend = new AutoLend(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, withdrawer);

        usdcLendVault = new MockERC4626Vault(usdc, "Lend USDC", "lUSDC");
        wethLendVault = new MockERC4626Vault(IERC20(address(weth)), "Lend WETH", "lWETH");

        autoLend.setAutoLendVault(address(usdc), IERC4626(address(usdcLendVault)));
        autoLend.setAutoLendVault(address(weth), IERC4626(address(wethLendVault)));

        // Needed for non-vault-only checks in config/deposit/withdraw paths
        autoLend.setVault(address(vault));
    }

    function _defaultConfig(uint64 maxRewardX64) internal pure returns (AutoLend.PositionConfig memory) {
        return AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: 10000,
            upperTickZoneWithdraw: 10000,
            maxRewardX64: maxRewardX64
        });
    }

    function _configWithWithdrawZones(int24 lowerTickZoneWithdraw, int24 upperTickZoneWithdraw)
        internal
        pure
        returns (AutoLend.PositionConfig memory)
    {
        return AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: lowerTickZoneWithdraw,
            upperTickZoneWithdraw: upperTickZoneWithdraw,
            maxRewardX64: 0
        });
    }

    function _configureAndApprove(uint256 tokenId, AutoLend.PositionConfig memory config) internal {
        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoLend), true);
    }

    function _pushTickToOrAbove(PoolKey memory poolKey, int24 targetTick) internal {
        for (uint256 i; i < 8; ++i) {
            if (_getCurrentTick(poolKey) >= targetTick) {
                return;
            }
            _swapExactInputSingle(poolKey, false, 5e18, 0);
        }
    }

    function _pushTickToOrAboveETH(PoolKey memory poolKey, int24 targetTick) internal {
        for (uint256 i; i < 10; ++i) {
            if (_getCurrentTick(poolKey) >= targetTick) {
                return;
            }
            _swapExactInputSingleETH(poolKey, false, 500e6, 0);
        }
    }

    function _pushTickBelow(PoolKey memory poolKey, int24 targetTick) internal {
        for (uint256 i; i < 10; ++i) {
            if (_getCurrentTick(poolKey) < targetTick) {
                return;
            }
            _swapExactInputSingle(poolKey, true, 10000e6, 0);
        }
    }

    function _pushTickIntoUpperWithdrawWindow(PoolKey memory poolKey, int24 tickUpper) internal {
        int24 currentTick = _getCurrentTick(poolKey);
        for (uint256 i; i < 20 && currentTick >= tickUpper + 5 * poolKey.tickSpacing; ++i) {
            _swapExactInputSingle(poolKey, true, 500e6, 0);
            currentTick = _getCurrentTick(poolKey);
        }

        for (uint256 i; i < 120 && (currentTick < tickUpper || currentTick >= tickUpper + poolKey.tickSpacing); ++i) {
            if (currentTick >= tickUpper + poolKey.tickSpacing) {
                _swapExactInputSingle(poolKey, true, 10e6, 0);
            } else {
                _swapExactInputSingle(poolKey, false, 1e15, 0);
            }
            currentTick = _getCurrentTick(poolKey);
        }
    }

    function _depositParams(uint256 tokenId) internal view returns (AutoLend.DepositParams memory) {
        return AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });
    }

    function _withdrawParams(uint256 tokenId) internal view returns (AutoLend.WithdrawParams memory) {
        return AutoLend.WithdrawParams({
            tokenId: tokenId,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });
    }

    function test_RevertWhenNonOperatorCallsDeposit() public {
        AutoLend.DepositParams memory params = AutoLend.DepositParams({
            tokenId: 1,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(makeAddr("random"));
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLend.deposit(params);
    }

    function test_RevertWhenNonOwnerSetsAutoLendVault() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        autoLend.setAutoLendVault(address(usdc), IERC4626(address(usdcLendVault)));
    }

    function test_RevertWhenVaultAssetMismatchesToken() public {
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoLend.setAutoLendVault(address(usdc), IERC4626(address(wethLendVault)));
    }

    function test_ConfigToken() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoLend.PositionConfig memory config = _defaultConfig(0);

        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, config);

        (bool isActive,,,,,) = autoLend.positionConfigs(tokenId);
        assertTrue(isActive);
    }

    function test_RevertWhenVaultOwnedPositionConfigured() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLend.configToken(tokenId, _defaultConfig(0));
    }

    function test_RevertWhenInactiveConfigHasNegativeZones() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoLend.PositionConfig memory invalidConfig = AutoLend.PositionConfig({
            isActive: false,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: -1,
            upperTickZoneWithdraw: 0,
            maxRewardX64: 0
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoLend.configToken(tokenId, invalidConfig);
    }

    function test_DepositAndWithdraw() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _defaultConfig(0));

        // Move below range and deposit
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

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

        (, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "should have shares after deposit");

        // Move back towards range and withdraw
        _swapExactInputSingle(poolKey, false, 2e18, 0);

        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});

        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "shares should be cleared");
    }

    function test_DepositAndWithdrawETHNativePosition() public {
        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

        // Native ETH positions lend through WETH vault.
        autoLend.setAutoLendVault(address(0), IERC4626(address(wethLendVault)));
        _configureAndApprove(tokenId, _defaultConfig(0));

        // Move below range and deposit (token0/native ETH should be lent via WETH vault).
        _swapExactInputSingleETH(poolKey, true, 1e16, 0);

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

        (address lentToken, uint256 shares,, address lendVault) = autoLend.lendStates(tokenId);
        assertEq(lentToken, address(0), "expected native ETH lend side");
        assertEq(lendVault, address(wethLendVault), "expected WETH lend vault");
        assertGt(shares, 0, "should have vault shares after deposit");
        assertEq(address(autoLend).balance, 0, "native ETH should be wrapped into vault");

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAboveETH(poolKey, posInfo.tickLower());

        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});

        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "shares should be cleared");
        assertEq(address(autoLend).balance, 0, "no native ETH should remain in contract");
    }

    function test_WithdrawToken0LentAddsLiquidityBackToExistingPosition() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _configWithWithdrawZones(10000, 10000));

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickBelow(poolKey, posInfo.tickLower());

        vm.prank(operator);
        autoLend.deposit(_depositParams(tokenId));

        (, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "deposit should create vault shares");

        uint256 nextTokenBefore = positionManager.nextTokenId();

        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(tokenId));

        assertEq(positionManager.nextTokenId(), nextTokenBefore, "withdraw should reuse the existing position");
        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "shares should be cleared");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "existing position should regain liquidity");
    }

    function test_WithdrawToken0LentMintsShiftedPositionWhenPriceRecovers() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _configWithWithdrawZones(0, 10000));

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickBelow(poolKey, posInfo.tickLower());

        vm.prank(operator);
        autoLend.deposit(_depositParams(tokenId));

        _pushTickToOrAbove(poolKey, posInfo.tickLower());

        uint256 nextTokenBefore = positionManager.nextTokenId();

        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(tokenId));

        uint256 nextTokenAfter = positionManager.nextTokenId();
        assertGt(nextTokenAfter, nextTokenBefore, "withdraw should mint a shifted replacement");

        uint256 newTokenId = nextTokenAfter - 1;
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "replacement position should have liquidity");
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), WHALE_ACCOUNT, "owner should receive the replacement");
        (bool isActiveOld,,,,,) = autoLend.positionConfigs(tokenId);
        assertFalse(isActiveOld, "old config should be cleared after remint");
    }

    function test_WithdrawToken1LentAddsLiquidityBackToExistingPosition() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _configWithWithdrawZones(10000, 10000));

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickUpper());

        vm.prank(operator);
        autoLend.deposit(_depositParams(tokenId));

        (, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "deposit should create vault shares");

        _pushTickIntoUpperWithdrawWindow(poolKey, posInfo.tickUpper());
        int24 currentTick = _getCurrentTick(poolKey);
        assertGe(currentTick, posInfo.tickUpper(), "price should stay above the original range for add-to-existing");
        assertLt(
            currentTick,
            posInfo.tickUpper() + poolKey.tickSpacing,
            "price should return close enough for token1 reentry on the existing range"
        );

        uint256 nextTokenBefore = positionManager.nextTokenId();

        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(tokenId));

        assertEq(positionManager.nextTokenId(), nextTokenBefore, "withdraw should reuse the existing position");
        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "shares should be cleared");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "existing position should regain liquidity");
    }

    function test_WithdrawToken1LentMintsShiftedPositionWhenPriceReturnsBelowUpper() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _configWithWithdrawZones(10000, 0));

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickUpper());

        vm.prank(operator);
        autoLend.deposit(_depositParams(tokenId));

        _pushTickBelow(poolKey, posInfo.tickUpper());

        uint256 nextTokenBefore = positionManager.nextTokenId();

        vm.prank(operator);
        autoLend.withdraw(_withdrawParams(tokenId));

        uint256 nextTokenAfter = positionManager.nextTokenId();
        assertGt(nextTokenAfter, nextTokenBefore, "withdraw should mint a shifted replacement");

        uint256 newTokenId = nextTokenAfter - 1;
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "replacement position should have liquidity");
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), WHALE_ACCOUNT, "owner should receive the replacement");
        (bool isActiveOld,,,,,) = autoLend.positionConfigs(tokenId);
        assertFalse(isActiveOld, "old config should be cleared after remint");
    }

    function test_DepositDoesNotChargePrincipalWhenNoLPFees() public {
        PoolKey memory poolKey = _createPool();
        _approveWhaleTokens();
        int24 currentTick = _getCurrentTick(poolKey);
        int24 tickSpacing = poolKey.tickSpacing;
        // Mint far below current price so deposit can run immediately without swaps (no accrued LP fees).
        int24 tickUpper = (currentTick / tickSpacing - 20) * tickSpacing;
        int24 tickLower = tickUpper - 4 * tickSpacing;
        uint256 tokenId = _mintPosition(poolKey, tickLower, tickUpper, 1e13);

        uint64 maxReward = type(uint64).max;
        _configureAndApprove(tokenId, _defaultConfig(maxReward));

        uint256 usdcBefore = usdc.balanceOf(address(autoLend));
        uint256 wethBefore = weth.balanceOf(address(autoLend));

        AutoLend.DepositParams memory depositParams = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        vm.prank(operator);
        autoLend.deposit(depositParams);

        uint256 usdcAfter = usdc.balanceOf(address(autoLend));
        uint256 wethAfter = weth.balanceOf(address(autoLend));

        assertEq(usdcAfter, usdcBefore, "no LP fees: deposit should not charge principal token0");
        assertEq(wethAfter, wethBefore, "no LP fees: deposit should not charge principal token1");
    }

    function test_WithdrawProtocolFeeComesFromVaultYield() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        uint64 maxReward = type(uint64).max;
        _configureAndApprove(tokenId, _defaultConfig(maxReward));

        // Move below range and deposit (token0/USDC should be lent)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

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

        (address lentToken,, uint256 principal, address lendVault) = autoLend.lendStates(tokenId);
        assertEq(lentToken, address(usdc), "expected USDC lend side");
        assertEq(lendVault, address(usdcLendVault), "expected USDC lend vault");
        assertGt(principal, 0, "principal should be recorded");

        // Create positive yield in the lend vault and fund the additional assets needed by the mock.
        // Force deterministic non-zero yield and fee accrual.
        uint256 donatedYield = principal + 1;
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(address(usdcLendVault), donatedYield);
        usdcLendVault.simulatePositiveYield(10000); // +100% assets/share

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickLower());

        uint256 usdcBeforeWithdraw = usdc.balanceOf(address(autoLend));

        AutoLend.WithdrawParams memory withdrawParams = AutoLend.WithdrawParams({
            tokenId: tokenId,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        uint256 usdcAfterWithdraw = usdc.balanceOf(address(autoLend));
        assertGt(usdcAfterWithdraw, usdcBeforeWithdraw, "protocol fee should accrue from generated vault yield");
    }

    function test_ConfigCopiedWhenNewPositionMinted() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoLend.PositionConfig memory config = AutoLend.PositionConfig({
            isActive: true,
            lowerTickZone: 0,
            upperTickZone: 0,
            lowerTickZoneWithdraw: 0,
            upperTickZoneWithdraw: 0,
            maxRewardX64: uint64(Q64 / 10)
        });
        _configureAndApprove(tokenId, config);

        // Deposit below range (token0 lent)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);
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

        // Push tick high enough to force the replacement mint path on withdraw
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickLower());
        assertTrue(_getCurrentTick(poolKey) >= posInfo.tickLower(), "tick should recover above lower");

        uint256 nextTokenBefore = positionManager.nextTokenId();

        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});
        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        uint256 nextTokenAfter = positionManager.nextTokenId();
        assertGt(nextTokenAfter, nextTokenBefore, "withdraw should mint a replacement position");

        uint256 newTokenId = nextTokenAfter - 1;
        (bool isActiveNew, int24 lzNew, int24 uzNew, int24 lzwNew, int24 uzwNew, uint64 maxRewardNew) =
            autoLend.positionConfigs(newTokenId);
        assertTrue(isActiveNew, "new position config should be active");
        assertEq(lzNew, config.lowerTickZone);
        assertEq(uzNew, config.upperTickZone);
        assertEq(lzwNew, config.lowerTickZoneWithdraw);
        assertEq(uzwNew, config.upperTickZoneWithdraw);
        assertEq(maxRewardNew, config.maxRewardX64);

        (bool isActiveOld,,,,,) = autoLend.positionConfigs(tokenId);
        assertFalse(isActiveOld, "old position config should be cleared");
    }

    function test_WithdrawBalancesEmitsEvent() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        uint64 maxReward = type(uint64).max;
        _configureAndApprove(tokenId, _defaultConfig(maxReward));

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

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

        (, uint256 shares, uint256 principal,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "position should be lent");

        uint256 donatedYield = principal + 1;
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(address(usdcLendVault), donatedYield);
        usdcLendVault.simulatePositiveYield(10000);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickLower());

        AutoLend.WithdrawParams memory withdrawParams = AutoLend.WithdrawParams({
            tokenId: tokenId,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });
        vm.prank(operator);
        autoLend.withdraw(withdrawParams);

        uint256 protocolFees = usdc.balanceOf(address(autoLend));
        assertGt(protocolFees, 0, "expected protocol fees in contract");

        address recipient = makeAddr("recipient");
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.expectEmit(false, false, false, true, address(autoLend));
        emit BalancesWithdrawn(tokens, recipient);

        vm.prank(withdrawer);
        autoLend.withdrawBalances(tokens, recipient);

        assertEq(usdc.balanceOf(address(autoLend)), 0, "fees should be withdrawn");
        assertEq(usdc.balanceOf(recipient), protocolFees, "recipient should receive withdrawn fees");
    }
}
