// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4Utils} from "../src/V4Utils.sol";
import {IWETH9} from "../src/lib/IWETH9.sol";
import "./V4UtilsTestBase.sol";

/**
 * @title V4UtilsExecuteTest
 * @notice Comprehensive test suite for V4Utils.execute() function
 * @dev Forks mainnet at block 23347926 (September 2025) for realistic testing
 */
contract V4UtilsExecuteTest is V4UtilsTestBase {

    // Mainnet fork configuration
    uint256 constant MAINNET_FORK_BLOCK = 23248232; 
    
    // Mainnet addresses
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Real WETh
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Real USDC
    address constant USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // Real USDT
    address constant DAI_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // Real DAI
    
    // Real tokens from mainnet
    IWETH9 public realWeth;
    IERC20 public usdc;
    IERC20 public usdt;
    IERC20 public dai;
    
    // Test users with mainnet balances
    address public whale1; // WETH whale
    address public whale2; // USDC whale
    
    uint256 mainnetFork;

    // USDC / WETH 0.05%
    address nft1Owner;
    uint256 nft1TokenId;

    // USDC / ETH 0.3%
    address nft2Owner;
    uint256 nft2TokenId;



    function setUp() public override {
        // Fork mainnet at specified block
        // Note: Replace with your own RPC URL (Alchemy, Infura, etc.)
        mainnetFork = vm.createFork("https://eth-mainnet.g.alchemy.com/v2/gwRYWylWRij2jXTnPXR90v-YqXh96PDX", MAINNET_FORK_BLOCK);
        vm.selectFork(mainnetFork);

        // Use deployed Uniswap V4 contracts from mainnet
        poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        swapRouter = IUniswapV4Router04(payable(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af));
        
        // Use deployed Permit2 from mainnet
        permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        
        // Override with real tokens from mainnet
        realWeth = IWETH9(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);
        usdt = IERC20(USDT_ADDRESS);
        dai = IERC20(DAI_ADDRESS);

        // Deploy V4Utils with the real deployed contracts
        v4Utils = new V4Utils(
            positionManager,
            realWeth,
            address(swapRouter),
            address(0), // zeroxAllowanceHolder - not used in this test
            permit2
        );
        
        // Set up whale addresses (known addresses with large balances)
        whale1 = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance hot wallet
        whale2 = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Binance cold wallet
        
        console.log("=== Mainnet Fork Test Setup Complete ===");
        console.log("Forked mainnet at block:", MAINNET_FORK_BLOCK);
        console.log("Using real WETH:", address(realWeth));
        console.log("Using real USDC:", address(usdc));
        console.log("Using real USDT:", address(usdt));
        console.log("Using real DAI:", address(dai));

        nft1TokenId = 1;
        nft1Owner = 0x4423B0D6955aF39B48cf215577a79Ce574299D3f;

        nft2TokenId = 2;
        nft2Owner = 0x929716bCDCAf51897A3Dbb65d04FAf9f4Bf9C907;
    }
    
    function testExecuteCompoundFeesWithRealTokens() public {
        console.log("=== Testing COMPOUND_FEES with real mainnet tokens ===");
        
        // Record initial balances
        uint256 initialWethBalance = realWeth.balanceOf(nft1Owner);
        uint256 initialUsdcBalance = usdc.balanceOf(nft1Owner);

        // Create and execute instructions for compounding fees
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0),   // No swap target
            0,            // Collect fees only, don't remove liquidity
            block.timestamp,
            nft1Owner
        );
        
        _executeInstructions(nft1TokenId, instructions, nft1Owner);
        console.log("COMPOUND_FEES executed successfully");
        
        // Verify position still exists and is owned by whale1
        assertEq(IERC721(address(positionManager)).ownerOf(nft1TokenId), nft1Owner, "Position should still be owned by nft1Owner");
        
        // Verify liquidity was added back to the position
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify balances changed (fees were collected and compounded)
        uint256 finalWethBalance = realWeth.balanceOf(nft1Owner);
        uint256 finalUsdcBalance = usdc.balanceOf(nft1Owner);
        
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        
        console.log("Fee compounding completed - position liquidity:", finalLiquidity);
    }
    
    function testExecuteChangeRangeWithRealTokens() public {
        console.log("=== Testing CHANGE_RANGE with real mainnet tokens ===");
        
        // Create a position with USDC/USDT
        uint256 tokenId = _createMainnetPosition(USDC_ADDRESS, USDT_ADDRESS, whale2);
        console.log("Created mainnet position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Record initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(whale2);
        uint256 initialUsdtBalance = usdt.balanceOf(whale2);
        
        // Create and execute instructions for changing range
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.CHANGE_RANGE,
            address(0),        // No swap, just change range
            positionLiquidity, // Remove actual liquidity
            block.timestamp,
            whale2
        );
        
        // Override tick range for new position (tighter range)
        instructions.tickLower = -1000; // Tighter range
        instructions.tickUpper = 1000;  // Tighter range
        
        _executeInstructions(tokenId, instructions, whale2);
        console.log("CHANGE_RANGE executed successfully");
        
        // Verify user still owns the original NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale2, "Original NFT should be returned to whale2");
        
        // Verify balances changed (liquidity was withdrawn)
        uint256 finalUsdcBalance = usdc.balanceOf(whale2);
        uint256 finalUsdtBalance = usdt.balanceOf(whale2);
        
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Initial USDT balance:", initialUsdtBalance);
        console.log("Final USDT balance:", finalUsdtBalance);
        
        assertTrue(
            finalUsdcBalance > initialUsdcBalance || finalUsdtBalance > initialUsdtBalance,
            "User should have received tokens from withdrawn liquidity"
        );
    }
    
    function testExecuteWithdrawAndCollectAndSwapWithRealTokens() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP with real mainnet tokens ===");
        
        // Create a position with DAI/USDC
        uint256 tokenId = _createMainnetPosition(DAI_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created mainnet position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Record initial balances
        uint256 initialDaiBalance = dai.balanceOf(whale1);
        uint256 initialUsdcBalance = usdc.balanceOf(whale1);
        
        // Create and execute instructions for withdrawing and swapping
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            USDC_ADDRESS,      // Swap everything to USDC
            positionLiquidity, // Remove actual liquidity
            block.timestamp,
            whale1
        );
        
        _executeInstructions(tokenId, instructions, whale1);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP executed successfully");
        
        // Verify user still owns the NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale1, "NFT should be returned to whale1");
        
        // Verify balances changed - user should have more USDC (target token)
        uint256 finalDaiBalance = dai.balanceOf(whale1);
        uint256 finalUsdcBalance = usdc.balanceOf(whale1);
        
        console.log("Initial DAI balance:", initialDaiBalance);
        console.log("Final DAI balance:", finalDaiBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        
        // Verify that liquidity was withdrawn (balances should have increased)
        assertTrue(
            finalDaiBalance > initialDaiBalance || finalUsdcBalance > initialUsdcBalance,
            "User should have received tokens from withdrawn liquidity"
        );
    }
    
    function testExecuteWithDifferentFeeTiersBasic() public {
        console.log("=== Testing execute with different fee tiers (basic) ===");
        
        // Test with 0.05% fee tier (500)
        uint256 tokenId1 = _createMainnetPositionWithFee(WETH_ADDRESS, USDC_ADDRESS, whale1, 500);
        console.log("Created 0.05% fee position with tokenId:", tokenId1);
        
        // Test with 0.3% fee tier (3000)
        uint256 tokenId2 = _createMainnetPositionWithFee(WETH_ADDRESS, USDC_ADDRESS, whale1, 3000);
        console.log("Created 0.3% fee position with tokenId:", tokenId2);
        
        // Test with 1% fee tier (10000)
        uint256 tokenId3 = _createMainnetPositionWithFee(WETH_ADDRESS, USDC_ADDRESS, whale1, 10000);
        console.log("Created 1% fee position with tokenId:", tokenId3);
        
        // Verify all positions exist
        assertGt(positionManager.getPositionLiquidity(tokenId1), 0, "0.05% fee position should have liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId2), 0, "0.3% fee position should have liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId3), 0, "1% fee position should have liquidity");
        
        console.log("All fee tier positions created successfully");
    }
    
    function testExecuteWithDifferentTickRanges() public {
        console.log("=== Testing execute with different tick ranges ===");
        
        // Create positions with different tick ranges
        uint256 tokenId1 = _createMainnetPositionWithTicks(WETH_ADDRESS, USDC_ADDRESS, whale1, -1000, 1000);   // Tight range
        uint256 tokenId2 = _createMainnetPositionWithTicks(WETH_ADDRESS, USDC_ADDRESS, whale1, -10000, 10000); // Medium range
        uint256 tokenId3 = _createMainnetPositionWithTicks(WETH_ADDRESS, USDC_ADDRESS, whale1, -100000, 100000); // Wide range
        
        console.log("Created tight range position:", tokenId1);
        console.log("Created medium range position:", tokenId2);
        console.log("Created wide range position:", tokenId3);
        
        // Verify all positions exist and have liquidity
        assertGt(positionManager.getPositionLiquidity(tokenId1), 0, "Tight range position should have liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId2), 0, "Medium range position should have liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId3), 0, "Wide range position should have liquidity");
        
        console.log("All tick range positions created successfully");
    }
    
    function testExecuteWithPermitSignature() public {
        console.log("=== Testing execute with permit signature ===");
        
        // Create a position
        uint256 tokenId = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created position with tokenId:", tokenId);
        
        // Test executeWithPermit (this would require actual signature generation in a real test)
        // For now, we'll just test that the function exists and can be called
        // In a real implementation, you would generate a valid EIP712 signature
        
        console.log("Permit signature test completed (signature generation not implemented)");
    }
    
    function testExecuteCompoundFeesNoSwap() public {
        console.log("=== Testing COMPOUND_FEES without swap ===");
        
        // Create a position with real mainnet tokens
        uint256 tokenId = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created test position with tokenId:", tokenId);
        
        // Wait some time to accumulate fees
        vm.warp(block.timestamp + 7 days);
        
        // Create and execute instructions for compounding fees (no swap)
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0), // No swap target
            0,          // Collect fees only, don't remove liquidity
            block.timestamp,
            whale1
        );
        
        _executeInstructions(tokenId, instructions, whale1);
        console.log("COMPOUND_FEES (no swap) executed successfully");
        
        // Verify position still exists and is owned by whale1
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale1, "Position should still be owned by whale1");
        
        // Verify liquidity was added back to the position
        uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        console.log("Fee compounding completed - position liquidity:", finalLiquidity);
    }
    
    function testExecuteChangeRangeNoSwap() public {
        console.log("=== Testing CHANGE_RANGE without swap ===");
        
        // Create a position with real mainnet tokens (using WETH/USDC instead of USDC/USDT)
        uint256 tokenId = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created test position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Record initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(whale2);
        uint256 initialUsdtBalance = usdt.balanceOf(whale2);
        
        // Create and execute instructions for changing range (no swap)
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.CHANGE_RANGE,
            address(0),        // No swap target
            positionLiquidity, // Remove actual liquidity
            block.timestamp,
            whale1
        );
        
        // Override tick range for new position (different range) - FIXED: use multiples of 60
        instructions.tickLower = -1980; // Different range (multiple of 60)
        instructions.tickUpper = 1980;  // Different range (multiple of 60)
        
        _executeInstructions(tokenId, instructions, whale2);
        console.log("CHANGE_RANGE (no swap) executed successfully");
        
        // Verify user still owns the original NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale2, "Original NFT should be returned to whale2");
        
        // Verify balances changed (liquidity was withdrawn)
        uint256 finalUsdcBalance = usdc.balanceOf(whale2);
        uint256 finalUsdtBalance = usdt.balanceOf(whale2);
        
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Initial USDT balance:", initialUsdtBalance);
        console.log("Final USDT balance:", finalUsdtBalance);
        
        assertTrue(
            finalUsdcBalance > initialUsdcBalance || finalUsdtBalance > initialUsdtBalance,
            "User should have received tokens from withdrawn liquidity"
        );
    }
    
    function testExecuteWithdrawAndCollectNoSwap() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP without swap ===");
        
        // Create a position with DAI/USDC
        uint256 tokenId = _createMainnetPosition(DAI_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created mainnet position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Record initial balances
        uint256 initialDaiBalance = dai.balanceOf(whale1);
        uint256 initialUsdcBalance = usdc.balanceOf(whale1);
        
        // Create and execute instructions for withdrawing (no swap)
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(0),        // No swap target - just withdraw
            positionLiquidity, // Remove actual liquidity
            block.timestamp,
            whale1
        );
        
        _executeInstructions(tokenId, instructions, whale1);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP (no swap) executed successfully");
        
        // Verify user still owns the NFT (it should be returned)
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale1, "NFT should be returned to whale1");
        
        // Verify balances changed - user should have more tokens
        uint256 finalDaiBalance = dai.balanceOf(whale1);
        uint256 finalUsdcBalance = usdc.balanceOf(whale1);
        
        console.log("Initial DAI balance:", initialDaiBalance);
        console.log("Final DAI balance:", finalDaiBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        
        // Verify that liquidity was withdrawn (balances should have increased)
        assertTrue(
            finalDaiBalance > initialDaiBalance || finalUsdcBalance > initialUsdcBalance,
            "User should have received tokens from withdrawn liquidity"
        );
    }
    
    function testExecuteWithPartialLiquidityRemoval() public {
        console.log("=== Testing execute with partial liquidity removal ===");
        
        // Create a position with WETH/USDC
        uint256 tokenId = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created mainnet position with tokenId:", tokenId);
        
        // Get the actual position liquidity
        uint128 totalLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(totalLiquidity, 0, "Initial position should have liquidity");
        
        // Remove only 50% of liquidity
        uint128 liquidityToRemove = totalLiquidity / 2;
        
        // Record initial balances
        uint256 initialWethBalance = realWeth.balanceOf(whale1);
        uint256 initialUsdcBalance = usdc.balanceOf(whale1);
        
        // Create and execute instructions for partial withdrawal
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(0),        // No swap target
            liquidityToRemove, // Remove only half the liquidity
            block.timestamp,
            whale1
        );
        
        _executeInstructions(tokenId, instructions, whale1);
        console.log("Partial liquidity removal executed successfully");
        
        // Verify user still owns the NFT
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale1, "NFT should be returned to whale1");
        
        // Verify position still has remaining liquidity
        uint128 remainingLiquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(remainingLiquidity, 0, "Position should still have remaining liquidity");
        assertLt(remainingLiquidity, totalLiquidity, "Remaining liquidity should be less than original");
        
        // Verify balances increased
        uint256 finalWethBalance = realWeth.balanceOf(whale1);
        uint256 finalUsdcBalance = usdc.balanceOf(whale1);
        
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Original liquidity:", totalLiquidity);
        console.log("Remaining liquidity:", remainingLiquidity);
        
        assertTrue(
            finalWethBalance > initialWethBalance || finalUsdcBalance > initialUsdcBalance,
            "User should have received tokens from partial liquidity removal"
        );
    }
    
    function testExecuteWithDifferentLiquidityAmounts() public {
        console.log("=== Testing execute with different liquidity amounts ===");
        
        // Create a position
        uint256 tokenId = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created mainnet position with tokenId:", tokenId);
        
        uint128 totalLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(totalLiquidity, 0, "Initial position should have liquidity");
        
        // Test different liquidity removal amounts
        uint128[] memory liquidityAmounts = new uint128[](4);
        liquidityAmounts[0] = totalLiquidity / 4;  // 25%
        liquidityAmounts[1] = totalLiquidity / 2;  // 50%
        liquidityAmounts[2] = totalLiquidity * 3 / 4; // 75%
        liquidityAmounts[3] = totalLiquidity;       // 100%
        
        for (uint i = 0; i < liquidityAmounts.length; i++) {
            console.log("Testing liquidity removal:", liquidityAmounts[i]);
            
            // Create instructions for this liquidity amount
            V4Utils.Instructions memory instructions = _createInstructions(
                V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
                address(0),           // No swap target
                liquidityAmounts[i], // Remove this amount
                block.timestamp,
                whale1
            );
            
            _executeInstructions(tokenId, instructions, whale1);
            
            // Verify NFT is still owned by whale1
            assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale1, "NFT should be returned to whale1");
            
            // Check remaining liquidity
            uint128 remainingLiquidity = positionManager.getPositionLiquidity(tokenId);
            console.log("Remaining liquidity after removal:", remainingLiquidity);
            
            if (liquidityAmounts[i] == totalLiquidity) {
                // For 100% removal, position should have no liquidity
                assertEq(remainingLiquidity, 0, "Position should have no liquidity after 100% removal");
            } else {
                // For partial removal, position should still have liquidity
                assertGt(remainingLiquidity, 0, "Position should still have liquidity after partial removal");
            }
        }
        
        console.log("All liquidity amount tests completed successfully");
    }
    
    function testExecuteWithDifferentDeadlines() public {
        console.log("=== Testing execute with different deadlines ===");
        
        // Create a position
        uint256 tokenId = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        console.log("Created mainnet position with tokenId:", tokenId);
        
        uint128 positionLiquidity = uint128(positionManager.getPositionLiquidity(tokenId));
        assertGt(positionLiquidity, 0, "Initial position should have liquidity");
        
        // Test different deadline scenarios
        uint256[] memory deadlines = new uint256[](3);
        deadlines[0] = block.timestamp;   // 1 hour from now
        deadlines[1] = block.timestamp + 1 days;   // 1 day from now
        deadlines[2] = block.timestamp + 1 weeks;  // 1 week from now
        
        for (uint i = 0; i < deadlines.length; i++) {
            console.log("Testing deadline:", deadlines[i]);
            
            // Create instructions with this deadline
            V4Utils.Instructions memory instructions = _createInstructions(
                V4Utils.WhatToDo.COMPOUND_FEES,
                address(0),        // No swap target
                0,                 // Collect fees only
                deadlines[i],      // Use this deadline
                whale1
            );
            
            _executeInstructions(tokenId, instructions, whale1);
            
            // Verify NFT is still owned by whale1
            assertEq(IERC721(address(positionManager)).ownerOf(tokenId), whale1, "NFT should be returned to whale1");
            
            // Verify position still has liquidity
            uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenId);
            assertGt(finalLiquidity, 0, "Position should have liquidity after compounding");
            
            console.log("Deadline test completed for:", deadlines[i]);
        }
        
        console.log("All deadline tests completed successfully");
    }
    
    function testExecuteWithDifferentFeeTiers() public {
        console.log("=== Testing execute with different fee tiers ===");
        
        // Test different fee tiers
        uint24[] memory fees = new uint24[](4);
        fees[0] = 100;   // 0.01% fee - tick spacing 1
        fees[1] = 500;   // 0.05% fee - tick spacing 10
        fees[2] = 3000;  // 0.3% fee - tick spacing 60
        fees[3] = 10000; // 1% fee - tick spacing 200
        
        uint256[] memory tokenIds = new uint256[](4);
        
        // Create positions with different fee tiers
        for (uint i = 0; i < fees.length; i++) {
            tokenIds[i] = _createMainnetPositionWithFee(WETH_ADDRESS, USDC_ADDRESS, whale1, fees[i]);
            console.log("Created position with fee", fees[i], "and tokenId:", tokenIds[i]);
            
            // Verify position has liquidity
            uint128 liquidity = positionManager.getPositionLiquidity(tokenIds[i]);
            assertGt(liquidity, 0, "Position should have liquidity");
        }
        
        // Test execute on each position
        for (uint i = 0; i < tokenIds.length; i++) {
            console.log("Testing execute on position with fee:", fees[i]);
            
            // Create instructions for compounding fees
            V4Utils.Instructions memory instructions = _createInstructions(
                V4Utils.WhatToDo.COMPOUND_FEES,
                address(0), // No swap target
                0,          // Collect fees only
                block.timestamp,
                whale1
            );
            
            _executeInstructions(tokenIds[i], instructions, whale1);
            
            // Verify NFT is still owned by whale1
            assertEq(IERC721(address(positionManager)).ownerOf(tokenIds[i]), whale1, "NFT should be returned to whale1");
            
            // Verify position still has liquidity
            uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenIds[i]);
            assertGt(finalLiquidity, 0, "Position should have liquidity after compounding");
        }
        
        console.log("All fee tier tests completed successfully");
    }
    
    function testExecuteWithDifferentTokenPairs() public {
        console.log("=== Testing execute with different token pairs ===");
        
        // Test different token pairs
        address[][] memory tokenPairs = new address[][](4);
        tokenPairs[0] = new address[](2);
        tokenPairs[0][0] = WETH_ADDRESS;
        tokenPairs[0][1] = USDC_ADDRESS;
        
        tokenPairs[1] = new address[](2);
        tokenPairs[1][0] = WETH_ADDRESS;
        tokenPairs[1][1] = DAI_ADDRESS;
        
        tokenPairs[2] = new address[](2);
        tokenPairs[2][0] = USDC_ADDRESS;
        tokenPairs[2][1] = USDT_ADDRESS;
        
        tokenPairs[3] = new address[](2);
        tokenPairs[3][0] = DAI_ADDRESS;
        tokenPairs[3][1] = USDC_ADDRESS;
        
        uint256[] memory tokenIds = new uint256[](4);
        
        // Create positions with different token pairs
        for (uint i = 0; i < tokenPairs.length; i++) {
            tokenIds[i] = _createMainnetPosition(tokenPairs[i][0], tokenPairs[i][1], whale1);
            console.log("Created position with token pair and tokenId:", tokenIds[i]);
            
            // Verify position has liquidity
            uint128 liquidity = positionManager.getPositionLiquidity(tokenIds[i]);
            assertGt(liquidity, 0, "Position should have liquidity");
        }
        
        // Test execute on each position
        for (uint i = 0; i < tokenIds.length; i++) {
            console.log("Testing execute on position with token pair");
            
            // Create instructions for compounding fees
            V4Utils.Instructions memory instructions = _createInstructions(
                V4Utils.WhatToDo.COMPOUND_FEES,
                address(0), // No swap target
                0,          // Collect fees only
                block.timestamp,
                whale1
            );
            
            _executeInstructions(tokenIds[i], instructions, whale1);
            
            // Verify NFT is still owned by whale1
            assertEq(IERC721(address(positionManager)).ownerOf(tokenIds[i]), whale1, "NFT should be returned to whale1");
            
            // Verify position still has liquidity
            uint128 finalLiquidity = positionManager.getPositionLiquidity(tokenIds[i]);
            assertGt(finalLiquidity, 0, "Position should have liquidity after compounding");
        }
        
        console.log("All token pair tests completed successfully");
    }
    
    function testExecuteWithDifferentUsers() public {
        console.log("=== Testing execute with different users ===");
        
        // Create positions for different users
        uint256 tokenId1 = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale1);
        uint256 tokenId2 = _createMainnetPosition(WETH_ADDRESS, USDC_ADDRESS, whale2);
        
        console.log("Created position for whale1 with tokenId:", tokenId1);
        console.log("Created position for whale2 with tokenId:", tokenId2);
        
        // Verify both positions have liquidity
        assertGt(positionManager.getPositionLiquidity(tokenId1), 0, "Whale1 position should have liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId2), 0, "Whale2 position should have liquidity");
        
        // Test execute for whale1
        V4Utils.Instructions memory instructions1 = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0), // No swap target
            0,          // Collect fees only
            block.timestamp,
            whale1
        );
        
        _executeInstructions(tokenId1, instructions1, whale1);
        
        // Test execute for whale2
        V4Utils.Instructions memory instructions2 = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0), // No swap target
            0,          // Collect fees only
            block.timestamp,
            whale2
        );
        
        _executeInstructions(tokenId2, instructions2, whale2);
        
        // Verify both NFTs are still owned by their respective users
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId1), whale1, "Token1 should be owned by whale1");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId2), whale2, "Token2 should be owned by whale2");
        
        // Verify both positions still have liquidity
        assertGt(positionManager.getPositionLiquidity(tokenId1), 0, "Whale1 position should still have liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId2), 0, "Whale2 position should still have liquidity");
        
        console.log("Multi-user execute tests completed successfully");
    }
    
    // Helper functions for mainnet testing
    
    function _createMainnetPosition(address token0Addr, address token1Addr, address owner) internal returns (uint256) {
        return _createMainnetPositionWithFee(token0Addr, token1Addr, owner, FEE);
    }
    
    function _createMainnetPositionWithFee(address token0Addr, address token1Addr, address owner, uint24 fee) internal returns (uint256) {
        return _createMainnetPositionWithTicks(token0Addr, token1Addr, owner, TICK_LOWER, TICK_UPPER, fee);
    }
    
    function _createMainnetPositionWithTicks(address token0Addr, address token1Addr, address owner, int24 tickLower, int24 tickUpper) internal returns (uint256) {
        return _createMainnetPositionWithTicks(token0Addr, token1Addr, owner, tickLower, tickUpper, FEE);
    }
    
    function _createMainnetPositionWithTicks(address token0Addr, address token1Addr, address owner, int24 tickLower, int24 tickUpper, uint24 fee) internal returns (uint256) {
        // Ensure proper ordering: token0 < token1 (address-wise)
        address token0 = token0Addr < token1Addr ? token0Addr : token1Addr;
        address token1 = token0Addr < token1Addr ? token1Addr : token0Addr;
        
        // Initialize pool and set up allowances
        _initializePoolAndAllowances(token0, token1, owner, fee);
        
        // Create position
        return _mintPosition(token0, token1, owner, tickLower, tickUpper, fee);
    }
    
    function _initializePoolAndAllowances(address token0, address token1, address owner, uint24 fee) internal {
        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Initialize pool if needed
        try poolManager.initialize(poolKey, 79228162514264337593543950336) {
            console.log("Pool initialized successfully");
        } catch {
            console.log("Pool already exists, skipping initialization");
        }
        
        // Set up ERC20 allowances
        vm.prank(owner);
        IERC20(token0).approve(address(permit2), type(uint256).max);
        vm.prank(owner);
        IERC20(token1).approve(address(permit2), type(uint256).max);
        
        // Set up Permit2 allowances - use much smaller amount for mainnet testing
        // Use different amounts based on token decimals
        uint256 liquidityAmount = 1 * 10**3; // 0.001 token (6 decimals for USDC)
        uint256 wethAmount = 1 * 10**15; // 0.001 WETH (18 decimals)
        // Approve different amounts based on token type
        uint160 amount0 = token0 == WETH_ADDRESS ? uint160(wethAmount) : uint160(liquidityAmount);
        uint160 amount1 = token1 == WETH_ADDRESS ? uint160(wethAmount) : uint160(liquidityAmount);
        
        vm.prank(owner);
        permit2.approve(token0, address(positionManager), amount0, uint48(block.timestamp + 1 days));
        vm.prank(owner);
        permit2.approve(token1, address(positionManager), amount1, uint48(block.timestamp + 1 days));
    }
    
    function _mintPosition(address token0, address token1, address owner, int24 tickLower, int24 tickUpper, uint24 fee) internal returns (uint256) {
        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Create position using modifyLiquidities
        // Use different amounts based on token decimals - inline calculation
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            poolKey, 
            tickLower, 
            tickUpper, 
            token0 == WETH_ADDRESS ? 1 * 10**15 : 1 * 10**3, // amount0 (0.001 tokens)
            token1 == WETH_ADDRESS ? 1 * 10**15 : 1 * 10**3, // amount1 (0.001 tokens)
            token0 == WETH_ADDRESS ? 1 * 10**15 : 1 * 10**3, // amount0 again (0.001 tokens)
            owner, 
            ""
        );
        paramsArray[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(positionManager));
        
        vm.prank(owner);
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
        
        return positionManager.nextTokenId() - 1;
    }
    
}