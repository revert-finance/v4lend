// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {LeverageTransformer} from "src/vault/transformers/LeverageTransformer.sol";
import {Automator} from "src/automators/Automator.sol";
import {AutoLeverage} from "src/automators/AutoLeverage.sol";
import {AutoExit} from "src/automators/AutoExit.sol";
import {Swapper} from "src/shared/swap/Swapper.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";

contract AutomatorSlippageHarness is Automator {
    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address _protocolFeeRecipient
    )
        Automator(
            _positionManager,
            _universalRouter,
            _zeroxAllowanceHolder,
            _permit2,
            _v4Oracle,
            _operator,
            _protocolFeeRecipient
        )
    {}

    function swapWithSlippageCheck(RouterSwapParams memory params, uint16 maxSwapSlippageBps)
        external
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        return _routerSwapWithSlippageCheck(params, maxSwapSlippageBps);
    }
}

/// @dev Values positions at 1:1 from their live liquidity and strict-reverts on same-underlying
///      (address(0), WETH) / (WETH, address(0)) oracle pool-price queries just like V4Oracle when
///      no redundant native/WETH pair exists.
contract LiveLiquidityMockV4Oracle is IV4Oracle {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error InvalidPair();

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    address public immutable wethAddress;

    mapping(address => mapping(address => PoolKey)) public poolKeys;

    constructor(IPositionManager _positionManager, address _wethAddress) {
        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
        wethAddress = _wethAddress;
    }

    function setPoolKey(address token0, address token1, PoolKey memory poolKey) external {
        poolKeys[token0][token1] = poolKey;
    }

    function getLiquidityForValue(uint256 tokenId, address, uint256)
        external
        view
        returns (uint128, uint256, uint256, uint256)
    {
        return (positionManager.getPositionLiquidity(tokenId), 0, 0, 2 ** 96);
    }

    function getRiskScore(uint256, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function validateRiskChange(uint256, address, uint256, uint256) external pure {}

    function validateBorrow(uint256, address) external pure {}

    function getPoolSqrtPriceX96(address token0, address token1) external view returns (uint160 sqrtPriceX96) {
        address norm0 = token0 == address(0) ? wethAddress : token0;
        address norm1 = token1 == address(0) ? wethAddress : token1;
        if (norm0 == norm1) {
            revert InvalidPair();
        }
        PoolKey memory key = poolKeys[token0][token1];
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }

    function getValue(uint256 tokenId, address)
        external
        view
        returns (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96)
    {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(info.tickLower()),
            TickMath.getSqrtPriceAtTick(info.tickUpper()),
            liquidity
        );
        return (amount0 + amount1, 0, 2 ** 96, 2 ** 96);
    }

    function getPositionBreakdown(uint256)
        external
        pure
        returns (Currency, Currency, uint24, uint128, uint256, uint256, uint128, uint128)
    {
        return (Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, 0, 0, 0, 0);
    }

    function getLiquidityAndFees(uint256) external pure returns (uint128, uint128, uint128) {
        return (0, 0, 0);
    }
}

/// @notice Fork-free regression tests for standalone automators (`AutoLeverage`, `AutoExit`, `Automator`)
///         operating on a WETH-asset `V4Vault` position in a native-ETH pool (`CurrencyLibrary.ADDRESS_ZERO`),
///         the standalone automator counterpart of `V4LE-49` and `V4LE-110`.
contract AutomatorNativeWethVaultTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;

    WETH internal weth;
    MockERC20 internal token;
    PoolKey internal poolKey;
    LiveLiquidityMockV4Oracle internal oracle;
    V4Vault internal vault;
    LeverageTransformer internal transformer;
    AutoLeverage internal autoLeverage;
    AutoExit internal autoExit;

    address internal operator = makeAddr("operator");
    address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address internal user = makeAddr("user");

    receive() external payable {}

    function setUp() public {
        deployArtifactsAndLabel();
        weth = new WETH();
        positionManager = IPositionManager(
            V4PositionManagerDeployer.deploy(address(poolManager), address(permit2), 300_000, address(0), address(weth))
        );
        token = deployToken();

        poolKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);
        vm.deal(address(this), 5_000 ether);
        _mintPositionEth(-887220, 887220, 1_000e18, address(this));

        oracle = new LiveLiquidityMockV4Oracle(positionManager, address(weth));
        oracle.setPoolKey(address(0), address(token), poolKey);
        oracle.setPoolKey(address(token), address(0), poolKey);

        vault = new V4Vault(
            "WETH vault",
            "rlWETH",
            address(weth),
            positionManager,
            new InterestRateModel(0, 0, 0, 0),
            oracle,
            IWETH9(address(weth))
        );
        vault.setTokenConfig(address(0), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(token), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 1e30, 1e30, 1e30, 1e30);
        vault.setHookAllowList(address(0), true);

        weth.deposit{value: 500 ether}();
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(500 ether, address(this));

        transformer = new LeverageTransformer(positionManager, address(swapRouter), address(0), permit2);
        autoLeverage = new AutoLeverage(
            positionManager, address(swapRouter), address(0), permit2, oracle, operator, protocolFeeRecipient
        );
        autoExit = new AutoExit(
            positionManager, address(swapRouter), address(0), permit2, oracle, operator, protocolFeeRecipient
        );

        vault.setTransformer(address(transformer), true);
        vault.setTransformer(address(autoLeverage), true);
        vault.setTransformer(address(autoExit), true);
        transformer.setVault(address(vault));
        autoLeverage.setVault(address(vault));
        autoExit.setVault(address(vault));

        vm.deal(user, 500 ether);
        token.transfer(user, 1_000e18);
    }

    function _mintPositionEth(int24 tickLower, int24 tickUpper, uint128 liquidity, address recipient)
        internal
        returns (uint256 tokenId)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, recipient, bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        params[2] = abi.encode(address(0), address(this));

        positionManager.modifyLiquidities{value: 2_000 ether}(abi.encode(actions, params), block.timestamp);
        tokenId = positionManager.nextTokenId() - 1;
    }

    /// @dev Mints a native-only position `[600, 1200]` (above current tick 0, so 100% native ETH)
    ///      worth ~100 ETH, deposits it into the WETH vault, and borrows `borrowAmount` WETH.
    function _createNativeOnlyVaultLoan(uint256 borrowAmount) internal returns (uint256 tokenId) {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(600), TickMath.getSqrtPriceAtTick(1200), 100 ether
        );
        tokenId = _mintPositionEth(600, 1200, liquidity, user);

        vm.startPrank(user);
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vault.create(tokenId, user);
        if (borrowAmount > 0) {
            vault.borrow(tokenId, borrowAmount);
        }
        vm.stopPrank();
    }

    function _assertAutomatorFlat(address target) internal view {
        assertEq(target.balance, 0, "no native ETH left in automator");
        assertEq(weth.balanceOf(target), 0, "no WETH left in automator");
        assertEq(token.balanceOf(target), 0, "no token1 left in automator");
    }

    /// @notice AutoLeverage leverage-up on a WETH-vault loan in a native-ETH pool unwraps borrowed WETH into
    ///         the native ETH leg and adds it as position liquidity instead of sweeping it as a third token.
    function testAutoLeverage_WethVaultNativePoolLeverageUpUnwrapsBorrowIntoNativeLeg() public {
        // Position worth ~100 ETH -> collateralValue ~90 ETH. Borrow 36 WETH -> initial ratio = 4000 bps (40%).
        uint256 tokenId = _createNativeOnlyVaultLoan(36 ether);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        uint256 userWethBefore = weth.balanceOf(user);

        // Configure target = 5000 bps (50%), threshold = 500 bps (5%).
        vm.startPrank(user);
        vault.approveTransform(tokenId, address(autoLeverage), true);
        autoLeverage.configToken(
            tokenId,
            AutoLeverage.PositionConfig({
                isActive: true,
                targetLeverageBps: 5000,
                rebalanceThresholdBps: 500,
                maxSwapSlippageBps: 500,
                maxRewardX64: 0
            })
        );
        vm.stopPrank();

        vm.prank(operator);
        autoLeverage.execute(
            AutoLeverage.ExecuteParams({
                tokenId: tokenId,
                vault: address(vault),
                leverageUp: true,
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                amountAddMin0: 15 ether,
                amountAddMin1: 0,
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                deadline: block.timestamp,
                decreaseLiquidityHookData: "",
                increaseLiquidityHookData: "",
                rewardX64: 0
            })
        );

        assertGt(positionManager.getPositionLiquidity(tokenId), liquidityBefore, "borrowed WETH added as native liquidity");
        (uint256 debtAfter,, uint256 collateralAfter,,) = vault.loanInfo(tokenId);
        assertGt(debtAfter, 36 ether, "debt increased");
        uint256 ratioAfter = debtAfter * 10000 / collateralAfter;
        assertApproxEqAbs(ratioAfter, 5000, 5, "landed on target leverage ratio");
        assertEq(weth.balanceOf(user), userWethBefore, "borrowed WETH was not swept out as a third token");
        _assertAutomatorFlat(address(autoLeverage));
    }

    /// @notice AutoLeverage leverage-down on a WETH-vault loan in a native-ETH pool wraps removed native ETH
    ///         into WETH and repays the vault debt down to target.
    function testAutoLeverage_WethVaultNativePoolLeverageDownWrapsNativeLegAndRepaysDebt() public {
        // Position worth ~100 ETH -> collateralValue ~90 ETH. Borrow 63 WETH -> initial ratio = 7000 bps (70%).
        uint256 tokenId = _createNativeOnlyVaultLoan(63 ether);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        // Configure target = 4000 bps (40%), threshold = 500 bps (5%).
        vm.startPrank(user);
        vault.approveTransform(tokenId, address(autoLeverage), true);
        autoLeverage.configToken(
            tokenId,
            AutoLeverage.PositionConfig({
                isActive: true,
                targetLeverageBps: 4000,
                rebalanceThresholdBps: 500,
                maxSwapSlippageBps: 500,
                maxRewardX64: 0
            })
        );
        vm.stopPrank();

        vm.prank(operator);
        autoLeverage.execute(
            AutoLeverage.ExecuteParams({
                tokenId: tokenId,
                vault: address(vault),
                leverageUp: false,
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                amountAddMin0: 0,
                amountAddMin1: 0,
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                deadline: block.timestamp,
                decreaseLiquidityHookData: "",
                increaseLiquidityHookData: "",
                rewardX64: 0
            })
        );

        (uint256 debtAfter,, uint256 collateralAfter,,) = vault.loanInfo(tokenId);
        uint256 repaid = debtBefore - debtAfter;
        assertGt(repaid, 30 ether, "native ETH leg wrapped and repaid WETH debt");
        assertEq(weth.balanceOf(address(vault)) - vaultWethBefore, repaid, "vault received wrapped WETH repayment");
        assertLt(positionManager.getPositionLiquidity(tokenId), liquidityBefore, "liquidity removed for deleverage");
        uint256 ratioAfter = debtAfter * 10000 / collateralAfter;
        assertApproxEqAbs(ratioAfter, 4000, 5, "landed on target leverage ratio");
        _assertAutomatorFlat(address(autoLeverage));
    }

    /// @notice AutoExit on a WETH-vault loan in a native-ETH pool accepts the position, wraps the required
    ///         native ETH into WETH to repay the vault debt (including dipping into reserved reward when needed),
    ///         and sends the remaining native ETH equity to the owner instead of reverting `InvalidConfig()`.
    function testAutoExit_WethVaultNativePoolRepaysDebtFromNativeProceeds() public {
        uint256 tokenId = _createNativeOnlyVaultLoan(60 ether);
        uint64 maxRewardX64 = uint64(Q64 / 100); // 1%
        uint256 userEthBefore = user.balance;
        uint256 feeRecipientEthBefore = protocolFeeRecipient.balance;
        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        // Current tick is 0, which is <= token0TriggerTick (600), so lower trigger is active.
        vm.startPrank(user);
        vault.approveTransform(tokenId, address(autoExit), true);
        autoExit.configToken(
            tokenId,
            AutoExit.PositionConfig({
                isActive: true,
                token0Swap: false,
                token1Swap: false,
                token0TriggerTick: 600,
                token1TriggerTick: 1200,
                token0SlippageBps: 500,
                token1SlippageBps: 500,
                maxRewardX64: maxRewardX64,
                onlyFees: false
            })
        );
        vm.stopPrank();

        vm.prank(operator);
        autoExit.executeWithVault(
            AutoExit.ExecuteParams({
                tokenId: tokenId,
                swapData: "",
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                amountOutMin: 0,
                deadline: block.timestamp,
                hookData: "",
                rewardX64: maxRewardX64,
                repayAmountIn: 0,
                repayAmountOutMin: 0,
                repaySwapData: ""
            }),
            address(vault)
        );

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        assertEq(debtAfter, 0, "WETH debt fully repaid from native ETH proceeds");
        assertEq(weth.balanceOf(address(vault)) - vaultWethBefore, 60 ether, "vault received 60 WETH");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "position liquidity fully exited");
        assertGt(protocolFeeRecipient.balance - feeRecipientEthBefore, 0, "protocol fee paid in native ETH");
        assertGt(user.balance - userEthBefore, 38 ether, "owner received net native ETH equity");
        _assertAutomatorFlat(address(autoExit));
    }

    /// @notice Direct wrapped-native swap in `_routerSwapWithSlippageCheck` succeeds when `maxSwapSlippageBps < 10000`
    ///         without querying `v4Oracle.getPoolSqrtPriceX96` on the identical underlying `(WETH, address(0))` pair.
    function testAutomator_DirectWrappedNativeSwapPassesSlippageCheck() public {
        AutomatorSlippageHarness harness = new AutomatorSlippageHarness(
            positionManager, address(swapRouter), address(0), permit2, oracle, operator, protocolFeeRecipient
        );
        vm.deal(address(harness), 2 ether);

        (uint256 inWrap, uint256 outWrap) = harness.swapWithSlippageCheck(
            Swapper.RouterSwapParams({
                tokenIn: CurrencyLibrary.ADDRESS_ZERO,
                tokenOut: Currency.wrap(address(weth)),
                amountIn: 2 ether,
                amountOutMin: 2 ether,
                swapData: ""
            }),
            100 // 1% slippage cap enabled; oracle.getPoolSqrtPriceX96(address(0), address(weth)) would revert InvalidPair()
        );
        assertEq(inWrap, 2 ether, "wrapped 2 ETH");
        assertEq(outWrap, 2 ether, "received 2 WETH");
        assertEq(weth.balanceOf(address(harness)), 2 ether);

        (uint256 inUnwrap, uint256 outUnwrap) = harness.swapWithSlippageCheck(
            Swapper.RouterSwapParams({
                tokenIn: Currency.wrap(address(weth)),
                tokenOut: CurrencyLibrary.ADDRESS_ZERO,
                amountIn: 2 ether,
                amountOutMin: 2 ether,
                swapData: ""
            }),
            100
        );
        assertEq(inUnwrap, 2 ether, "unwrapped 2 WETH");
        assertEq(outUnwrap, 2 ether, "received 2 ETH");
        assertEq(address(harness).balance, 2 ether);
    }
}
