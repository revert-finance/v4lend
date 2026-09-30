// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoExit} from "../../src/automators/AutoExit.sol";
import {Constants} from "src/shared/Constants.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";
import {ProtocolFeeRecipientProbe} from "./utils/ProtocolFeeRecipientProbe.sol";

contract AutoExitTest is AutomatorTestBase {
    AutoExit public autoExit;

    function setUp() public override {
        super.setUp();

        autoExit =
            new AutoExit(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);
        autoExit.setVault(address(vault));
        vault.setTransformer(address(autoExit), true);
    }

    function _execute(address caller, AutoExit.ExecuteParams memory params) internal {
        vm.prank(caller);
        autoExit.execute(params);
        _assertNoAutomatorDust(address(autoExit), "AutoExit");
    }

    function _executeWithVault(AutoExit.ExecuteParams memory params) internal {
        vm.prank(operator);
        autoExit.executeWithVault(params, address(vault));
        _assertNoAutomatorDust(address(autoExit), "AutoExit");
    }

    // --- Access Control ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: 1,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoExit.execute(params);
    }

    // --- Config Tests ---

    function test_ConfigToken() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        int24 tick = _getCurrentTick(poolKey);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: tick - 1000,
            token1TriggerTick: tick + 1000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        (bool isActive,,,,,,,,) = autoExit.positionConfigs(tokenId);
        assertTrue(isActive);
    }

    function test_RevertWhenNonOwnerConfigures() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: -1000,
            token1TriggerTick: 1000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoExit.configToken(tokenId, config);
    }

    function test_RevertWhenInvalidConfigTriggerTicks() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // token0TriggerTick >= token1TriggerTick is invalid
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: 1000,
            token1TriggerTick: 500,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoExit.configToken(tokenId, config);
    }

    // --- Execute Tests ---

    function test_ExecuteLimitOrder() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Set trigger ticks so that a large swap will trigger exit
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false, // No swap - limit order style
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        // Approve NFT
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move price below position range (large swap to move tick far enough)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Execute exit
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        _execute(operator, params);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after exit");

        // Config should be deleted
        (bool isActive,,,,,,,,) = autoExit.positionConfigs(tokenId);
        assertFalse(isActive, "Config should be deleted after exit");
    }

    function test_RevertWhenNotReady() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        int24 tick = _getCurrentTick(poolKey);

        // Set trigger ticks very far away
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: tick - 100000,
            token1TriggerTick: tick + 100000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        vm.prank(operator);
        vm.expectRevert(Constants.NotReady.selector);
        autoExit.execute(params);
    }

    /// @notice V4LE-60: the lower trigger is reached when the pool tick equals it, like the upper one
    ///         and like the hook's inclusive evaluation; the operator could not exit at the exact tick.
    function test_ExecuteAtExactLowerTriggerTick() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);
        int24 tick = _getCurrentTick(poolKey);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: tick,
            token1TriggerTick: tick + 100000,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });
        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });
        _execute(operator, params);
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "exit executes at the exact lower trigger tick");
    }

    function test_ExecuteWithSwap() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Configure with swap enabled
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: true,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move tick below range — position holds only token0 (USDC)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Build swap data: USDC → WETH via Universal Router V3 swap
        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        _execute(operator, params);

        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Position should be empty");
    }

    function test_ProtocolFeesAreSentToRecipientInTokens() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint64 maxReward = type(uint64).max;

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: maxReward,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        uint256 recipientUsdcBefore = usdc.balanceOf(protocolFeeRecipient);
        uint256 recipientWethBefore = weth.balanceOf(protocolFeeRecipient);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        _execute(operator, params);

        assertEq(usdc.balanceOf(address(autoExit)), 0, "contract should not retain USDC protocol fees");
        assertEq(weth.balanceOf(address(autoExit)), 0, "contract should not retain WETH protocol fees");
        assertGt(usdc.balanceOf(protocolFeeRecipient), recipientUsdcBefore, "recipient should receive USDC protocol fees");
        assertEq(weth.balanceOf(protocolFeeRecipient), recipientWethBefore, "recipient should not receive WETH here");
    }

    function test_RevertWhenSwapExceedsMaxSlippage() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: true,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Make oracle slippage guard stricter than pool fee so swap must fail.
        config.token0SlippageBps = 1;
        config.token1SlippageBps = 1;
        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit));

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        vm.prank(operator);
        vm.expectRevert(Constants.SlippageError.selector);
        autoExit.execute(params);
    }

    // --- Native ETH Position Tests ---

    function test_ExecuteLimitOrderETH() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Set trigger ticks so exit triggers when price moves
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        // Move price below range (large ETH sell)
        _swapExactInputSingleEth(poolKey, true, 10e18, 0);

        // Execute exit
        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        uint256 ethBefore = WHALE_ACCOUNT.balance;
        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        _execute(operator, params);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after ETH exit");

        // Owner should receive tokens (ETH as native, not WETH)
        uint256 ethAfter = WHALE_ACCOUNT.balance;
        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        assertTrue(ethAfter > ethBefore || usdcAfter > usdcBefore, "Owner should receive ETH/USDC after exit");
    }

    function test_NativeProtocolFeeSendFinalizesConfigBeforeCallback() public {
        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint64 maxReward = uint64(Q64 * 10 / 100);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: maxReward,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoExit), tokenId);

        _swapExactInputSingleEth(poolKey, true, 10e18, 0);

        ProtocolFeeRecipientProbe probe = new ProtocolFeeRecipientProbe();
        autoExit.setProtocolFeeRecipient(address(probe));
        autoExit.setOperator(address(probe), true);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        probe.configure(address(autoExit), abi.encodeWithSignature("positionConfigs(uint256)", tokenId), 0);
        probe.setReentry(address(autoExit), abi.encodeCall(autoExit.execute, (params)));

        _execute(address(probe), params);

        assertGt(probe.totalNativeReceived(), 0, "probe should receive native protocol fees");
        assertTrue(probe.attemptedReentry(), "probe should attempt reentry");
        assertFalse(probe.reentrySucceeded(), "reentrant execute should fail");
        assertEq(uint256(probe.observedWord()), 0, "config should be cleared before native fee send");
    }

    function test_ExecuteWithVaultETH() public {
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createEthPool();
        _createFullRangePositionEth(poolKey);
        uint256 tokenId = _createNarrowPositionEth(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        // Move price out of range
        _swapExactInputSingleEth(poolKey, true, 10e18, 0);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        _executeWithVault(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after ETH vault exit");
    }

    // --- Vault Exit Test ---

    /// @notice V4LE-14: the automation reward was reserved before the vault debt was repaid, so a
    ///         loan whose gross proceeds cover the debt but whose reward-reduced proceeds do not could
    ///         never be exited: repayment left debt on an emptied position and the vault's health
    ///         check rolled the whole exit back. Debt is senior to the reward.
    function test_ExecuteWithVaultRepaysDebtBeforeReservingReward() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        uint64 reward = uint64(Q64 / 5); // 20% of the proceeds
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: reward,
            onlyFees: false
        });
        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        // price below the range: the position is all USDC (the lend token). Borrow 88% of full value:
        // gross proceeds cover it, proceeds after a 20% reward do not.
        _swapExactInputSingle(poolKey, true, 10000e6, 0);
        (, uint256 fullValue,,,) = vault.loanInfo(tokenId);
        uint256 debt = fullValue * 88 / 100;
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, debt);
        uint256 recipientBefore = usdc.balanceOf(protocolFeeRecipient);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: reward,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });
        _executeWithVault(params);

        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "position exited");
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0, "debt fully repaid from gross proceeds");
        uint256 rewardPaid = usdc.balanceOf(protocolFeeRecipient) - recipientBefore;
        assertGt(rewardPaid, 0, "the reward is capped to the residual, not dropped");
        assertLt(rewardPaid, fullValue / 5, "reward reduced by what the debt needed");
    }

    /// @notice V4LE-34: a zero-debt vault position whose pool omits the lend asset needs no repayment
    ///         and no conversion; the exit must not be blocked by the pair check meant for debt repayment.
    function test_ExecuteWithVaultZeroDebtThirdTokenPair() public {
        vault.setTokenConfig(address(dai), uint32(Q32 * 9 / 10), type(uint32).max);
        v4Oracle.setMaxPoolPriceDifference(type(uint16).max);
        PoolKey memory poolKey = _createDaiWethPool();
        uint256 tokenId = _createFullRangePositionDaiWeth(poolKey);
        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // trigger already satisfied on the upper side: no price movement needed
        int24 tick = _getCurrentTick(poolKey);
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: tick - 1000,
            token1TriggerTick: tick - 500,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });
        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);
        uint256 daiBefore = dai.balanceOf(WHALE_ACCOUNT);
        uint256 wethBefore = weth.balanceOf(WHALE_ACCOUNT);

        _executeWithVault(
            AutoExit.ExecuteParams({
                tokenId: tokenId,
                swapData: bytes(""),
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                amountOutMin: 0,
                deadline: block.timestamp,
                hookData: bytes(""),
                rewardX64: 0,
                repayAmountIn: 0,
                repayAmountOutMin: 0,
                repaySwapData: bytes("")
            })
        );
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "zero-debt third-token position exited");
        assertTrue(
            dai.balanceOf(WHALE_ACCOUNT) > daiBefore || weth.balanceOf(WHALE_ACCOUNT) > wethBefore,
            "owner received the removed tokens"
        );
    }

    function _createDaiWethPool() internal returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(dai)),
            currency1: Currency.wrap(address(weth)),
            fee: 7778,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(poolKey, v4Oracle.getPoolSqrtPriceX96(address(dai), address(weth)));
    }

    function _createFullRangePositionDaiWeth(PoolKey memory poolKey) internal returns (uint256 tokenId) {
        deal(address(dai), WHALE_ACCOUNT, 1_000_000e18);
        deal(address(weth), WHALE_ACCOUNT, 1_000e18);
        vm.startPrank(WHALE_ACCOUNT);
        dai.approve(address(permit2), type(uint256).max);
        weth.approve(address(permit2), type(uint256).max);
        permit2.approve(address(dai), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        tokenId = _mintPosition(poolKey, -887220, 887220, 1e16);
    }

    function test_ExecuteWithVault() public {
        // Increase oracle tolerance for large swap price impact
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createPool();
        // Create a full-range liquidity position to support swaps
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Add position to vault (no borrowing - just testing exit functionality)
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Configure auto-exit
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: false,
            token1Swap: false,
            token0TriggerTick: posInfo.tickLower(),
            token1TriggerTick: posInfo.tickUpper(),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);

        // Approve autoExit to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        // Move price out of range (large swap)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        AutoExit.ExecuteParams memory params = AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });

        _executeWithVault(params);

        // Position should have 0 liquidity
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityAfter, 0, "Position should have 0 liquidity after vault exit");
    }

    // --- V4LE-134 / V4LE-102 / V4LE-100: debt is senior to the exit direction and to the reward ---

    /// @dev An in-range USDC/WETH position (both legs hold value) in the USDC vault, borrowed to 88% of its
    ///      value: more than either leg alone but well below the combined proceeds.
    function _inRangeVaultPositionWithHeavyDebt(uint64 maxRewardX64, bool upperTrigger, bool swapOnTrigger)
        internal
        returns (uint256 tokenId, uint256 fullValue)
    {
        v4Oracle.setMaxPoolPriceDifference(10000);
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        tokenId = _createNarrowPosition(poolKey);
        _depositToVault(50000000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // the trigger is already reached at the current tick without moving the price, so the position
        // still holds both tokens when it is removed
        int24 tick = _getCurrentTick(poolKey);
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig({
            isActive: true,
            token0Swap: !upperTrigger && swapOnTrigger,
            token1Swap: upperTrigger && swapOnTrigger,
            token0TriggerTick: upperTrigger ? tick - 1200 : tick + 600,
            token1TriggerTick: upperTrigger ? tick - 600 : tick + 1200,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: maxRewardX64,
            onlyFees: false
        });
        vm.prank(WHALE_ACCOUNT);
        autoExit.configToken(tokenId, config);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoExit), true);

        (, fullValue,,,) = vault.loanInfo(tokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(tokenId, fullValue * 88 / 100);
    }

    function _exitParams(uint256 tokenId, bytes memory swapData, uint64 rewardX64)
        internal
        view
        returns (AutoExit.ExecuteParams memory)
    {
        return AutoExit.ExecuteParams({
            tokenId: tokenId,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountOutMin: 0,
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: rewardX64,
            repayAmountIn: 0,
            repayAmountOutMin: 0,
            repaySwapData: bytes("")
        });
    }

    /// @notice V4LE-134: a lower-trigger stop loss sells the lend token (USDC) into WETH. Settlement only
    ///         used the USDC leg, and the exit swap then moved away from the lend token, so a debt above the
    ///         USDC leg could never be settled although the WETH leg covered it. Like the hook's own path,
    ///         the other leg is converted into the lend token first, the debt repaid, and only the remainder
    ///         consolidated into the configured exit token.
    function testV4LE134_LowerTriggerExitRepaysLendSideDebtFromTheOtherLeg() public {
        (uint256 tokenId,) = _inRangeVaultPositionWithHeavyDebt(0, false, true);
        AutoExit.ExecuteParams memory params =
            _exitParams(tokenId, _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoExit)), 0);

        // without a repay route the USDC leg alone cannot settle the debt: the vault's health check rolls
        // the emptied, still indebted position back
        vm.prank(operator);
        vm.expectRevert(Constants.CollateralFail.selector);
        autoExit.executeWithVault(params, address(vault));

        params.repayAmountIn = type(uint256).max; // the whole WETH leg, capped on-chain to its proceeds
        params.repaySwapData = _createSwapDataWithRecipient(WETH_ADDRESS, USDC_ADDRESS, address(autoExit));
        uint256 ownerWethBefore = weth.balanceOf(WHALE_ACCOUNT);
        uint256 ownerUsdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        _executeWithVault(params);

        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "position exited");
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0, "debt settled from both legs");
        assertGt(weth.balanceOf(WHALE_ACCOUNT), ownerWethBefore, "equity consolidated into the exit token");
        assertEq(usdc.balanceOf(WHALE_ACCOUNT), ownerUsdcBefore, "no lend token left for the owner");
    }

    /// @notice V4LE-102 / V4LE-100: an upper-trigger stop loss sells WETH into USDC (the lend token). The reward
    ///         reserved in the sold WETH leg was never available for a USDC-side shortfall, so a debt that the
    ///         gross proceeds cover could not be settled. The repay route converts the sold leg including its
    ///         reserved reward, and the reward is reduced by what the debt needed (the V4LE-14 rule for the
    ///         lend leg now holds for both legs).
    function testV4LE102_UpperTriggerExitUsesTheSoldLegRewardForTheDebt() public {
        uint64 reward = uint64(Q64 * 3 / 10); // 30% of the proceeds
        (uint256 tokenId, uint256 fullValue) = _inRangeVaultPositionWithHeavyDebt(reward, true, true);
        bytes memory wethToUsdc = _createSwapDataWithRecipient(WETH_ADDRESS, USDC_ADDRESS, address(autoExit));
        AutoExit.ExecuteParams memory params = _exitParams(tokenId, wethToUsdc, reward);

        // exit swap of the net WETH plus the whole USDC leg is short of the debt by the WETH-side reward
        vm.prank(operator);
        vm.expectRevert(Constants.CollateralFail.selector);
        autoExit.executeWithVault(params, address(vault));

        params.repayAmountIn = type(uint256).max;
        params.repaySwapData = wethToUsdc;
        uint256 recipientUsdcBefore = usdc.balanceOf(protocolFeeRecipient);
        uint256 recipientWethBefore = weth.balanceOf(protocolFeeRecipient);

        _executeWithVault(params);

        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "position exited");
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0, "debt settled");
        uint256 rewardPaid = usdc.balanceOf(protocolFeeRecipient) - recipientUsdcBefore;
        assertGt(rewardPaid, 0, "the reward is capped to the residual, not dropped");
        assertLt(rewardPaid, fullValue * 3 / 10, "reward reduced by what the debt needed");
        assertEq(weth.balanceOf(protocolFeeRecipient), recipientWethBefore, "the sold-leg reward went to the debt");
    }
}
