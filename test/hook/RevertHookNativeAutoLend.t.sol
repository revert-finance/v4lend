// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {RevertHook} from "src/RevertHook.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {LiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {MockERC4626Vault} from "test/utils/MockERC4626Vault.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";

contract NativeFeeRecipientProbe {
    RevertHook internal immutable hook;
    IWETH9 internal immutable weth;
    uint256 internal immutable tokenId;

    uint256 public nativeReceived;
    uint256 public observedAutoLendShares;

    constructor(RevertHook _hook, IWETH9 _weth, uint256 _tokenId) {
        hook = _hook;
        weth = _weth;
        tokenId = _tokenId;
    }

    receive() external payable {
        nativeReceived += msg.value;
        (,,, , uint256 autoLendShares,,,) = hook.positionStates(tokenId);
        observedAutoLendShares = autoLendShares;
    }

    function wethBalance() external view returns (uint256) {
        return weth.balanceOf(address(this));
    }
}

contract RevertHookNativeAutoLendTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency internal constant NATIVE = CurrencyLibrary.ADDRESS_ZERO;

    MockERC20 internal token1;
    IWETH9 internal weth;
    RevertHook internal hook;
    LiquidityCalculator internal liquidityCalculator;
    MockV4Oracle internal v4Oracle;
    MockERC4626Vault internal wethVault;
    MockERC4626Vault internal token1Vault;

    PoolKey internal poolKey;
    uint256 internal tokenId;
    int24 internal positionTickLower;
    int24 internal positionTickUpper;

    receive() external payable {}

    function deployPositionManager() internal override {
        if (block.chainid == 31337) {
            WETH wrappedNative = new WETH();
            positionManager = IPositionManager(
                V4PositionManagerDeployer.deploy(
                    address(poolManager), address(permit2), 300_000, address(0), address(wrappedNative)
                )
            );
        } else {
            super.deployPositionManager();
        }
    }

    function setUp() public {
        deployArtifactsAndLabel();

        token1 = deployToken();
        weth = NativeWrapper(payable(address(positionManager))).WETH9();

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4445 << 144)
        );

        v4Oracle = new MockV4Oracle(positionManager);
        liquidityCalculator = new LiquidityCalculator();

        RevertHookPositionActions positionActions =
            new RevertHookPositionActions(permit2, v4Oracle, liquidityCalculator);
        RevertHookAutoLeverageActions autoLeverageActions =
            new RevertHookAutoLeverageActions(permit2, v4Oracle, liquidityCalculator);
        RevertHookAutoLendActions autoLendActions =
            new RevertHookAutoLendActions(permit2, v4Oracle, liquidityCalculator);

        bytes memory constructorArgs = abi.encode(
            address(this),
            makeAddr("protocolFeeRecipient"),
            permit2,
            v4Oracle,
            liquidityCalculator,
            positionActions,
            autoLeverageActions,
            autoLendActions
        );
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, flags);
        hook = RevertHook(payable(flags));

        wethVault = new MockERC4626Vault(IERC20(address(weth)), "Wrapped Native Vault", "vWETH");
        token1Vault = new MockERC4626Vault(IERC20(address(token1)), "Token1 Vault", "vT1");

        hook.setAutoLendVault(address(0), IERC4626(address(wethVault)));
        hook.setAutoLendVault(address(token1), IERC4626(address(token1Vault)));

        poolKey = PoolKey({
            currency0: NATIVE,
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        v4Oracle.setPoolKey(address(0), address(token1), poolKey);

        vm.deal(address(this), 1_000 ether);
        _mintPositionEth(poolKey, TickMath.minUsableTick(poolKey.tickSpacing), TickMath.maxUsableTick(poolKey.tickSpacing), 100e18);

        int24 currentTick = _getCurrentTick();
        positionTickLower = _getTickLower(currentTick, poolKey.tickSpacing) - poolKey.tickSpacing;
        positionTickUpper = _getTickLower(currentTick, poolKey.tickSpacing) + poolKey.tickSpacing;
        tokenId = _mintPositionEth(poolKey, positionTickLower, positionTickUpper, 100e18);

        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 60,
                autoLeverageTargetBps: 0
            })
        );
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);
    }

    function testSetAutoLendVault_AllowsNativeTokenConfigWithWethVault() public view {
        assertEq(address(hook.autoLendVaults(address(0))), address(wethVault), "native auto-lend vault should use WETH");
    }

    function testAutoLend_DepositAndWithdrawNativePosition() public {
        uint256 wethVaultAssetsBefore = wethVault.totalAssets();

        _swapExactInputSingleEth(poolKey, true, 2e18, 0);

        (,,, address autoLendToken, uint256 autoLendShares,, address autoLendVault,) = hook.positionStates(tokenId);
        assertEq(autoLendToken, address(0), "native side should be parked as ETH");
        assertEq(autoLendVault, address(wethVault), "hook should remember the WETH vault");
        assertGt(autoLendShares, 0, "deposit should mint vault shares");
        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "deposit should remove LP liquidity");
        assertGt(wethVault.totalAssets(), wethVaultAssetsBefore, "wrapped native vault should receive funds");
        assertEq(address(hook).balance, 0, "hook should not retain ETH after wrapping");
        assertEq(weth.balanceOf(address(hook)), 0, "hook should not retain WETH after deposit");

        _pushTickToOrAbove(positionTickLower - 120);

        uint256 currentTokenId = positionManager.nextTokenId() - 1;
        (,,, address autoLendTokenAfter, uint256 autoLendSharesAfter,,,) = hook.positionStates(currentTokenId);
        assertEq(autoLendTokenAfter, address(0), "withdraw should clear the parked token");
        assertEq(autoLendSharesAfter, 0, "withdraw should clear vault shares");
        assertGt(positionManager.getPositionLiquidity(currentTokenId), 0, "withdraw should restore liquidity");
        assertEq(address(hook).balance, 0, "hook should not retain ETH after reentry");
        assertEq(weth.balanceOf(address(hook)), 0, "hook should not retain WETH after reentry");
    }

    function testAutoLend_ForceExitUnwrapsNativePosition() public {
        _swapExactInputSingleEth(poolKey, true, 2e18, 0);

        (,,, address autoLendToken, uint256 autoLendShares,,,) = hook.positionStates(tokenId);
        assertEq(autoLendToken, address(0), "position should be parked in native auto-lend");
        assertGt(autoLendShares, 0, "position should hold vault shares before force exit");

        hook.autoLendForceExit(tokenId);

        (,,, address autoLendTokenAfter, uint256 autoLendSharesAfter,,,) = hook.positionStates(tokenId);
        assertEq(autoLendTokenAfter, address(0), "force exit should clear parked token state");
        assertEq(autoLendSharesAfter, 0, "force exit should clear parked shares");
        assertEq(address(hook).balance, 0, "force exit should not strand ETH in the hook");
        assertEq(weth.balanceOf(address(hook)), 0, "force exit should not strand WETH in the hook");
    }

    function testAutoLend_WithdrawSendsNativeProtocolFeesInEth() public {
        _swapExactInputSingleEth(poolKey, true, 2e18, 0);

        (,,, address autoLendToken, uint256 autoLendShares, uint256 autoLendAmount,,) = hook.positionStates(tokenId);
        assertEq(autoLendToken, address(0), "position should be parked in native auto-lend");
        assertGt(autoLendShares, 0, "position should hold vault shares before withdraw");

        NativeFeeRecipientProbe feeRecipient = new NativeFeeRecipientProbe(hook, weth, tokenId);
        hook.setProtocolFeeRecipient(address(feeRecipient));

        uint256 donatedYield = autoLendAmount + 1;
        weth.deposit{value: donatedYield}();
        IERC20(address(weth)).transfer(address(wethVault), donatedYield);
        wethVault.simulatePositiveYield(10000);

        _pushTickToOrAbove(positionTickLower - 120);

        assertGt(address(feeRecipient).balance, 0, "fee recipient should receive native ETH");
        assertEq(feeRecipient.wethBalance(), 0, "fee recipient should not receive WETH");
        assertEq(
            feeRecipient.observedAutoLendShares(), 0, "auto-lend shares should already be cleared during fee callback"
        );
    }

    function _mintPositionEth(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 newTokenId)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        params[2] = abi.encode(address(0), address(this));

        positionManager.modifyLiquidities{value: 100 ether}(abi.encode(actions, params), block.timestamp);
        newTokenId = positionManager.nextTokenId() - 1;
    }

    function _swapExactInputSingleEth(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
    {
        swapRouter.swapExactTokensForTokens{value: zeroForOne ? amountIn : 0}(
            amountIn, minAmountOut, zeroForOne, key, bytes(""), address(this), block.timestamp
        );
    }

    function _pushTickToOrAbove(int24 targetTick) internal {
        uint256 attempts;
        while (_getCurrentTick() < targetTick && attempts < 12) {
            _swapExactInputSingleEth(poolKey, false, 2e18, 0);
            unchecked {
                ++attempts;
            }
        }
        assertGe(_getCurrentTick(), targetTick, "price should recover into the withdraw zone");
    }

    function _getCurrentTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        return tick < 0 && tick % tickSpacing != 0 ? (tick / tickSpacing - 1) * tickSpacing : (tick / tickSpacing) * tickSpacing;
    }
}
