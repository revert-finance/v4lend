// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoRange} from "../../src/automators/AutoRange.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoRangeTest is AutomatorTestBase {
    AutoRange public autoRange;

    function setUp() public override {
        super.setUp();

        autoRange = new AutoRange(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, withdrawer);
        autoRange.setVault(address(vault));
        vault.setTransformer(address(autoRange), true);
    }

    // --- Access Control ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: 1,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoRange.execute(params);
    }

    // --- Config Tests ---

    function test_ConfigToken() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 0,
            upperTickLimit: 0,
            lowerTickDelta: -120,
            upperTickDelta: 120,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        (int32 lowerTickLimit,,,,,,,) = autoRange.positionConfigs(tokenId);
        assertEq(lowerTickLimit, 0);
    }

    function test_RevertWhenNonOwnerConfigures() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 0,
            upperTickLimit: 0,
            lowerTickDelta: -120,
            upperTickDelta: 120,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoRange.configToken(tokenId, address(0), config);
    }

    // --- Execute Tests ---

    function test_ExecuteRangeChange() public {
        PoolKey memory poolKey = _createPool();
        // Need full-range position for swap liquidity
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 tickLowerBefore = posInfo.tickLower();
        int24 tickUpperBefore = posInfo.tickUpper();

        // Configure auto-range: trigger when 1 tick out of range
        // New range: above current tick (one-sided token0 position, no swap needed)
        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60, // +1 tick spacing above current
            upperTickDelta: 300, // +5 tick spacings above current
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        // Approve NFT
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoRange), true);

        // Move price to trigger range change (large swap to move tick far enough)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Execute range change
        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoRange.execute(params);

        // Verify original position has 0 liquidity
        uint128 oldLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertEq(oldLiquidity, 0, "Old position should have 0 liquidity");

        // Verify new position was created
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        assertGt(newTokenId, tokenId, "New tokenId should be greater");

        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        assertGt(newLiquidity, 0, "New position should have liquidity");

        // Verify new position is owned by original owner
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), WHALE_ACCOUNT);

        // Verify config was copied to new position
        (int32 lowerTickLimit,,,,,,,) = autoRange.positionConfigs(newTokenId);
        assertEq(lowerTickLimit, 1, "Config should be copied to new position");
    }

    function test_RevertWhenSwapExceedsMaxSlippage() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60,
            upperTickDelta: 300,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoRange), true);

        config.token0SlippageBps = 1;
        config.token1SlippageBps = 1;
        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        bytes memory swapData = _createSwapDataWithRecipient(USDC_ADDRESS, WETH_ADDRESS, address(autoRange));

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 1e5,
            amountOutMin: 0,
            swapData: swapData,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.SlippageError.selector);
        autoRange.execute(params);
    }

    function test_RevertWhenRewardConsumesAllRangeLiquidity() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);

        _approveWhaleTokens();
        int24 currentTick = _getCurrentTick(poolKey);
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing;
        uint256 tokenId = _mintPosition(poolKey, tickLower, tickUpper, 1);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60,
            upperTickDelta: 300,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: type(uint64).max,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoRange), tokenId);

        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: type(uint64).max
        });

        vm.prank(operator);
        vm.expectRevert(Constants.NoLiquidity.selector);
        autoRange.execute(params);
    }

    function test_RevertWhenNotReady() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        // Configure with large tick limits (position needs to be very out of range)
        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 10000,
            upperTickLimit: 10000,
            lowerTickDelta: -120,
            upperTickDelta: 120,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoRange), tokenId);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.NotReady.selector);
        autoRange.execute(params);
    }

    function test_RevertWhenSameRange() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Move price out of range first (so NotReady check passes)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        int24 currentTick = _getCurrentTick(poolKey);
        int24 tickSpacing = poolKey.tickSpacing;
        int24 baseTick = (currentTick / tickSpacing) * tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            baseTick -= tickSpacing;
        }

        // Configure deltas so that new range (baseTick + delta) equals old range
        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: int32(posInfo.tickLower() - baseTick),
            upperTickDelta: int32(posInfo.tickUpper() - baseTick),
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoRange), tokenId);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.SameRange.selector);
        autoRange.execute(params);
    }

    // --- Native ETH Position Tests ---

    function test_ExecuteRangeChangeETH() public {
        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

        // Configure auto-range: trigger when 1 tick out of range
        // New range above current tick (one-sided, no swap needed)
        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60,
            upperTickDelta: 300,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoRange), true);

        // Move price out of range (large ETH sell)
        _swapExactInputSingleETH(poolKey, true, 10e18, 0);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoRange.execute(params);

        // Verify original position has 0 liquidity
        uint128 oldLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertEq(oldLiquidity, 0, "Old ETH position should have 0 liquidity");

        // Verify new position was created with liquidity
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        assertGt(newTokenId, tokenId, "New tokenId should be greater");
        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        assertGt(newLiquidity, 0, "New ETH position should have liquidity");

        // Verify new position owned by original owner
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), WHALE_ACCOUNT);
    }

    function test_ExecuteWithVaultETH() public {
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createETHPool();
        _createFullRangePositionETH(poolKey);
        uint256 tokenId = _createNarrowPositionETH(poolKey);

        // Add to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoRange), true);

        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60,
            upperTickDelta: 300,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(vault), config);

        // Move price out of range
        _swapExactInputSingleETH(poolKey, true, 10e18, 0);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoRange.executeWithVault(params, address(vault));

        // Old position should have 0 liquidity
        assertEq(positionManager.getPositionLiquidity(tokenId), 0);

        // New position should be owned by vault
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(vault));
    }

    // --- Reward Retention Test ---

    function test_RewardStaysInContract() public {
        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        // Generate fees so there's something to take reward from
        _generateFees(poolKey);

        // Configure with reward enabled (10% reward on total = Q64 * 10 / 100)
        uint64 maxReward = uint64(Q64 * 10 / 100);
        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60,
            upperTickDelta: 300,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: maxReward,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(0), config);
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(autoRange), true);

        // Move price to trigger range change
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        // Check contract balances before
        uint256 contractUsdcBefore = usdc.balanceOf(address(autoRange));
        uint256 contractWethBefore = weth.balanceOf(address(autoRange));

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: maxReward
        });

        vm.prank(operator);
        autoRange.execute(params);

        // Contract should retain reward (at least one token should have increased)
        uint256 contractUsdcAfter = usdc.balanceOf(address(autoRange));
        uint256 contractWethAfter = weth.balanceOf(address(autoRange));
        assertTrue(
            contractUsdcAfter > contractUsdcBefore || contractWethAfter > contractWethBefore,
            "Contract should retain protocol reward"
        );

        // Withdrawer can collect the reward
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        uint256 withdrawerUsdcBefore = usdc.balanceOf(withdrawer);
        uint256 withdrawerWethBefore = weth.balanceOf(withdrawer);

        vm.prank(withdrawer);
        autoRange.withdrawBalances(tokens, withdrawer);

        assertTrue(
            usdc.balanceOf(withdrawer) > withdrawerUsdcBefore || weth.balanceOf(withdrawer) > withdrawerWethBefore,
            "Withdrawer should be able to collect reward"
        );
    }

    // --- Vault Tests ---

    function test_ExecuteWithVault() public {
        // Increase oracle tolerance for large swap price impact
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createPool();
        _createFullRangePosition(poolKey);
        uint256 tokenId = _createNarrowPosition(poolKey);

        // Add to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoRange), true);

        // Configure auto-range (one-sided range above current tick, no swap needed)
        AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
            lowerTickLimit: 1,
            upperTickLimit: 1,
            lowerTickDelta: 60,
            upperTickDelta: 300,
            token0SlippageBps: 10000,
            token1SlippageBps: 10000,
            maxRewardX64: 0,
            onlyFees: false
        });

        vm.prank(WHALE_ACCOUNT);
        autoRange.configToken(tokenId, address(vault), config);

        // Move price out of range (large swap)
        _swapExactInputSingle(poolKey, true, 10000e6, 0);

        AutoRange.ExecuteParams memory params = AutoRange.ExecuteParams({
            tokenId: tokenId,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: bytes(""),
            mintHookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        autoRange.executeWithVault(params, address(vault));

        // Old position should have 0 liquidity
        assertEq(positionManager.getPositionLiquidity(tokenId), 0);

        // New position should be owned by vault
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(vault));
    }
}
