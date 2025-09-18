// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";


import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {V4Utils} from "../src/V4Utils.sol";


/**
 * @title V4UtilsTestBase
 * @notice Base contract for V4Utils tests with shared setup and utilities
 * @dev Contains common deployment, setup, and helper functions
 */
abstract contract V4UtilsTestBase is Test {
    // V4 Contracts
    IPermit2 public permit2;
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IUniswapV4Router04 public swapRouter;
    V4Utils public v4Utils;
    
    // Test tokens
    ERC20Mock public token0;
    ERC20Mock public token1;
    ERC20Mock public weth;
    
    // Test users
    address public user1;
    address public user2;
    
    // Common constants
    uint24 public constant FEE = 3000;
    int24 public constant TICK_LOWER = -887220; // Must be multiple of tick spacing (60)
    int24 public constant TICK_UPPER = 887220;  // Must be multiple of tick spacing (60)
    uint256 public constant INITIAL_LIQUIDITY = 1000 ether;
    uint256 public constant USER_BALANCE = 10_000_000 ether; // Increased to ensure sufficient balance
    uint256 public constant ETH_BALANCE = 100 ether;
    
    function setUp() public virtual {
        // Set up test users
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Deploy V4 contracts
        _deployV4Contracts();
        
        // Deploy test tokens
        _deployTestTokens();
        
        // Deploy V4Utils
        v4Utils = new V4Utils(
            positionManager,
            address(swapRouter),
            address(0), // zeroxAllowanceHolder - not used in this test
            permit2
        );
        
        // Fund test users
        _fundUsers();
        
        console.log("=== Test Setup Complete ===");
        console.log("V4Utils deployed at:", address(v4Utils));
        console.log("PositionManager:", address(positionManager));
        console.log("PoolManager:", address(poolManager));
    }
    
    function _deployV4Contracts() internal {
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
        
        // Deploy Router
        swapRouter = IUniswapV4Router04(
            payable(V4RouterDeployer.deploy(address(poolManager), address(permit2)))
        );
    }
    
    function _deployTestTokens() internal virtual {
        // Deploy mock tokens
        ERC20Mock tempToken0 = new ERC20Mock();
        ERC20Mock tempToken1 = new ERC20Mock();
        weth = new ERC20Mock();
        
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
        weth.mint(address(this), 100_000_000 ether);
    }
    
    function _fundUsers() internal {
        // Fund users with test tokens
        token0.transfer(user1, USER_BALANCE);
        token1.transfer(user1, USER_BALANCE);
        token0.transfer(user2, USER_BALANCE);
        token1.transfer(user2, USER_BALANCE);
        
        // Fund users with ETH
        vm.deal(user1, ETH_BALANCE);
        vm.deal(user2, ETH_BALANCE);
    }
    
    function _createTestPosition(address owner) internal returns (uint256 tokenId) {
        // Create a pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Initialize the pool
        vm.prank(owner);
        poolManager.initialize(poolKey, 79228162514264337593543950336); // sqrt price
        
        // First set up ERC20 allowances from user to Permit2
        vm.prank(owner);
        token0.approve(address(permit2), type(uint256).max);
        vm.prank(owner);
        token1.approve(address(permit2), type(uint256).max);
        
        // Then set up Permit2 allowances for the user to allow PositionManager to transfer tokens
        vm.prank(owner);
        permit2.approve(
            address(token0),
            address(positionManager),
            uint160(INITIAL_LIQUIDITY),
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        vm.prank(owner);
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(INITIAL_LIQUIDITY),
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        
        // Also set up Permit2 allowances for V4Utils (needed when V4Utils mints new positions)
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        
        permit2.approve(
            address(token0),
            address(positionManager),
            uint160(10_000_000 ether), // Large allowance for V4Utils
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(10_000_000 ether), // Large allowance for V4Utils
            uint48(block.timestamp + 1 days) // 1 day expiration
        );
        
        // Create position using modifyLiquidities with MINT_POSITION action
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            INITIAL_LIQUIDITY,
            INITIAL_LIQUIDITY, // amount0Max
            INITIAL_LIQUIDITY, // amount1Max
            owner,             // recipient
            ""                 // hookData
        );
        paramsArray[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(positionManager));
        
        vm.prank(owner);
        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
        
        // Get the newly minted token ID
        tokenId = positionManager.nextTokenId() - 1;
        
        return tokenId;
    }
    
    function _createInstructions(
        V4Utils.WhatToDo whatToDo,
        address targetToken,
        uint128 liquidity,
        uint256 deadline,
        address owner
    ) internal view returns (V4Utils.Instructions memory) {
        return V4Utils.Instructions({
            whatToDo: whatToDo,
            targetToken: targetToken,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            feeAmount0: 0, // Legacy - not used
            feeAmount1: 0, // Legacy - not used
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidity: liquidity,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: deadline,
            recipient: owner,
            recipientNFT: owner,
            returnData: "",
            swapAndMintReturnData: ""
        });
    }
    
    function _executeInstructions(uint256 tokenId, V4Utils.Instructions memory instructions, address owner) internal {
        vm.prank(owner);
        IERC721(address(positionManager)).safeTransferFrom(
            owner, 
            address(v4Utils), 
            tokenId, 
            abi.encode(instructions)
        );
    }
    
    function _checkBalances(address user, string memory label) internal view {
        console.log("=== Balances for", label, "===");
        console.log("Token0 balance:", token0.balanceOf(user));
        console.log("Token1 balance:", token1.balanceOf(user));
        console.log("ETH balance:", user.balance);
        console.log("WETH balance:", weth.balanceOf(user));
    }
    
    function _approveTokens(address user, uint256 amount) internal {
        vm.prank(user);
        IERC20(address(token0)).approve(address(v4Utils), amount);
        vm.prank(user);
        IERC20(address(token1)).approve(address(v4Utils), amount);
    }
}
