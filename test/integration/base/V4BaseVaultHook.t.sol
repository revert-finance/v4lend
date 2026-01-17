// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {RevertHookState} from "../../../src/RevertHookState.sol";
import {V4BaseForkTestBase} from "./V4BaseForkTestBase.sol";

/**
 * @title V4BaseVaultHook
 * @notice Integration tests for RevertHook on Base network
 * @dev Tests auto-compound and auto-range functionality with vault integration
 */
contract V4BaseVaultHook is V4BaseForkTestBase {
    /**
     * @notice Test auto-compound functionality for a collateralized position
     * @dev Creates a position, configures auto-compound, generates fees, and verifies compounding
     */
    function test_AutoCompound() public {
        console.log("\n=== Test: Auto-Compound on Base ===");

        // Step 1: Create hooked pool
        PoolKey memory hookedPoolKey = _createHookedPool();
        console.log("Created hooked pool");

        // Step 2: Create position in hooked pool
        uint256 tokenId = _createPositionInHookedPool(hookedPoolKey);
        console.log("Created position:", tokenId);

        // Step 3: Configure for auto-compound
        _configurePositionForAutoCompound(tokenId);
        console.log("Configured for auto-compound");

        // Step 4: Setup collateralized position
        (uint256 collateralValue, uint128 initialLiquidity) = _setupCollateralizedPosition(tokenId);
        console.log("Initial collateral value:", collateralValue);
        console.log("Initial liquidity:", initialLiquidity);

        // Step 5: Generate fees via swaps
        _generateFees(hookedPoolKey);
        console.log("Generated fees via swaps");

        // Step 6: Execute auto-compound and verify
        _executeAndVerifyAutoCompound(tokenId, collateralValue, initialLiquidity);

        console.log("=== Auto-Compound Test Passed ===\n");
    }

    /**
     * @notice Test auto-range functionality for a collateralized position
     * @dev Creates a narrow-range position, moves price out of range, verifies auto-rebalancing
     */
    function test_AutoRange() public {
        console.log("\n=== Test: Auto-Range on Base ===");

        // Step 1: Create hooked pool
        PoolKey memory hookedPoolKey = _createHookedPool();
        console.log("Created hooked pool");

        // Step 2: Create full-range position for liquidity
        _createPositionInHookedPool(hookedPoolKey);
        console.log("Created full-range liquidity position");

        // Step 3: Create narrow-range position for auto-range testing
        uint256 tokenId = _createNarrowRangePosition(hookedPoolKey);
        console.log("Created narrow-range position:", tokenId);

        // Step 4: Configure for auto-range
        _configurePositionForAutoRange(tokenId, hookedPoolKey);
        console.log("Configured for auto-range");

        // Step 5: Setup collateralized position
        (uint256 collateralValue, int24 initialTickLower, int24 initialTickUpper) =
            _setupCollateralizedPositionForAutoRange(tokenId);
        console.log("Initial collateral value:", collateralValue);
        console.log("Initial tick lower:", initialTickLower);
        console.log("Initial tick upper:", initialTickUpper);

        // Step 6: Trigger auto-range by moving price
        _triggerAutoRange(hookedPoolKey, initialTickLower);
        console.log("Triggered auto-range via price movement");

        // Step 7: Verify auto-range execution
        _verifyAutoRangeExecution(tokenId, initialTickLower, initialTickUpper);

        console.log("=== Auto-Range Test Passed ===\n");
    }

    // ==================== Internal Helper Functions ====================

    function _configurePositionForAutoCompound(uint256 tokenId) internal {
        vm.prank(whaleAccount);
        revertHook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                mode: RevertHookState.PositionMode.AUTO_COMPOUND_ONLY,
                autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
    }

    function _setupCollateralizedPosition(uint256 tokenId)
        internal
        returns (uint256 collateralValue, uint128 initialLiquidity)
    {
        // Deposit USDC to vault as lender
        _deposit(500_000_000, whaleAccount); // 500 USDC

        // Add position as collateral
        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        // Approve hook for transforms
        vm.prank(whaleAccount);
        vault.approveTransform(tokenId, address(revertHook), true);

        // Borrow against collateral
        vm.prank(whaleAccount);
        vault.borrow(tokenId, 100_000_000); // Borrow 100 USDC

        // Get initial state
        (,, uint256 collateralValue_,,) = vault.loanInfo(tokenId);
        collateralValue = collateralValue_;
        initialLiquidity = positionManager.getPositionLiquidity(tokenId);
    }

    function _generateFees(PoolKey memory hookedPoolKey) internal {
        // Approve for swaps
        vm.prank(whaleAccount);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(whaleAccount);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        // Execute swaps to generate fees
        _swapExactInputSingle(hookedPoolKey, true, 100e6, 0); // Swap 100 USDC -> WETH
        _swapExactInputSingle(hookedPoolKey, false, 1e17, 0); // Swap 0.1 WETH -> USDC
    }

    function _executeAndVerifyAutoCompound(uint256 tokenId, uint256 initialCollateralValue, uint128 initialLiquidity)
        internal
    {
        // Verify liquidity unchanged before compound
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        assertEq(liquidityBefore, initialLiquidity, "Liquidity should be unchanged before compound");

        // Execute auto-compound
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(whaleAccount);
        revertHook.autoCompound(tokenIds);

        // Verify liquidity increased
        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, initialLiquidity, "Liquidity should increase after auto-compound");
        console.log("Liquidity increased from", initialLiquidity, "to", liquidityAfter);

        // Verify collateral value increased
        (,, uint256 collateralValueAfter,,) = vault.loanInfo(tokenId);
        assertGt(collateralValueAfter, initialCollateralValue, "Collateral value should increase");
        console.log("Collateral value increased from", initialCollateralValue, "to", collateralValueAfter);

        // Verify position still owned by vault
        assertEq(
            IERC721(address(positionManager)).ownerOf(tokenId), address(vault), "Position should still be in vault"
        );
    }

    function _createNarrowRangePosition(PoolKey memory hookedPoolKey) internal returns (uint256 tokenId) {
        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));

        // Create narrow range around current price
        int24 tickSpacing = hookedPoolKey.tickSpacing;
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing;

        // Approve and mint
        vm.startPrank(whaleAccount);
        usdc.approve(address(permit2), type(uint256).max);
        weth.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(0x00), uint8(0x0f)); // MINT_POSITION, SETTLE_PAIR
        bytes[] memory params = new bytes[](2);

        uint128 liquidity = 1e14;
        params[0] = abi.encode(
            hookedPoolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, whaleAccount, bytes("")
        );
        params[1] = abi.encode(hookedPoolKey.currency0, hookedPoolKey.currency1, whaleAccount);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();

        tokenId = positionManager.nextTokenId() - 1;
        console.log("Narrow-range tick lower:", tickLower);
        console.log("Narrow-range tick upper:", tickUpper);
    }

    function _configurePositionForAutoRange(uint256 tokenId, PoolKey memory hookedPoolKey) internal {
        int24 tickSpacing = hookedPoolKey.tickSpacing;

        vm.prank(whaleAccount);
        revertHook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                mode: RevertHookState.PositionMode.AUTO_RANGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -tickSpacing,
                autoRangeUpperDelta: tickSpacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
    }

    function _setupCollateralizedPositionForAutoRange(uint256 tokenId)
        internal
        returns (uint256 collateralValue, int24 initialTickLower, int24 initialTickUpper)
    {
        // Get initial position range
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        initialTickLower = posInfo.tickLower();
        initialTickUpper = posInfo.tickUpper();

        // Deposit to vault
        _deposit(500_000_000, whaleAccount);

        // Add as collateral
        vm.prank(whaleAccount);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(whaleAccount);
        vault.create(tokenId, whaleAccount);

        // Approve hook
        vm.prank(whaleAccount);
        vault.approveTransform(tokenId, address(revertHook), true);

        // Borrow
        vm.prank(whaleAccount);
        vault.borrow(tokenId, 50_000_000); // 50 USDC

        (,, collateralValue,,) = vault.loanInfo(tokenId);
    }

    function _triggerAutoRange(PoolKey memory hookedPoolKey, int24 initialTickLower) internal {
        // Approve for swaps
        vm.prank(whaleAccount);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(whaleAccount);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        (, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Tick before swap:", tickBefore);

        // Large swap to move price significantly
        _swapExactInputSingle(hookedPoolKey, true, 500e6, 0); // Swap 500 USDC -> WETH

        (, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Tick after swap:", tickAfter);
        console.log("Tick moved:", tickBefore - tickAfter);
    }

    function _verifyAutoRangeExecution(uint256 originalTokenId, int24 initialTickLower, int24 initialTickUpper)
        internal
    {
        // Original position should have zero liquidity
        uint128 originalLiquidity = positionManager.getPositionLiquidity(originalTokenId);
        assertEq(originalLiquidity, 0, "Original position should have zero liquidity");

        // New position should exist
        uint256 newTokenId = positionManager.nextTokenId() - 1;
        assertGt(newTokenId, originalTokenId, "New position should be created");

        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        assertGt(newLiquidity, 0, "New position should have liquidity");
        console.log("New position tokenId:", newTokenId);
        console.log("New position liquidity:", newLiquidity);

        // New position should have different range
        (, PositionInfo newPosInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        int24 newTickLower = newPosInfo.tickLower();
        int24 newTickUpper = newPosInfo.tickUpper();
        console.log("New tick lower:", newTickLower);
        console.log("New tick upper:", newTickUpper);

        assertTrue(newTickLower <= initialTickLower, "New tickLower should be <= initial");
        assertTrue(newTickUpper <= initialTickUpper, "New tickUpper should be <= initial");

        // New position should be owned by vault
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(vault), "New position should be in vault");

        // Loan should be transferred
        (uint256 newDebt,, uint256 newCollateral,,) = vault.loanInfo(newTokenId);
        assertGt(newDebt, 0, "Debt should be transferred to new position");
        assertGt(newCollateral, 0, "Collateral should exist on new position");
        console.log("New position debt:", newDebt);
        console.log("New position collateral:", newCollateral);
    }
}
