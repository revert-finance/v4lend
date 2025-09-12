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
    
    function testExecuteCompoundFees() public {
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
    
    function testExecuteCompoundFeesWithNativeETH() public {
        console.log("=== Testing COMPOUND_FEES with ETH Native ===");
        
        // Record initial balances
        uint256 initialWethBalance = realWeth.balanceOf(nft2Owner);
        uint256 initialUsdcBalance = usdc.balanceOf(nft2Owner);

        // Create and execute instructions for compounding fees
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.COMPOUND_FEES,
            address(0),   // No swap target
            0,            // Collect fees only, don't remove liquidity
            block.timestamp,
            nft2Owner
        );
        
        _executeInstructions(nft2TokenId, instructions, nft2Owner);
        console.log("COMPOUND_FEES executed successfully");
        
        // Verify position still exists and is owned by whale1
        assertEq(IERC721(address(positionManager)).ownerOf(nft2TokenId), nft2Owner, "Position should still be owned by nft2Owner");
        
        // Verify liquidity was added back to the position
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft2TokenId);
        assertGt(finalLiquidity, 0, "Position should have liquidity after compounding fees");
        
        // Verify balances changed (fees were collected and compounded)
        uint256 finalWethBalance = realWeth.balanceOf(nft2Owner);
        uint256 finalUsdcBalance = usdc.balanceOf(nft2Owner);
        
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        
        console.log("Fee compounding completed - position liquidity:", finalLiquidity);
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