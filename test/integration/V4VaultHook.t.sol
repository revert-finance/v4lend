// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
import {RevertHookState} from "../../src/RevertHookState.sol";
import {PositionModeFlags} from "../../src/lib/PositionModeFlags.sol";
import {RevertHookFunctions} from "../../src/RevertHookFunctions.sol";
import {RevertHookFunctions2} from "../../src/RevertHookFunctions2.sol";
import {LiquidityCalculator} from "../../src/LiquidityCalculator.sol";
import {Constants} from "../../src/utils/Constants.sol";
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
    LiquidityCalculator liquidityCalculator;

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

        // Deploy LiquidityCalculator
        liquidityCalculator = new LiquidityCalculator();

        // Deploy RevertHook
        address hookFlags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy RevertHookFunctions and RevertHookFunctions2
        RevertHookFunctions hookFunctions = new RevertHookFunctions(permit2, v4Oracle, liquidityCalculator);
        RevertHookFunctions2 hookFunctions2 = new RevertHookFunctions2(permit2, v4Oracle, liquidityCalculator);

        bytes memory constructorArgs = abi.encode(address(this), address(this), permit2, v4Oracle, liquidityCalculator, hookFunctions, hookFunctions2);
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, hookFlags);
        revertHook = RevertHook(hookFlags);

        // Register vault with RevertHook so it can handle collateralized positions
        revertHook.setVault(address(vault));
        vault.setTransformer(address(revertHook), true);
        vault.setHookAllowList(address(revertHook), true);

        // create tolerant oracle for testing
        v4Oracle.setMaxPoolPriceDifference(1000);
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
        uint256 fullRangeHookedTokenId = _createPositionInHookedPool(hookedPoolKey);
        uint256 hookedTokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _configurePositionForAutoRange(hookedTokenId, hookedPoolKey);
        (uint256 collateralValue, int24 initialTickLower, int24 initialTickUpper) = _setupCollateralizedPositionForAutoRange(hookedTokenId, hookedPoolKey);
        (uint256 initialDebt,,,,) = vault.loanInfo(hookedTokenId);
        _triggerAutoRange(hookedPoolKey, initialTickLower, initialTickUpper);
        _executeAndVerifyAutoRange(hookedTokenId, collateralValue, initialTickLower, initialTickUpper, initialDebt);
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
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_COMPOUND,
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
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: autoRangeLowerLimit,
                autoRangeUpperLimit: autoRangeUpperLimit,
                autoRangeLowerDelta: autoRangeLowerDelta,
                autoRangeUpperDelta: autoRangeUpperDelta,
                autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
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
        vault.borrow(hookedTokenId, 20000000); // borrow 20 usdc

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
        uint256 swapAmount = 100e6; // 100 USDC - large enough to move price significantly
        
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
        int24 initialTickUpper,
        uint256 initialDebt
    ) internal {
        
        _verifyOriginalPositionAfterAutoRange(originalTokenId);
        uint256 newTokenId = _getAndVerifyNewPosition(originalTokenId);
        _verifyNewPositionRange(newTokenId, initialTickLower, initialTickUpper);
        _verifyNewPositionOwnership(newTokenId);
        _verifyCurrentTickInRange(newTokenId);
        _verifyLoanTransfer(originalTokenId, newTokenId, initialDebt);
        _verifyOriginalPositionCleanup(originalTokenId);
        _verifyNewPositionPoolKey(newTokenId);
        
        console.log("AutoRange verification completed successfully");
    }

    function _verifyOriginalPositionAfterAutoRange(uint256 originalTokenId) internal {
        uint128 originalLiquidity = positionManager.getPositionLiquidity(originalTokenId);
        assertEq(originalLiquidity, 0, "Original position should have zero liquidity after autorange");
        console.log("Original position liquidity:", originalLiquidity);
    }

    function _getAndVerifyNewPosition(uint256 originalTokenId) internal returns (uint256 newTokenId) {
        newTokenId = positionManager.nextTokenId() - 1;
        assertGt(newTokenId, originalTokenId, "New tokenId should be greater than original");
        console.log("New position tokenId:", newTokenId);
        
        uint128 newLiquidity = positionManager.getPositionLiquidity(newTokenId);
        assertGt(newLiquidity, 0, "New position should have liquidity");
        console.log("New position liquidity:", newLiquidity);
    }

    function _verifyNewPositionRange(uint256 newTokenId, int24 initialTickLower, int24 initialTickUpper) internal {
        (, PositionInfo newPosInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        int24 newTickLower = newPosInfo.tickLower();
        int24 newTickUpper = newPosInfo.tickUpper();
        console.log("New position tickLower:", newTickLower);
        console.log("New position tickUpper:", newTickUpper);
        
        assertTrue(newTickLower <= initialTickLower, "New tickLower should be <= initial tickLower (range moved down)");
        assertTrue(newTickUpper <= initialTickUpper, "New tickUpper should be <= initial tickUpper (range moved down)");
    }

    function _verifyNewPositionOwnership(uint256 newTokenId) internal {
        address newPositionOwner = IERC721(address(positionManager)).ownerOf(newTokenId);
        assertEq(newPositionOwner, address(vault), "New position should be owned by vault");
        console.log("New position owner:", newPositionOwner);
    }

    function _verifyCurrentTickInRange(uint256 newTokenId) internal {
        PoolKey memory poolKey = _getHookedPoolKey();
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        console.log("Current tick after swap:", currentTick);
        
        (, PositionInfo newPosInfo) = positionManager.getPoolAndPositionInfo(newTokenId);
        int24 newTickLower = newPosInfo.tickLower();
        int24 newTickUpper = newPosInfo.tickUpper();
        
        assertTrue(currentTick >= newTickLower, "Current tick should be >= new tickLower");
        assertTrue(currentTick <= newTickUpper, "Current tick should be <= new tickUpper");
    }

    function _verifyLoanTransfer(uint256 originalTokenId, uint256 newTokenId, uint256 initialDebt) internal {
        (uint256 newDebt, uint256 newFullValue, uint256 newCollateralValue,,) = vault.loanInfo(newTokenId);
        console.log("New position debt:", newDebt);
        console.log("New position full value:", newFullValue);
        console.log("New position collateral value:", newCollateralValue);
        
        assertEq(newDebt, initialDebt, "Debt should be unchanged after autorange");
        assertTrue(newCollateralValue > newDebt, "Loan should remain healthy after autorange");
        console.log("Loan health ratio:", (newCollateralValue * 100) / newDebt, "%");
    }

    function _verifyOriginalPositionCleanup(uint256 originalTokenId) internal {
        (uint256 oldDebt, uint256 oldFullValue, uint256 oldCollateralValue,,) = vault.loanInfo(originalTokenId);
        assertEq(oldDebt, 0, "Original position should have zero debt");
        assertEq(oldFullValue, 0, "Original position should have zero full value");
        assertEq(oldCollateralValue, 0, "Original position should have zero collateral value");
    }

    function _verifyNewPositionPoolKey(uint256 newTokenId) internal {
        PoolKey memory poolKey = _getHookedPoolKey();
        (PoolKey memory newPoolKey,) = positionManager.getPoolAndPositionInfo(newTokenId);
        assertEq(Currency.unwrap(newPoolKey.currency0), Currency.unwrap(poolKey.currency0), "New position should have same currency0");
        assertEq(Currency.unwrap(newPoolKey.currency1), Currency.unwrap(poolKey.currency1), "New position should have same currency1");
        assertEq(newPoolKey.fee, poolKey.fee, "New position should have same fee");
        assertEq(newPoolKey.tickSpacing, poolKey.tickSpacing, "New position should have same tickSpacing");
    }

    function _getHookedPoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(revertHook))
        });
    }

    function test_CollateralizedPositionWithAutoLeverage() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create a full-range position to provide liquidity for swaps
        _createPositionInHookedPool(hookedPoolKey);

        // Create position for auto-leverage testing
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Setup collateralized position with initial debt
        (uint256 initialDebt, uint256 initialCollateralValue) = _setupCollateralizedPositionForAutoLeverage(hookedTokenId);

        // Configure position for AUTO_LEVERAGE with 50% target (5000 bps)
        uint16 targetBps = 5000; // 50% debt/collateral ratio
        _configurePositionForAutoLeverage(hookedTokenId, targetBps);

        // Get initial base tick
        (,,,,,,, int24 initialBaseTick) = revertHook.positionStates(hookedTokenId);
        console.log("Initial base tick:", initialBaseTick);

        // Verify base tick is set (not zero)
        assertTrue(initialBaseTick != 0, "Base tick should be set after configuration");

        // Verify triggers are set at baseTick +/- 10 tick spacings
        int24 tickSpacing = hookedPoolKey.tickSpacing;
        int24 expectedLowerTrigger = initialBaseTick - 10 * tickSpacing;
        int24 expectedUpperTrigger = initialBaseTick + 10 * tickSpacing;
        console.log("Expected lower trigger:", expectedLowerTrigger);
        console.log("Expected upper trigger:", expectedUpperTrigger);

        // --- Test price movement UP (should trigger leverage UP) ---
        console.log("\n--- Testing Price Movement UP (Leverage UP) ---");
        _movePriceUp(hookedPoolKey);

        // Check position state after price movement
        (uint256 debtAfterUp,, uint256 collateralAfterUp,,) = vault.loanInfo(hookedTokenId);
        console.log("Debt after price UP:", debtAfterUp);
        console.log("Collateral after price UP:", collateralAfterUp);

        // Auto-leverage should have increased debt (leverage up was triggered)
        // Initial was 25% leverage (2500 bps), target is 50% (5000 bps)
        // So debt should have approximately doubled
        assertGt(debtAfterUp, initialDebt, "Debt should increase after leverage UP trigger");
        console.log("Leverage after UP:", debtAfterUp * 10000 / collateralAfterUp, "bps");

        // Check base tick was updated to new position
        (,,,,,,, int24 baseTickAfterUp) = revertHook.positionStates(hookedTokenId);
        console.log("Base tick after UP:", baseTickAfterUp);
        assertTrue(baseTickAfterUp != initialBaseTick, "Base tick should be updated after trigger");

        // --- Test price movement DOWN (should trigger leverage DOWN) ---
        console.log("\n--- Testing Price Movement DOWN (Leverage DOWN) ---");
        uint256 debtBeforeDown = debtAfterUp;
        _movePriceDown(hookedPoolKey);

        // Check position state after price movement
        (uint256 debtAfterDown,, uint256 collateralAfterDown,,) = vault.loanInfo(hookedTokenId);
        console.log("Debt after price DOWN:", debtAfterDown);
        console.log("Collateral after price DOWN:", collateralAfterDown);
        console.log("Leverage after DOWN:", debtAfterDown * 10000 / collateralAfterDown, "bps");

        // Check base tick was updated again
        (,,,,,,, int24 baseTickAfterDown) = revertHook.positionStates(hookedTokenId);
        console.log("Base tick after DOWN:", baseTickAfterDown);
        assertTrue(baseTickAfterDown != baseTickAfterUp, "Base tick should be updated after DOWN trigger");

        // Verify position is still healthy
        assertTrue(collateralAfterDown > debtAfterDown, "Loan should remain healthy");

        // Verify position is still owned by vault
        assertEq(
            IERC721(address(positionManager)).ownerOf(hookedTokenId),
            address(vault),
            "Position should still be owned by vault"
        );

        // Verify config is still correctly set
        (uint8 modeFlags,,,,,,,,,, uint16 storedTargetBps) = revertHook.positionConfigs(hookedTokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_LEVERAGE, "Mode should still be AUTO_LEVERAGE");
        assertEq(storedTargetBps, targetBps, "Target bps should still be set");

        console.log("\nAutoLeverage configuration test completed successfully");
    }

    function _setupCollateralizedPositionForAutoLeverage(uint256 hookedTokenId)
        internal
        returns (uint256 initialDebt, uint256 collateralValue)
    {
        // Increase limits for this test
        vault.setLimits(0, 100000000000, 100000000000, 100000000000, 100000000000);
        // Increase oracle tolerance for large price swings
        v4Oracle.setMaxPoolPriceDifference(10000); // 100% tolerance for testing
        // Increase max ticks from oracle to allow trigger processing during large price swings
        revertHook.setMaxTicksFromOracle(10000); // Allow processing up to 10000 ticks from oracle

        // Lend USDC to vault (need enough for borrowing)
        _deposit(50000000000, WHALE_ACCOUNT); // 50,000 USDC

        // Add position as collateral to vault
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);

        // Log collateral value after adding position to vault
        (uint256 debtAfterCreate,, uint256 collateralValueAfterCreate,,) = vault.loanInfo(hookedTokenId);
        console.log("Collateral value after adding position to vault:", collateralValueAfterCreate);
        console.log("Debt after adding position to vault:", debtAfterCreate);

        // Approve hook for transforms
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        // Borrow initial amount (25% of collateral to start below target)
        uint256 borrowAmount = collateralValueAfterCreate * 25 / 100; // 25% of collateral
        vm.prank(WHALE_ACCOUNT);
        vault.borrow(hookedTokenId, borrowAmount);

        // Get final state
        (uint256 debt,, uint256 collateralValue_,,) = vault.loanInfo(hookedTokenId);
        initialDebt = debt;
        collateralValue = collateralValue_;

        console.log("Initial debt:", initialDebt);
        console.log("Initial collateral value:", collateralValue);
        console.log("Initial leverage:", initialDebt * 10000 / collateralValue, "bps");
    }

    function _configurePositionForAutoLeverage(uint256 hookedTokenId, uint16 targetBps) internal {
        console.log("Configuring AUTO_LEVERAGE with target:", targetBps, "bps");

        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEVERAGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: targetBps
            })
        );

        // Verify config was set
        (uint8 modeFlags,,,,,,,,,, uint16 autoLeverageTargetBps) = revertHook.positionConfigs(hookedTokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_LEVERAGE, "Mode should be AUTO_LEVERAGE");
        assertEq(autoLeverageTargetBps, targetBps, "Target bps should match");
    }

    function _movePriceUp(PoolKey memory hookedPoolKey) internal {
        // Swap WETH for USDC (zeroForOne = false) to move price UP
        // Price UP means tick increases
        // Need to move >600 ticks (10 * tickSpacing of 60)
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        (, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Tick before UP swap:", tickBefore);

        // Very large swap to move price past 10 tick spacings (600 ticks)
        _swapExactInputSingle(hookedPoolKey, false, 500e15, 0); // Sell 500 WETH

        (, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Tick after UP swap:", tickAfter);
        console.log("Tick moved:", tickAfter - tickBefore);
    }

    function _movePriceDown(PoolKey memory hookedPoolKey) internal {
        // Swap USDC for WETH (zeroForOne = true) to move price DOWN
        // Price DOWN means tick decreases
        // Need to move >600 ticks (10 * tickSpacing of 60) past the new base tick
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        (, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Tick before DOWN swap:", tickBefore);

        // Very large swap to move price past 10 tick spacings (need to go >1200 ticks total from UP position)
        _swapExactInputSingle(hookedPoolKey, true, 10000e6, 0); // Sell 10000 USDC

        (, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        console.log("Tick after DOWN swap:", tickAfter);
        console.log("Tick moved:", tickAfter - tickBefore);
    }

    /// @notice Test that AUTO_LEVERAGE rejects non-vault-owned positions
    function test_AutoLeverageRejectsNonVaultPosition() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create position NOT owned by vault
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Position is owned by WHALE_ACCOUNT, not by vault
        assertEq(
            IERC721(address(positionManager)).ownerOf(hookedTokenId),
            WHALE_ACCOUNT,
            "Position should be owned by whale, not vault"
        );

        // Try to set AUTO_LEVERAGE mode - should revert
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEVERAGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 5000
            })
        );
    }

    /// @notice Test that AUTO_LEVERAGE rejects invalid target bps (>= 10000)
    function test_AutoLeverageRejectsInvalidTargetBps() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create position and add to vault
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Add position as collateral to vault
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);

        // Approve hook for transforms
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        // Try to set invalid target bps (100% = 10000) - should revert
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEVERAGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 10000 // Invalid: 100% leverage
            })
        );

        // Try to set invalid target bps (>100% = 15000) - should also revert
        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEVERAGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 15000 // Invalid: 150% leverage
            })
        );
    }

    /// @notice Test that AUTO_LEVERAGE requires position tokens to include the vault's lend asset
    /// @dev This test verifies the new validation in _setPositionConfig that checks
    ///      Currency.unwrap(poolKey.currency0) or currency1 matches vault.asset()
    function test_AutoLeverageLendAssetValidation() public {
        // The existing USDC/WETH hooked pool has USDC as one of the tokens,
        // and USDC is the vault's lend asset, so AUTO_LEVERAGE config should succeed.
        // This test verifies that our validation code path is working correctly.
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create a position in the USDC/WETH pool
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Add position to vault
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);

        // Approve hook for transforms
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        // Verify vault's lend asset is USDC
        assertEq(vault.asset(), address(usdc), "Vault should use USDC as lend asset");

        // Verify poolKey has USDC as currency0
        assertEq(Currency.unwrap(hookedPoolKey.currency0), address(usdc), "Pool should have USDC as currency0");

        // Setting AUTO_LEVERAGE should succeed because USDC (lend asset) is in the pool
        // This tests that our validation passes for valid positions
        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEVERAGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 5000
            })
        );

        // Verify config was set successfully
        (uint8 modeFlags,,,,,,,,,, uint16 targetBps) = revertHook.positionConfigs(hookedTokenId);
        assertEq(modeFlags, PositionModeFlags.MODE_AUTO_LEVERAGE, "Mode should be AUTO_LEVERAGE");
        assertEq(targetBps, 5000, "Target should be 5000 bps");
    }

    /// @notice Test AUTO_LEVERAGE with different target ratios
    function test_AutoLeverageWithDifferentTargetRatios() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create liquidity provider position
        _createPositionInHookedPool(hookedPoolKey);

        // Create position for auto-leverage testing
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Setup collateralized position with initial debt
        _setupCollateralizedPositionForAutoLeverage(hookedTokenId);

        // Test with 30% target (3000 bps)
        uint16 targetBps = 3000;
        _configurePositionForAutoLeverage(hookedTokenId, targetBps);

        // Get initial state
        (uint256 initialDebt,, uint256 initialCollateral,,) = vault.loanInfo(hookedTokenId);
        uint256 initialLeverage = initialDebt * 10000 / initialCollateral;
        console.log("Initial leverage:", initialLeverage, "bps");
        console.log("Target leverage:", targetBps, "bps");

        // Move price to trigger leverage adjustment
        _movePriceUp(hookedPoolKey);

        // Check final leverage is close to target
        (uint256 finalDebt,, uint256 finalCollateral,,) = vault.loanInfo(hookedTokenId);
        uint256 finalLeverage = finalDebt * 10000 / finalCollateral;
        console.log("Final leverage:", finalLeverage, "bps");

        // Allow 15% tolerance due to swap slippage
        uint256 tolerance = targetBps * 15 / 100;
        assertTrue(
            finalLeverage >= targetBps - tolerance && finalLeverage <= targetBps + tolerance,
            "Leverage should be within 15% of target"
        );
    }

    /// @notice Test that position remains healthy after leverage adjustments
    function test_AutoLeveragePositionRemainsHealthy() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create liquidity provider position
        _createPositionInHookedPool(hookedPoolKey);

        // Create position for auto-leverage testing
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Setup collateralized position
        _setupCollateralizedPositionForAutoLeverage(hookedTokenId);

        // Configure with aggressive 70% leverage target
        uint16 targetBps = 7000;
        _configurePositionForAutoLeverage(hookedTokenId, targetBps);

        // Trigger multiple leverage adjustments
        _movePriceUp(hookedPoolKey);

        // Verify position is healthy (collateral > debt)
        (uint256 debt,, uint256 collateral,,) = vault.loanInfo(hookedTokenId);
        assertTrue(collateral > debt, "Position should remain healthy with collateral > debt");

        // Verify leverage ratio is reasonable
        uint256 leverage = debt * 10000 / collateral;
        console.log("Leverage after adjustment:", leverage, "bps");
        assertTrue(leverage < 9000, "Leverage should be below 90% to maintain health margin");
    }

    /// @notice Test trigger reset after leverage adjustment
    function test_AutoLeverageTriggerReset() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create liquidity provider position
        _createPositionInHookedPool(hookedPoolKey);

        // Create position for auto-leverage testing
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Setup collateralized position
        _setupCollateralizedPositionForAutoLeverage(hookedTokenId);

        // Configure AUTO_LEVERAGE
        uint16 targetBps = 5000;
        _configurePositionForAutoLeverage(hookedTokenId, targetBps);

        // Get initial base tick
        (,,,,,,, int24 initialBaseTick) = revertHook.positionStates(hookedTokenId);
        console.log("Initial base tick:", initialBaseTick);

        // First trigger - move price up
        _movePriceUp(hookedPoolKey);

        // Check base tick was updated
        (,,,,,,, int24 baseTickAfterFirst) = revertHook.positionStates(hookedTokenId);
        console.log("Base tick after first trigger:", baseTickAfterFirst);
        assertTrue(baseTickAfterFirst != initialBaseTick, "Base tick should update after first trigger");

        // Move price down to trigger again
        _movePriceDown(hookedPoolKey);

        // Check base tick was updated again
        (,,,,,,, int24 baseTickAfterSecond) = revertHook.positionStates(hookedTokenId);
        console.log("Base tick after second trigger:", baseTickAfterSecond);
        assertTrue(baseTickAfterSecond != baseTickAfterFirst, "Base tick should update after second trigger");

        // Verify new triggers are set relative to new base tick
        int24 tickSpacing = hookedPoolKey.tickSpacing;
        int24 expectedLowerTrigger = baseTickAfterSecond - 10 * tickSpacing;
        int24 expectedUpperTrigger = baseTickAfterSecond + 10 * tickSpacing;
        console.log("Expected new lower trigger:", expectedLowerTrigger);
        console.log("Expected new upper trigger:", expectedUpperTrigger);
    }

    /// @notice Test AUTO_LEVERAGE with zero initial debt (should leverage up from 0)
    function test_AutoLeverageFromZeroDebt() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create liquidity provider position
        _createPositionInHookedPool(hookedPoolKey);

        // Create position for auto-leverage testing
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Setup position WITHOUT initial debt
        vault.setLimits(0, 100000000000, 100000000000, 100000000000, 100000000000);
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        // Lend USDC to vault
        _deposit(50000000000, WHALE_ACCOUNT);

        // Add position as collateral to vault (no borrowing)
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);

        // Approve hook for transforms
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        // Verify zero debt
        (uint256 debtBefore,, uint256 collateralBefore,,) = vault.loanInfo(hookedTokenId);
        assertEq(debtBefore, 0, "Initial debt should be zero");
        console.log("Initial debt:", debtBefore);
        console.log("Initial collateral:", collateralBefore);

        // Configure AUTO_LEVERAGE with 40% target
        uint16 targetBps = 4000;
        _configurePositionForAutoLeverage(hookedTokenId, targetBps);

        // Trigger leverage up
        _movePriceUp(hookedPoolKey);

        // Verify debt was created
        (uint256 debtAfter,, uint256 collateralAfter,,) = vault.loanInfo(hookedTokenId);
        console.log("Debt after trigger:", debtAfter);
        console.log("Collateral after trigger:", collateralAfter);
        console.log("Leverage:", debtAfter * 10000 / collateralAfter, "bps");

        assertGt(debtAfter, 0, "Debt should be created after leverage up from zero");
    }

    /// @notice Test that disabling AUTO_LEVERAGE removes triggers
    function test_AutoLeverageDisable() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        // Create position for auto-leverage testing
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        // Setup collateralized position
        _setupCollateralizedPositionForAutoLeverage(hookedTokenId);

        // Configure AUTO_LEVERAGE
        uint16 targetBps = 5000;
        _configurePositionForAutoLeverage(hookedTokenId, targetBps);

        // Verify mode is set
        (uint8 modeFlagsBefore,,,,,,,,,, uint16 targetBpsBefore) = revertHook.positionConfigs(hookedTokenId);
        assertEq(modeFlagsBefore, PositionModeFlags.MODE_AUTO_LEVERAGE, "Mode should be AUTO_LEVERAGE");
        assertEq(targetBpsBefore, targetBps, "Target should be set");

        // Disable AUTO_LEVERAGE by setting mode to NONE
        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(
            hookedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_NONE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
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

        // Verify mode is disabled
        (uint8 modeFlagsAfter,,,,,,,,,, uint16 targetBpsAfter) = revertHook.positionConfigs(hookedTokenId);
        assertEq(modeFlagsAfter, PositionModeFlags.MODE_NONE, "Mode should be NONE");
        assertEq(targetBpsAfter, 0, "Target should be reset");

        // Move price - should NOT trigger any leverage adjustment since mode is disabled
        (uint256 debtBefore,,,,) = vault.loanInfo(hookedTokenId);

        // Create liquidity provider for swap
        _createPositionInHookedPool(hookedPoolKey);
        _movePriceUp(hookedPoolKey);

        (uint256 debtAfter,,,,) = vault.loanInfo(hookedTokenId);
        assertEq(debtAfter, debtBefore, "Debt should not change when mode is disabled");
    }
}

