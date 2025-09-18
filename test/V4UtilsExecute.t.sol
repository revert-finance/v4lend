// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4Utils} from "../src/V4Utils.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

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
            address(swapRouter),
            address(0x0000000000001fF3684f28c67538d4D072C22734),
            permit2
        );

        vm.etch(address(0x1234567890123456789012345678901234567890), address(v4Utils).code);
        vm.copyStorage(address(v4Utils), address(0x1234567890123456789012345678901234567890));
        vm.deal(address(0x1234567890123456789012345678901234567890), 0);

        v4Utils = V4Utils(payable(address(0x1234567890123456789012345678901234567890)));
        

        console.log("V4Utils deployed at:", address(v4Utils));
        
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

    function testExecuteWithdrawAndCollectAndSwapToETH() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP to ETH ===");
        
        // Record initial balances
        uint256 initialWethBalance = realWeth.balanceOf(nft1Owner);
        uint256 initialUsdcBalance = usdc.balanceOf(nft1Owner);
        uint256 initialEthBalance = nft1Owner.balance;
        
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial ETH balance:", initialEthBalance);
        
        // Get pool info to show token addresses
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(nft1TokenId);
        console.log("NFT Token ID:", nft1TokenId);
        console.log("Token0 address:", Currency.unwrap(poolKey.currency0));
        console.log("Token1 address:", Currency.unwrap(poolKey.currency1));

        // USD -> ETH / WETH -> ETH
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(0),   // Swap to ETH
            0,            // Only fees are collected
            block.timestamp,
            nft1Owner
        );
        instructions.swapData0 = hex"2213bc0b000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000068e76b000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000009641fff991f0000000000000000000000001234567890123456789012345678901234567890000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000000000543ce8502d1f800000000000000000000000000000000000000000000000000000000000000a01658b3d5083c4a24a5333c230000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000003600000000000000000000000000000000000000000000000000000000000000620000000000000000000000000000000000000000000000000000000000000076000000000000000000000000000000000000000000000000000000000000000e4c1fb425e000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000068e76b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068cb447c00000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000164fd8c38e1000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000271000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000ffffffffffffffc500000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002e2710012260fac5e5542a773aa44fbcfedf7c193bc2c5996b61d8680c4f9e560c8306807908553f95c749c500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000028438c9c1470000000000000000000000002260fac5e5542a773aa44fbcfedf7c193bc2c5990000000000000000000000000000000000000000000000000000000000002710000000000000000000000000aaaaaaaaa24eeeb8d57d431224f73832bc34f688000000000000000000000000000000000000000000000000000000000000010400000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001a4a15112f900000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002260fac5e5542a773aa44fbcfedf7c193bc2c59900000000000000000000000000000000000000000000000000000000000001a400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000170300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010438c9c147000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000002710000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000024d0e30db000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010438c9c147000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000000000000002710000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000242e1a7d4d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        instructions.amountIn0 = 6874987;
        instructions.amountOut0Min = 1357024286962374;

        instructions.swapData1 = hex"";
        instructions.amountIn1 = 14158266761780632;
        instructions.amountOut1Min = 14158266761780632;

        _executeInstructions(nft1TokenId, instructions, nft1Owner);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP executed successfully");
        
        // Check if position still exists and has liquidity
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft1TokenId);
        console.log("Final position liquidity:", finalLiquidity);
        
        // Note: Position might still exist with minimal liquidity due to rounding
        // This is normal behavior in Uniswap V4
        
        // Record final balances
        uint256 finalWethBalance = realWeth.balanceOf(nft1Owner);
        uint256 finalUsdcBalance = usdc.balanceOf(nft1Owner);
        uint256 finalEthBalance = nft1Owner.balance;
        
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Final ETH balance:", finalEthBalance);
        
        assertEq(finalWethBalance, initialWethBalance, "WETH balance should not have increased after withdrawal - all swapped");
        assertEq(finalUsdcBalance, initialUsdcBalance, "USDC balance should not have increased after withdrawal - all swapped");
        assertGt(finalEthBalance, initialEthBalance, "ETH balance should grow");
        
        console.log("WETH balance increase:", finalWethBalance - initialWethBalance);
        console.log("USDC balance increase:", finalUsdcBalance - initialUsdcBalance);
        console.log("ETH balance increase:", finalEthBalance - initialEthBalance);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP completed successfully");

        assertEq(address(v4Utils).balance, 0, "ETH balance should be 0");
        assertEq(realWeth.balanceOf(address(v4Utils)), 0, "WETH balance should be 0");
        assertEq(usdc.balanceOf(address(v4Utils)), 0, "USDC balance should be 0");
    }

    function testExecuteWithdrawAndCollectAndSwapToETH_NFT2() public {
        console.log("=== Testing WITHDRAW_AND_COLLECT_AND_SWAP to ETH with NFT2 ===");
        
        // Record initial balances
        uint256 initialWethBalance = realWeth.balanceOf(nft2Owner);
        uint256 initialUsdcBalance = usdc.balanceOf(nft2Owner);
        uint256 initialEthBalance = nft2Owner.balance;
        
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial ETH balance:", initialEthBalance);
        
        // Get pool info to show token addresses
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(nft2TokenId);
        console.log("NFT Token ID:", nft2TokenId);
        console.log("Token0 address:", Currency.unwrap(poolKey.currency0));
        console.log("Token1 address:", Currency.unwrap(poolKey.currency1));

        // USD -> ETH / WETH -> ETH
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(realWeth),   // Swap to WETH
            0,            // Only fees are collected
            block.timestamp,
            nft2Owner
        );

        // ETH -> WETH
        instructions.swapData0 = hex"";
        instructions.amountIn0 = 63079250674003;
        instructions.amountOut0Min = 63079250674003;

        // USDC -> WETH
        instructions.swapData1 = hex"2213bc0b000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000d5271000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000004041fff991f0000000000000000000000001234567890123456789012345678901234567890000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000000aa8f9b752f1c00000000000000000000000000000000000000000000000000000000000000a08db59c201dad4cf48b3789dd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000e4c1fb425e000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000d527100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068cb566a00000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001a4d92aadfb000000000000000000000000df31a70a21a1931e02033dbba7deace6c45cfd0f000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000000ac48a75f2762c4e52903a5e675894ed8c88c7df7bc498c5c6ce7968aac036a7172a04a4fa3b70000000000000000000000000000000000000000000000000000000068cb559f000000000000000000000000bb289bc97591f70d8216462df40ed713011b968a0000000000000000000000000000000000000000000000000000000000000120000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000d52710000000000000000000000000000000000000000000000000000000000000041bd41293b16678add92bf8192b53c32d54b7e47caef29fb2989c513d706f9d88717ef21fc24b062858bd9a83020e0b7ce48ced91bbf619413b7324357a60f81b91b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        instructions.amountIn1 = 873073;
        instructions.amountOut1Min = 188428045653858;

        _executeInstructions(nft2TokenId, instructions, nft2Owner);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP executed successfully");
        
        // Check if position still exists and has liquidity
        uint128 finalLiquidity = positionManager.getPositionLiquidity(nft2TokenId);
        console.log("Final position liquidity:", finalLiquidity);
 
        
        // Record final balances
        uint256 finalWethBalance = realWeth.balanceOf(nft2Owner);
        uint256 finalUsdcBalance = usdc.balanceOf(nft2Owner);
        uint256 finalEthBalance = nft2Owner.balance;
        
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Final ETH balance:", finalEthBalance);

        assertGt(finalWethBalance, initialWethBalance, "WETH balance should grow");
        assertEq(finalUsdcBalance, initialUsdcBalance, "USDC balance should not have increased after withdrawal - all swapped");
        assertEq(finalEthBalance, initialEthBalance, "ETH balance should not have increased after withdrawal - all swapped");

        console.log("WETH balance increase:", finalWethBalance - initialWethBalance);
        console.log("USDC balance increase:", finalUsdcBalance - initialUsdcBalance);
        console.log("ETH balance increase:", finalEthBalance - initialEthBalance);
        console.log("WITHDRAW_AND_COLLECT_AND_SWAP completed successfully");

        assertEq(address(v4Utils).balance, 0, "ETH balance should be 0");
        assertEq(realWeth.balanceOf(address(v4Utils)), 0, "WETH balance should be 0");
        assertEq(usdc.balanceOf(address(v4Utils)), 0, "USDC balance should be 0");
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