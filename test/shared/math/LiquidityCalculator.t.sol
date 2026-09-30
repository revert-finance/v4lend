// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {LiquidityCalculator, ILiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";

contract LiquidityCalculatorHelper {
    ILiquidityCalculator public immutable liquidityCalculator;

    constructor(ILiquidityCalculator _liquidityCalculator) {
        liquidityCalculator = _liquidityCalculator;
    }

    function getOptimalSwap(
        ILiquidityCalculator.V4PoolInfo memory cfg,
        int24 lower,
        int24 upper,
        uint256 amt0,
        uint256 amt1
    ) external view returns (uint256 inAmt, uint256 outAmt, bool dir, uint160 price) {
        return liquidityCalculator.calculateSamePool(cfg, lower, upper, amt0, amt1);
    }

    /// @dev Route liquidity deep enough that the constant-liquidity quote is the spot quote for
    ///      any test-sized swap (price impact around 1e-11) while a 6-decimal input still moves
    ///      the price by a resolvable amount; the spot-price tests below rely on it.
    uint128 internal constant DEEP_ROUTE_LIQUIDITY = 1e31;

    function getSimpleSwap(
        uint160 sqrtPrice,
        int24 lower,
        int24 upper,
        uint256 amt0,
        uint256 amt1,
        uint24 feeRate
    ) external view returns (uint256 inAmt, uint256 outAmt, bool dir) {
        return liquidityCalculator.calculateSimple(
            sqrtPrice, sqrtPrice, DEEP_ROUTE_LIQUIDITY, lower, upper, amt0, amt1, feeRate, 0
        );
    }

    function getSimpleSwapWithRoutePrice(
        uint160 positionSqrtPrice,
        uint160 swapSqrtPrice,
        int24 lower,
        int24 upper,
        uint256 amt0,
        uint256 amt1,
        uint24 feeRate
    ) external view returns (uint256 inAmt, uint256 outAmt, bool dir) {
        return liquidityCalculator.calculateSimple(
            positionSqrtPrice, swapSqrtPrice, DEEP_ROUTE_LIQUIDITY, lower, upper, amt0, amt1, feeRate, 0
        );
    }

    function getSimpleSwapThroughPool(
        uint160 positionSqrtPrice,
        ILiquidityCalculator.V4PoolInfo memory swapPool,
        int24 lower,
        int24 upper,
        uint256 amt0,
        uint256 amt1,
        uint24 outputFeePips
    ) external view returns (uint256 inAmt, uint256 outAmt, bool dir) {
        return liquidityCalculator.calculateSimple(positionSqrtPrice, swapPool, lower, upper, amt0, amt1, outputFeePips);
    }

    function getSimpleSwapWithRoute(
        uint160 positionSqrtPrice,
        uint160 swapSqrtPrice,
        uint128 swapLiquidity,
        int24 lower,
        int24 upper,
        uint256 amt0,
        uint256 amt1,
        uint24 feeRate,
        uint24 outputFeePips
    ) external view returns (uint256 inAmt, uint256 outAmt, bool dir) {
        return liquidityCalculator.calculateSimple(
            positionSqrtPrice, swapSqrtPrice, swapLiquidity, lower, upper, amt0, amt1, feeRate, outputFeePips
        );
    }
}

/// @title Test suite for OptimalSwap library (V4)
contract LiquidityCalculatorTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    IPoolManager poolManager;
    IPositionManager positionManager;
    IPermit2 permit2;
    ILiquidityCalculator.V4PoolInfo poolCallee;
    LiquidityCalculatorHelper helper;
    LiquidityCalculator liquidityCalculator;
    
    // Test tokens
    ERC20Mock token0;
    ERC20Mock token1;
    
    // Standard test parameters
    uint160 constant SQRT_PRICE_1_0 = 79228162514264337593543950336; // sqrt(1.0) * 2^96
    uint24 constant DEFAULT_FEE = 3000; // 0.3% fee in hundredths of a bip
    int24 constant DEFAULT_TICK_SPACING = 60;
    
    PoolKey poolKey;
    PoolId poolId;

    struct SwapCallbackData {
        PoolKey key;
        SwapParams params;
        address sender;
    }

    function setUp() public {
        // Deploy Permit2
        address permit2Address = AddressConstants.getPermit2Address();
        if (permit2Address.code.length == 0) {
            address tempDeployAddress = address(Permit2Deployer.deploy());
            vm.etch(permit2Address, tempDeployAddress.code);
        }
        permit2 = IPermit2(permit2Address);
        
        // Deploy PoolManager
        poolManager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(0x4444))));
        
        // Deploy PositionManager
        positionManager = IPositionManager(
            address(
                V4PositionManagerDeployer.deploy(
                    address(poolManager), 
                    address(permit2), 
                    300_000, 
                    address(0), 
                    address(0)
                )
            )
        );
        
        // Deploy test tokens
        ERC20Mock tempToken0 = new ERC20Mock();
        ERC20Mock tempToken1 = new ERC20Mock();
        
        // Ensure proper ordering: token0 < token1 (address-wise)
        if (address(tempToken0) < address(tempToken1)) {
            token0 = tempToken0;
            token1 = tempToken1;
        } else {
            token0 = tempToken1;
            token1 = tempToken0;
        }
        
        // Mint tokens to this contract
        token0.mint(address(this), 100_000_000 ether);
        token1.mint(address(this), 100_000_000 ether);
        
        // Create a pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        
        // Initialize the pool in PoolManager
        poolManager.initialize(poolKey, SQRT_PRICE_1_0);
        
        // Deploy LiquidityCalculator contract
        liquidityCalculator = new LiquidityCalculator();

        // Create pool callee struct
        poolCallee = ILiquidityCalculator.V4PoolInfo({
            poolMgr: poolManager,
            poolIdentifier: poolId,
            tickSpacing: DEFAULT_TICK_SPACING
        });

        // Deploy helper contract
        helper = new LiquidityCalculatorHelper(liquidityCalculator);
        
        // Set up token approvals for PositionManager
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        
        permit2.approve(
            address(token0),
            address(positionManager),
            uint160(10_000_000 ether),
            uint48(block.timestamp + 1 days)
        );
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(10_000_000 ether),
            uint48(block.timestamp + 1 days)
        );
    }

    /// @notice Helper function to add liquidity using PositionManager
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param amount0 Amount of token0 to add
    /// @param amount1 Amount of token1 to add
    function _addLiquidity(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) internal {
        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        
        // Calculate liquidity from amounts
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            amount0,
            amount1
        );
        
        // Create position using modifyLiquidities with MINT_POSITION action
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity), // liquidity
            amount0, // amount0Max
            amount1, // amount1Max
            address(this), // recipient
            "" // hookData
        );
        paramsArray[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(positionManager));
        
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
    }

    /// @notice Helper function to execute a swap using PoolManager
    /// @param amountIn Amount to swap in
    /// @param zeroForOne Direction of swap (true = token0 to token1)
    function _executeSwap(uint256 amountIn, bool zeroForOne) internal returns (BalanceDelta) {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        return abi.decode(
            poolManager.unlock(abi.encode(SwapCallbackData(poolKey, swapParams, address(this)))),
            (BalanceDelta)
        );
    }

    /// @notice Callback for unlock to execute swap
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));
        
        // Execute swap
        BalanceDelta delta = poolManager.swap(data.key, data.params, "");
        
        // Settle currencies
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();
        
        if (delta0 < 0) {
            // We owe token0 - settle it
            data.key.currency0.settle(poolManager, data.sender, uint256(-delta0), false);
        } else if (delta0 > 0) {
            // We receive token0 - take it
            data.key.currency0.take(poolManager, data.sender, uint256(delta0), false);
        }
        
        if (delta1 < 0) {
            // We owe token1 - settle it
            data.key.currency1.settle(poolManager, data.sender, uint256(-delta1), false);
        } else if (delta1 > 0) {
            // We receive token1 - take it
            data.key.currency1.take(poolManager, data.sender, uint256(delta1), false);
        }
        
        return abi.encode(delta);
    }

    /// @notice Helper to execute swap and add liquidity, then check leftovers
    function _executeSwapAndAddLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amountIn,
        uint256 amountOut,
        bool zeroForOne
    ) internal {
        uint256 a0Desired = amount0Desired;
        uint256 a1Desired = amount1Desired;
        
        // Execute the optimal swap
        _executeSwap(amountIn, zeroForOne);
        
        // Calculate amounts available after swap
        uint256 amount0Available = zeroForOne ? a0Desired - amountIn : a0Desired + amountOut;
        uint256 amount1Available = zeroForOne ? a1Desired + amountOut : a1Desired - amountIn;
        
        console.log("Amount0 available for liquidity:", amount0Available);
        console.log("Amount1 available for liquidity:", amount1Available);
        
        // Record balances before adding liquidity
        uint256 balance0BeforeLiquidity = token0.balanceOf(address(this));
        uint256 balance1BeforeLiquidity = token1.balanceOf(address(this));
        
        // Add liquidity with the available amounts
        _addLiquidity(tickLower, tickUpper, amount0Available, amount1Available);
        
        // Record balances after adding liquidity
        uint256 balance0AfterLiquidity = token0.balanceOf(address(this));
        uint256 balance1AfterLiquidity = token1.balanceOf(address(this));
        
        // Calculate tokens used for liquidity and leftover tokens
        uint256 used0 = balance0BeforeLiquidity - balance0AfterLiquidity;
        uint256 used1 = balance1BeforeLiquidity - balance1AfterLiquidity;
        uint256 leftover0 = amount0Available > used0 ? amount0Available - used0 : 0;
        uint256 leftover1 = amount1Available > used1 ? amount1Available - used1 : 0;
        
        console.log("Used token0 for liquidity:", used0);
        console.log("Used token1 for liquidity:", used1);
        console.log("Leftover token0:", leftover0);
        console.log("Leftover token1:", leftover1);
        
        // Assert that leftover tokens are minimal (less than 1% of input)
        assertLt(leftover0, a0Desired / 10000, "Leftover token0 should be less than 0.01%");
        assertLt(leftover1, a1Desired / 10000, "Leftover token1 should be less than 0.01%");
    }

    /// @notice Test optimal swap calculation after adding liquidity
    function test_LiquidityCalculator_AfterAddingLiquidity() public {
        
        console.log("Initial tick:", TickMath.getTickAtSqrtPrice(SQRT_PRICE_1_0));

        // Add initial liquidity to the pool
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        // Verify liquidity was added
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0, "Liquidity should be greater than 0");
        

        // Now test optimal swap calculation with different amounts
        int24 tickLower = 1140;
        int24 tickUpper = 1200;

        // User wants to add more liquidity with different amounts
        uint256 amount0Desired = 5 ether;
        uint256 amount1Desired = 5 ether; // More token1 than token0
        
        // Calculate optimal swap using helper contract
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                amount0Desired,
                amount1Desired
            );
        
        // Verify swap calculation results
        assertGt(amountIn, 0, "Swap amount should be greater than 0");
        assertGt(amountOut, 0, "Output amount should be greater than 0");
        assertGt(sqrtPriceX96, 0, "Final sqrt price should be greater than 0");
        
        // Log results for debugging
        console.log("Initial liquidity:", liquidity);
        console.log("Amount in:", amountIn);
        console.log("Amount out:", amountOut);
        console.log("Zero for one:", zeroForOne);
        console.log("Final sqrt price:", sqrtPriceX96);
        console.log("Final tick:", TickMath.getTickAtSqrtPrice(sqrtPriceX96));
        
        // Execute swap, add liquidity, and verify minimal leftovers
        _executeSwapAndAddLiquidity(
            tickLower,
            tickUpper,
            amount0Desired,
            amount1Desired,
            amountIn,
            amountOut,
            zeroForOne
        );
    }

    /// @notice Test with zero amounts (both zero)
    function test_LiquidityCalculator_ZeroAmounts() public view {
        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                0,
                0
            );
        
        assertEq(amountIn, 0, "Amount in should be 0");
        assertEq(amountOut, 0, "Amount out should be 0");
        assertEq(sqrtPriceX96, 0, "Sqrt price should be 0");
    }

    /// @notice Test with only token0 amount
    function test_LiquidityCalculator_OnlyToken0() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (uint256 amountIn,, bool zeroForOne, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                10 ether,
                0
            );
        
        // Should swap token0 -> token1
        assertTrue(zeroForOne, "Should swap token0 to token1");
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with only token1 amount
    function test_LiquidityCalculator_OnlyToken1() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (uint256 amountIn,, bool zeroForOne, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                0,
                10 ether
            );
        
        // Should swap token1 -> token0
        assertFalse(zeroForOne, "Should swap token1 to token0");
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with price below range (should swap token1 -> token0)
    function test_LiquidityCalculator_PriceBelowRange() public {
        // Move price down by swapping token0 -> token1 (this decreases price)
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        _executeSwap(1000 ether, true); // Swap token0 -> token1 to lower price
        
        // Price should now be below the range we'll test
        // Price is below range, should swap token1 -> token0
        (uint256 amountIn,, bool zeroForOne, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                0,
                600,
                10 ether,
                10 ether
            );
        
        assertFalse(zeroForOne, "Should swap token1 to token0 when price below range");
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with price above range (should swap token0 -> token1)
    function test_LiquidityCalculator_PriceAboveRange() public {
        // Move price up by swapping token1 -> token0 (this increases price)
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        _executeSwap(1000 ether, false); // Swap token1 -> token0 to raise price
        
        // Price should now be above the range we'll test
        // Price is above range, should swap token0 -> token1
        (uint256 amountIn,, bool zeroForOne, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                0,
                10 ether,
                10 ether
            );

        assertTrue(zeroForOne, "Should swap token0 to token1 when price above range");
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with price in range
    function test_LiquidityCalculator_PriceInRange() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        // Price is in range, direction depends on amounts
        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                10 ether,
                5 ether
            );
        
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(amountOut, 0, "Should have swap output");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with empty pool (no initial liquidity): nothing to swap against, so the plan is
    ///         deterministically "no swap at the current price" (external audit V4LE-89; it used to
    ///         revert Math_Overflow out of the analytic solver).
    function test_LiquidityCalculator_EmptyPool() public view {
        // Don't add initial liquidity
        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) =
            helper.getOptimalSwap(poolCallee, -600, 600, 10 ether, 10 ether);
        assertEq(amountIn, 0, "no input without liquidity");
        assertEq(amountOut, 0, "no output without liquidity");
        assertEq(sqrtPriceX96, SQRT_PRICE_1_0, "price unchanged without liquidity");
    }

    /// @notice External audit V4LE-89: the sole in-range position is crossed at its upper tick by an
    ///         exact-limit swap, leaving the pool at that tick with ZERO active liquidity while the
    ///         position still exists. The same-pool planner for a replacement range around the new
    ///         tick, holding only token1 (what the crossed position is made of), used to revert
    ///         Math_Overflow - and the hook's caught AUTO_RANGE action consumed the trigger. It must
    ///         return a no-swap plan at the current price instead.
    function test_LiquidityCalculator_ZeroLiquidityAfterSolePositionBoundaryCrossing() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);

        // swap token1 -> token0 with the price limit exactly at the position's upper tick
        SwapParams memory swapParams =
            SwapParams({zeroForOne: false, amountSpecified: -int256(10_000 ether), sqrtPriceLimitX96: sqrtUpper});
        poolManager.unlock(abi.encode(SwapCallbackData(poolKey, swapParams, address(this))));
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, sqrtUpper, "precondition: price at the upper tick");
        assertEq(tick, 600, "precondition: upper tick crossed");
        assertEq(poolManager.getLiquidity(poolId), 0, "precondition: zero active liquidity");

        // centered replacement range around the new tick, one-sided token1 holdings
        (uint256 amountIn, uint256 amountOut, bool zeroForOne, uint160 planSqrtPrice) =
            helper.getOptimalSwap(poolCallee, 300, 900, 0, 500 ether);
        assertEq(amountIn, 0, "nothing to swap against");
        assertEq(amountOut, 0, "no output");
        assertFalse(zeroForOne, "direction of the one-sided token1 holdings");
        assertEq(planSqrtPrice, sqrtUpper, "current price returned");

        // the mirror: token0-only holdings plan a 0->1 swap that re-enters the crossed position's
        // liquidity, so the planner keeps producing a real swap there
        (amountIn,, zeroForOne,) = helper.getOptimalSwap(poolCallee, 300, 900, 500 ether, 0);
        assertTrue(zeroForOne);
        assertGt(amountIn, 0, "liquidity below the tick is still usable");
    }

    /// @notice Test with imbalanced amounts (much more token0)
    function test_LiquidityCalculator_ImbalancedAmounts_MoreToken0() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne,) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                100 ether,
                1 ether
            );
        
        // Should swap token0 -> token1
        assertTrue(zeroForOne, "Should swap token0 to token1 with imbalanced amounts");
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(amountOut, 0, "Should have swap output");
    }

    /// @notice Test with imbalanced amounts (much more token1)
    function test_LiquidityCalculator_ImbalancedAmounts_MoreToken1() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (uint256 amountIn, uint256 amountOut, bool zeroForOne,) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                1 ether,
                100 ether
            );
        
        // Should swap token1 -> token0
        assertFalse(zeroForOne, "Should swap token1 to token0 with imbalanced amounts");
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(amountOut, 0, "Should have swap output");
    }

    /// @notice Test with narrow tick range
    function test_LiquidityCalculator_NarrowRange() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        int24 tickLower = 0;
        int24 tickUpper = 60; // Very narrow range
        
        (uint256 amountIn,,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                10 ether,
                10 ether
            );
        
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");

        // Verify final price is within range
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        assertGe(sqrtPriceX96, sqrtLower, "Final price should be >= lower bound");
        assertLe(sqrtPriceX96, sqrtUpper, "Final price should be <= upper bound");
    }

    /// @notice Test with wide tick range
    function test_LiquidityCalculator_WideRange() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        int24 tickLower = -3000;
        int24 tickUpper = 3000; // Very wide range
        
        (uint256 amountIn,,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                tickLower,
                tickUpper,
                20 ether,
                10 ether
            );
        
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with very small amounts
    function test_LiquidityCalculator_SmallAmounts() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (,,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                1 wei,
                1 wei
            );
        
        // Should still calculate, but swap might be very small or zero
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with very large amounts
    function test_LiquidityCalculator_LargeAmounts() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (uint256 amountIn,,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                100000 ether,
                10000 ether
            );
        
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test error case: invalid tick range (lower >= upper)
    function test_LiquidityCalculator_InvalidTickRange_Reversed() public {
        vm.expectRevert();
        helper.getOptimalSwap(
            poolCallee,
            600,
            -600, // Lower > upper
            10 ether,
            10 ether
        );
    }

    /// @notice Test error case: invalid tick range (lower == upper)
    function test_LiquidityCalculator_InvalidTickRange_Equal() public {
        vm.expectRevert();
        helper.getOptimalSwap(
            poolCallee,
            0,
            0, // Lower == upper
            10 ether,
            10 ether
        );
    }

    /// @notice Test with multiple liquidity positions (crossing ticks)
    function test_LiquidityCalculator_CrossingTicks() public {
        // Add liquidity at different ranges to create multiple ticks
        _addLiquidity(-1200, -600, 500 ether, 500 ether);
        _addLiquidity(-600, 0, 500 ether, 500 ether);
        _addLiquidity(0, 600, 500 ether, 500 ether);
        _addLiquidity(600, 1200, 500 ether, 500 ether);
        
        // Test with range that will cross multiple ticks
        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -1200,
                1200,
                50000 ether,
                50 ether
            );
        
        assertGt(amountIn, 0, "Should have swap input");
        assertGt(amountOut, 0, "Should have swap output");
        assertGt(sqrtPriceX96, 0, "Should have final price");
    }

    /// @notice Test with price exactly at lower bound
    /// @notice V4LE-81: a pool with the maximum (100%) LP fee is a valid v4 pool. The same-pool
    ///         planner divided by (1 - fee) == 0 for an in-range position; it must reject the fee
    ///         deterministically like calculateSimple does.
    function test_LiquidityCalculator_RejectsHundredPercentFeePool() public {
        PoolKey memory fullFeeKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 1_000_000,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(fullFeeKey, SQRT_PRICE_1_0);
        // in-range liquidity so the analytic branch is reached
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] =
            abi.encode(fullFeeKey, int24(-600), int24(600), uint256(1e18), 1000 ether, 1000 ether, address(this), "");
        paramsArray[1] = abi.encode(fullFeeKey.currency0, fullFeeKey.currency1, address(positionManager));
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);

        ILiquidityCalculator.V4PoolInfo memory fullFeePool = ILiquidityCalculator.V4PoolInfo({
            poolMgr: poolManager,
            poolIdentifier: fullFeeKey.toId(),
            tickSpacing: DEFAULT_TICK_SPACING
        });
        vm.expectRevert(ILiquidityCalculator.Invalid_Fee.selector);
        helper.getOptimalSwap(fullFeePool, -600, 600, 10 ether, 1 ether);
    }

    function test_LiquidityCalculator_PriceAtLowerBound() public {
        int24 tickLower = -600;
        // Move price to lower bound by swapping
        _addLiquidity(tickLower, 600, 1000 ether, 1000 ether);
        // Swap to move price to lower bound (swap token0 -> token1 to lower price)
        _executeSwap(500 ether, true); // Swap token0 -> token1 to lower price
        
        (uint256 amountIn,, bool zeroForOne,) = 
            helper.getOptimalSwap(
                poolCallee,
                tickLower,
                600,
                10 ether,
                10 ether
            );
        
        // Should swap token1 -> token0 (price at lower bound, need more token0)
        assertFalse(zeroForOne, "Should swap token1 to token0 at lower bound");
        assertGt(amountIn, 0, "Should have swap input");
    }

    /// @notice Test with price exactly at upper bound
    function test_LiquidityCalculator_PriceAtUpperBound() public {
        int24 tickUpper = 600;
        // Move price to upper bound by swapping
        _addLiquidity(-600, tickUpper, 1000 ether, 1000 ether);
        // Swap to move price to upper bound (swap token1 -> token0 to raise price)
        _executeSwap(500 ether, false); // Swap token1 -> token0 to raise price
        
        (uint256 amountIn,, bool zeroForOne,) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                tickUpper,
                10 ether,
                10 ether
            );
        
        // Should swap token0 -> token1 (price at upper bound, need more token1)
        assertTrue(zeroForOne, "Should swap token0 to token1 at upper bound");
        assertGt(amountIn, 0, "Should have swap input");
    }

    /// @notice Test optimal swap with balanced amounts in range
    function test_LiquidityCalculator_BalancedAmountsInRange() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                10 ether,
                10 ether
            );
        
        // The balance root of an exactly balanced state is the current price up to the integer
        // precision of the solver's coefficients (~1e-21 relative), so the plan is dust at most.
        assertLt(amountIn, 10 ether / 1e12, "Should have no swap input beyond dust");
        assertLt(amountOut, 10 ether / 1e12, "Should have no swap output beyond dust");

        // Verify final price is reasonable
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);
        assertGe(sqrtPriceX96, sqrtLower, "Final price should be >= lower bound");
        assertLe(sqrtPriceX96, sqrtUpper, "Final price should be <= upper bound");
    }

    /// @notice Test that swap results are consistent
    function test_LiquidityCalculator_Consistency() public {
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);
        
        // Run calculation twice with same inputs
        (uint256 amountIn1, uint256 amountOut1, bool zeroForOne1, uint160 sqrtPrice1) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                10 ether,
                20 ether
            );
        
        (uint256 amountIn2, uint256 amountOut2, bool zeroForOne2, uint160 sqrtPrice2) = 
            helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                10 ether,
                20 ether
            );
        
        // Results should be identical
        assertEq(amountIn1, amountIn2, "Amount in should be consistent");
        assertEq(amountOut1, amountOut2, "Amount out should be consistent");
        assertEq(zeroForOne1, zeroForOne2, "Direction should be consistent");
        assertEq(sqrtPrice1, sqrtPrice2, "Final price should be consistent");
    }

    // ============ Tests for calculateSimple ============

    /// @notice Test calculateSimple with zero amounts
    function test_calculateSimple_ZeroAmounts() public view {
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                0,
                0,
                DEFAULT_FEE
            );
        
        assertEq(inputAmount, 0, "Input amount should be 0");
        assertEq(outputAmount, 0, "Output amount should be 0");
        assertFalse(swapDir0to1, "Direction should be false");
    }

    /// @notice Test calculateSimple with price below range
    function test_calculateSimple_PriceBelowRange() public view {
        uint160 sqrtPriceLow = TickMath.getSqrtPriceAtTick(-1200); // Price below range
        
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = 
            helper.getSimpleSwap(
                sqrtPriceLow,
                -600,
                600,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        // Should swap token1 -> token0 (all token1)
        assertFalse(swapDir0to1, "Should swap token1 to token0 when price below range");
        assertEq(inputAmount, 10 ether, "Should swap all token1");
        assertGt(outputAmount, 0, "Should have output amount");
    }

    /// @notice Test calculateSimple with price above range
    function test_calculateSimple_PriceAboveRange() public view {
        uint160 sqrtPriceHigh = TickMath.getSqrtPriceAtTick(1200); // Price above range
        
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = 
            helper.getSimpleSwap(
                sqrtPriceHigh,
                -600,
                600,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        // Should swap token0 -> token1 (all token0)
        assertTrue(swapDir0to1, "Should swap token0 to token1 when price above range");
        assertEq(inputAmount, 10 ether, "Should swap all token0");
        assertGt(outputAmount, 0, "Should have output amount");
    }

    /// @notice Test calculateSimple with price in range - balanced amounts
    function test_calculateSimple_PriceInRange_Balanced() public view {
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        // May or may not need swap depending on exact ratio
        assertGe(inputAmount, 0, "Input amount should be >= 0");
        assertGe(outputAmount, 0, "Output amount should be >= 0");
    }

    /// @notice Test calculateSimple with price in range - imbalanced amounts (more token0)
    function test_calculateSimple_PriceInRange_MoreToken0() public view {
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                100 ether,
                1 ether,
                DEFAULT_FEE
            );
        
        // Should swap token0 -> token1
        assertTrue(swapDir0to1, "Should swap token0 to token1 with imbalanced amounts");
        assertGt(inputAmount, 0, "Should have swap input");
        assertGt(outputAmount, 0, "Should have swap output");
    }

    /// @notice Test calculateSimple with price in range - imbalanced amounts (more token1)
    function test_calculateSimple_PriceInRange_MoreToken1() public view {
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                1 ether,
                100 ether,
                DEFAULT_FEE
            );
        
        // Should swap token1 -> token0
        assertFalse(swapDir0to1, "Should swap token1 to token0 with imbalanced amounts");
        assertGt(inputAmount, 0, "Should have swap input");
        assertGt(outputAmount, 0, "Should have swap output");
    }

    /// @notice Test calculateSimple with only token0
    function test_calculateSimple_OnlyToken0() public view {
        (uint256 inputAmount,, bool swapDir0to1) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                10 ether,
                0,
                DEFAULT_FEE
            );
        
        // Should swap token0 -> token1
        assertTrue(swapDir0to1, "Should swap token0 to token1");
        assertGt(inputAmount, 0, "Should have swap input");
    }

    /// @notice Test calculateSimple with only token1
    function test_calculateSimple_OnlyToken1() public view {
        (uint256 inputAmount,, bool swapDir0to1) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                0,
                10 ether,
                DEFAULT_FEE
            );
        
        // Should swap token1 -> token0
        assertFalse(swapDir0to1, "Should swap token1 to token0");
        assertGt(inputAmount, 0, "Should have swap input");
    }

    /// @notice Regression for the Base RevertHook WETH/USDC leverage failure.
    /// @dev The old external-route formula mixed sqrt-price ratios with token
    ///      amount ratios. With different token decimals it capped the swap at
    ///      the full USDC balance, leaving no token1 for liquidity and causing
    ///      Auto-Leverage to roll back with RestoreFailed().
    function test_calculateSimple_BaseWethUsdc_OnlyUsdcDoesNotSwapAll() public view {
        uint160 sqrtPrice = 3941941468696704008371436;
        uint256 usdcAmount = 8_624_832;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-210000);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(-190000);

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = helper.getSimpleSwap(
            sqrtPrice,
            -210000,
            -190000,
            0,
            usdcAmount,
            500
        );

        assertFalse(swapDir0to1, "USDC must swap to WETH");
        assertGt(inputAmount, 0, "some USDC must be swapped");
        assertLt(inputAmount, usdcAmount, "must retain USDC for two-sided liquidity");
        assertGt(outputAmount, 0, "swap must produce WETH");

        uint128 liquidityFromWeth = LiquidityAmounts.getLiquidityForAmount0(sqrtPrice, sqrtUpper, outputAmount);
        uint128 liquidityFromUsdc =
            LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtPrice, usdcAmount - inputAmount);
        uint256 liquidityDifference = liquidityFromWeth > liquidityFromUsdc
            ? liquidityFromWeth - liquidityFromUsdc
            : liquidityFromUsdc - liquidityFromWeth;
        assertLe(liquidityDifference * 10_000 / liquidityFromUsdc, 10, "post-swap amounts must be within 0.1%");
    }

    function test_calculateSimple_UsesExternalRoutePriceForSwapSizing() public view {
        uint160 positionSqrtPrice = SQRT_PRICE_1_0;
        uint160 routeSqrtPrice = TickMath.getSqrtPriceAtTick(100);
        uint256 amount1 = 100 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = helper.getSimpleSwapWithRoutePrice(
            positionSqrtPrice, routeSqrtPrice, -600, 600, 0, amount1, 0
        );

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);
        uint128 liquidityFromToken0 =
            LiquidityAmounts.getLiquidityForAmount0(positionSqrtPrice, sqrtUpper, outputAmount);
        uint128 liquidityFromToken1 =
            LiquidityAmounts.getLiquidityForAmount1(sqrtLower, positionSqrtPrice, amount1 - inputAmount);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;

        assertFalse(swapDir0to1, "token1-only input swaps token1 to token0");
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "route-priced result must be balanced");
    }

    function test_calculateSimple_UsesExternalRoutePriceForReverseSwapSizing() public view {
        uint160 positionSqrtPrice = SQRT_PRICE_1_0;
        uint160 routeSqrtPrice = TickMath.getSqrtPriceAtTick(-100);
        uint256 amount0 = 100 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = helper.getSimpleSwapWithRoutePrice(
            positionSqrtPrice, routeSqrtPrice, -600, 600, amount0, 0, 0
        );

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);
        uint128 liquidityFromToken0 =
            LiquidityAmounts.getLiquidityForAmount0(positionSqrtPrice, sqrtUpper, amount0 - inputAmount);
        uint128 liquidityFromToken1 =
            LiquidityAmounts.getLiquidityForAmount1(sqrtLower, positionSqrtPrice, outputAmount);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;

        assertTrue(swapDir0to1, "token0-only input swaps token0 to token1");
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "route-priced result must be balanced");
    }

    function test_calculateSimple_RejectsInvalidPoolPriceAndFee() public {
        vm.expectRevert(ILiquidityCalculator.Invalid_Pool.selector);
        liquidityCalculator.calculateSimple(SQRT_PRICE_1_0, 0, 1e18, -600, 600, 1 ether, 0, 3000, 0);

        vm.expectRevert(ILiquidityCalculator.Invalid_Fee.selector);
        liquidityCalculator.calculateSimple(
            SQRT_PRICE_1_0, SQRT_PRICE_1_0, 1e18, -600, 600, 1 ether, 0, 1_000_000, 0
        );

        vm.expectRevert(ILiquidityCalculator.Invalid_Fee.selector);
        liquidityCalculator.calculateSimple(
            SQRT_PRICE_1_0, SQRT_PRICE_1_0, 1e18, -600, 600, 1 ether, 0, 3000, 1_000_000
        );
    }

    /// @notice A route without active liquidity cannot deliver anything: no swap is planned.
    function test_calculateSimple_ZeroRouteLiquidityPlansNoSwap() public view {
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) =
            helper.getSimpleSwapWithRoute(SQRT_PRICE_1_0, SQRT_PRICE_1_0, 0, -600, 600, 10 ether, 0, 3000, 0);
        assertTrue(swapDir0to1, "direction still reported");
        assertEq(inputAmount, 0, "no input planned against an empty route");
        assertEq(outputAmount, 0, "no output planned against an empty route");
    }

    /// @notice V4LE-53: the finding's shape. Position pool at 1:1 with (0, 1000e18) for [-600, 600],
    ///         a full-range route holding ~1000e18 per side at 0.3%. Spot pricing planned ~500.75 in
    ///         for ~499.25 out, but the route only returns ~333 for that input, so the mint was short
    ///         a third of its token0 and the surplus token1 left as leftover. The plan must match
    ///         the route's real output and balance the position within 0.1%.
    function test_calculateSimple_ExternalRouteAccountsForDepth() public {
        _addLiquidity(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1000 ether, 1000 ether);
        (uint160 routeSqrtPrice,,,) = poolManager.getSlot0(poolId);
        uint128 routeLiquidity = poolManager.getLiquidity(poolId);
        uint256 amount1 = 1000 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = helper.getSimpleSwapWithRoute(
            SQRT_PRICE_1_0, routeSqrtPrice, routeLiquidity, -600, 600, 0, amount1, DEFAULT_FEE, 0
        );
        assertFalse(swapDir0to1, "token1-only input swaps token1 to token0");
        assertGt(inputAmount, 500 ether, "depth-aware plan swaps more than the spot plan (~500.75e18)");
        assertLt(outputAmount, 499 ether, "and expects less than the spot quote (~499.25e18)");

        // the route delivers what was planned
        BalanceDelta delta = _executeSwap(inputAmount, false);
        uint256 actualOut = uint256(int256(delta.amount0()));
        assertApproxEqRel(actualOut, outputAmount, 1e12, "planned output matches the route's real output");

        // and the post-swap amounts fund the range evenly
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);
        uint128 liquidityFromToken0 = LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_0, sqrtUpper, actualOut);
        uint128 liquidityFromToken1 =
            LiquidityAmounts.getLiquidityForAmount1(sqrtLower, SQRT_PRICE_1_0, amount1 - inputAmount);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "post-swap amounts within 0.1%");
    }

    /// @notice Same shape through the pool-reading overload (what the hook calls).
    function test_calculateSimple_PoolOverloadAccountsForDepth() public {
        _addLiquidity(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1000 ether, 1000 ether);
        uint256 amount1 = 1000 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 0, amount1, 0);
        assertFalse(swapDir0to1);
        BalanceDelta delta = _executeSwap(inputAmount, false);
        uint256 actualOut = uint256(int256(delta.amount0()));
        assertApproxEqRel(actualOut, outputAmount, 1e12, "planned output matches the route's real output");

        uint128 liquidityFromToken0 =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_0, TickMath.getSqrtPriceAtTick(600), actualOut);
        uint128 liquidityFromToken1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(-600), SQRT_PRICE_1_0, amount1 - inputAmount
        );
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "post-swap amounts within 0.1%");
    }

    /// @notice A route whose liquidity is thin at the current tick and thick beyond it (a hole
    ///         around the price, as low-TVL pools have after the price left the main positions).
    ///         The constant-liquidity model alone would price the whole swap against the thin
    ///         book; the tick walk picks up the thick liquidity once the first tick is crossed
    ///         and the plan matches the pool's real output.
    function test_calculateSimple_PoolOverloadWalksThroughLiquidityHole() public {
        _addLiquidity(-60, 60, 1 ether, 1 ether); // thin around the price
        _addLiquidity(-6000, -60, 0, 5000 ether); // thick below
        _addLiquidity(60, 6000, 5000 ether, 0); // thick above
        uint256 amount0 = 300 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, amount0, 0, 0);
        assertTrue(swapDir0to1);
        assertGt(inputAmount, 100 ether, "a thin-book-only plan would swap almost nothing");
        BalanceDelta delta = _executeSwap(inputAmount, true);
        uint256 actualOut = uint256(int256(delta.amount1()));
        assertApproxEqRel(actualOut, outputAmount, 1e12, "planned output matches the real multi-tick output");

        uint128 liquidityFromToken0 = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_0, TickMath.getSqrtPriceAtTick(600), amount0 - inputAmount
        );
        uint128 liquidityFromToken1 =
            LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(-600), SQRT_PRICE_1_0, actualOut);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 50, "post-swap amounts within 0.5%");
    }

    /// @notice The same route, below range: all token1 is swapped and the output is the route's
    ///         real output for that input, not the spot quote.
    function test_calculateSimple_BelowRangeUsesRouteDepth() public {
        _addLiquidity(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1000 ether, 1000 ether);
        (uint160 routeSqrtPrice,,,) = poolManager.getSlot0(poolId);
        uint128 routeLiquidity = poolManager.getLiquidity(poolId);
        uint160 positionSqrtPrice = TickMath.getSqrtPriceAtTick(-1200);

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = helper.getSimpleSwapWithRoute(
            positionSqrtPrice, routeSqrtPrice, routeLiquidity, -600, 600, 0, 300 ether, DEFAULT_FEE, 0
        );
        assertFalse(swapDir0to1);
        assertEq(inputAmount, 300 ether, "all token1 is swapped below range");
        BalanceDelta delta = _executeSwap(inputAmount, false);
        assertApproxEqRel(uint256(int256(delta.amount0())), outputAmount, 1e12, "output is the route's real output");
    }

    /// @notice V4LE-21: an output fee the caller takes before minting is planned for, so the net
    ///         output funds the range evenly instead of leaving the input side over-supplied.
    function test_calculateSimple_OutputFeeIsPlannedFor() public view {
        uint24 outputFeePips = 100_000; // 10%, the hook's maximum swap fee
        (uint256 inputNoFee, uint256 outputNoFee,) = helper.getSimpleSwapWithRoute(
            SQRT_PRICE_1_0, SQRT_PRICE_1_0, 1_000_000 ether, -600, 600, 100 ether, 0, 0, 0
        );
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = helper.getSimpleSwapWithRoute(
            SQRT_PRICE_1_0, SQRT_PRICE_1_0, 1_000_000 ether, -600, 600, 100 ether, 0, 0, outputFeePips
        );
        assertTrue(swapDir0to1);
        assertGt(inputAmount, inputNoFee, "more input is swapped to make up for the fee");
        assertLt(outputAmount, outputNoFee, "net output is what reaches the mint");

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);
        uint128 liquidityFromToken0 =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_0, sqrtUpper, 100 ether - inputAmount);
        uint128 liquidityFromToken1 = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, SQRT_PRICE_1_0, outputAmount);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "net-of-fee amounts within 0.1%");
    }

    function test_calculateSimple_BelowRangeUsesSpotPrice() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(-1200);
        uint256 amount1 = 10 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) =
            helper.getSimpleSwap(sqrtPrice, -600, 600, 0, amount1, 0);

        uint256 expectedOutput = amount1 * SQRT_PRICE_1_0 / uint256(sqrtPrice) * SQRT_PRICE_1_0
            / uint256(sqrtPrice);
        assertFalse(swapDir0to1, "below range swaps token1 to token0");
        assertEq(inputAmount, amount1, "all token1 is swapped below range");
        assertApproxEqRel(outputAmount, expectedOutput, 1e9, "output must use spot price, not lower boundary");
    }

    function test_calculateSimple_AboveRangeUsesSpotPrice() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(1200);
        uint256 amount0 = 10 ether;

        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) =
            helper.getSimpleSwap(sqrtPrice, -600, 600, amount0, 0, 0);

        uint256 expectedOutput = amount0 * uint256(sqrtPrice) / SQRT_PRICE_1_0 * uint256(sqrtPrice)
            / SQRT_PRICE_1_0;
        assertTrue(swapDir0to1, "above range swaps token0 to token1");
        assertEq(inputAmount, amount0, "all token0 is swapped above range");
        assertApproxEqRel(outputAmount, expectedOutput, 1e9, "output must use spot price, not upper boundary");
    }

    /// @notice Test calculateSimple with different fee rates
    function test_calculateSimple_DifferentFeeRates() public view {
        uint24 feeRate1 = 100; // 0.01%
        uint24 feeRate2 = 10000; // 1%
        
        (uint256 inputAmount1, uint256 outputAmount1,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                10 ether,
                5 ether,
                feeRate1
            );
        
        (uint256 inputAmount2, uint256 outputAmount2,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                10 ether,
                5 ether,
                feeRate2
            );
        
        // Higher fee should result in less output for same input
        if (inputAmount1 > 0 && inputAmount2 > 0) {
            // With higher fee, output should be less (or input should be more for same output)
            assertTrue(
                outputAmount1 > outputAmount2 || inputAmount1 <= inputAmount2,
                "Fee rate should affect swap amounts"
            );
        }
    }

    /// @notice Test calculateSimple with narrow range
    function test_calculateSimple_NarrowRange() public view {
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                0,
                60,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        assertGe(inputAmount, 0, "Should have valid input amount");
        assertGe(outputAmount, 0, "Should have valid output amount");
    }

    /// @notice Test calculateSimple with wide range
    function test_calculateSimple_WideRange() public view {
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -3000,
                3000,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        assertGe(inputAmount, 0, "Should have valid input amount");
        assertGe(outputAmount, 0, "Should have valid output amount");
    }

    /// @notice Test calculateSimple error case: invalid tick range (lower >= upper)
    function test_calculateSimple_InvalidTickRange_Reversed() public {
        vm.expectRevert();
        helper.getSimpleSwap(
            SQRT_PRICE_1_0,
            600,
            -600,
            10 ether,
            10 ether,
            DEFAULT_FEE
        );
    }

    /// @notice Test calculateSimple error case: invalid tick range (lower == upper)
    function test_calculateSimple_InvalidTickRange_Equal() public {
        vm.expectRevert();
        helper.getSimpleSwap(
            SQRT_PRICE_1_0,
            0,
            0,
            10 ether,
            10 ether,
            DEFAULT_FEE
        );
    }

    /// @notice Test calculateSimple with price exactly at lower bound
    function test_calculateSimple_PriceAtLowerBound() public view {
        int24 tickLower = -600;
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        
        (uint256 inputAmount,, bool swapDir0to1) = 
            helper.getSimpleSwap(
                sqrtPriceLower,
                tickLower,
                600,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        // Should swap token1 -> token0 (price at lower bound, need more token0)
        assertFalse(swapDir0to1, "Should swap token1 to token0 at lower bound");
        assertGt(inputAmount, 0, "Should have swap input");
    }

    /// @notice Test calculateSimple with price exactly at upper bound
    function test_calculateSimple_PriceAtUpperBound() public view {
        int24 tickUpper = 600;
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        
        (uint256 inputAmount,, bool swapDir0to1) = 
            helper.getSimpleSwap(
                sqrtPriceUpper,
                -600,
                tickUpper,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        // Should swap token0 -> token1 (price at upper bound, need more token1)
        assertTrue(swapDir0to1, "Should swap token0 to token1 at upper bound");
        assertGt(inputAmount, 0, "Should have swap input");
    }

    /// @notice Test calculateSimple consistency - same inputs produce same outputs
    function test_calculateSimple_Consistency() public view {
        (uint256 inputAmount1, uint256 outputAmount1, bool swapDir0to1_1) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        (uint256 inputAmount2, uint256 outputAmount2, bool swapDir0to1_2) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                10 ether,
                10 ether,
                DEFAULT_FEE
            );
        
        assertEq(inputAmount1, inputAmount2, "Input amount should be consistent");
        assertEq(outputAmount1, outputAmount2, "Output amount should be consistent");
        assertEq(swapDir0to1_1, swapDir0to1_2, "Direction should be consistent");
    }

    /// @notice Test calculateSimple with very small amounts
    function test_calculateSimple_SmallAmounts() public view {
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                1 wei,
                1 wei,
                DEFAULT_FEE
            );
        
        assertGe(inputAmount, 0, "Should handle small amounts");
        assertGe(outputAmount, 0, "Should handle small amounts");
    }

    /// @notice Test calculateSimple with very large amounts
    function test_calculateSimple_LargeAmounts() public view {
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                100000 ether,
                100000 ether,
                DEFAULT_FEE
            );
        
        assertGe(inputAmount, 0, "Should handle large amounts");
        assertGe(outputAmount, 0, "Should handle large amounts");
    }

    /// @notice Test calculateSimple - no swap needed when amounts are already optimal
    function test_calculateSimple_NoSwapNeeded() public view {
        // When amounts are already in perfect ratio, no swap should be needed
        // This is hard to test exactly, but we can test that the function doesn't revert
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                SQRT_PRICE_1_0,
                -600,
                600,
                5 ether,
                5 ether,
                DEFAULT_FEE
            );
        
        // Either no swap needed (both zero) or small swap needed
        assertGe(inputAmount, 0, "Input amount should be valid");
        assertGe(outputAmount, 0, "Output amount should be valid");
    }

    /// @notice Test calculateSimple with price below range and zero token1
    function test_calculateSimple_PriceBelowRange_ZeroToken1() public view {
        uint160 sqrtPriceLow = TickMath.getSqrtPriceAtTick(-1200);
        
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                sqrtPriceLow,
                -600,
                600,
                10 ether,
                0,
                DEFAULT_FEE
            );
        
        // No swap needed if no token1
        assertEq(inputAmount, 0, "Should have no swap input when token1 is zero");
        assertEq(outputAmount, 0, "Should have no swap output");
    }

    /// @notice Test calculateSimple with price above range and zero token0
    function test_calculateSimple_PriceAboveRange_ZeroToken0() public view {
        uint160 sqrtPriceHigh = TickMath.getSqrtPriceAtTick(1200);
        
        (uint256 inputAmount, uint256 outputAmount,) = 
            helper.getSimpleSwap(
                sqrtPriceHigh,
                -600,
                600,
                0,
                10 ether,
                DEFAULT_FEE
            );
        
        // No swap needed if no token0
        assertEq(inputAmount, 0, "Should have no swap input when token0 is zero");
        assertEq(outputAmount, 0, "Should have no swap output");
    }

    /// @notice Test calculateSimple with specific values and detailed output
    /// @dev This test verifies actual calculated values and logs them for inspection
    function test_calculateSimple_DetailedOutput() public view {
        // Test with price in range and imbalanced amounts
        uint160 sqrtPrice = SQRT_PRICE_1_0; // Price = 1.0
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 amount0 = 100 ether;
        uint256 amount1 = 10 ether;
        uint24 feeRate = 0; // no fee
        
        // Calculate expected sqrt prices
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        
        console.log("=== calculateSimple Detailed Test ===");
        console.log("Sqrt Price:", sqrtPrice);
        console.log("Sqrt Lower:", sqrtLower);
        console.log("Sqrt Upper:", sqrtUpper);
        console.log("Amount0:", amount0);
        console.log("Amount1:", amount1);
        console.log("Fee Rate:", feeRate);
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        
        (uint256 inputAmount, uint256 outputAmount, bool swapDir0to1) = 
            helper.getSimpleSwap(
                sqrtPrice,
                tickLower,
                tickUpper,
                amount0,
                amount1,
                feeRate
            );
        
        console.log("--- Results ---");
        console.log("Input Amount:", inputAmount);
        console.log("Output Amount:", outputAmount);
        console.log("Swap Direction (0->1):", swapDir0to1);
        
        // Verify we're swapping token0 -> token1 (since we have much more token0)
        assertTrue(swapDir0to1, "Should swap token0 to token1");
        
        // Input amount should be less than or equal to available amount0
        assertLe(inputAmount, amount0, "Input amount should not exceed available token0");
        
        // Output amount should be positive if input is positive
        if (inputAmount > 0) {
            assertGt(outputAmount, 0, "Output amount should be positive when input is positive");
            
            // External-route output is valued at the route's current price, not
            // at a position boundary. At price 1, zero fee and the helper's deep
            // route it is one token1 unit per token0 unit up to the route's
            // (negligible) price impact.
            uint256 expectedOutputApprox = inputAmount;
            console.log("Expected Output (approx):", expectedOutputApprox);
            assertApproxEqRel(outputAmount, expectedOutputApprox, 1e9, "Output should be close to expected");
        }
        
        // Verify amounts after swap would be more balanced
        uint256 amount0After = amount0 - inputAmount;
        uint256 amount1After = amount1 + outputAmount;
        
        console.log("--- After Swap (simulated) ---");
        console.log("Amount0 After:", amount0After);
        console.log("Amount1 After:", amount1After);
        console.log("Ratio After (amount0/amount1):", amount1After > 0 ? amount0After * 1e18 / amount1After : 0);
        
        // The ratio should be more balanced after swap
        if (amount1After > 0) {
            uint256 ratioAfter = amount0After * 1e18 / amount1After;
            uint256 ratioBefore = amount1 > 0 ? amount0 * 1e18 / amount1 : type(uint256).max;
            
            console.log("Ratio Before:", ratioBefore);
            console.log("Ratio After:", ratioAfter);
            
            // Ratio should be closer to 1:1 after swap (more balanced)
            // Since we had 10:1 ratio before, after swap it should be closer to balanced
            assertLt(ratioAfter, ratioBefore, "Ratio should be more balanced after swap");
        }
    }

    // ==================== Zero-fee exact-boundary states (external audit V4LE-85) ====================
    // With a zero total fee and the live price exactly at a requested range bound, the solver's
    // coefficient guards used to reject the state as invalid (strict `a > amount0Target` /
    // `c > amount1Target`) although it is a valid, exactly balanced boundary: the pool accepts fee 0
    // and any initialized tick is a normal post-swap price. The planner must return a real plan.

    /// @dev Executes the planned swap and asserts the resulting holdings fit the range with a
    ///      negligible one-sided leftover, i.e. the plan was the balancing swap.
    function _assertPlanBalancesHoldings(
        int24 lower,
        int24 upper,
        uint256 amount0,
        uint256 amount1,
        uint256 amountIn,
        uint256 predictedOut,
        bool dir0to1
    ) internal {
        BalanceDelta delta = _executeSwap(amountIn, dir0to1);
        uint256 actualOut = dir0to1 ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        assertApproxEqRel(actualOut, predictedOut, PREDICTION_TOLERANCE, "executed output deviates from prediction");
        uint256 have0 = dir0to1 ? amount0 - amountIn : amount0 + actualOut;
        uint256 have1 = dir0to1 ? amount1 + actualOut : amount1 - amountIn;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, have0, have1);
        (uint256 used0, uint256 used1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
        // prices sit at ~1:1 in these scenarios, so summing the two tokens' leftovers is fair
        assertLt((have0 - used0) + (have1 - used1), (have0 + have1) / 1000, "leftover above 0.1%");
    }

    /// @notice Price exactly at the requested LOWER bound of a zero-fee pool, holding token1: the
    ///         1->0 solver's `c == amount1Target` equality used to revert Math_Overflow.
    function test_calculateSamePool_ZeroFee_PriceAtLowerBound_SwapsToken1() public {
        _usePoolAtTick(0, 0);
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);

        (uint256 amountIn, uint256 amountOut, bool dir0to1,) = helper.getOptimalSwap(poolCallee, 0, 60, 0, 1 ether);
        assertFalse(dir0to1, "token1 -> token0 into the range");
        assertGt(amountIn, 0, "a real balancing swap is planned");
        _assertPlanBalancesHoldings(0, 60, 0, 1 ether, amountIn, amountOut, false);
    }

    /// @notice Same state with token0 only: already balanced (the range is all token0 at its lower
    ///         bound), so the plan is deterministically "no swap" instead of a revert.
    function test_calculateSamePool_ZeroFee_PriceAtLowerBound_Token0OnlyNoSwap() public {
        _usePoolAtTick(0, 0);
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);

        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) =
            helper.getOptimalSwap(poolCallee, 0, 60, 1 ether, 0);
        assertEq(amountIn, 0, "nothing to swap");
        assertEq(amountOut, 0);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_0, "current price");
    }

    /// @notice Price exactly at the requested UPPER bound of a zero-fee pool, holding token0: the
    ///         0->1 solver's `a == amount0Target` equality used to revert Math_Overflow.
    function test_calculateSamePool_ZeroFee_PriceAtUpperBound_SwapsToken0() public {
        _usePoolAtTick(0, 0);
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);

        (uint256 amountIn, uint256 amountOut, bool dir0to1,) = helper.getOptimalSwap(poolCallee, -60, 0, 1 ether, 0);
        assertTrue(dir0to1, "token0 -> token1 into the range");
        assertGt(amountIn, 0, "a real balancing swap is planned");
        _assertPlanBalancesHoldings(-60, 0, 1 ether, 0, amountIn, amountOut, true);
    }

    /// @notice Same state with token1 only: already balanced, no swap.
    function test_calculateSamePool_ZeroFee_PriceAtUpperBound_Token1OnlyNoSwap() public {
        _usePoolAtTick(0, 0);
        _addLiquidity(-600, 600, 1000 ether, 1000 ether);

        (uint256 amountIn, uint256 amountOut,, uint160 sqrtPriceX96) =
            helper.getOptimalSwap(poolCallee, -60, 0, 0, 1 ether);
        assertEq(amountIn, 0, "nothing to swap");
        assertEq(amountOut, 0);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_0, "current price");
    }

    // ==================== Discriminant overflow (external audit V4LE-33) ====================

    /// @dev The audit's state: tick spacing 60, price at tick 400000, ~0.3% fee (2500 pips here so
    ///      the key differs from the default 3000-pip pool), active liquidity 2e30 from the range
    ///      [396480, 404040] (its token1 requirement ~1.56e38 fits int128).
    function _setUpHighTickHeavyLiquidityPool() internal {
        _usePoolAtTick(2500, 400000);
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);
        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            poolKey, int24(396480), int24(404040), uint256(2e30), type(uint128).max, type(uint128).max, address(this), ""
        );
        paramsArray[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(positionManager));
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
        assertEq(poolManager.getLiquidity(poolId), 2e30, "precondition: active liquidity");
    }

    /// @notice For a valid but extreme same-pool state the quadratic's b*b wrapped modulo 2^256 in
    ///         unchecked arithmetic and the planner returned a plausible but WRONG plan (input,
    ///         output and final price for a price outside the requested range). The discriminant is
    ///         now checked: the state reverts Math_Overflow instead of misplanning.
    function test_calculateSamePool_RevertsOnDiscriminantOverflowInsteadOfWrapping() public {
        _setUpHighTickHeavyLiquidityPool();
        vm.expectRevert(ILiquidityCalculator.Math_Overflow.selector);
        helper.getOptimalSwap(poolCallee, 399720, 400320, 1e30, 1e12);
    }

    /// @notice The same pool with a smaller token0 target keeps a 218-bit discriminant and plans a
    ///         normal swap: the check only fires where the arithmetic really overflows.
    function test_calculateSamePool_LargeButFittingDiscriminantStillPlans() public {
        _setUpHighTickHeavyLiquidityPool();
        (uint256 amountIn, uint256 amountOut, bool dir0to1, uint160 sqrtPriceX96) =
            helper.getOptimalSwap(poolCallee, 399720, 400320, 1e24, 1e12);
        assertTrue(dir0to1, "token0 -> token1");
        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
        assertGe(sqrtPriceX96, TickMath.getSqrtPriceAtTick(399720), "final price inside the requested range");
        assertLe(sqrtPriceX96, TickMath.getSqrtPriceAtTick(400000), "final price does not exceed the current price");
    }

    // ==================== Tick bitmap search regressions (M-04) ====================
    // `_locateNextTick` has to see every initialized tick on the simulated swap path: ticks in the
    // current bitmap word in both directions and every bit of the neighbouring words, including
    // bit 0 and bit 255. Each scenario builds a pool whose liquidity changes at a specific tick,
    // asks calculateSamePool for the optimal swap, executes exactly that swap and compares the
    // executed output and final price with the prediction. A missed tick makes the planner
    // simulate the wrong liquidity and mis-predict by double-digit percentages.

    uint256 constant PREDICTION_TOLERANCE = 1e15; // 0.1%

    /// @dev Re-points the harness at a fresh pool (same tokens and tick spacing, different fee)
    ///      initialized at `initTick`, so scenarios can start away from tick 0.
    function _usePoolAtTick(uint24 fee, int24 initTick) internal {
        _usePool(fee, DEFAULT_TICK_SPACING, initTick);
    }

    /// @dev Same, with the pool's own tick spacing.
    function _usePool(uint24 fee, int24 tickSpacing, int24 initTick) internal {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(initTick));
        poolCallee = ILiquidityCalculator.V4PoolInfo({
            poolMgr: poolManager,
            poolIdentifier: poolId,
            tickSpacing: tickSpacing
        });
    }

    /// @dev Mints exactly `liquidity` into [lower, upper] of the current pool.
    function _mintLiquidity(int24 lower, int24 upper, uint128 liquidity) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            poolKey, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, address(this), ""
        );
        paramsArray[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(positionManager));
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
    }

    /// @dev Predicts the optimal swap for a deposit, executes it and asserts the prediction held.
    ///      `mustPassTick` is an initialized tick the executed swap has to cross, proving the
    ///      scenario exercised the bitmap search for that tick.
    function _assertPredictionMatchesExecution(
        int24 lower,
        int24 upper,
        uint256 amount0,
        uint256 amount1,
        bool expectDir0to1,
        int24 mustPassTick
    ) internal {
        (uint256 amountIn, uint256 predictedOut, bool dir0to1, uint160 predictedSqrtPrice) =
            helper.getOptimalSwap(poolCallee, lower, upper, amount0, amount1);
        assertEq(dir0to1, expectDir0to1, "unexpected swap direction");
        assertGt(amountIn, 0, "expected a swap");

        BalanceDelta delta = _executeSwap(amountIn, dir0to1);
        uint256 actualOut = dir0to1 ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);

        if (dir0to1) {
            assertLt(tickAfter, mustPassTick, "swap did not cross the target tick");
        } else {
            assertGe(tickAfter, mustPassTick, "swap did not cross the target tick");
        }
        console.log("Predicted output:", predictedOut);
        console.log("Executed output: ", actualOut);
        assertApproxEqRel(actualOut, predictedOut, PREDICTION_TOLERANCE, "executed output deviates from prediction");
        assertApproxEqRel(
            sqrtPriceAfter, predictedSqrtPrice, PREDICTION_TOLERANCE, "final price deviates from prediction"
        );
    }

    /// @notice 1->0 swap from tick 0 with the liquidity step at 600/1200, inside the current word
    function test_calculateSamePool_rightSearchSeesTicksInCurrentWord() public {
        _addLiquidity(-1200, 1200, 10 ether, 10 ether);
        _addLiquidity(600, 1200, 100 ether, 0);
        _assertPredictionMatchesExecution(-1200, 1200, 0, 100 ether, false, 600);
    }

    /// @notice 0->1 swap from tick 7200 with the liquidity step at 6600/6000, inside the current word
    function test_calculateSamePool_leftSearchSeesTicksInCurrentWord() public {
        _usePoolAtTick(500, 7200);
        _addLiquidity(-30720, 30720, 10 ether, 10 ether);
        _addLiquidity(6000, 6600, 0, 1000 ether);
        _assertPredictionMatchesExecution(-30720, 30720, 100 ether, 0, true, 6600);
    }

    /// @notice 0->1 swap from tick 0; word 0 is empty, the liquidity step at -600/-1200 is in word -1
    function test_calculateSamePool_leftSearchSeesTicksInPreviousWord() public {
        _addLiquidity(-30720, 30720, 10 ether, 10 ether);
        _addLiquidity(-1200, -600, 0, 1000 ether);
        _assertPredictionMatchesExecution(-30720, 30720, 100 ether, 0, true, -600);
    }

    /// @notice 1->0 swap from tick 0; word 0 is empty, the liquidity step at 15420/16020 is in word 1
    function test_calculateSamePool_rightSearchSeesTicksInNextWord() public {
        _addLiquidity(-30720, 30720, 10 ether, 10 ether);
        _addLiquidity(15420, 16020, 1000 ether, 0); // word 1, bits 1 and 11
        _assertPredictionMatchesExecution(-30720, 30720, 0, 100 ether, false, 15420);
    }

    /// @notice 0->1 swap crossing bit 255 (-60) and bit 0 (-15360) of word -1
    function test_calculateSamePool_leftSearchSeesWordBoundaryBits() public {
        _addLiquidity(-46080, 46080, 10 ether, 10 ether); // words -3 / 3, bit 0
        _addLiquidity(-15360, 15360, 10 ether, 10 ether); // words -1 / 1, bit 0
        _addLiquidity(-60, 30660, 10 ether, 10 ether); // words -1 / 1, bit 255
        _assertPredictionMatchesExecution(-46080, 46080, 180 ether, 0, true, -15360);
    }

    /// @notice 1->0 swap crossing bit 0 (15360) and bit 255 (30660) of word 1
    function test_calculateSamePool_rightSearchSeesWordBoundaryBits() public {
        _addLiquidity(-46080, 46080, 10 ether, 10 ether); // words -3 / 3, bit 0
        _addLiquidity(-15360, 15360, 10 ether, 10 ether); // words -1 / 1, bit 0
        _addLiquidity(-60, 30660, 10 ether, 10 ether); // words -1 / 1, bit 255
        _assertPredictionMatchesExecution(-46080, 46080, 0, 1400 ether, false, 30660);
    }

    // ==================== External audit scan #2 (2026-09) ====================

    /// @notice V4LE-140: a route with the maximum tick spacing (32767) and one position over
    ///         [-32767, 32767]. Once a 1->0 quote crosses +32767 nothing lies ahead; the empty-word
    ///         walk used to form the far-edge tick in int24, wrap 25599 * 32767 to -58367 (inside
    ///         the domain) and walk back through the same position, quoting its token0 again. The
    ///         plan must stop at the route's real depth and its output must be what the pool pays.
    function testV4LE140_MaxTickSpacingWalkStopsAtTheDomainBound() public {
        _usePool(3000, TickMath.MAX_TICK_SPACING, 0);
        _mintLiquidity(-32767, 32767, 1e18);
        uint256 amount1 = 100 ether;
        uint256 routeToken0 =
            SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_0, TickMath.getSqrtPriceAtTick(32767), 1e18, false);

        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 0, amount1, 0);
        assertFalse(dir0to1, "token1 is swapped for the token0 the range needs");
        assertLe(outputAmount, routeToken0, "the route cannot deliver more token0 than it holds");
        assertLt(inputAmount, amount1, "the plan stops where the route's liquidity ends");
        BalanceDelta delta = _executeSwap(inputAmount, false);
        assertApproxEqRel(
            uint256(int256(delta.amount0())), outputAmount, PREDICTION_TOLERANCE, "executed output deviates from plan"
        );
    }

    /// @dev A zero-fee pool at tick 0 whose liquidity above the price is `count` consecutive
    ///      one-spacing positions [60i, 60i + 60] of 1e18 each: a 1->0 walk crosses one initialized
    ///      tick per 60 ticks of price movement, so a large swap crosses more ticks than one quote
    ///      steps (MAX_ROUTE_QUOTE_CROSSINGS = 64).
    function _setUpDenselyTickedPool(uint256 count) internal {
        _usePoolAtTick(0, 0);
        for (uint256 i; i < count; ++i) {
            int24 lower = int24(int256(60 * i));
            _mintLiquidity(lower, lower + 60, 1e18);
        }
    }

    /// @notice V4LE-124: a route with no active liquidity at its price but an initialized position
    ///         [60, 6000] ahead of a 1->0 swap (and [-6000, -60] ahead of a 0->1 swap). Pool.swap
    ///         crosses the gap for free and buys from that position; the planner returned no swap
    ///         and the action minted from unbalanced holdings. The plan must be the balancing swap
    ///         through the gap, and executing it must pay what was planned.
    function testV4LE124_ZeroActiveLiquidityWithInitializedTicksAheadPlans() public {
        _addLiquidity(60, 6000, 5000 ether, 0);
        assertEq(poolManager.getLiquidity(poolId), 0, "precondition: no active liquidity at the price");

        // 1->0 through the gap above the price
        uint256 amount1 = 100 ether;
        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 0, amount1, 0);
        assertFalse(dir0to1);
        assertGt(inputAmount, 0, "the route's liquidity beyond the gap is planned against");
        BalanceDelta delta = _executeSwap(inputAmount, false);
        uint256 actualOut = uint256(int256(delta.amount0()));
        assertApproxEqRel(actualOut, outputAmount, 1e12, "planned output matches the route's real output");
        uint128 liquidityFromToken0 =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_0, TickMath.getSqrtPriceAtTick(600), actualOut);
        uint128 liquidityFromToken1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(-600), SQRT_PRICE_1_0, amount1 - inputAmount
        );
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "post-swap amounts within 0.1%");

        // 0->1 through the gap below the price of a fresh route holding only [-6000, -60]
        _usePoolAtTick(500, 0);
        _addLiquidity(-6000, -60, 0, 5000 ether);
        assertEq(poolManager.getLiquidity(poolId), 0, "precondition: no active liquidity at the price");
        (inputAmount, outputAmount, dir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 100 ether, 0, 0);
        assertTrue(dir0to1);
        assertGt(inputAmount, 0);
        delta = _executeSwap(inputAmount, true);
        assertApproxEqRel(uint256(int256(delta.amount1())), outputAmount, 1e12, "0->1 output matches");
    }

    /// @notice V4LE-124: a route whose only initialized liquidity lies behind the swap direction
    ///         still plans no swap (nothing ahead can be bought).
    function testV4LE124_ZeroActiveLiquidityWithNothingAheadPlansNoSwap() public view {
        // the default pool has no positions at all
        (uint256 inputAmount, uint256 outputAmount,) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 0, 100 ether, 0);
        assertEq(inputAmount, 0);
        assertEq(outputAmount, 0);
    }

    /// @notice V4LE-128: a hookless zero-fee route at 1:1 whose liquidity drops from 10e18 to 1e14 at
    ///         tick -480, position range [-600, 600] holding (1e18, 0). The constant-liquidity start
    ///         plus two effective-price re-solves linearized the route and returned ~0.7424e18
    ///         while the exact balance root is ~0.7628e18 (~2% of the principal left unbalanced).
    ///         The plan must be the root: executing it leaves the holdings balanced for the range.
    function testV4LE128_ExternalRoutePlanConvergesAcrossLiquidityDrop() public {
        _usePoolAtTick(0, 0);
        _mintLiquidity(-480, 480, 10e18);
        _mintLiquidity(TickMath.minUsableTick(60), -480, 1e14);
        uint256 amount0 = 1e18;

        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, amount0, 0, 0);
        assertTrue(dir0to1);
        assertApproxEqRel(inputAmount, 0.762771e18, 1e15, "plan is the exact balance root (finding: 0.762771e18)");

        BalanceDelta delta = _executeSwap(inputAmount, true);
        uint256 actualOut = uint256(int256(delta.amount1()));
        assertApproxEqRel(actualOut, outputAmount, 1e12, "planned output matches the route's real output");
        uint128 liquidityFromToken0 = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_0, TickMath.getSqrtPriceAtTick(600), amount0 - inputAmount
        );
        uint128 liquidityFromToken1 =
            LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(-600), SQRT_PRICE_1_0, actualOut);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "post-swap amounts within 0.1%");
    }

    /// @notice V4LE-95: a one-sided external-route plan (position below its range, all token1 to
    ///         swap) through a route with more initialized ticks in the path than one quote steps.
    ///         The quote stops early; the plan used to keep the full input and feed the partial
    ///         output into an effective price. It is now capped at the input the quote consumed,
    ///         so executing it pays exactly the planned output.
    function testV4LE95_TruncatedOneSidedQuoteCapsThePlanAtTheQuotedInput() public {
        _setUpDenselyTickedPool(70);
        uint160 positionSqrtPrice = TickMath.getSqrtPriceAtTick(-1200);
        uint256 amount1 = 10 ether;

        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwapThroughPool(positionSqrtPrice, poolCallee, -600, 600, 0, amount1, 0);
        assertFalse(dir0to1);
        assertGt(inputAmount, 0);
        assertLt(inputAmount, amount1, "the plan is capped at what the quote consumed");

        BalanceDelta delta = _executeSwap(inputAmount, false);
        assertApproxEqRel(
            uint256(int256(delta.amount0())), outputAmount, 1e12, "planned output is what the route pays"
        );
    }

    /// @notice V4LE-95: the in-range external-route plan through the same route. The balancing swap
    ///         needs token0 from beyond the quote's step bound, so no exact plan exists: the planner
    ///         reverts Quote_Truncated instead of returning an approximation as if it balanced.
    ///         A smaller holding whose root lies within the bound still plans normally.
    function testV4LE95_TruncatedInRangeQuoteRevertsExplicitly() public {
        _setUpDenselyTickedPool(70);

        vm.expectRevert(ILiquidityCalculator.Quote_Truncated.selector);
        helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 0, 10 ether, 0);

        uint256 amount1 = 0.05 ether;
        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwapThroughPool(SQRT_PRICE_1_0, poolCallee, -600, 600, 0, amount1, 0);
        assertFalse(dir0to1);
        BalanceDelta delta = _executeSwap(inputAmount, false);
        uint256 actualOut = uint256(int256(delta.amount0()));
        assertApproxEqRel(actualOut, outputAmount, 1e12, "planned output matches the route's real output");
        uint128 liquidityFromToken0 =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_0, TickMath.getSqrtPriceAtTick(600), actualOut);
        uint128 liquidityFromToken1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(-600), SQRT_PRICE_1_0, amount1 - inputAmount
        );
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "post-swap amounts within 0.1%");
    }

    /// @notice V4LE-114: the same-pool bisection (output-fee overload) in a wide range of the densely
    ///         ticked pool. With 10 ether of token1 the balance root lies beyond the quote's step
    ///         bound; the bisection used to converge on that bound and return the truncated input as
    ///         the plan. It now reverts Quote_Truncated. A holding whose root lies within the bound
    ///         plans a swap that crosses many ticks and matches execution exactly.
    function testV4LE114_SamePoolBisectionRevertsInsteadOfTruncating() public {
        _setUpDenselyTickedPool(70);

        vm.expectRevert(ILiquidityCalculator.Quote_Truncated.selector);
        liquidityCalculator.calculateSamePool(poolCallee, -6000, 6000, 0, 10 ether, 1);

        uint256 amount1 = 0.1 ether;
        (uint256 amountIn, uint256 predictedOut, bool dir0to1, uint160 predictedSqrtPrice) =
            liquidityCalculator.calculateSamePool(poolCallee, -6000, 6000, 0, amount1, 1);
        assertFalse(dir0to1);
        BalanceDelta delta = _executeSwap(amountIn, false);
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        assertGe(tickAfter, 600, "the swap crossed many initialized ticks");
        assertApproxEqRel(
            uint256(int256(delta.amount0())) * 999_999 / 1_000_000,
            predictedOut,
            PREDICTION_TOLERANCE,
            "executed output deviates from prediction"
        );
        assertApproxEqRel(sqrtPriceAfter, predictedSqrtPrice, PREDICTION_TOLERANCE, "final price deviates");
    }

    /// @notice V4LE-145: the finding's state, external route. Position pool at tick -887100 (a
    ///         valid price near MIN_TICK, sqrt price ~4.3e9), replacement range [-887160, -887040]
    ///         with the position's token1 to place. The required-ratio denominator floored to zero
    ///         here and the plan reverted on the division; the plan must be the balancing swap.
    function testV4LE145_ExternalRouteInRangeNearMinTickPlans() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(-887100);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-887160);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(-887040);
        uint256 amount1 = 1e18;

        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwap(sqrtPrice, -887160, -887040, 0, amount1, DEFAULT_FEE);
        assertFalse(dir0to1, "token1 is swapped for the token0 the range needs");
        assertGt(inputAmount, 0, "a real balancing swap is planned");
        assertLt(inputAmount, amount1, "token1 is retained for the range");
        // LiquidityAmounts.getLiquidityForAmount0 floors sqrtA * sqrtB / Q96 to zero at these prices,
        // so the token0 side is measured with the exact product order
        uint256 liquidityFromToken0 = FullMath.mulDiv(
            outputAmount, FullMath.mulDiv(sqrtPrice, sqrtUpper, sqrtUpper - sqrtPrice), FixedPoint96.Q96
        );
        uint256 liquidityFromToken1 =
            LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtPrice, amount1 - inputAmount);
        uint256 liquidityDifference = liquidityFromToken0 > liquidityFromToken1
            ? liquidityFromToken0 - liquidityFromToken1
            : liquidityFromToken1 - liquidityFromToken0;
        assertLe(liquidityDifference * 10_000 / liquidityFromToken1, 10, "post-swap amounts within 0.1%");
    }

    /// @notice V4LE-146: same price, holding 1e18 token0 and no token1. The direction check
    ///         floored amount0 * sqrtPrice / Q96 to zero, compared the holding as empty and chose
    ///         1->0 with nothing to swap. The correct reading is token0 in surplus (0->1); at this
    ///         price 1e18 token0 is worth less than one unit of token1, so the sensible plan is
    ///         "no swap" reached through the right direction, not a spurious 1->0.
    function testV4LE146_DirectionNearMinTickSeesTheToken0Surplus() public {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(-887100);

        (uint256 inputAmount, uint256 outputAmount, bool dir0to1) =
            helper.getSimpleSwap(sqrtPrice, -887160, -887040, 1e18, 0, DEFAULT_FEE);
        assertTrue(dir0to1, "token0 is the surplus side");
        assertEq(outputAmount, 0, "1e18 token0 buys no token1 at this price");
        assertEq(inputAmount, 0, "so nothing is swapped");

        // the same-pool path: a pool at that tick with the same holding must not report 1->0
        _usePoolAtTick(500, -887100);
        _mintLiquidity(-887160, -887040, 1e6);
        (,, bool samePoolDir0to1,) = helper.getOptimalSwap(poolCallee, -887160, -887040, 1e18, 0);
        assertTrue(samePoolDir0to1, "same-pool direction sees the token0 surplus");
    }

    /// @notice The rewritten comparator agrees with LiquidityAmounts at ordinary prices: the side
    ///         funding less liquidity is the one the plan buys.
    function testV4LE146_DirectionMatchesLiquidityComparison() public view {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(600);
        uint256[4] memory amounts0 = [uint256(1 ether), 100 ether, 1e6, 3e25];
        uint256[4] memory amounts1 = [uint256(1 ether + 1), 1 ether, 1e6 + 1e3, 3e25 - 1e20];
        for (uint256 i; i < 4; ++i) {
            (,, bool dir0to1) = helper.getSimpleSwap(SQRT_PRICE_1_0, -600, 600, amounts0[i], amounts1[i], 0);
            bool expected = LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_0, sqrtUpper, amounts0[i])
                > LiquidityAmounts.getLiquidityForAmount1(sqrtLower, SQRT_PRICE_1_0, amounts1[i]);
            assertEq(dir0to1, expected, "direction differs from the liquidity comparison");
        }
    }

    /// @notice V4LE-150: the finding's state. 0.3% pool at tick 0 with liquidity exactly 1e18,
    ///         replacement range [-60, 60], holdings (4,659,021,152,677 wei token0, 1e15 token1).
    ///         The 1->0 solver's leading coefficient is exactly zero here, so its balance equation
    ///         is linear; the quadratic formula divided by zero and planned no swap although most
    ///         of the token1 is surplus (the balancing swap is ~43% of it: buying token0 lifts the
    ///         price, which raises the token1 share the range needs). The plan must be that swap.
    function testV4LE150_SamePoolLinearBalanceEquationPlansTheSwap() public {
        _mintLiquidity(-600, 600, 1e18);
        uint256 amount0 = 4_659_021_152_677;
        uint256 amount1 = 1e15;
        // precondition: a == amount0 + L / sqrtP - L / ((1 - f) * sqrtU) == 0 in the solver's integer arithmetic
        uint256 liqX96 = uint256(1e18) << 96;
        assertEq(
            amount0 + liqX96 / SQRT_PRICE_1_0,
            (1e6 * liqX96) / (997_000 * uint256(TickMath.getSqrtPriceAtTick(60))),
            "precondition: leading coefficient is zero"
        );

        (uint256 amountIn, uint256 amountOut, bool dir0to1,) =
            helper.getOptimalSwap(poolCallee, -60, 60, amount0, amount1);
        assertFalse(dir0to1, "token1 is in surplus");
        assertGt(amountIn, amount1 / 3, "the linear root is the balancing swap, not no swap");
        _assertPlanBalancesHoldings(-60, 60, amount0, amount1, amountIn, amountOut, false);
    }
}
