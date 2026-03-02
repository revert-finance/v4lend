// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {V4Vault} from "../../src/V4Vault.sol";
import {V4Oracle, AggregatorV3Interface} from "../../src/V4Oracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {Swapper} from "../../src/utils/Swapper.sol";

import {IUniversalRouter} from "../../src/lib/IUniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {MockERC4626Vault} from "../utils/MockERC4626Vault.sol";

/// @title AutomatorTestBase
/// @notice Shared test base for all automator contract tests
contract AutomatorTestBase is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    uint256 constant MAINNET_FORK_BLOCK = 23248232;

    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC_ADDRESS = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CHAINLINK_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    address constant EX0x = 0x0000000000001fF3684f28c67538d4D072C22734;

    address WHALE_ACCOUNT = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;

    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IUniswapV4Router04 public swapRouter;
    IPermit2 public permit2;

    IWETH9 public weth;
    IERC20 public usdc;
    IERC20 public usdt;
    IERC20 public dai;
    IERC20 public wbtc;

    V4Oracle public v4Oracle;
    V4Vault public vault;
    InterestRateModel public interestRateModel;

    address public operator;
    address public withdrawer;

    function setUp() public virtual {
        // Fork mainnet
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/gwRYWylWRij2jXTnPXR90v-YqXh96PDX", MAINNET_FORK_BLOCK);

        // Use deployed contracts
        poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        swapRouter = IUniswapV4Router04(payable(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af));
        permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        // Initialize real tokens
        weth = IWETH9(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);
        usdt = IERC20(USDT_ADDRESS);
        dai = IERC20(DAI_ADDRESS);
        wbtc = IERC20(WBTC_ADDRESS);

        // Deploy oracle
        v4Oracle = new V4Oracle(positionManager, USDC_ADDRESS, address(0xdead));
        v4Oracle.setMaxPoolPriceDifference(1000);
        v4Oracle.setTokenConfig(USDC_ADDRESS, AggregatorV3Interface(CHAINLINK_USDC_USD), 3600 * 24 * 30);
        v4Oracle.setTokenConfig(DAI_ADDRESS, AggregatorV3Interface(CHAINLINK_DAI_USD), 3600 * 24 * 30);
        v4Oracle.setTokenConfig(WETH_ADDRESS, AggregatorV3Interface(CHAINLINK_ETH_USD), 3600 * 24 * 30);
        v4Oracle.setTokenConfig(WBTC_ADDRESS, AggregatorV3Interface(CHAINLINK_BTC_USD), 3600 * 24 * 30);
        v4Oracle.setTokenConfig(address(0), AggregatorV3Interface(CHAINLINK_ETH_USD), 3600 * 24 * 30);

        // Deploy interest rate model and vault
        interestRateModel = new InterestRateModel(0, Q64 * 5 / 100, Q64 * 109 / 100, Q64 * 80 / 100);
        vault = new V4Vault("Revert Lend usdc", "rlusdc", USDC_ADDRESS, positionManager, interestRateModel, v4Oracle, IWETH9(WETH_ADDRESS));
        vault.setTokenConfig(USDC_ADDRESS, uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(WETH_ADDRESS, uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(0), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 100000000000, 100000000000, 100000000000, 100000000000);
        vault.setReserveFactor(0);
        vault.setHookAllowList(address(0), true);

        // Set up operator and withdrawer
        operator = makeAddr("operator");
        withdrawer = makeAddr("withdrawer");
    }

    // --- Pool helpers ---

    function _createPool() internal returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _getCurrentTick(PoolKey memory poolKey) internal view returns (int24) {
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        return tick;
    }

    // --- Position helpers ---

    function _approveWhaleTokens() internal {
        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        weth.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _createFullRangePosition(PoolKey memory poolKey) internal returns (uint256 tokenId) {
        _approveWhaleTokens();
        tokenId = _mintPosition(poolKey, -887220, 887220, 1e14);
    }

    function _createNarrowPosition(PoolKey memory poolKey) internal returns (uint256 tokenId) {
        _approveWhaleTokens();
        int24 currentTick = _getCurrentTick(poolKey);
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing;
        tokenId = _mintPosition(poolKey, tickLower, tickUpper, 1e13);
    }

    function _mintPosition(PoolKey memory poolKey, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);
        params_array[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, WHALE_ACCOUNT, bytes("")
        );
        params_array[1] = abi.encode(poolKey.currency0, poolKey.currency1, WHALE_ACCOUNT);

        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities(abi.encode(actions, params_array), block.timestamp);
        tokenId = positionManager.nextTokenId() - 1;
    }

    // --- Vault helpers ---

    function _depositToVault(uint256 amount, address account) internal {
        vm.prank(account);
        usdc.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount, account);
    }

    function _addPositionToVault(uint256 tokenId) internal {
        vm.prank(WHALE_ACCOUNT);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vm.prank(WHALE_ACCOUNT);
        vault.create(tokenId, WHALE_ACCOUNT);
    }

    // --- Swap helpers ---

    function _swapExactInputSingle(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
    {
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(weth), address(swapRouter), type(uint160).max, type(uint48).max);

        bytes memory commands = hex"10";
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

        vm.prank(WHALE_ACCOUNT);
        IUniversalRouter(address(swapRouter)).execute(commands, inputs, block.timestamp);
    }

    function _generateFees(PoolKey memory poolKey) internal {
        _swapExactInputSingle(poolKey, true, 10e6, 0);
        _swapExactInputSingle(poolKey, false, 10e15, 0);
    }

    /// @dev Create Universal Router swap data for token swaps through the non-hooked USDC/WETH 3000 pool
    function _createSwapData(uint256 amountIn, uint256 amountOutMin, address tokenIn, address tokenOut)
        internal
        view
        returns (bytes memory swapData)
    {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            address(0), // recipient placeholder - will be the automator contract
            amountIn,
            amountOutMin,
            abi.encodePacked(tokenIn, uint24(3000), tokenOut),
            false
        );
        inputs[1] = abi.encode(tokenIn, address(0), 0);
        swapData = abi.encode(
            address(swapRouter), abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp))
        );
    }

    /// @dev Create Universal Router swap data with explicit recipient through V3 USDC/WETH 500 pool
    /// Uses CONTRACT_BALANCE (1 << 255) to swap whatever amount was transferred to the router
    function _createSwapDataWithRecipient(address tokenIn, address tokenOut, address recipient)
        internal
        view
        returns (bytes memory swapData)
    {
        uint256 CONTRACT_BALANCE = 1 << 255;
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            recipient,
            CONTRACT_BALANCE, // use whatever was transferred to the router
            0, // amountOutMin
            abi.encodePacked(tokenIn, uint24(500), tokenOut),
            false // payerIsUser
        );
        inputs[1] = abi.encode(tokenIn, recipient, 0);
        swapData = abi.encode(
            address(swapRouter), abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp))
        );
    }

    // --- Native ETH Pool Helpers ---

    /// @notice Create an ETH/USDC pool (native ETH as currency0, USDC as currency1)
    /// Uses fee=7777, tickSpacing=60 to avoid conflict with existing mainnet V4 pools
    function _createETHPool() internal returns (PoolKey memory poolKey) {
        // address(0) < USDC_ADDRESS, so ETH is always currency0
        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // Native ETH
            currency1: Currency.wrap(address(usdc)),
            fee: 7777,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Initialize the pool at ~1 ETH = 4318 USDC (matching Chainlink at fork block 23248232)
        // price = token1/token0 = USDC/ETH = 4318e6 / 1e18 = 4.318e-9
        // sqrtPrice = sqrt(4.318e-9) ≈ 6.571e-5
        // sqrtPriceX96 = 6.571e-5 * 2^96 ≈ 5206259495888489151463424
        poolManager.initialize(poolKey, 5206259495888489151463424);
    }

    function _approveWhaleTokensETH() internal {
        vm.prank(WHALE_ACCOUNT);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        // No approval needed for native ETH
    }

    function _createFullRangePositionETH(PoolKey memory poolKey) internal returns (uint256 tokenId) {
        _approveWhaleTokensETH();
        tokenId = _mintPositionETH(poolKey, -887220, 887220, 1e14);
    }

    function _createNarrowPositionETH(PoolKey memory poolKey) internal returns (uint256 tokenId) {
        _approveWhaleTokensETH();
        int24 currentTick = _getCurrentTick(poolKey);
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing;
        tokenId = _mintPositionETH(poolKey, tickLower, tickUpper, 1e13);
    }

    function _mintPositionETH(PoolKey memory poolKey, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        // For native ETH, need SETTLE_PAIR + SWEEP to handle excess ETH
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params_array = new bytes[](3);
        params_array[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, WHALE_ACCOUNT, bytes("")
        );
        params_array[1] = abi.encode(poolKey.currency0, poolKey.currency1, WHALE_ACCOUNT);
        params_array[2] = abi.encode(address(0), WHALE_ACCOUNT); // Sweep leftover ETH back to whale

        // Fund whale with ETH and send value
        vm.deal(WHALE_ACCOUNT, 1000 ether);
        vm.prank(WHALE_ACCOUNT);
        positionManager.modifyLiquidities{value: 100 ether}(abi.encode(actions, params_array), block.timestamp);
        tokenId = positionManager.nextTokenId() - 1;
    }

    function _swapExactInputSingleETH(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
    {
        vm.prank(WHALE_ACCOUNT);
        permit2.approve(address(usdc), address(swapRouter), type(uint160).max, type(uint48).max);

        bytes memory commands = hex"10";
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions;
        bytes[] memory params;

        if (zeroForOne) {
            // ETH → USDC: need SETTLE for ETH (native), TAKE_ALL for USDC
            actions = abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE),
                uint8(Actions.TAKE_ALL)
            );
            params = new bytes[](3);
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: true,
                    amountIn: amountIn,
                    amountOutMinimum: minAmountOut,
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(key.currency0, amountIn, true); // SETTLE native ETH
            params[2] = abi.encode(key.currency1, minAmountOut); // TAKE_ALL USDC
        } else {
            // USDC → ETH: need SETTLE_ALL for USDC, TAKE_ALL for ETH
            actions = abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            );
            params = new bytes[](3);
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: false,
                    amountIn: amountIn,
                    amountOutMinimum: minAmountOut,
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(key.currency1, amountIn); // SETTLE_ALL USDC
            params[2] = abi.encode(key.currency0, minAmountOut); // TAKE_ALL ETH (native)
        }

        inputs[0] = abi.encode(actions, params);

        if (zeroForOne) {
            vm.deal(WHALE_ACCOUNT, WHALE_ACCOUNT.balance + amountIn);
            vm.prank(WHALE_ACCOUNT);
            IUniversalRouter(address(swapRouter)).execute{value: amountIn}(commands, inputs, block.timestamp);
        } else {
            vm.prank(WHALE_ACCOUNT);
            IUniversalRouter(address(swapRouter)).execute(commands, inputs, block.timestamp);
        }
    }

    function _generateFeesETH(PoolKey memory poolKey) internal {
        // Swap ETH → USDC then USDC → ETH to generate fees
        _swapExactInputSingleETH(poolKey, true, 1e16, 0); // 0.01 ETH → USDC
        _swapExactInputSingleETH(poolKey, false, 10e6, 0); // 10 USDC → ETH
    }
}
