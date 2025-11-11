// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {LiquidityCalculator} from "../src/LiquidityCalculator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
    function getOptimalSwap(
        LiquidityCalculator.V4PoolInfo memory cfg,
        int24 lower,
        int24 upper,
        uint256 amt0,
        uint256 amt1
    ) external view returns (uint256 inAmt, uint256 outAmt, bool dir, uint160 price) {
        return LiquidityCalculator.calculateSamePool(cfg, lower, upper, amt0, amt1);
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
    LiquidityCalculator.V4PoolInfo poolCallee;
    LiquidityCalculatorHelper helper;
    
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
        
        // Create pool callee struct
        poolCallee = LiquidityCalculator.V4PoolInfo({
            poolMgr: poolManager,
            poolIdentifier: poolId,
            tickSpacing: DEFAULT_TICK_SPACING
        });
        
        // Deploy helper contract
        helper = new LiquidityCalculatorHelper();
        
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

    /// @notice Test with empty pool (no initial liquidity)
    function test_LiquidityCalculator_EmptyPool() public {
        // Don't add initial liquidity
        
        vm.expectRevert(LiquidityCalculator.Math_Overflow.selector);
        helper.getOptimalSwap(
                poolCallee,
                -600,
                600,
                10 ether,
                10 ether
            );
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
        
        assertEq(amountIn, 0, "Should have no swap input");
        assertEq(amountOut, 0, "Should have no swap output");
        
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

}
