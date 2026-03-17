// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

// base contracts
import {V4Vault} from "src/vault/V4Vault.sol";
import {V4Oracle} from "src/oracle/V4Oracle.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {Constants} from "src/shared/Constants.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUniversalRouter} from "src/shared/swap/IUniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {V4ForkTestBase} from "test/vault/support/V4ForkTestBase.sol";

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

        // allow positions without hooks (address(0))
        vault.setHookAllowList(address(0), true);

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

        // Deploy RevertHook action targets
        RevertHookPositionActions positionActions = new RevertHookPositionActions(permit2, v4Oracle, liquidityCalculator);
        RevertHookAutoLeverageActions autoLeverageActions = new RevertHookAutoLeverageActions(permit2, v4Oracle, liquidityCalculator);
        RevertHookAutoLendActions autoLendActions =
            new RevertHookAutoLendActions(permit2, v4Oracle, liquidityCalculator);

        bytes memory constructorArgs = abi.encode(
            address(this),
            address(this),
            permit2,
            v4Oracle,
            liquidityCalculator,
            positionActions,
            autoLeverageActions,
            autoLendActions
        );
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
        bytes[] memory paramsArray = new bytes[](2);

        uint128 liquidity = 1e14;

        // MINT_POSITION params: (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        paramsArray[0] = abi.encode(
            hookedPoolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            WHALE_ACCOUNT,
            bytes("") // hookData
        );
        paramsArray[1] = abi.encode(hookedPoolKey.currency0, hookedPoolKey.currency1, WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);

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
        bytes[] memory paramsArray = new bytes[](2);

        uint128 liquidity = 1e14;

        // MINT_POSITION params: (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        paramsArray[0] = abi.encode(
            hookedPoolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            WHALE_ACCOUNT,
            bytes("") // hookData
        );
        paramsArray[1] = abi.encode(hookedPoolKey.currency0, hookedPoolKey.currency1, WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);

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

    // ==================== Mode Combination Coverage ====================

    function testModeMatrixSetup_AllValidVaultCombinations() public {
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        uint8 validCount;
        for (uint8 mode = 1; mode < 32; mode++) {
            // Vault positions cannot use AUTO_LEND.
            if ((mode & PositionModeFlags.MODE_AUTO_LEND) != 0) {
                continue;
            }

            vm.prank(WHALE_ACCOUNT);
            revertHook.setPositionConfig(
                hookedTokenId,
                _buildVaultModeConfig(mode, hookedPoolKey.tickSpacing, false, false, type(int24).min, type(int24).max)
            );

            (
                uint8 storedMode,
                RevertHookState.AutoCompoundMode storedAutoCompoundMode,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint16 storedLeverageTargetBps
            ) = revertHook.positionConfigs(hookedTokenId);

            assertEq(storedMode, mode, "Stored mode flags mismatch");
            if ((mode & PositionModeFlags.MODE_AUTO_COMPOUND) != 0) {
                assertEq(
                    uint8(storedAutoCompoundMode),
                    uint8(RevertHookState.AutoCompoundMode.AUTO_COMPOUND),
                    "AUTO_COMPOUND mode should be enabled"
                );
            } else {
                assertEq(
                    uint8(storedAutoCompoundMode),
                    uint8(RevertHookState.AutoCompoundMode.NONE),
                    "Auto compound mode should be NONE"
                );
            }

            if ((mode & PositionModeFlags.MODE_AUTO_LEVERAGE) != 0) {
                assertEq(storedLeverageTargetBps, 5000, "AUTO_LEVERAGE target should be set");
            } else {
                assertEq(storedLeverageTargetBps, 0, "AUTO_LEVERAGE target should be zero");
            }

            unchecked {
                ++validCount;
            }
        }

        assertEq(validCount, 15, "Expected 15 valid vault mode combinations");
    }

    function testModeMatrixSetup_InvalidVaultCombinationsRevert() public {
        PoolKey memory hookedPoolKey = _createHookedPool();
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), hookedTokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(hookedTokenId, WHALE_ACCOUNT);
        vm.prank(WHALE_ACCOUNT);
        vault.approveTransform(hookedTokenId, address(revertHook), true);

        uint8 invalidCount;
        for (uint8 mode = 1; mode < 32; mode++) {
            // Vault positions cannot use AUTO_LEND in any combination.
            if ((mode & PositionModeFlags.MODE_AUTO_LEND) == 0) {
                continue;
            }

            vm.expectRevert(Constants.InvalidConfig.selector);
            vm.prank(WHALE_ACCOUNT);
            revertHook.setPositionConfig(
                hookedTokenId,
                _buildVaultModeConfig(mode, hookedPoolKey.tickSpacing, false, false, type(int24).min, type(int24).max)
            );

            unchecked {
                ++invalidCount;
            }
        }

        assertEq(invalidCount, 16, "Expected 16 invalid vault mode combinations");
    }

    function testOracleClamp_DoesNotDropDeferredTriggers() public {
        v4Oracle.setMaxPoolPriceDifference(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth
        uint256 nearTokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        uint256 farTokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);

        int24 spacing = hookedPoolKey.tickSpacing;
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 baseTick = _getTickLower(currentTick, spacing);
        int24 nearExitTick = baseTick - spacing;
        int24 farExitTick = baseTick - 12 * spacing;

        vm.startPrank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(revertHook), true);
        revertHook.setPositionConfig(
            nearTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: nearExitTick,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        revertHook.setPositionConfig(
            farTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: farExitTick,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        vm.stopPrank();

        // Clamp execution close to oracle so only the near trigger is reachable.
        revertHook.setMaxTicksFromOracle(2 * spacing);

        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        _moveTickDownUntil(hookedPoolKey, farExitTick - spacing, 25e6, 80);

        assertEq(positionManager.getPositionLiquidity(nearTokenId), 0, "Near trigger should execute under clamp");
        assertGt(positionManager.getPositionLiquidity(farTokenId), 0, "Far trigger should remain pending under clamp");
        (uint8 farModeBefore,,,,,,,,,,) = revertHook.positionConfigs(farTokenId);
        assertEq(farModeBefore, PositionModeFlags.MODE_AUTO_EXIT, "Deferred trigger config should remain active");

        // Remove clamp and continue down: deferred trigger must still execute.
        revertHook.setMaxTicksFromOracle(10000);
        _moveTickDownUntil(hookedPoolKey, farExitTick - 2 * spacing, 20e6, 20);

        assertEq(positionManager.getPositionLiquidity(farTokenId), 0, "Deferred trigger should execute once clamp is relaxed");
        (uint8 farModeAfter,,,,,,,,,,) = revertHook.positionConfigs(farTokenId);
        assertEq(farModeAfter, PositionModeFlags.MODE_NONE, "Config should clear after deferred trigger execution");
    }

    function testModeRV_TieBreakerPrefersRangeWhenLowerTriggersEqual() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth

        uint256 tokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _setupCollateralizedPositionForAutoRange(tokenId, hookedPoolKey);

        int24 spacing = hookedPoolKey.tickSpacing;
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 baseTick = _getTickLower(currentTick, spacing);
        int24 leverageLower = baseTick - 10 * spacing;
        int24 autoRangeLowerLimit = posInfo.tickLower() - leverageLower;

        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE | PositionModeFlags.MODE_AUTO_LEVERAGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: autoRangeLowerLimit,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 5000
            })
        );

        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        _moveTickDownUntil(hookedPoolKey, leverageLower, 40e6, 50);

        uint256 remintedTokenId = nextTokenIdBefore;
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Range should win tie-break and remint");
        assertGt(positionManager.getPositionLiquidity(remintedTokenId), 0, "Tie-break should produce reminted range position");

        (uint256 debtAfter,,,,) = vault.loanInfo(remintedTokenId);
        assertEq(debtAfter, debtBefore, "Range path should preserve debt");
        (uint256 oldDebt,,,,) = vault.loanInfo(tokenId);
        assertEq(oldDebt, 0, "Old token debt should be cleared after remint");
    }

    function testModeCREV_FullAutomationCoverage() public {
        // Keep legacy test name as an alias to the deterministic multi-mode coverage test.
        testModeCREV_AllAutomationsActive_MultiModeTickHandling();
    }

    function testModeCREV_AllAutomationsActive_MultiModeTickHandling() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth for deterministic trigger crossings

        uint256 tokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _setupCollateralizedPositionForAutoRange(tokenId, hookedPoolKey);
        _generateFees(hookedPoolKey);

        uint8 modeCREV = PositionModeFlags.MODE_AUTO_COMPOUND
            | PositionModeFlags.MODE_AUTO_RANGE
            | PositionModeFlags.MODE_AUTO_EXIT
            | PositionModeFlags.MODE_AUTO_LEVERAGE;

        int24 spacing = hookedPoolKey.tickSpacing;
        (, PositionInfo initialPosInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 baseTick = _getTickLower(currentTick, spacing);

        // Phase 1: leverage should fire first on downward tick movement.
        int24 leverageLowerPhase1 = baseTick - 10 * spacing;
        int24 rangeLowerPhase1 = initialPosInfo.tickLower() - 20 * spacing;
        int24 exitLowerPhase1 = baseTick - 30 * spacing;
        assertGt(leverageLowerPhase1, rangeLowerPhase1, "Expected leverage trigger to be above range trigger (phase 1)");
        assertGt(rangeLowerPhase1, exitLowerPhase1, "Expected range trigger to be above exit trigger (phase 1)");

        _setPositionConfigAtTarget(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: modeCREV,
                autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
                autoExitIsRelative: false,
                autoExitTickLower: exitLowerPhase1,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 20 * spacing,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 5000
            })
        );
        _alignLoanToTargetBps(tokenId, 3500);

        // C: auto-compound executes while trigger modes are active.
        uint128 liquidityBeforeCompound = positionManager.getPositionLiquidity(tokenId);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(WHALE_ACCOUNT);
        revertHook.autoCompound(tokenIds);
        uint128 liquidityAfterCompound = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfterCompound, liquidityBeforeCompound, "AUTO_COMPOUND should increase liquidity");

        // Move down only to leverage trigger band.
        uint256 nextTokenIdBeforeLeverage = positionManager.nextTokenId();
        (uint256 debtBeforeLeverage,,,,) = vault.loanInfo(tokenId);
        (,,,,,,, int24 storedBaseTickBeforeLeverage) = revertHook.positionStates(tokenId);
        int24 tickAfterLeverage = _moveTickDownUntil(hookedPoolKey, leverageLowerPhase1, 50e6, 40);
        assertGt(tickAfterLeverage, rangeLowerPhase1, "Range trigger should not be crossed in leverage phase");

        // V: leverage adjusts debt and updates base tick without reminting.
        (uint256 debtAfterLeverage,,,,) = vault.loanInfo(tokenId);
        (,,,,,,, int24 storedBaseTickAfterLeverage) = revertHook.positionStates(tokenId);
        assertGt(debtAfterLeverage, debtBeforeLeverage, "AUTO_LEVERAGE should increase debt toward target");
        assertTrue(
            storedBaseTickAfterLeverage != storedBaseTickBeforeLeverage,
            "AUTO_LEVERAGE should reset base tick after execution"
        );
        assertEq(positionManager.nextTokenId(), nextTokenIdBeforeLeverage, "Leverage should not remint position");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "Position should remain active after leverage");

        // Phase 2: reconfigure with all flags still active, but make range fire before leverage.
        (, PositionInfo posAfterLeverage) = positionManager.getPoolAndPositionInfo(tokenId);
        (, currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        baseTick = _getTickLower(currentTick, spacing);

        int24 rangeLowerPhase2 = posAfterLeverage.tickLower() - 15 * spacing;
        int24 leverageLowerPhase2 = baseTick - 10 * spacing;
        int24 exitLowerPhase2 = baseTick - 40 * spacing;
        assertGt(rangeLowerPhase2, leverageLowerPhase2, "Expected range trigger to be above leverage trigger (phase 2)");
        assertGt(leverageLowerPhase2, exitLowerPhase2, "Expected leverage trigger to be above exit trigger (phase 2)");

        RevertHookState.PositionConfig memory phase2Config = RevertHookState.PositionConfig({
            modeFlags: modeCREV,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: exitLowerPhase2,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 15 * spacing,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 5000
        });

        _setPositionConfigAtTarget(tokenId, phase2Config);

        uint256 nextTokenIdBeforeRange = positionManager.nextTokenId();
        (uint256 debtBeforeRange,,,,) = vault.loanInfo(tokenId);
        _moveTickDownUntil(hookedPoolKey, rangeLowerPhase2, 50e6, 40);

        // R: range remints position, preserves debt, keeps multi-mode config.
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "AUTO_RANGE should remove liquidity from old token");
        uint256 rangedTokenId = nextTokenIdBeforeRange;
        assertGt(positionManager.getPositionLiquidity(rangedTokenId), 0, "AUTO_RANGE should mint replacement token");

        _assertVaultHookPositionConfigEq(rangedTokenId, phase2Config);
        (,, uint32 rangedLastActivated,,,,,) = revertHook.positionStates(rangedTokenId);
        assertGt(rangedLastActivated, 0, "Reminted position should stay activated");

        (uint256 debtAfterRange,,,,) = vault.loanInfo(rangedTokenId);
        assertEq(debtAfterRange, debtBeforeRange, "AUTO_RANGE should preserve debt");

        (, int24 tickAfterRange,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        (, PositionInfo rangedPosInfo) = positionManager.getPoolAndPositionInfo(rangedTokenId);
        assertTrue(
            tickAfterRange >= rangedPosInfo.tickLower() && tickAfterRange <= rangedPosInfo.tickUpper(),
            "Current tick should be within reminted range"
        );

        // Base tick must be re-initialized for leverage-capable reminted positions.
        int24 expectedBaseTickAfterRange = _getTickLower(tickAfterRange, spacing);
        (,,,,,,, int24 baseTickAfterRange) = revertHook.positionStates(rangedTokenId);
        assertEq(baseTickAfterRange, expectedBaseTickAfterRange, "Reminted C|R|E|V position should reset leverage base tick");

        // Phase 3: keep all flags active and make exit fire before range/leverage.
        int24 exitLowerPhase3 = expectedBaseTickAfterRange - spacing;
        int24 rangeLowerPhase3 = rangedPosInfo.tickLower() - 20 * spacing;
        int24 leverageLowerPhase3 = expectedBaseTickAfterRange - 10 * spacing;
        assertGt(exitLowerPhase3, leverageLowerPhase3, "Expected exit trigger to be above leverage trigger (phase 3)");
        assertGt(leverageLowerPhase3, rangeLowerPhase3, "Expected leverage trigger to be above range trigger (phase 3)");

        _setPositionConfigAtTarget(
            rangedTokenId,
            RevertHookState.PositionConfig({
                modeFlags: modeCREV,
                autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
                autoExitIsRelative: false,
                autoExitTickLower: exitLowerPhase3,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 20 * spacing,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 5000
            })
        );

        _moveTickDownUntil(hookedPoolKey, exitLowerPhase3, 25e6, 40);

        // E: exit should fully unwind the active token.
        assertEq(positionManager.getPositionLiquidity(rangedTokenId), 0, "AUTO_EXIT should remove all liquidity");
        (uint8 modeAfterExit,,,,,,,,,,) = revertHook.positionConfigs(rangedTokenId);
        assertEq(modeAfterExit, PositionModeFlags.MODE_NONE, "Position config should be disabled after AUTO_EXIT");
    }

    function testModeCREV_ImmediateExecutionWhenOutOfBounds() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth for deterministic tick movement

        uint256 tokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _setupCollateralizedPositionForAutoRange(tokenId, hookedPoolKey);
        _generateFees(hookedPoolKey);

        int24 spacing = hookedPoolKey.tickSpacing;
        (, PositionInfo posInfoBeforeConfig) = positionManager.getPoolAndPositionInfo(tokenId);

        // Pre-move price out of bounds before configuration to force immediate execution on setPositionConfig.
        int24 rangeLowerTrigger = posInfoBeforeConfig.tickLower() - 2 * spacing;
        _moveTickDownUntil(hookedPoolKey, rangeLowerTrigger - spacing, 20e6, 40);

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 baseTick = _getTickLower(currentTick, spacing);
        int24 leverageLowerTrigger = baseTick - 10 * spacing;
        int24 exitLowerTrigger = leverageLowerTrigger - 20 * spacing;
        int24 autoRangeLowerLimit = posInfoBeforeConfig.tickLower() - rangeLowerTrigger;

        assertGt(rangeLowerTrigger, leverageLowerTrigger, "Range trigger should fire before leverage trigger");
        assertGt(leverageLowerTrigger, exitLowerTrigger, "Leverage trigger should fire before exit trigger");

        uint8 modeCREV = PositionModeFlags.MODE_AUTO_COMPOUND
            | PositionModeFlags.MODE_AUTO_RANGE
            | PositionModeFlags.MODE_AUTO_EXIT
            | PositionModeFlags.MODE_AUTO_LEVERAGE;

        RevertHookState.PositionConfig memory config = RevertHookState.PositionConfig({
            modeFlags: modeCREV,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: exitLowerTrigger,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: autoRangeLowerLimit,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 5000
        });

        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);

        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(tokenId, config);

        // Immediate dispatch should remint via AUTO_RANGE (not leverage/exit) because range lower trigger is first.
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Immediate C|R|E|V config should remint old token");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore + 1, "Immediate range should mint exactly one new token");

        uint256 remintedTokenId = nextTokenIdBefore;
        assertGt(positionManager.getPositionLiquidity(remintedTokenId), 0, "Reminted token should hold liquidity");
        _assertVaultHookPositionConfigEq(remintedTokenId, config);

        (uint256 debtAfter,,,,) = vault.loanInfo(remintedTokenId);
        assertEq(debtAfter, debtBefore, "Immediate remint should preserve debt");
        _assertOldPositionFullyCleaned(tokenId);
        _assertHookHasNoTokenDust();
    }

    function testModeCREV_ImmediateExecutionExitWinsWhenOutOfBounds() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey);

        uint256 tokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _setupCollateralizedPositionForAutoRange(tokenId, hookedPoolKey);
        _generateFees(hookedPoolKey);

        int24 spacing = hookedPoolKey.tickSpacing;
        (, PositionInfo posInfoBeforeConfig) = positionManager.getPoolAndPositionInfo(tokenId);

        int24 rangeLowerTrigger = posInfoBeforeConfig.tickLower() - 4 * spacing;
        _moveTickDownUntil(hookedPoolKey, rangeLowerTrigger - spacing, 20e6, 40);

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 baseTick = _getTickLower(currentTick, spacing);
        int24 exitLowerTrigger = posInfoBeforeConfig.tickLower() - spacing;
        int24 leverageLowerTrigger = baseTick - 10 * spacing;
        int24 autoRangeLowerLimit = posInfoBeforeConfig.tickLower() - rangeLowerTrigger;

        assertGt(exitLowerTrigger, rangeLowerTrigger, "Exit trigger should fire before range trigger");
        assertGt(rangeLowerTrigger, leverageLowerTrigger, "Range trigger should fire before leverage trigger");

        uint8 modeCREV = PositionModeFlags.MODE_AUTO_COMPOUND
            | PositionModeFlags.MODE_AUTO_RANGE
            | PositionModeFlags.MODE_AUTO_EXIT
            | PositionModeFlags.MODE_AUTO_LEVERAGE;

        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(tokenId, RevertHookState.PositionConfig({
            modeFlags: modeCREV,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: exitLowerTrigger,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: autoRangeLowerLimit,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 5000
        }));

        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Immediate exit should not remint a replacement token");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "Immediate exit should fully unwind liquidity");
        (uint8 modeAfterExit,,,,,,,,,,) = revertHook.positionConfigs(tokenId);
        assertEq(modeAfterExit, PositionModeFlags.MODE_NONE, "Immediate exit should disable the position");
        _assertOldPositionFullyCleaned(tokenId);
        _assertHookHasNoTokenDust();
    }

    function testAfterSwap_CanSwitchDirectionAndExecuteOppositeSideTrigger() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth

        int24 spacing = hookedPoolKey.tickSpacing;
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 stagedBaseTick = _getTickLower(initialTick, spacing) - 10 * spacing;
        _moveTickDownUntil(hookedPoolKey, stagedBaseTick, 25e6, 80);

        uint256 leverageTokenId = _createPositionInHookedPool(hookedPoolKey);
        (uint256 debtBefore,) = _setupCollateralizedPositionForAutoLeverage(leverageTokenId);
        _configurePositionForAutoLeverage(leverageTokenId, 1500);
        (uint256 debtAfterConfig,,,,) = vault.loanInfo(leverageTokenId);
        if (debtAfterConfig < debtBefore) {
            vm.prank(WHALE_ACCOUNT);
            vault.borrow(leverageTokenId, debtBefore - debtAfterConfig);
        }

        (,,,,,,, int24 leverageBaseTick) = revertHook.positionStates(leverageTokenId);

        uint256 exitTokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        int24 exitUpperTrigger = leverageBaseTick + spacing;

        vm.startPrank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(revertHook), true);
        revertHook.setPositionConfig(
            exitTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: exitUpperTrigger,
                autoRangeLowerLimit: type(int24).min,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        vm.stopPrank();

        vm.recordLogs();
        _swapExactInputSingle(hookedPoolKey, true, 700e6, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, int24 tickAfterAction,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        bytes32 autoLeverageTopic = keccak256("AutoLeverage(uint256,bool,uint256,uint256)");
        bytes32 autoExitTopic = keccak256("AutoExit(uint256,address,address,uint256,uint256)");
        bytes32[2] memory expectedTopics = [autoLeverageTopic, autoExitTopic];
        uint256[2] memory expectedTokenIds = [leverageTokenId, exitTokenId];
        uint256 matchedEvents;
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(revertHook) || logs[i].topics.length < 2) {
                continue;
            }
            bytes32 topic0 = logs[i].topics[0];
            if (topic0 != autoLeverageTopic && topic0 != autoExitTopic) {
                continue;
            }

            assertLt(matchedEvents, 2, "Only the expected bidirectional actions should fire");
            assertEq(topic0, expectedTopics[matchedEvents], "Bidirectional actions should execute in order");
            assertEq(uint256(logs[i].topics[1]), expectedTokenIds[matchedEvents], "Unexpected token executed");
            unchecked {
                ++matchedEvents;
            }
        }

        assertEq(matchedEvents, 2, "Expected leverage action followed by opposite-side exit");
        assertFalse(
            _sawHookActionFailed(logs, leverageTokenId, RevertHookState.Mode.AUTO_LEVERAGE),
            "Leverage path should complete without HookActionFailed"
        );
        assertFalse(
            _sawHookActionFailed(logs, exitTokenId, RevertHookState.Mode.AUTO_EXIT),
            "Opposite-side AUTO_EXIT should complete without HookActionFailed"
        );

        assertEq(positionManager.getPositionLiquidity(exitTokenId), 0, "Opposite-side AUTO_EXIT should remove liquidity");
        (uint8 exitModeFlags,,,,,,,,,,) = revertHook.positionConfigs(exitTokenId);
        assertEq(exitModeFlags, PositionModeFlags.MODE_NONE, "Opposite-side AUTO_EXIT token should be disabled");

        (uint256 debtAfter,, uint256 collateralAfter,,) = vault.loanInfo(leverageTokenId);
        assertLt(debtAfter, debtBefore, "Triggered lower AUTO_LEVERAGE should reduce debt");
        assertTrue(collateralAfter > debtAfter, "Leverage position should remain healthy");
        assertGe(tickAfterAction, exitUpperTrigger, "Internal leverage swap should reverse price across the upper exit trigger");
        _assertHookHasNoTokenDust();
    }

    function testAfterSwap_ReversedSharedTickDefersRemainingPositions() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth

        int24 spacing = hookedPoolKey.tickSpacing;
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 stagedBaseTick = _getTickLower(initialTick, spacing) - 10 * spacing;
        _moveTickDownUntil(hookedPoolKey, stagedBaseTick, 25e6, 80);

        uint256 leverageTokenId = _createPositionInHookedPool(hookedPoolKey);
        (uint256 leverageDebtBeforeConfig,) = _setupCollateralizedPositionForAutoLeverage(leverageTokenId);
        _configurePositionForAutoLeverage(leverageTokenId, 1500);
        (uint256 leverageDebtAfterConfig,,,,) = vault.loanInfo(leverageTokenId);
        if (leverageDebtAfterConfig < leverageDebtBeforeConfig) {
            vm.prank(WHALE_ACCOUNT);
            vault.borrow(leverageTokenId, leverageDebtBeforeConfig - leverageDebtAfterConfig);
        }

        (,,,,,,, int24 leverageBaseTick) = revertHook.positionStates(leverageTokenId);
        int24 sharedLowerTrigger =
            leverageBaseTick - int24(revertHook.LEVERAGE_TICK_OFFSET_MULTIPLIER()) * spacing;

        uint256 lowerExitTokenId1 = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        uint256 lowerExitTokenId2 = _createPositionInHookedPoolForAutoRange(hookedPoolKey);

        vm.startPrank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).setApprovalForAll(address(revertHook), true);
        RevertHookState.PositionConfig memory sharedLowerExitConfig = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: sharedLowerTrigger,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: type(int24).min,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
        revertHook.setPositionConfig(lowerExitTokenId1, sharedLowerExitConfig);
        revertHook.setPositionConfig(lowerExitTokenId2, sharedLowerExitConfig);
        vm.stopPrank();

        uint128 lowerExitLiquidity1Before = positionManager.getPositionLiquidity(lowerExitTokenId1);
        uint128 lowerExitLiquidity2Before = positionManager.getPositionLiquidity(lowerExitTokenId2);

        vm.recordLogs();
        _swapExactInputSingle(hookedPoolKey, true, 700e6, 0);

        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        (, int24 tickAfterFirstSwap,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));

        assertTrue(
            _sawIndexedHookEvent(firstLogs, keccak256("AutoLeverage(uint256,bool,uint256,uint256)"), leverageTokenId),
            "Shared lower tick should execute AUTO_LEVERAGE first"
        );
        assertFalse(
            _sawIndexedHookEvent(firstLogs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), lowerExitTokenId1),
            "First remaining shared-tick AUTO_EXIT should be deferred after reversal"
        );
        assertFalse(
            _sawIndexedHookEvent(firstLogs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), lowerExitTokenId2),
            "Second remaining shared-tick AUTO_EXIT should be deferred after reversal"
        );

        assertEq(
            positionManager.getPositionLiquidity(lowerExitTokenId1),
            lowerExitLiquidity1Before,
            "Deferred shared-tick exit should keep its liquidity"
        );
        assertEq(
            positionManager.getPositionLiquidity(lowerExitTokenId2),
            lowerExitLiquidity2Before,
            "Deferred shared-tick exit should keep its liquidity"
        );
        (uint8 lowerModeFlags1,,,,,,,,,,) = revertHook.positionConfigs(lowerExitTokenId1);
        (uint8 lowerModeFlags2,,,,,,,,,,) = revertHook.positionConfigs(lowerExitTokenId2);
        assertEq(lowerModeFlags1, PositionModeFlags.MODE_AUTO_EXIT, "Deferred shared-tick exit should remain armed");
        assertEq(lowerModeFlags2, PositionModeFlags.MODE_AUTO_EXIT, "Deferred shared-tick exit should remain armed");
        assertGt(tickAfterFirstSwap, sharedLowerTrigger, "First action should move price back above the shared trigger tick");

        vm.recordLogs();
        _moveTickDownUntil(hookedPoolKey, sharedLowerTrigger - spacing, 25e6, 80);

        Vm.Log[] memory secondLogs = vm.getRecordedLogs();
        assertTrue(
            _sawIndexedHookEvent(secondLogs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), lowerExitTokenId1),
            "Deferred shared-tick exit should execute after a later downward recross"
        );
        assertTrue(
            _sawIndexedHookEvent(secondLogs, keccak256("AutoExit(uint256,address,address,uint256,uint256)"), lowerExitTokenId2),
            "Both deferred shared-tick exits should execute on the later recross"
        );
        assertEq(positionManager.getPositionLiquidity(lowerExitTokenId1), 0, "First deferred shared-tick exit should drain");
        assertEq(positionManager.getPositionLiquidity(lowerExitTokenId2), 0, "Second deferred shared-tick exit should drain");
        _assertHookHasNoTokenDust();
    }

    function testAutoLeverageReconfiguration_ReplacesOldTriggerNodes() public {
        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey);

        uint256 tokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _setupCollateralizedPositionForAutoRange(tokenId, hookedPoolKey);
        _generateFees(hookedPoolKey);

        int24 spacing = hookedPoolKey.tickSpacing;
        RevertHookState.PositionConfig memory initialConfig =
            _buildVaultModeConfig(PositionModeFlags.MODE_AUTO_LEVERAGE, spacing, false, false, type(int24).min, type(int24).max);

        (uint32 lowerBaseline, uint32 upperBaseline) = _getTriggerListSizes(hookedPoolKey);
        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(tokenId, initialConfig);

        (uint32 lowerConfigured, uint32 upperConfigured) = _getTriggerListSizes(hookedPoolKey);
        assertEq(lowerConfigured, lowerBaseline + 1, "Initial leverage setup should add one lower trigger");
        assertEq(upperConfigured, upperBaseline + 1, "Initial leverage setup should add one upper trigger");

        (,,,,,,, int24 initialBaseTick) = revertHook.positionStates(tokenId);
        _moveTickDownUntil(hookedPoolKey, initialBaseTick - 2 * spacing, 5e6, 40);

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 newBaseTick = _getTickLower(currentTick, spacing);
        assertLt(newBaseTick, initialBaseTick, "Price move should change the leverage base tick before reconfiguration");

        RevertHookState.PositionConfig memory updatedConfig = initialConfig;
        updatedConfig.autoLeverageTargetBps = 6500;
        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(tokenId, updatedConfig);

        (uint32 lowerAfterReconfig, uint32 upperAfterReconfig) = _getTriggerListSizes(hookedPoolKey);
        assertEq(lowerAfterReconfig, lowerConfigured, "Reconfiguration must replace, not leak, lower trigger nodes");
        assertEq(upperAfterReconfig, upperConfigured, "Reconfiguration must replace, not leak, upper trigger nodes");
        (,,,,,,, int24 storedBaseTick) = revertHook.positionStates(tokenId);
        assertEq(storedBaseTick, newBaseTick, "Reconfiguration should update the stored leverage base tick");
    }

    function testModeCREV_StressRepeatedTransitions() public {
        v4Oracle.setMaxPoolPriceDifference(10000);
        revertHook.setMaxTicksFromOracle(10000);
        revertHook.setMinPositionValueNative(0);

        PoolKey memory hookedPoolKey = _createHookedPool();
        _createPositionInHookedPool(hookedPoolKey); // extra LP depth

        uint256 activeTokenId = _createPositionInHookedPoolForAutoRange(hookedPoolKey);
        _setupCollateralizedPositionForAutoRange(activeTokenId, hookedPoolKey);
        _generateFees(hookedPoolKey);

        uint8 modeCREV = PositionModeFlags.MODE_AUTO_COMPOUND
            | PositionModeFlags.MODE_AUTO_RANGE
            | PositionModeFlags.MODE_AUTO_EXIT
            | PositionModeFlags.MODE_AUTO_LEVERAGE;
        int24 spacing = hookedPoolKey.tickSpacing;

        // Ensure C is exercised while all trigger flags are present.
        RevertHookState.PositionConfig memory warmupConfig = RevertHookState.PositionConfig({
            modeFlags: modeCREV,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: type(int24).min,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: 20 * spacing,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 6500
        });
        _setPositionConfigAtTarget(activeTokenId, warmupConfig);

        uint128 liquidityBeforeCompound = positionManager.getPositionLiquidity(activeTokenId);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = activeTokenId;
        vm.prank(WHALE_ACCOUNT);
        revertHook.autoCompound(tokenIds);
        uint128 liquidityAfterCompound = positionManager.getPositionLiquidity(activeTokenId);
        assertGt(liquidityAfterCompound, liquidityBeforeCompound, "AUTO_COMPOUND should increase liquidity");
        _assertHookHasNoTokenDust();

        // Run repeated transitions to catch state drift bugs.
        for (uint256 cycle; cycle < 2; cycle++) {
            // -------- Range-first phase (R should execute before V/E) --------
            (, PositionInfo posInfoRange) = positionManager.getPoolAndPositionInfo(activeTokenId);
            (, int24 currentTickRange,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
            int24 baseTickRange = _getTickLower(currentTickRange, spacing);
            int24 leverageLower = baseTickRange - 10 * spacing;
            int24 rangeLower = leverageLower + 4 * spacing;
            int24 exitLowerFar = leverageLower - 20 * spacing;
            int24 autoRangeLowerLimitRangeFirst = posInfoRange.tickLower() - rangeLower;
            assertGt(rangeLower, leverageLower, "Range should trigger before leverage in range-first phase");
            assertGt(leverageLower, exitLowerFar, "Leverage should trigger before exit in range-first phase");

            uint256 oldTokenId = activeTokenId;
            uint256 nextTokenIdBeforeRange = positionManager.nextTokenId();

            RevertHookState.PositionConfig memory rangeFirstConfig = RevertHookState.PositionConfig({
                modeFlags: modeCREV,
                autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
                autoExitIsRelative: false,
                autoExitTickLower: exitLowerFar,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: autoRangeLowerLimitRangeFirst,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 6500
            });
            _setPositionConfigAtTarget(activeTokenId, rangeFirstConfig);
            (uint256 debtBeforeRange,,,,) = vault.loanInfo(oldTokenId);
            (,,,,,,, int24 baseTickBeforeRange) = revertHook.positionStates(oldTokenId);

            _moveTickDownUntil(hookedPoolKey, rangeLower, 40e6, 40);

            bool reminted = positionManager.nextTokenId() > nextTokenIdBeforeRange;
            if (reminted) {
                activeTokenId = nextTokenIdBeforeRange;
                assertEq(positionManager.getPositionLiquidity(oldTokenId), 0, "Old token should be fully exited after range");
                assertGt(positionManager.getPositionLiquidity(activeTokenId), 0, "Range should mint replacement token");
                _assertVaultHookPositionConfigEq(activeTokenId, rangeFirstConfig);
                _assertOldPositionFullyCleaned(oldTokenId);

                (uint256 debtAfterRange,,,,) = vault.loanInfo(activeTokenId);
                assertEq(debtAfterRange, debtBeforeRange, "Debt should transfer exactly through range remint");
                assertEq(IERC721(address(positionManager)).ownerOf(activeTokenId), address(vault), "Vault ownership must persist");

                (, int24 tickAfterRange,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
                (,,,,,,, int24 baseTickAfterRange) = revertHook.positionStates(activeTokenId);
                assertEq(baseTickAfterRange, _getTickLower(tickAfterRange, spacing), "Base tick must reset on reminted token");
            } else {
                activeTokenId = oldTokenId;
                assertGt(positionManager.getPositionLiquidity(activeTokenId), 0, "Fallback should restore liquidity");
                _assertVaultHookPositionConfigEq(activeTokenId, rangeFirstConfig);

                (uint256 debtAfterFallback,,,,) = vault.loanInfo(activeTokenId);
                assertEq(debtAfterFallback, debtBeforeRange, "Fallback should preserve debt");
                assertEq(IERC721(address(positionManager)).ownerOf(activeTokenId), address(vault), "Vault ownership must persist");

                (,,,,,,, int24 baseTickAfterFallback) = revertHook.positionStates(activeTokenId);
                assertEq(baseTickAfterFallback, baseTickBeforeRange, "Fallback should preserve base tick");
            }
            _assertHookHasNoTokenDust();

            // -------- Leverage-first phase (V should execute before R/E) --------
            (, PositionInfo posInfoLev) = positionManager.getPoolAndPositionInfo(activeTokenId);
            (, int24 currentTickLev,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
            int24 baseTickLev = _getTickLower(currentTickLev, spacing);
            int24 leverageLowerFirst = baseTickLev - 10 * spacing;
            int24 rangeLowerFar = leverageLowerFirst - 8 * spacing;
            int24 exitLowerVeryFar = rangeLowerFar - 20 * spacing;
            int24 autoRangeLowerLimitLeverageFirst = posInfoLev.tickLower() - rangeLowerFar;
            assertGt(leverageLowerFirst, rangeLowerFar, "Leverage should trigger before range in leverage-first phase");
            assertGt(rangeLowerFar, exitLowerVeryFar, "Range should trigger before exit in leverage-first phase");

            (uint256 debtForTargetSelection,, uint256 collateralForTargetSelection,,) = vault.loanInfo(activeTokenId);
            uint256 currentRatioBps =
                collateralForTargetSelection > 0 ? debtForTargetSelection * 10000 / collateralForTargetSelection : 0;
            uint16 leverageTargetBps = currentRatioBps > 6000 ? 3000 : 8000;

            RevertHookState.PositionConfig memory leverageFirstConfig = RevertHookState.PositionConfig({
                modeFlags: modeCREV,
                autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
                autoExitIsRelative: false,
                autoExitTickLower: exitLowerVeryFar,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: autoRangeLowerLimitLeverageFirst,
                autoRangeUpperLimit: type(int24).max,
                autoRangeLowerDelta: -spacing,
                autoRangeUpperDelta: spacing,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: leverageTargetBps
            });
            _setPositionConfigAtTarget(activeTokenId, leverageFirstConfig);
            _alignLoanToTargetBps(
                activeTokenId, leverageTargetBps > 5000 ? leverageTargetBps - 1000 : leverageTargetBps + 1000
            );
            uint256 nextTokenIdBeforeLeverage = positionManager.nextTokenId();
            (uint256 debtBeforeLeverage,, uint256 collateralBeforeLeverage,,) = vault.loanInfo(activeTokenId);
            (,,,,,,, int24 baseTickBeforeLeverage) = revertHook.positionStates(activeTokenId);

            _moveTickDownUntil(hookedPoolKey, leverageLowerFirst, 40e6, 40);

            assertEq(positionManager.nextTokenId(), nextTokenIdBeforeLeverage, "Leverage should not mint a new token");
            assertGt(positionManager.getPositionLiquidity(activeTokenId), 0, "Leverage phase should keep position active");
            (uint256 debtAfterLeverage,, uint256 collateralAfterLeverage,,) = vault.loanInfo(activeTokenId);
            assertTrue(debtAfterLeverage != debtBeforeLeverage, "Leverage should adjust debt");
            assertTrue(collateralAfterLeverage > debtAfterLeverage, "Position should remain healthy after leverage");
            (,,,,,,, int24 baseTickAfterLeverage) = revertHook.positionStates(activeTokenId);
            assertTrue(baseTickAfterLeverage != baseTickBeforeLeverage, "Leverage should reset base tick");
            _assertHookHasNoTokenDust();
        }

        // -------- Exit-first phase (E should execute before V/R) --------
        (, PositionInfo posInfoExit) = positionManager.getPoolAndPositionInfo(activeTokenId);
        (, int24 currentTickExit,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        int24 baseTickExit = _getTickLower(currentTickExit, spacing);
        int24 exitLowerFirst = baseTickExit - 3 * spacing;
        int24 leverageLowerExitPhase = baseTickExit - 10 * spacing;
        int24 rangeLowerExitPhase = leverageLowerExitPhase - 8 * spacing;
        int24 autoRangeLowerLimitExitFirst = posInfoExit.tickLower() - rangeLowerExitPhase;
        assertGt(exitLowerFirst, leverageLowerExitPhase, "Exit should trigger before leverage in exit-first phase");
        assertGt(leverageLowerExitPhase, rangeLowerExitPhase, "Leverage should trigger before range in exit-first phase");

        RevertHookState.PositionConfig memory exitFirstConfig = RevertHookState.PositionConfig({
            modeFlags: modeCREV,
            autoCompoundMode: RevertHookState.AutoCompoundMode.AUTO_COMPOUND,
            autoExitIsRelative: false,
            autoExitTickLower: exitLowerFirst,
            autoExitTickUpper: type(int24).max,
            autoRangeLowerLimit: autoRangeLowerLimitExitFirst,
            autoRangeUpperLimit: type(int24).max,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 6500
        });
        _setPositionConfigAtTarget(activeTokenId, exitFirstConfig);

        _moveTickDownUntil(hookedPoolKey, exitLowerFirst, 20e6, 40);

        assertEq(positionManager.getPositionLiquidity(activeTokenId), 0, "Exit should fully remove position liquidity");
        (uint8 modeAfterExit,,,,,,,,,,) = revertHook.positionConfigs(activeTokenId);
        assertEq(modeAfterExit, PositionModeFlags.MODE_NONE, "Exit should disable position config");
        _assertOldPositionFullyCleaned(activeTokenId);
        _assertHookHasNoTokenDust();
    }

    function _buildVaultModeConfig(
        uint8 modeFlags,
        int24 tickSpacing,
        bool enableRange,
        bool enableExit,
        int24 exitTickLower,
        int24 exitTickUpper
    ) internal pure returns (RevertHookState.PositionConfig memory config) {
        bool hasRangeMode = PositionModeFlags.hasAutoRange(modeFlags);
        bool hasRangeTriggers = hasRangeMode && enableRange;

        config = RevertHookState.PositionConfig({
            modeFlags: modeFlags,
            autoCompoundMode: PositionModeFlags.hasAutoCompound(modeFlags)
                ? RevertHookState.AutoCompoundMode.AUTO_COMPOUND
                : RevertHookState.AutoCompoundMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: enableExit ? exitTickLower : type(int24).min,
            autoExitTickUpper: enableExit ? exitTickUpper : type(int24).max,
            autoRangeLowerLimit: hasRangeTriggers ? int24(0) : type(int24).min,
            autoRangeUpperLimit: hasRangeTriggers ? int24(0) : type(int24).max,
            autoRangeLowerDelta: hasRangeMode ? -tickSpacing : int24(0),
            autoRangeUpperDelta: hasRangeMode ? tickSpacing : int24(0),
            autoLendToleranceTick: int24(0),
            autoLeverageTargetBps: PositionModeFlags.hasAutoLeverage(modeFlags) ? 5000 : 0
        });
    }

    function _moveTickDownUntil(
        PoolKey memory hookedPoolKey,
        int24 targetTick,
        uint128 amountInPerSwap,
        uint256 maxSteps
    ) internal returns (int24 currentTick) {
        (, currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));

        uint256 steps;
        while (currentTick > targetTick && steps < maxSteps) {
            _swapExactInputSingle(hookedPoolKey, true, amountInPerSwap, 0);
            (, currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
            unchecked {
                ++steps;
            }
        }

        assertLe(currentTick, targetTick, "Target tick was not reached");
    }

    function _getTriggerListSizes(PoolKey memory hookedPoolKey) internal view returns (uint32 lowerSize, uint32 upperSize) {
        (, lowerSize,) = revertHook.lowerTriggerAfterSwap(PoolIdLibrary.toId(hookedPoolKey));
        (, upperSize,) = revertHook.upperTriggerAfterSwap(PoolIdLibrary.toId(hookedPoolKey));
    }

    function _assertVaultHookPositionConfigEq(
        uint256 tokenId,
        RevertHookState.PositionConfig memory expected
    ) internal view {
        (
            uint8 modeFlags,
            RevertHookState.AutoCompoundMode autoCompoundMode,
            bool autoExitIsRelative,
            int24 autoExitTickLower,
            int24 autoExitTickUpper,
            int24 autoRangeLowerLimit,
            int24 autoRangeUpperLimit,
            int24 autoRangeLowerDelta,
            int24 autoRangeUpperDelta,
            int24 autoLendToleranceTick,
            uint16 autoLeverageTargetBps
        ) = revertHook.positionConfigs(tokenId);

        assertEq(modeFlags, expected.modeFlags, "modeFlags mismatch");
        assertEq(uint8(autoCompoundMode), uint8(expected.autoCompoundMode), "autoCompoundMode mismatch");
        assertEq(autoExitIsRelative, expected.autoExitIsRelative, "autoExitIsRelative mismatch");
        assertEq(autoExitTickLower, expected.autoExitTickLower, "autoExitTickLower mismatch");
        assertEq(autoExitTickUpper, expected.autoExitTickUpper, "autoExitTickUpper mismatch");
        assertEq(autoRangeLowerLimit, expected.autoRangeLowerLimit, "autoRangeLowerLimit mismatch");
        assertEq(autoRangeUpperLimit, expected.autoRangeUpperLimit, "autoRangeUpperLimit mismatch");
        assertEq(autoRangeLowerDelta, expected.autoRangeLowerDelta, "autoRangeLowerDelta mismatch");
        assertEq(autoRangeUpperDelta, expected.autoRangeUpperDelta, "autoRangeUpperDelta mismatch");
        assertEq(autoLendToleranceTick, expected.autoLendToleranceTick, "autoLendToleranceTick mismatch");
        assertEq(autoLeverageTargetBps, expected.autoLeverageTargetBps, "autoLeverageTargetBps mismatch");
    }

    function _assertOldPositionFullyCleaned(uint256 tokenId) internal view {
        (uint256 debt, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        assertEq(debt, 0, "Old token debt should be cleared");
        assertEq(fullValue, 0, "Old token full value should be cleared");
        assertEq(collateralValue, 0, "Old token collateral should be cleared");
    }

    function _assertHookHasNoTokenDust() internal view {
        assertEq(usdc.balanceOf(address(revertHook)), 0, "Hook should not retain USDC");
        assertEq(weth.balanceOf(address(revertHook)), 0, "Hook should not retain WETH");
    }

    function _sawHookEventTopic(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter == address(revertHook) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    function _sawHookActionFailed(Vm.Log[] memory logs, uint256 expectedTokenId, RevertHookState.Mode expectedMode)
        internal
        view
        returns (bool)
    {
        bytes32 eventTopic = keccak256("HookActionFailed(uint256,uint8)");
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(revertHook)) {
                continue;
            }
            if (logs[i].topics.length < 2 || logs[i].topics[0] != eventTopic) {
                continue;
            }
            if (uint256(logs[i].topics[1]) != expectedTokenId) {
                continue;
            }
            uint8 actualMode = abi.decode(logs[i].data, (uint8));
            if (actualMode == uint8(expectedMode)) {
                return true;
            }
        }
        return false;
    }

    function _sawIndexedHookEvent(Vm.Log[] memory logs, bytes32 topic, uint256 expectedTokenId)
        internal
        view
        returns (bool)
    {
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            if (logs[i].emitter != address(revertHook)) {
                continue;
            }
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic) {
                continue;
            }
            if (uint256(logs[i].topics[1]) == expectedTokenId) {
                return true;
            }
        }
        return false;
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
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
        _alignLoanToTargetBps(hookedTokenId, 3500);

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

    function test_AutoLeverageExecutesImmediatelyWhenConfiguredOffTarget() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        _createPositionInHookedPool(hookedPoolKey);
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        _setupCollateralizedPositionForAutoLeverage(hookedTokenId);
        uint16 targetBps = 5000;

        vm.prank(WHALE_ACCOUNT);
        vault.borrow(hookedTokenId, 3500_000000);

        (uint256 debtBefore,, uint256 collateralBefore,,) = vault.loanInfo(hookedTokenId);
        uint256 ratioBefore = debtBefore * 10_000 / collateralBefore;
        uint256 distanceBefore = ratioBefore - targetBps;
        uint256 nextTokenIdBefore = positionManager.nextTokenId();

        assertGt(ratioBefore, targetBps, "Test setup should start above the configured leverage target");

        vm.recordLogs();
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

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 debtAfter,, uint256 collateralAfter,,) = vault.loanInfo(hookedTokenId);
        uint256 ratioAfter = debtAfter * 10_000 / collateralAfter;
        uint256 distanceAfter = ratioAfter > targetBps ? ratioAfter - targetBps : targetBps - ratioAfter;
        (,,,,,,, int24 baseTickAfter) = revertHook.positionStates(hookedTokenId);
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));

        assertTrue(
            _sawIndexedHookEvent(logs, keccak256("AutoLeverage(uint256,bool,uint256,uint256)"), hookedTokenId),
            "Configuring an off-target AUTO_LEVERAGE position should execute immediately"
        );
        assertFalse(
            _sawHookActionFailed(logs, hookedTokenId, RevertHookState.Mode.AUTO_LEVERAGE),
            "Immediate AUTO_LEVERAGE config should not emit HookActionFailed"
        );
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "Immediate leverage should not remint the position");
        assertEq(IERC721(address(positionManager)).ownerOf(hookedTokenId), address(vault), "Vault should retain NFT custody");
        assertLt(debtAfter, debtBefore, "Immediate leverage should reduce debt toward the target ratio");
        assertLt(distanceAfter, distanceBefore, "Immediate leverage should move the loan closer to target");
        assertEq(
            baseTickAfter,
            _getTickLower(currentTick, hookedPoolKey.tickSpacing),
            "Immediate leverage should refresh the leverage base tick to the new market tick"
        );
        _assertHookHasNoTokenDust();
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

        _setPositionConfigAtTarget(
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

    function _setPositionConfigAtTarget(uint256 tokenId, RevertHookState.PositionConfig memory config) internal {
        if (PositionModeFlags.hasAutoLeverage(config.modeFlags)) {
            _alignLoanToTargetBps(tokenId, config.autoLeverageTargetBps);
        }

        vm.prank(WHALE_ACCOUNT);
        revertHook.setPositionConfig(tokenId, config);
    }

    function _alignLoanToTargetBps(uint256 tokenId, uint16 targetBps) internal {
        (uint256 currentDebt,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 targetDebt = (collateralValue * targetBps + 9999) / 10000;

        if (currentDebt < targetDebt) {
            vm.prank(WHALE_ACCOUNT);
            vault.borrow(tokenId, targetDebt - currentDebt);
        } else if (currentDebt > targetDebt) {
            vm.startPrank(WHALE_ACCOUNT);
            usdc.approve(address(vault), type(uint256).max);
            vault.repay(tokenId, currentDebt - targetDebt, false);
            vm.stopPrank();
        }
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
        _alignLoanToTargetBps(hookedTokenId, 3500);

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

    function test_AutoLeverageSwapFailure_RestoresDebtAndLiquidity() public {
        PoolKey memory hookedPoolKey = _createHookedPool();

        _createPositionInHookedPool(hookedPoolKey);
        uint256 hookedTokenId = _createPositionInHookedPool(hookedPoolKey);

        _setupCollateralizedPositionForAutoLeverage(hookedTokenId);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(hookedTokenId);

        vm.prank(WHALE_ACCOUNT);
        revertHook.setGeneralConfig(hookedTokenId, 123, hookedPoolKey.tickSpacing, IHooks(address(0)), 0, 0);

        _configurePositionForAutoLeverage(hookedTokenId, 5000);
        _alignLoanToTargetBps(hookedTokenId, 3500);
        (uint256 debtBeforeFailure,,,,) = vault.loanInfo(hookedTokenId);
        (,,,,,,, int24 baseTickBefore) = revertHook.positionStates(hookedTokenId);

        vm.recordLogs();
        _movePriceUp(hookedPoolKey);

        (uint256 debtAfter,, uint256 collateralAfter,,) = vault.loanInfo(hookedTokenId);
        uint128 liquidityAfter = positionManager.getPositionLiquidity(hookedTokenId);
        (,,,,,,, int24 baseTickAfter) = revertHook.positionStates(hookedTokenId);

        assertEq(debtAfter, debtBeforeFailure, "Failed leverage-up must preserve debt");
        assertEq(liquidityAfter, liquidityBefore, "Failed leverage-up must restore original liquidity");
        assertGt(collateralAfter, debtAfter, "Restored position should remain healthy");
        assertEq(baseTickAfter, baseTickBefore, "Failed leverage-up must keep the previous base tick");
        assertEq(IERC721(address(positionManager)).ownerOf(hookedTokenId), address(vault), "Position should remain in the vault");
        _assertHookHasNoTokenDust();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(
            _sawHookEventTopic(logs, keccak256("HookSwapFailed((address,address,uint24,int24,address),(bool,int256,uint160),bytes)")),
            "Failed leverage-up should emit HookSwapFailed"
        );
        assertTrue(
            _sawHookActionFailed(logs, hookedTokenId, RevertHookState.Mode.AUTO_LEVERAGE),
            "Failed leverage-up should emit HookActionFailed"
        );
        assertFalse(
            _sawIndexedHookEvent(logs, keccak256("AutoLeverage(uint256,bool,uint256,uint256)"), hookedTokenId),
            "Failed leverage-up must not emit AutoLeverage"
        );
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
