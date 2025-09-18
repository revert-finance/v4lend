// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {V4Utils} from "../src/V4Utils.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import "./V4UtilsTestBase.sol";

/**
 * @title V4UtilsExecuteTestBase
 * @notice Base contract with common logic for V4Utils.execute() tests
 * @dev Contains shared setup, structs, and helper functions
 */
contract V4UtilsExecuteTestBase is V4UtilsTestBase {
    // Mainnet fork configuration
    uint256 constant MAINNET_FORK_BLOCK = 23248232; 
    
    // Mainnet addresses
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Real WETH
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
        
        console.log("=== Mainnet Fork Test Setup Complete ===");
        console.log("Forked mainnet at block:", MAINNET_FORK_BLOCK);
        
        // Initialize real tokens
        realWeth = IWETH9(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);
        usdt = IERC20(USDT_ADDRESS);
        dai = IERC20(DAI_ADDRESS);
        
        
        // Deploy V4Utils with the real deployed contracts
        v4Utils = new V4Utils(
            positionManager, address(swapRouter), address(0x0000000000001fF3684f28c67538d4D072C22734), permit2
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

    // Common structs for different test types
    struct WithdrawAndCollectAndSwapTestParams {
        uint256 tokenId;
        address owner;
        address swapTarget;
        bytes swapData0;
        bytes swapData1;
        uint256 amountIn0;
        uint256 amountOut0Min;
        uint256 amountIn1;
        uint256 amountOut1Min;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        string testName;
    }

    struct ChangeRangeTestParams {
        uint256 tokenId;
        address owner;
        address targetToken;
        uint24 newFee;
        int24 newTickLower;
        int24 newTickUpper;
        uint128 liquidityToRemove;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        string testName;
    }

    struct CompoundFeesTestParams {
        uint256 tokenId;
        address owner;
        address targetToken;
        uint128 liquidityToRemove;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        string testName;
    }

    // Common helper functions
    function _executeInstructions(uint256 tokenId, V4Utils.Instructions memory instructions, address owner) internal override {
        // Approve V4Utils to manage the NFT
        vm.prank(owner);
        IERC721(address(positionManager)).approve(address(v4Utils), tokenId);
        
        // Execute the instructions
        vm.prank(owner);
        v4Utils.execute(tokenId, instructions);
    }

    function _verifyContractCleanup() internal {
        // Verify V4Utils contract has no leftover tokens
        assertEq(address(v4Utils).balance, 0, "V4Utils ETH balance should be 0");
        assertEq(realWeth.balanceOf(address(v4Utils)), 0, "V4Utils WETH balance should be 0");
        assertEq(usdc.balanceOf(address(v4Utils)), 0, "V4Utils USDC balance should be 0");
    }

    function _logPositionInfo(uint256 tokenId) internal view {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        console.log("NFT Token ID:", tokenId);
        console.log("Token0 address:", Currency.unwrap(poolKey.currency0));
        console.log("Token1 address:", Currency.unwrap(poolKey.currency1));
        console.log("Current fee:", poolKey.fee);
        console.log("Current tick spacing:", poolKey.tickSpacing);
        console.log("Current tick lower:", positionInfo.tickLower());
        console.log("Current tick upper:", positionInfo.tickUpper());
    }

    function _logInitialBalances(
        address /* owner */,
        uint256 initialWethBalance,
        uint256 initialUsdcBalance,
        uint256 initialEthBalance
    ) internal pure {
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial ETH balance:", initialEthBalance);
    }

    function _logBalanceChanges(
        address /* owner */,
        uint256 initialWethBalance,
        uint256 finalWethBalance,
        uint256 initialUsdcBalance,
        uint256 finalUsdcBalance,
        uint256 initialEthBalance,
        uint256 finalEthBalance
    ) internal pure {
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Final ETH balance:", finalEthBalance);
        
        console.log("WETH balance change:", int256(finalWethBalance) - int256(initialWethBalance));
        console.log("USDC balance change:", int256(finalUsdcBalance) - int256(initialUsdcBalance));
        console.log("ETH balance change:", int256(finalEthBalance) - int256(initialEthBalance));
    }
}
