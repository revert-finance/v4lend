// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {AutoLend} from "../../src/automators/AutoLend.sol";
import {Constants} from "src/shared/Constants.sol";
import {MockERC4626Vault} from "../utils/MockERC4626Vault.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";
import {ProtocolFeeRecipientProbe} from "./utils/ProtocolFeeRecipientProbe.sol";

contract AutoLendTest is AutomatorTestBase {
    AutoLend public autoLend;
    MockERC4626Vault public usdcLendVault;
    MockERC4626Vault public wethLendVault;

    function setUp() public override {
        super.setUp();

        autoLend =
            new AutoLend(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);

        usdcLendVault = new MockERC4626Vault(usdc, "Lend USDC", "lUSDC");
        wethLendVault = new MockERC4626Vault(IERC20(address(weth)), "Lend WETH", "lWETH");

        autoLend.setAutoLendVault(address(usdc), IERC4626(address(usdcLendVault)));
        autoLend.setAutoLendVault(address(weth), IERC4626(address(wethLendVault)));

        // Needed for non-vault-only checks in config/deposit/withdraw paths
        autoLend.setVault(address(vault));
    }

    function _deposit(address caller, AutoLend.DepositParams memory params) internal {
        vm.prank(caller);
        autoLend.deposit(params);
        _assertNoAutomatorDust(address(autoLend), "AutoLend");
    }

    function _withdraw(address caller, AutoLend.WithdrawParams memory params) internal {
        vm.prank(caller);
        autoLend.withdraw(params);
        _assertNoAutomatorDust(address(autoLend), "AutoLend");
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
            _swapExactInputSingleEth(poolKey, false, 500e6, 0);
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

        _deposit(operator, depositParams);

        (, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "should have shares after deposit");

        // Move back towards range and withdraw
        _swapExactInputSingle(poolKey, false, 2e18, 0);

        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});

        _withdraw(operator, withdrawParams);

        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "shares should be cleared");
    }

    /// @notice V4LE-31: deactivating a position must stop the operator's withdraw leg too, not only
    ///         deposits; the owner keeps forceExit as the recovery path.
    function test_WithdrawRejectsDeactivatedPosition() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);
        _configureAndApprove(tokenId, _defaultConfig(0));
        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        _deposit(
            operator,
            AutoLend.DepositParams({
                tokenId: tokenId,
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                deadline: block.timestamp,
                hookData: bytes(""),
                rewardX64: 0
            })
        );
        (, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0);

        AutoLend.PositionConfig memory disabled = _defaultConfig(0);
        disabled.isActive = false;
        vm.prank(WHALE_ACCOUNT);
        autoLend.configToken(tokenId, disabled);

        _swapExactInputSingle(poolKey, false, 2e18, 0);
        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});
        vm.prank(operator);
        vm.expectRevert(Constants.NotConfigured.selector);
        autoLend.withdraw(withdrawParams);
        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, shares, "disabled position keeps its lend state for the owner");
    }

    function test_WithdrawSweepsDustedBalances() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _defaultConfig(0));

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        _deposit(operator, _depositParams(tokenId));

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickLower());

        uint256 dustAmount = 777;
        deal(address(weth), address(autoLend), dustAmount);
        uint256 ownerWethBefore = weth.balanceOf(WHALE_ACCOUNT);

        _withdraw(operator, _withdrawParams(tokenId));

        assertEq(weth.balanceOf(address(autoLend)), 0, "dusted WETH should be swept out by withdraw");
        assertGe(weth.balanceOf(WHALE_ACCOUNT) - ownerWethBefore, dustAmount, "owner should receive the dusted WETH");
    }

    function test_DepositAndWithdrawETHNativePosition() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        // Native ETH positions lend through WETH vault.
        autoLend.setAutoLendVault(address(0), IERC4626(address(wethLendVault)));
        _configureAndApprove(tokenId, _defaultConfig(0));

        // Move below range and deposit (token0/native ETH should be lent via WETH vault).
        _swapExactInputSingleEth(poolKey, true, 1e16, 0);

        AutoLend.DepositParams memory depositParams = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _deposit(operator, depositParams);

        (address lentToken, uint256 shares,, address lendVault) = autoLend.lendStates(tokenId);
        assertEq(lentToken, address(0), "expected native ETH lend side");
        assertEq(lendVault, address(wethLendVault), "expected WETH lend vault");
        assertGt(shares, 0, "should have vault shares after deposit");
        assertEq(address(autoLend).balance, 0, "native ETH should be wrapped into vault");

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAboveETH(poolKey, posInfo.tickLower());

        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});

        _withdraw(operator, withdrawParams);

        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "shares should be cleared");
        assertEq(address(autoLend).balance, 0, "no native ETH should remain in contract");
    }

    function test_DepositProtocolFeesAreSentToRecipient() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        uint64 maxReward = type(uint64).max;
        _configureAndApprove(tokenId, _defaultConfig(maxReward));

        _generateFees(poolKey);
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        uint256 recipientUsdcBefore = usdc.balanceOf(protocolFeeRecipient);
        uint256 recipientWethBefore = weth.balanceOf(protocolFeeRecipient);

        AutoLend.DepositParams memory depositParams = AutoLend.DepositParams({
            tokenId: tokenId,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        _deposit(operator, depositParams);

        assertEq(usdc.balanceOf(address(autoLend)), 0, "contract should not retain USDC protocol fees");
        assertEq(weth.balanceOf(address(autoLend)), 0, "contract should not retain WETH protocol fees");
        assertTrue(
            usdc.balanceOf(protocolFeeRecipient) > recipientUsdcBefore
                || weth.balanceOf(protocolFeeRecipient) > recipientWethBefore,
            "recipient should receive deposit protocol fees"
        );
    }

    function test_NativeProtocolFeeSendClearsLendStateBeforeCallback() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        uint64 maxReward = uint64(Q64 * 10 / 100);
        _configureAndApprove(tokenId, _defaultConfig(maxReward));

        _swapExactInputSingleEth(poolKey, true, 10e18, 0);

        _deposit(operator, _depositParams(tokenId));

        (, uint256 shares, uint256 principal,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "position should be lent");

        uint256 donatedYield = principal + 1;
        vm.prank(WHALE_ACCOUNT);
        weth.transfer(address(wethLendVault), donatedYield);
        wethLendVault.simulatePositiveYield(10000);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAboveETH(poolKey, posInfo.tickLower());

        ProtocolFeeRecipientProbe probe = new ProtocolFeeRecipientProbe();
        autoLend.setProtocolFeeRecipient(address(probe));
        autoLend.setOperator(address(probe), true);

        AutoLend.WithdrawParams memory withdrawParams = AutoLend.WithdrawParams({
            tokenId: tokenId,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        probe.configure(address(autoLend), abi.encodeWithSignature("lendStates(uint256)", tokenId), 1);
        probe.setReentry(address(autoLend), abi.encodeCall(autoLend.withdraw, (withdrawParams)));

        _withdraw(address(probe), withdrawParams);

        assertGt(probe.totalNativeReceived(), 0, "probe should receive native protocol fees");
        assertTrue(probe.attemptedReentry(), "probe should attempt reentry");
        assertFalse(probe.reentrySucceeded(), "reentrant withdraw should fail");
        assertEq(uint256(probe.observedWord()), 0, "lend shares should be cleared before native fee send");
    }

    function test_WithdrawToken0LentAddsLiquidityBackToExistingPosition() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _configWithWithdrawZones(10000, 10000));

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickBelow(poolKey, posInfo.tickLower());

        _deposit(operator, _depositParams(tokenId));

        (, uint256 shares,,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "deposit should create vault shares");

        uint256 nextTokenBefore = positionManager.nextTokenId();

        _withdraw(operator, _withdrawParams(tokenId));

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

        _deposit(operator, _depositParams(tokenId));

        _pushTickToOrAbove(poolKey, posInfo.tickLower());

        uint256 nextTokenBefore = positionManager.nextTokenId();

        _withdraw(operator, _withdrawParams(tokenId));

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

        _deposit(operator, _depositParams(tokenId));

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

        _withdraw(operator, _withdrawParams(tokenId));

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

        _deposit(operator, _depositParams(tokenId));

        _pushTickBelow(poolKey, posInfo.tickUpper());

        uint256 nextTokenBefore = positionManager.nextTokenId();

        _withdraw(operator, _withdrawParams(tokenId));

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

        _deposit(operator, depositParams);

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

        _deposit(operator, depositParams);

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

        uint256 recipientUsdcBefore = usdc.balanceOf(protocolFeeRecipient);

        AutoLend.WithdrawParams memory withdrawParams = AutoLend.WithdrawParams({
            tokenId: tokenId,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        _withdraw(operator, withdrawParams);

        assertGt(
            usdc.balanceOf(protocolFeeRecipient),
            recipientUsdcBefore,
            "protocol fee should be sent from generated vault yield"
        );
        assertEq(usdc.balanceOf(address(autoLend)), 0, "contract should not retain protocol fees");
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
        _deposit(operator, depositParams);

        // Push tick high enough to force the replacement mint path on withdraw
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        _pushTickToOrAbove(poolKey, posInfo.tickLower());
        assertTrue(_getCurrentTick(poolKey) >= posInfo.tickLower(), "tick should recover above lower");

        uint256 nextTokenBefore = positionManager.nextTokenId();

        AutoLend.WithdrawParams memory withdrawParams =
            AutoLend.WithdrawParams({tokenId: tokenId, deadline: block.timestamp, hookData: bytes(""), rewardX64: 0});
        _withdraw(operator, withdrawParams);

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

    function test_ForceExitRedeemsSharesToOwner() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _defaultConfig(0));

        // Move below range and deposit (token0/USDC lent)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        _deposit(operator, _depositParams(tokenId));

        (, uint256 shares, uint256 principal,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "position should be lent");
        assertEq(autoLend.vaultPositionCount(address(usdcLendVault)), 1, "vault should be referenced");

        uint256 ownerUsdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        autoLend.forceExit(tokenId);
        _assertNoAutomatorDust(address(autoLend), "AutoLend");

        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "lend state should be cleared");
        assertEq(autoLend.vaultPositionCount(address(usdcLendVault)), 0, "vault reference should be released");
        assertGe(usdc.balanceOf(WHALE_ACCOUNT) - ownerUsdcBefore, principal, "owner should receive lent principal");

        (bool isActive,,,,,) = autoLend.positionConfigs(tokenId);
        assertFalse(isActive, "config should be deactivated after force exit");
    }

    function _burnEmptyPosition(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function test_ForceExitRevertsAfterBurn() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _defaultConfig(0));
        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        _deposit(operator, _depositParams(tokenId));

        // Burning the empty lent position destroys the ownerOf record. forceExit then reverts for
        // everyone (shares locked, self-inflicted) rather than misdirecting funds to a stale depositor.
        _burnEmptyPosition(tokenId);

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert();
        autoLend.forceExit(tokenId);
    }

    function test_RevertWhenNonOwnerForceExits() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        _configureAndApprove(tokenId, _defaultConfig(0));

        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        _deposit(operator, _depositParams(tokenId));

        vm.prank(makeAddr("random"));
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLend.forceExit(tokenId);

        vm.prank(operator);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoLend.forceExit(tokenId);
    }

    function test_RevertWhenForceExitWithoutActiveLend() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.NotConfigured.selector);
        autoLend.forceExit(tokenId);
    }

    function test_ForceExitChargesProtocolFeeOnYield() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        uint64 maxReward = uint64(Q64 * 10 / 100);
        _configureAndApprove(tokenId, _defaultConfig(maxReward));

        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        _deposit(operator, _depositParams(tokenId));

        (, uint256 shares, uint256 principal,) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "position should be lent");

        uint256 donatedYield = principal + 1;
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(address(usdcLendVault), donatedYield);
        usdcLendVault.simulatePositiveYield(10000); // +100% assets/share

        uint256 recipientUsdcBefore = usdc.balanceOf(protocolFeeRecipient);

        vm.prank(WHALE_ACCOUNT);
        autoLend.forceExit(tokenId);
        _assertNoAutomatorDust(address(autoLend), "AutoLend");

        assertGt(
            usdc.balanceOf(protocolFeeRecipient),
            recipientUsdcBefore,
            "protocol fee should be charged from vault yield on force exit"
        );
    }

    function test_ForceExitETHNativePosition() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        autoLend.setAutoLendVault(address(0), IERC4626(address(wethLendVault)));
        _configureAndApprove(tokenId, _defaultConfig(0));

        _swapExactInputSingleEth(poolKey, true, 1e16, 0);
        _deposit(operator, _depositParams(tokenId));

        (address lentToken, uint256 shares, uint256 principal,) = autoLend.lendStates(tokenId);
        assertEq(lentToken, address(0), "expected native ETH lend side");
        assertGt(shares, 0, "position should be lent");

        uint256 ownerEthBefore = WHALE_ACCOUNT.balance;

        vm.prank(WHALE_ACCOUNT);
        autoLend.forceExit(tokenId);
        _assertNoAutomatorDust(address(autoLend), "AutoLend");

        (, uint256 sharesAfter,,) = autoLend.lendStates(tokenId);
        assertEq(sharesAfter, 0, "lend state should be cleared");
        assertEq(address(autoLend).balance, 0, "no native ETH should remain in contract");
        assertGe(WHALE_ACCOUNT.balance - ownerEthBefore, principal, "owner should receive native ETH proceeds");
    }

    function test_ProtocolFeesAreSentToRecipient() public {
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
        _deposit(operator, depositParams);

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
        _withdraw(operator, withdrawParams);

        assertEq(usdc.balanceOf(address(autoLend)), 0, "contract should not retain protocol fees");
        assertGt(usdc.balanceOf(protocolFeeRecipient), 0, "recipient should receive protocol fees");
    }

    // --- H-02: share-token pools and custodied share isolation ---

    /// @dev Initializes a fresh (idleToken, otherToken) pool at tick 0 and mints a position for `owner` whose
    ///      range lies entirely on the `idleToken` side, so it is out of range and holds only `idleToken`.
    ///      `owner` must already hold enough `idleToken`.
    function _mintOneSidedOutOfRangePosition(address owner, address idleToken, address otherToken)
        internal
        returns (PoolKey memory key, uint256 tokenId)
    {
        bool idleIs0 = idleToken < otherToken;
        key = PoolKey({
            currency0: Currency.wrap(idleIs0 ? idleToken : otherToken),
            currency1: Currency.wrap(idleIs0 ? otherToken : idleToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(key, uint160(Q96)); // tick 0
        // token0-only range sits above the current tick, token1-only range below it
        (int24 lo, int24 hi) = idleIs0 ? (int24(60), int24(120)) : (int24(-120), int24(-60));

        vm.startPrank(owner);
        IERC20(idleToken).approve(address(permit2), type(uint256).max);
        permit2.approve(idleToken, address(positionManager), type(uint160).max, type(uint48).max);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(key, lo, hi, uint128(1e12), type(uint256).max, type(uint256).max, owner, bytes(""));
        p[1] = abi.encode(key.currency0, key.currency1, owner);
        positionManager.modifyLiquidities(abi.encode(actions, p), block.timestamp);
        tokenId = positionManager.nextTokenId() - 1;
        IERC721(address(positionManager)).setApprovalForAll(address(autoLend), true);
        vm.stopPrank();
    }

    function _fundUsdc(address account, uint256 amount) internal {
        vm.prank(WHALE_ACCOUNT);
        usdc.transfer(account, amount);
    }

    /// @dev Lends the whale's USDC/WETH narrow position (token0 lent) and returns the custodied shares.
    function _lendWhaleUsdcPosition() internal returns (uint256 tokenId, uint256 shares, address lendVault) {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        tokenId = _createNarrowPosition(poolKey);
        _configureAndApprove(tokenId, _defaultConfig(0));
        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        vm.prank(operator);
        autoLend.deposit(_depositParams(tokenId));
        (, shares,, lendVault) = autoLend.lendStates(tokenId);
        assertGt(shares, 0, "whale position should be lent");
    }

    function test_CustodiedSharesTrackLentShares() public {
        (uint256 tokenId, uint256 shares, address lendVault) = _lendWhaleUsdcPosition();
        assertEq(lendVault, address(usdcLendVault));
        assertEq(autoLend.custodiedShares(address(usdcLendVault)), shares, "deposit should custody shares");
        assertEq(usdcLendVault.balanceOf(address(autoLend)), shares, "balance equals custodied shares");

        vm.prank(WHALE_ACCOUNT);
        autoLend.forceExit(tokenId);
        assertEq(autoLend.custodiedShares(address(usdcLendVault)), 0, "exit should release custody");
        assertEq(usdcLendVault.balanceOf(address(autoLend)), 0, "no shares left");
    }

    /// @dev Regression for H-02: a config on a (USDC, shareToken) pool stored before the share token was
    ///      registered must not be executable afterwards, otherwise the whole-balance sweep of the share
    ///      token hands every custodied share to that position's owner.
    function test_RevertWhenDepositOnShareTokenPoolRegisteredAfterConfig() public {
        // 1. New USDC vault exists but is not yet registered in AutoLend.
        MockERC4626Vault newUsdcVault = new MockERC4626Vault(usdc, "Lend USDC v2", "lUSDC2");

        // 2. Attacker configures a one-sided USDC position in the (USDC, lUSDC2) pool; accepted because
        //    isKnownVault[lUSDC2] is still false.
        address attacker = makeAddr("attacker");
        _fundUsdc(attacker, 10_000e6);
        (, uint256 atkTokenId) = _mintOneSidedOutOfRangePosition(attacker, address(usdc), address(newUsdcVault));
        vm.prank(attacker);
        autoLend.configToken(atkTokenId, _defaultConfig(0));

        // 3. Owner registers the new vault. Re-configuring is now rejected, but the stored config remains.
        autoLend.setAutoLendVault(address(usdc), IERC4626(address(newUsdcVault)));
        vm.prank(attacker);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoLend.configToken(atkTokenId, _defaultConfig(0));

        // 4. Victim's idle USDC is lent into lUSDC2 and custodied by AutoLend.
        (uint256 victimTokenId, uint256 victimShares, address victimVault) = _lendWhaleUsdcPosition();
        assertEq(victimVault, address(newUsdcVault));
        assertEq(newUsdcVault.balanceOf(address(autoLend)), victimShares, "autolend custodies victim shares");

        // 5. Legitimately triggered deposit on the attacker's position must be refused at execution time.
        vm.prank(operator);
        vm.expectRevert(AutoLend.ShareTokenPool.selector);
        autoLend.deposit(_depositParams(atkTokenId));

        // 6. Nothing moved; the victim can still exit.
        assertEq(newUsdcVault.balanceOf(address(autoLend)), victimShares, "custodied shares untouched");
        assertEq(newUsdcVault.balanceOf(attacker), 0, "attacker received no shares");
        vm.prank(WHALE_ACCOUNT);
        autoLend.forceExit(victimTokenId);
        assertEq(newUsdcVault.balanceOf(address(autoLend)), 0);
    }

    /// @dev A position lent BEFORE its pool currency became a registered share token can no longer be
    ///      withdrawn by the operator (pool-key sweep path), but the owner's escape hatch must keep working.
    function test_WithdrawBlockedButForceExitWorksWhenShareTokenRegisteredAfterLend() public {
        MockERC4626Vault newUsdcVault = new MockERC4626Vault(usdc, "Lend USDC v2", "lUSDC2");

        address user = makeAddr("user");
        _fundUsdc(user, 10_000e6);
        (, uint256 tokenId) = _mintOneSidedOutOfRangePosition(user, address(usdc), address(newUsdcVault));
        vm.prank(user);
        autoLend.configToken(tokenId, _defaultConfig(0));

        // Lent while lUSDC2 is still unknown: idle USDC goes to the currently registered usdcLendVault.
        vm.prank(operator);
        autoLend.deposit(_depositParams(tokenId));
        (, uint256 shares, uint256 principal, address lendVault) = autoLend.lendStates(tokenId);
        assertEq(lendVault, address(usdcLendVault));
        assertGt(shares, 0);

        autoLend.setAutoLendVault(address(usdc), IERC4626(address(newUsdcVault)));

        vm.prank(operator);
        vm.expectRevert(AutoLend.ShareTokenPool.selector);
        autoLend.withdraw(_withdrawParams(tokenId));

        uint256 userUsdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        autoLend.forceExit(tokenId);
        assertGe(usdc.balanceOf(user) - userUsdcBefore, principal, "owner gets lent principal back");
        assertEq(autoLend.custodiedShares(address(usdcLendVault)), 0);
        _assertNoAutomatorDust(address(autoLend), "AutoLend");
    }

    /// @dev Proves the sweep itself is safe even when a share token legitimately IS the lent currency
    ///      (vault-of-vault: lUSDC lent into a meta vault). Position A's forceExit sweeps lUSDC, but only
    ///      the amount above the shares custodied for position B.
    function test_ForceExitDoesNotSweepOtherPositionsCustodiedShares() public {
        // Fresh instance so registration order can be controlled: meta vault (asset lUSDC) first.
        AutoLend lend2 =
            new AutoLend(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);
        lend2.setVault(address(vault));
        MockERC4626Vault metaVault = new MockERC4626Vault(IERC20(address(usdcLendVault)), "Meta lUSDC", "mlUSDC");
        lend2.setAutoLendVault(address(usdcLendVault), IERC4626(address(metaVault)));
        assertFalse(lend2.isKnownVault(address(usdcLendVault)), "lUSDC not yet a known vault");

        // Position A: one-sided lUSDC in a (USDC, lUSDC) pool, lent into the meta vault.
        address userA = makeAddr("userA");
        _fundUsdc(userA, 5_000e6);
        vm.startPrank(userA);
        usdc.approve(address(usdcLendVault), type(uint256).max);
        usdcLendVault.deposit(5_000e6, userA);
        vm.stopPrank();
        AutoLend autoLendSaved = autoLend;
        autoLend = lend2; // helpers approve / act on `autoLend`
        (, uint256 tokenA) = _mintOneSidedOutOfRangePosition(userA, address(usdcLendVault), address(usdc));
        vm.prank(userA);
        lend2.configToken(tokenA, _defaultConfig(0));
        vm.prank(operator);
        lend2.deposit(_depositParams(tokenA));
        (address lentA, uint256 sharesA, uint256 principalA, address vaultA) = lend2.lendStates(tokenA);
        assertEq(lentA, address(usdcLendVault));
        assertEq(vaultA, address(metaVault));
        assertEq(lend2.custodiedShares(address(metaVault)), sharesA);

        // Now register usdcLendVault for USDC: lUSDC becomes a known share token.
        lend2.setAutoLendVault(address(usdc), IERC4626(address(usdcLendVault)));

        // Position B (whale): USDC lent into usdcLendVault, so lend2 custodies lUSDC shares.
        (uint256 tokenB, uint256 sharesB, address vaultB) = _lendWhaleUsdcPosition();
        autoLend = autoLendSaved;
        assertEq(vaultB, address(usdcLendVault));
        assertEq(usdcLendVault.balanceOf(address(lend2)), sharesB, "lend2 custodies B's lUSDC shares");
        assertEq(lend2.custodiedShares(address(usdcLendVault)), sharesB);

        // A exits: meta vault redeems into lUSDC held by lend2, whose lUSDC balance now also contains B's shares.
        uint256 userALusdcBefore = usdcLendVault.balanceOf(userA);
        vm.prank(userA);
        lend2.forceExit(tokenA);

        assertEq(usdcLendVault.balanceOf(userA) - userALusdcBefore, principalA, "A receives exactly its own lUSDC");
        assertEq(usdcLendVault.balanceOf(address(lend2)), sharesB, "B's custodied shares were not swept");
        assertEq(lend2.custodiedShares(address(metaVault)), 0);

        // B can still exit and gets its principal.
        (,, uint256 principalB,) = lend2.lendStates(tokenB);
        uint256 whaleUsdcBefore = usdc.balanceOf(WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        lend2.forceExit(tokenB);
        assertGe(usdc.balanceOf(WHALE_ACCOUNT) - whaleUsdcBefore, principalB);
        assertEq(usdcLendVault.balanceOf(address(lend2)), 0);
        assertEq(lend2.custodiedShares(address(usdcLendVault)), 0);
    }
}
