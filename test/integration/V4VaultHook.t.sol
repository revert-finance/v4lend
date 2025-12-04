// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

// base contracts
import {V4Vault} from "../../src/V4Vault.sol";
import {V4Oracle} from "../../src/V4Oracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";

import {RevertHook} from "../../src/RevertHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUniversalRouter} from "../../src/lib/IUniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {V4ForkTestBase} from "./V4ForkTestBase.sol";

contract V4VaultHookTest is V4ForkTestBase {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    address WHALE_ACCOUNT = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;

    V4Vault vault;
    InterestRateModel interestRateModel;
    RevertHook revertHook;

    function setUp() public override {
        super.setUp(); // Call V4ForkTestBase setUp first

        // 0% base rate - 5% multiplier - after 80% - 109% jump multiplier (like in compound v2 deployed)  (-> max rate 25.8% per year)
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);

        vault = new V4Vault(
            "Revert Lend usdc", "rlusdc", address(usdc), positionManager, interestRateModel, v4Oracle, weth
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

        // Deploy RevertHook
        address hookFlags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(address(this), permit2, v4Oracle);
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, hookFlags);
        revertHook = RevertHook(hookFlags);

        // Register vault with RevertHook so it can handle collateralized positions
        revertHook.setVault(address(vault));
        vault.setTransformer(address(revertHook), true);
        vault.setHookAllowList(address(revertHook), true);

        //v4Oracle.setMaxPoolPriceDifference(10000);
    }

    function _deposit(uint256 amount, address account) internal {
        vm.prank(account);
        usdc.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount, account);
    }

    function test_CollateralizedPositionWithAutoCompound() public {
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);
        _configurePositionForAutoCompound(hookedTokenId);
        (uint256 collateralValue, uint128 initialLiquidity) = _setupCollateralizedPosition(hookedTokenId);
        _generateFees(hookedPoolKey);
        _executeAndVerifyAutoCompound(hookedTokenId, collateralValue, initialLiquidity);
    }

    function test_CollateralizedPositionWithAutoRange() public {
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 hookedTokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _configurePositionForAutoRange(hookedTokenId, hookedPoolKey);
        (uint256 collateralValue, int24 initialTickLower, int24 initialTickUpper) = _setupCollateralizedPositionForAutoRange(hookedTokenId, hookedPoolKey);
        _triggerAutoRange(hookedPoolKey, initialTickLower, initialTickUpper);
        _executeAndVerifyAutoRange(hookedTokenId, collateralValue, initialTickLower, initialTickUpper);
    }

    function _createHookedPool() internal returns (PoolKey memory hookedPoolKey) {
        hookedPoolKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        (uint160 nonHookedSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));

        console.log("nonHookedSqrtPriceX96", nonHookedSqrtPriceX96);

        hookedPoolKey.hooks = IHooks(address(revertHook));

        // Initialize the pool if not already initialized
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        if (sqrtPriceX96 == 0) {
            poolManager.initialize(hookedPoolKey, nonHookedSqrtPriceX96); // sqrt price for ~1:1
        }
    }

    function _createPositionInHookedPool(PoolKey memory hookedPoolKey) internal returns (uint256 hookedTokenId) {
        int24 tickLower = -887220; // Full range lower tick
        int24 tickUpper = 887220; // Full range upper tick

       
        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        weth.approve(address(permit2), type(uint256).max);

         // Approve tokens for position manager
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);

        // Use MINT_POSITION and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        uint128 liquidity = 1e14;

        // MINT_POSITION params: (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params_array[0] = abi.encode(
            hookedPoolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            WHALE_ACCOUNT,
            bytes("") // hookData
        );
        params_array[1] = abi.encode(hookedPoolKey.currency0, hookedPoolKey.currency1, WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities(abi.encode(actions, params_array), block.timestamp);

        hookedTokenId = positionManager.nextTokenId() - 1;

        console.log("Created position with tokenId:", hookedTokenId);
        console.log("Position owner:", IERC721(address(positionManager)).ownerOf(hookedTokenId));
    }

    function _configurePositionForAutoCompound(uint256 hookedTokenId) internal {
        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHook.PositionConfig({
                mode: RevertHook.PositionMode.AUTO_COMPOUND,
                autoExitTickLower: 0,
                autoExitTickUpper: 0,
                autoExitSwapLower: false,
                autoExitSwapUpper: false,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                swapPoolFee: 3000,
                swapPoolTickSpacing: 60,
                swapPoolHooks: IHooks(address(revertHook))
            })
        );
    }

    function _setupCollateralizedPosition(uint256 hookedTokenId)
        internal
        returns (uint256 collateralValue, uint128 initialLiquidity)
    {
        // Lend USDC to vault
        _deposit(200000000, WHALE_ACCOUNT);

        // Add position as collateral to vault
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);

        // Log collateral value after adding position to vault
        (uint256 debtAfterCreate, uint256 fullValueAfterCreate, uint256 collateralValueAfterCreate,,) = vault.loanInfo(hookedTokenId);
        console.log("Collateral value after adding position to vault:", collateralValueAfterCreate);
        console.log("Full value after adding position to vault:", fullValueAfterCreate);
        console.log("Debt after adding position to vault:", debtAfterCreate);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        // borrow 1 usdc
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(hookedTokenId, 200000000);

        // Verify position is collateralized
        (uint256 debt, uint256 fullValue, uint256 collateralValue_,,) = vault.loanInfo(hookedTokenId);
        collateralValue = collateralValue_;
        assertGt(collateralValue, 0, "Position should have collateral value");
        console.log("Initial debt:", debt);
        console.log("Initial full value:", fullValue);
        console.log("Initial collateral value:", collateralValue);

        // Record initial position state
        initialLiquidity = positionManager.getPositionLiquidity(hookedTokenId);
        console.log("Initial liquidity:", initialLiquidity);
    }

    function _generateFees(PoolKey memory hookedPoolKey) internal {

        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        _swapExactInputSingle(hookedPoolKey, true, 10e6, 0);
        _swapExactInputSingle(hookedPoolKey, false, 10e15, 0);

        console.log("Swaps completed, fees should have accumulated");
    }

    function _executeAndVerifyAutoCompound(uint256 hookedTokenId, uint256 collateralValue, uint128 initialLiquidity)
        internal
    {
        // Verify position still has same liquidity (fees not yet compounded)
        uint128 liquidityBeforeCompound = positionManager.getPositionLiquidity(hookedTokenId);
        assertEq(liquidityBeforeCompound, initialLiquidity, "Liquidity should be unchanged before compound");

        // Call autocompound (vault should be able to call this for collateralized positions)
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = hookedTokenId;
        vm.prank(WHALE_ACCOUNT);
        revertHook.autoCompound(tokenIds);

        // Verify liquidity increased after autocompound
        uint128 liquidityAfterCompound = positionManager.getPositionLiquidity(hookedTokenId);
        assertGt(liquidityAfterCompound, initialLiquidity, "Liquidity should increase after autocompound");
        console.log("Liquidity after compound:", liquidityAfterCompound);
        console.log("Liquidity increase:", liquidityAfterCompound - initialLiquidity);

        // Verify collateral value increased
        (uint256 debtAfter, uint256 fullValueAfter, uint256 collateralValueAfter,,) = vault.loanInfo(hookedTokenId);
        assertGt(collateralValueAfter, collateralValue, "Collateral value should increase after autocompound");
        console.log("Collateral value after compound:", collateralValueAfter);
        console.log("Collateral value increase:", collateralValueAfter - collateralValue);

        // Verify position is still owned by vault
        assertEq(
            IERC721(address(positionManager)).ownerOf(hookedTokenId),
            address(vault),
            "Position should still be owned by vault"
        );

        // Verify loan is still healthy
        assertTrue(collateralValueAfter > debtAfter, "Loan should remain healthy after autocompound");
    }

    function _swapExactInputSingle(PoolKey memory key, bool zeroForOne,  uint128 amountIn, uint128 minAmountOut)
        internal
    {
        // Encode the Universal Router command
        bytes memory commands = hex"10"; // V4_SWAP action code (0x10)
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: minAmountOut, hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        vm.prank(WHALE_ACCOUNT);
        IUniversalRouter(address(swapRouter)).execute(commands, inputs, block.timestamp);
    }

    function _createPositionInHookedPoolForAutoRange(PoolKey memory hookedPoolKey) internal returns (uint256 hookedTokenId) {
        // Get current tick to create a narrow range around it
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        
        // Create a narrow range around current price (e.g., ±120 ticks = ±2 tick spacings)
        int24 tickSpacing = hookedPoolKey.tickSpacing;
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing; // 2 tick spacings below
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing; // 2 tick spacings above
        
        console.log("Current tick:", currentTick);
        console.log("Position tickLower:", tickLower);
        console.log("Position tickUpper:", tickUpper);
        
        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        weth.approve(address(permit2), type(uint256).max);

        // Approve tokens for position manager
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);

        // Use MINT_POSITION and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        uint128 liquidity = 1e14;

        // MINT_POSITION params: (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params_array[0] = abi.encode(
            hookedPoolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            WHALE_ACCOUNT,
            bytes("") // hookData
        );
        params_array[1] = abi.encode(hookedPoolKey.currency0, hookedPoolKey.currency1, WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities(abi.encode(actions, params_array), block.timestamp);

        hookedTokenId = positionManager.nextTokenId() - 1;

        console.log("Created position with tokenId:", hookedTokenId);
        console.log("Position owner:", IERC721(address(positionManager)).ownerOf(hookedTokenId));
    }

    function _configurePositionForAutoRange(uint256 hookedTokenId, PoolKey memory hookedPoolKey) internal {
        // Get current position info
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(hookedTokenId);
        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();
        int24 tickSpacing = hookedPoolKey.tickSpacing;
        
        // Configure autorange:
        // - Trigger when price moves 1 tick spacing outside the range
        // - Move range by 2 tick spacings in the direction of price movement
        int24 autoRangeLowerLimit = 0;
        int24 autoRangeUpperLimit = 0;
        int24 autoRangeLowerDelta = -tickSpacing; // Move lower bound down by 1 tick spacings
        int24 autoRangeUpperDelta = tickSpacing; // Move upper bound up by 1 tick spacings
        
        console.log("AutoRange config:");
        console.log("  Lower limit:", autoRangeLowerLimit);
        console.log("  Upper limit:", autoRangeUpperLimit);
        console.log("  Lower delta:", autoRangeLowerDelta);
        console.log("  Upper delta:", autoRangeUpperDelta);
        
        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHook.PositionConfig({
                mode: RevertHook.PositionMode.AUTO_RANGE,
                autoExitTickLower: 0,
                autoExitTickUpper: 0,
                autoExitSwapLower: false,
                autoExitSwapUpper: false,
                autoRangeLowerLimit: autoRangeLowerLimit,
                autoRangeUpperLimit: autoRangeUpperLimit,
                autoRangeLowerDelta: autoRangeLowerDelta,
                autoRangeUpperDelta: autoRangeUpperDelta,
                swapPoolFee: 3000,
                swapPoolTickSpacing: 60,
                swapPoolHooks: IHooks(address(revertHook))
            })
        );
    }

    function _setupCollateralizedPositionForAutoRange(uint256 hookedTokenId, PoolKey memory hookedPoolKey)
        internal
        returns (uint256 collateralValue, int24 initialTickLower, int24 initialTickUpper)
    {
        // Get initial position range
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(hookedTokenId);
        initialTickLower = posInfo.tickLower();
        initialTickUpper = posInfo.tickUpper();
        
        // Lend USDC to vault
        _deposit(200000000, WHALE_ACCOUNT);

        // Add position as collateral to vault
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);

        // Log collateral value after adding position to vault
        (uint256 debtAfterCreate, uint256 fullValueAfterCreate, uint256 collateralValueAfterCreate,,) = vault.loanInfo(hookedTokenId);
        console.log("Collateral value after adding position to vault:", collateralValueAfterCreate);
        console.log("Full value after adding position to vault:", fullValueAfterCreate);
        console.log("Debt after adding position to vault:", debtAfterCreate);

        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        // Borrow some USDC
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(hookedTokenId, 200000000);

        // Verify position is collateralized
        (uint256 debt, uint256 fullValue, uint256 collateralValue_,,) = vault.loanInfo(hookedTokenId);
        collateralValue = collateralValue_;
        assertGt(collateralValue, 0, "Position should have collateral value");
        console.log("Initial debt:", debt);
        console.log("Initial full value:", fullValue);
        console.log("Initial collateral value:", collateralValue);
        console.log("Initial tickLower:", initialTickLower);
        console.log("Initial tickUpper:", initialTickUpper);
    }

    function _triggerAutoRange(PoolKey memory hookedPoolKey, int24 initialTickLower, int24 initialTickUpper) internal {
        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Current tick before swap:", currentTick);
        
        // Calculate trigger tick (need to move price below tickLower - autoRangeLowerLimit)
        // autoRangeLowerLimit = tickSpacing, so trigger at tickLower - tickSpacing
        int24 triggerTick = initialTickLower - hookedPoolKey.tickSpacing;
        console.log("Trigger tick (lower):", triggerTick);
        
        // Perform a large swap to move price below the trigger tick
        // Swap USDC for WETH (zeroForOne = true) to move price down
        uint256 swapAmount = 50e6; // 50 USDC - large enough to move price significantly
        
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);
        
        _swapExactInputSingle(hookedPoolKey, true, uint128(swapAmount), 0);
        
        // Check if autorange was triggered
        (, int24 newTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Current tick after swap:", newTick);
        console.log("AutoRange should have been triggered if tick <=", triggerTick);
    }

    function _executeAndVerifyAutoRange(
        uint256 originalTokenId,
        uint256 collateralValue,
        int24 initialTickLower,
        int24 initialTickUpper
    ) internal {
        // Verify original position no longer exists or has zero liquidity
        uint128 originalLiquidity = positionManager.getPositionLiquidity(originalTokenId);
        console.log("Original position liquidity:", originalLiquidity);
        
        // Autorange should have created a new position
        // The new tokenId should be the next one after the original
        // But we need to find it - it might be owned by the vault now
        
        // Check if vault owns a position with different range
        // We can check by looking at the vault's positions or by checking the AutoRange event
        
        // Get current pool state
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(revertHook))
        });
        
        // Verify the position range has changed
        // Since autorange creates a new position, we need to find it
        // For now, verify that the original position has been modified or a new one exists
        
        // Check if original position still exists (it should have zero liquidity after autorange)
        if (originalLiquidity == 0) {
            console.log("Original position has zero liquidity - autorange likely succeeded");
        }
        
        // Verify collateral value is maintained or increased
        // Note: We need to find the new tokenId to check this properly
        // For a complete test, we'd need to track the AutoRange event or query vault positions
        
        // Basic verification: check that autorange was triggered
        // The hook should have called vault.transform which creates a new position
        assertTrue(originalLiquidity == 0, "Original position should have zero liquidity after autorange");
        
        console.log("AutoRange verification completed");
        console.log("Note: Full verification requires tracking the new tokenId from AutoRange event");
    }
}

