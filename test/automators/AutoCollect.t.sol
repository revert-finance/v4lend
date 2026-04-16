// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {AutoCollect} from "../../src/automators/AutoCollect.sol";
import {Constants} from "src/shared/Constants.sol";
import {AutomatorTestBase} from "./AutomatorTestBase.sol";

contract AutoCollectTest is AutomatorTestBase {
    AutoCollect public autoCollect;

    function setUp() public override {
        super.setUp();

        autoCollect =
            new AutoCollect(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, protocolFeeRecipient);

        // Register vault
        autoCollect.setVault(address(vault));
        vault.setTransformer(address(autoCollect), true);
    }

    function _execute(AutoCollect.ExecuteParams memory params) internal {
        vm.prank(operator);
        autoCollect.execute(params);
        _assertNoAutomatorDust(address(autoCollect), "AutoCollect");
    }

    function _executeWithVault(AutoCollect.ExecuteParams memory params) internal {
        vm.prank(operator);
        autoCollect.executeWithVault(params, address(vault));
        _assertNoAutomatorDust(address(autoCollect), "AutoCollect");
    }

    function _collectConfig(
        uint64 maxRewardX64,
        uint16 token0SlippageBps,
        uint16 token1SlippageBps,
        uint128 minCollectAmount0,
        uint128 minCollectAmount1
    ) internal pure returns (AutoCollect.PositionConfig memory) {
        return AutoCollect.PositionConfig({
            maxRewardX64: maxRewardX64,
            token0SlippageBps: token0SlippageBps,
            token1SlippageBps: token1SlippageBps,
            minCollectAmount0: minCollectAmount0,
            minCollectAmount1: minCollectAmount1
        });
    }

    // --- Access Control Tests ---

    function test_RevertWhenNonOperatorCallsExecute() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert(Constants.Unauthorized.selector);
        autoCollect.execute(params);
    }

    function test_SetOperator() public {
        address newOperator = makeAddr("newOperator");
        autoCollect.setOperator(newOperator, true);
        assertTrue(autoCollect.operators(newOperator));
        autoCollect.setOperator(newOperator, false);
        assertFalse(autoCollect.operators(newOperator));
    }

    function test_SetProtocolFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        autoCollect.setProtocolFeeRecipient(newRecipient);

        assertEq(autoCollect.protocolFeeRecipient(), newRecipient, "protocol fee recipient should update");
    }

    function test_RevertWhenProtocolFeeRecipientIsZero() public {
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoCollect.setProtocolFeeRecipient(address(0));
    }

    function test_RevertWhenConstructorProtocolFeeRecipientIsZero() public {
        vm.expectRevert(Constants.InvalidConfig.selector);
        new AutoCollect(positionManager, address(swapRouter), EX0x, permit2, v4Oracle, operator, address(0));
    }

    function test_RevertWhenNonOwnerSetsProtocolFeeRecipient() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        autoCollect.setProtocolFeeRecipient(makeAddr("newRecipient"));
    }

    // --- AutoCollect Mode Tests ---

    function test_AutoCollect() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Approve NFT to autoCollect
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Execute auto-compound (no swap for simplicity)
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after auto-compound");
    }

    function test_AutoCollectRevertsWhenBelowMinAmounts() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(0, 10000, 10000, type(uint128).max, 0));

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.AmountError.selector);
        autoCollect.execute(params);
    }

    function test_AutoCollectWithVault() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve autoCollect to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoCollect), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Execute via vault
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _executeWithVault(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after vault auto-compound");

        // Verify position still owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    // --- Harvest Mode Tests ---

    function test_HarvestTokens() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        // Approve NFT
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 wethBefore = weth.balanceOf(WHALE_ACCOUNT);

        // Execute harvest
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        uint256 wethAfter = weth.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens
        assertTrue(usdcAfter > usdcBefore || wethAfter > wethBefore, "Owner should receive harvested tokens");

        // Liquidity should not change (harvest doesn't add liquidity)
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidity, 0, "Position should still have liquidity");
    }

    function test_HarvestTokensRevertsWhenBelowMinAmounts() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(0, 10000, 10000, type(uint128).max, 0));

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        vm.prank(operator);
        vm.expectRevert(Constants.AmountError.selector);
        autoCollect.execute(params);
    }

    function test_HarvestToken0() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKEN_0,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);
        assertGt(usdcAfter, usdcBefore, "Owner should receive token0 (USDC)");
    }

    function test_HarvestToken1() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 wethBefore = weth.balanceOf(WHALE_ACCOUNT);
        uint256 ethBefore = WHALE_ACCOUNT.balance;

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKEN_1,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        uint256 wethAfter = weth.balanceOf(WHALE_ACCOUNT);
        uint256 ethAfter = WHALE_ACCOUNT.balance;
        assertGt(wethAfter, wethBefore, "Owner should receive token1 as WETH");
        assertEq(ethAfter, ethBefore, "WETH positions should not unwrap to native ETH");
    }

    // --- Leftovers paid out immediately ---

    function test_AutoCollectDoesNotRetainPositionBalances() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 contractUsdcBefore = usdc.balanceOf(address(autoCollect));
        uint256 contractWethBefore = weth.balanceOf(address(autoCollect));
        uint256 contractEthBefore = address(autoCollect).balance;

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        // With zero protocol fee, the contract should not keep position leftovers.
        assertEq(usdc.balanceOf(address(autoCollect)), contractUsdcBefore);
        assertEq(weth.balanceOf(address(autoCollect)), contractWethBefore);
        assertEq(address(autoCollect).balance, contractEthBefore);
    }

    function test_AutoCollectSweepsDustedBalances() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 dustAmount = 12345;
        deal(address(usdc), address(autoCollect), dustAmount);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        assertEq(usdc.balanceOf(address(autoCollect)), 0, "dusted USDC should be swept out by the run");
        assertEq(weth.balanceOf(address(autoCollect)), 0, "no extra WETH should remain");
    }

    // --- Native ETH Position Tests ---

    function test_AutoCollectETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        // Generate fees with native ETH swaps
        _generateFeesEth(poolKey);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Approve NFT to autoCollect
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Execute auto-compound
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH auto-compound");
    }

    function test_AutoCollectETHWithVault() public {
        // Increase oracle tolerance for custom pool price
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        // Generate fees
        _generateFeesEth(poolKey);

        // Add position to vault
        _depositToVault(200000000, WHALE_ACCOUNT);
        _addPositionToVault(tokenId);

        // Approve autoCollect to transform
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(tokenId, address(autoCollect), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Execute via vault
        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _executeWithVault(params);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore, "Liquidity should increase after ETH vault auto-compound");

        // Verify position still owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
    }

    function test_AutoCollectDoesNotRetainPositionBalancesETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 contractUsdcBefore = usdc.balanceOf(address(autoCollect));
        uint256 contractEthBefore = address(autoCollect).balance;

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        // With zero protocol fee, the contract should not keep position leftovers.
        assertEq(usdc.balanceOf(address(autoCollect)), contractUsdcBefore);
        assertEq(address(autoCollect).balance, contractEthBefore);
    }

    // --- Withdraw protocol fees ---

    function test_ProtocolFeesAreSentToRecipientInETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        // Generate fees
        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Configure a 100% fee capture so all collected fees go to the recipient.
        uint64 maxReward = type(uint64).max;
        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(maxReward, 10000, 10000, 0, 0));

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: type(uint64).max
        });

        uint256 recipientEthBefore = protocolFeeRecipient.balance;
        _execute(params);

        assertEq(address(autoCollect).balance, 0, "contract should not retain ETH protocol fees");
        assertGt(protocolFeeRecipient.balance, recipientEthBefore, "recipient should receive ETH protocol fees");
    }

    function test_ProtocolFeesInETHSweepPreDustedNativeBalance() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint64 maxReward = type(uint64).max;
        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(maxReward, 10000, 10000, 0, 0));

        uint256 dustAmount = 0.25 ether;
        vm.deal(address(autoCollect), dustAmount);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: maxReward
        });

        uint256 recipientEthBefore = protocolFeeRecipient.balance;
        _execute(params);

        assertEq(address(autoCollect).balance, 0, "pre-dusted ETH should be swept out by the run");
        assertEq(usdc.balanceOf(address(autoCollect)), 0, "contract should not retain USDC after native fee send");
        assertGt(protocolFeeRecipient.balance, recipientEthBefore, "recipient should still receive native protocol fees");
    }

    function test_ProtocolFeesAreSentToRecipientInTokens() public {
        PoolKey memory poolKey = _createPool();
        uint256 tokenId = _createFullRangePosition(poolKey);

        // Generate fees
        _generateFees(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        // Configure a 100% fee capture so all collected fees go to the recipient.
        uint64 maxReward = type(uint64).max;
        vm.prank(WHALE_ACCOUNT);
        autoCollect.configToken(tokenId, _collectConfig(maxReward, 10000, 10000, 0, 0));

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.AUTO_COLLECT,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: type(uint64).max
        });

        _execute(params);

        assertEq(usdc.balanceOf(address(autoCollect)), 0, "contract should not retain USDC protocol fees");
        assertEq(weth.balanceOf(address(autoCollect)), 0, "contract should not retain WETH protocol fees");

        assertTrue(
            usdc.balanceOf(protocolFeeRecipient) > 0 || weth.balanceOf(protocolFeeRecipient) > 0,
            "recipient should receive protocol fees in the pool tokens"
        );
    }

    function test_HarvestTokensETH() public {
        PoolKey memory poolKey = _createEthPool();
        uint256 tokenId = _createFullRangePositionEth(poolKey);

        _generateFeesEth(poolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(autoCollect), tokenId);

        uint256 ethBefore = WHALE_ACCOUNT.balance;
        uint256 usdcBefore = usdc.balanceOf(WHALE_ACCOUNT);

        AutoCollect.ExecuteParams memory params = AutoCollect.ExecuteParams({
            tokenId: tokenId,
            mode: AutoCollect.CollectMode.HARVEST_TOKENS,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: bytes(""),
            deadline: block.timestamp,
            hookData: bytes(""),
            rewardX64: 0
        });

        _execute(params);

        uint256 ethAfter = WHALE_ACCOUNT.balance;
        uint256 usdcAfter = usdc.balanceOf(WHALE_ACCOUNT);

        // Owner should receive harvested tokens (ETH and/or USDC)
        assertTrue(ethAfter > ethBefore || usdcAfter > usdcBefore, "Owner should receive harvested ETH/USDC tokens");
    }
}
