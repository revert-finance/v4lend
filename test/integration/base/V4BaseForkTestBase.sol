// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {Swapper} from "../../../src/utils/Swapper.sol";
import {V4Utils} from "../../../src/transformers/V4Utils.sol";
import {V4Oracle, AggregatorV3Interface} from "../../../src/V4Oracle.sol";
import {V4Vault} from "../../../src/V4Vault.sol";
import {InterestRateModel} from "../../../src/InterestRateModel.sol";
import {RevertHook} from "../../../src/RevertHook.sol";
import {RevertHookFunctions} from "../../../src/RevertHookFunctions.sol";
import {RevertHookFunctions2} from "../../../src/RevertHookFunctions2.sol";
import {RevertHookState} from "../../../src/RevertHookState.sol";
import {LiquidityCalculator, ILiquidityCalculator} from "../../../src/LiquidityCalculator.sol";
import {IUniversalRouter} from "../../../src/lib/IUniversalRouter.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {V4TestBase} from "../../V4TestBase.sol";

/**
 * @title V4BaseForkTestBase
 * @notice Base contract for Base network fork tests
 * @dev Deploys full ecosystem on Base fork for integration testing
 */
contract V4BaseForkTestBase is V4TestBase {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;

    // Base fork configuration
    // Note: Update FORK_BLOCK to a recent block after Base mainnet testing
    uint256 constant BASE_FORK_BLOCK = 25000000;

    // ==================== Base Contract Addresses ====================
    // Source: https://docs.uniswap.org/contracts/v4/deployments

    address constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant BASE_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant BASE_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant BASE_ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // ==================== Base Token Addresses ====================

    address constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006; // OP Stack WETH
    address constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Native USDC on Base
    address constant ETH_ADDRESS = address(0);

    // ==================== Chainlink Oracle Feeds ====================

    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // ==================== Configuration Constants ====================

    uint32 constant MAX_FEED_AGE = 86400 * 30; // 30 days for testing (relaxed)
    uint16 constant MAX_POOL_PRICE_DIFFERENCE = 1000; // 10% for testing (relaxed)

    // Real tokens from Base
    IWETH9 public weth;
    IERC20 public usdc;

    // Whale accounts on Base (known addresses with balances)
    address public whaleAccount;

    uint256 baseFork;

    // Deployed contracts
    V4Vault public vault;
    InterestRateModel public interestRateModel;
    RevertHook public revertHook;
    LiquidityCalculator public liquidityCalculator;
    RevertHookFunctions public hookFunctions;
    RevertHookFunctions2 public hookFunctions2;

    function setUp() public virtual override {
        // Fork Base at specified block
        // Note: Replace with your own Base RPC URL
        string memory baseRpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        baseFork = vm.createFork(baseRpc, BASE_FORK_BLOCK);
        vm.selectFork(baseFork);

        console.log("=== Base Fork Test Setup ===");
        console.log("Forked Base at block:", BASE_FORK_BLOCK);

        // Use deployed Uniswap V4 contracts from Base
        poolManager = IPoolManager(BASE_POOL_MANAGER);
        positionManager = IPositionManager(BASE_POSITION_MANAGER);
        swapRouter = IUniswapV4Router04(payable(BASE_UNIVERSAL_ROUTER));
        permit2 = IPermit2(BASE_PERMIT2);

        // Initialize real tokens
        weth = IWETH9(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);

        // Find a whale account - we'll use deal() to fund test accounts instead
        whaleAccount = makeAddr("whale");

        // Fund whale account
        _fundWhaleAccount();

        // Deploy test infrastructure
        _deployTestContracts();

        console.log("=== Base Fork Test Setup Complete ===");
    }

    function _fundWhaleAccount() internal {
        // Fund whale with ETH
        vm.deal(whaleAccount, 1000 ether);

        // Fund whale with WETH
        vm.prank(whaleAccount);
        weth.deposit{value: 500 ether}();

        // Fund whale with USDC using deal
        deal(address(usdc), whaleAccount, 10_000_000 * 1e6); // 10M USDC

        console.log("Funded whale account:", whaleAccount);
        console.log("  ETH balance:", whaleAccount.balance);
        console.log("  WETH balance:", weth.balanceOf(whaleAccount));
        console.log("  USDC balance:", usdc.balanceOf(whaleAccount));
    }

    function _deployTestContracts() internal {
        // Deploy InterestRateModel
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);
        console.log("InterestRateModel deployed at:", address(interestRateModel));

        // Deploy LiquidityCalculator
        liquidityCalculator = new LiquidityCalculator();
        console.log("LiquidityCalculator deployed at:", address(liquidityCalculator));

        // Deploy V4Oracle
        v4Oracle = new V4Oracle(positionManager, WETH_ADDRESS, address(0));
        v4Oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        v4Oracle.setSequencerUptimeFeed(SEQUENCER_UPTIME_FEED);

        // Configure token feeds
        v4Oracle.setTokenConfig(WETH_ADDRESS, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        v4Oracle.setTokenConfig(ETH_ADDRESS, AggregatorV3Interface(CHAINLINK_ETH_USD), MAX_FEED_AGE);
        v4Oracle.setTokenConfig(USDC_ADDRESS, AggregatorV3Interface(CHAINLINK_USDC_USD), MAX_FEED_AGE);
        console.log("V4Oracle deployed and configured at:", address(v4Oracle));

        // Deploy V4Utils
        v4Utils = new V4Utils(positionManager, BASE_UNIVERSAL_ROUTER, BASE_ZEROX_ALLOWANCE_HOLDER, permit2);
        console.log("V4Utils deployed at:", address(v4Utils));

        // Deploy RevertHookFunctions
        hookFunctions = new RevertHookFunctions(permit2, v4Oracle, ILiquidityCalculator(liquidityCalculator));
        console.log("RevertHookFunctions deployed at:", address(hookFunctions));

        // Deploy RevertHookFunctions2
        hookFunctions2 = new RevertHookFunctions2(permit2, v4Oracle, ILiquidityCalculator(liquidityCalculator));
        console.log("RevertHookFunctions2 deployed at:", address(hookFunctions2));

        // Deploy RevertHook with correct flags using deployCodeTo
        address hookFlags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );

        bytes memory constructorArgs =
            abi.encode(address(this), permit2, v4Oracle, ILiquidityCalculator(liquidityCalculator));
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, hookFlags);
        revertHook = RevertHook(hookFlags);
        console.log("RevertHook deployed at:", address(revertHook));

        // Deploy V4Vault
        vault = new V4Vault(
            "Revert Lend USDC",
            "rlUSDC",
            USDC_ADDRESS,
            positionManager,
            interestRateModel,
            v4Oracle,
            weth
        );

        // Configure vault
        vault.setTokenConfig(USDC_ADDRESS, uint32(Q32 * 9 / 10), type(uint32).max); // 90% CF
        vault.setTokenConfig(WETH_ADDRESS, uint32(Q32 * 9 / 10), type(uint32).max); // 90% CF
        vault.setTokenConfig(ETH_ADDRESS, uint32(Q32 * 9 / 10), type(uint32).max); // 90% CF
        vault.setLimits(0, 10_000_000_000_000, 10_000_000_000_000, 10_000_000_000_000, 10_000_000_000_000);
        vault.setReserveFactor(0);
        console.log("V4Vault deployed and configured at:", address(vault));

        // Register vault with RevertHook
        revertHook.setVault(address(vault));
        vault.setTransformer(address(revertHook), true);
        vault.setHookAllowList(address(revertHook), true);

        // Register V4Utils with vault
        v4Utils.setVault(address(vault));
        vault.setTransformer(address(v4Utils), true);

        console.log("Contract integrations configured");
    }

    // ==================== Helper Functions ====================

    function _createHookedPool() internal returns (PoolKey memory hookedPoolKey) {
        // First check if a non-hooked pool exists to get the price
        PoolKey memory nonHookedPoolKey = PoolKey({
            currency0: Currency.wrap(USDC_ADDRESS),
            currency1: Currency.wrap(WETH_ADDRESS),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        (uint160 existingSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(nonHookedPoolKey));

        // Create hooked pool key
        hookedPoolKey = PoolKey({
            currency0: Currency.wrap(USDC_ADDRESS),
            currency1: Currency.wrap(WETH_ADDRESS),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(revertHook))
        });

        // Initialize the hooked pool if not already initialized
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(hookedPoolKey));
        if (sqrtPriceX96 == 0) {
            // Use existing price or a reasonable default (~$2500 ETH/USDC)
            uint160 initPrice = existingSqrtPriceX96 > 0 ? existingSqrtPriceX96 : 1461446703485210103287273052203988822378723970341;
            poolManager.initialize(hookedPoolKey, initPrice);
            console.log("Hooked pool initialized");
        }
    }

    function _createPositionInHookedPool(PoolKey memory hookedPoolKey) internal returns (uint256 tokenId) {
        int24 tickLower = -887220; // Full range
        int24 tickUpper = 887220;

        // Approve tokens
        vm.startPrank(whaleAccount);
        usdc.approve(address(permit2), type(uint256).max);
        weth.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);

        // Mint position
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        uint128 liquidity = 1e14;
        params[0] = abi.encode(
            hookedPoolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, whaleAccount, bytes("")
        );
        params[1] = abi.encode(hookedPoolKey.currency0, hookedPoolKey.currency1, whaleAccount);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();

        tokenId = positionManager.nextTokenId() - 1;
        console.log("Created position with tokenId:", tokenId);
    }

    function _deposit(uint256 amount, address account) internal {
        vm.prank(account);
        usdc.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount, account);
    }

    function _swapExactInputSingle(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
    {
        bytes memory commands = hex"10"; // V4_SWAP action code
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, minAmountOut);

        inputs[0] = abi.encode(actions, params);

        vm.prank(whaleAccount);
        IUniversalRouter(address(swapRouter)).execute(commands, inputs, block.timestamp);
    }

    function _executeInstructions(uint256 tokenId, V4Utils.Instructions memory instructions, address owner)
        internal
        override
    {
        vm.prank(owner);
        IERC721(address(positionManager)).approve(address(v4Utils), tokenId);

        vm.prank(owner);
        v4Utils.execute(tokenId, instructions);
    }

    function _recordInitialBalances(address owner)
        internal
        view
        returns (uint256 initialWethBalance, uint256 initialUsdcBalance, uint256 initialEthBalance)
    {
        initialWethBalance = weth.balanceOf(owner);
        initialUsdcBalance = usdc.balanceOf(owner);
        initialEthBalance = owner.balance;

        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial ETH balance:", initialEthBalance);
    }

    function _recordFinalBalances(
        address owner,
        uint256 initialWethBalance,
        uint256 initialUsdcBalance,
        uint256 initialEthBalance
    ) internal view returns (uint256 finalWethBalance, uint256 finalUsdcBalance, uint256 finalEthBalance) {
        finalWethBalance = weth.balanceOf(owner);
        finalUsdcBalance = usdc.balanceOf(owner);
        finalEthBalance = owner.balance;

        console.log("Final WETH balance:", finalWethBalance);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Final ETH balance:", finalEthBalance);
        console.log("WETH change:", int256(finalWethBalance) - int256(initialWethBalance));
        console.log("USDC change:", int256(finalUsdcBalance) - int256(initialUsdcBalance));
    }
}
