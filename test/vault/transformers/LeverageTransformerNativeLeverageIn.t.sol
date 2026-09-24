// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {LeverageTransformer} from "src/vault/transformers/LeverageTransformer.sol";

/// @notice External audit V4LE-84: `leverageIn` required one raw pool currency to equal the vault asset, so a
///         WETH-asset vault could not open a leveraged position in a native-ETH pool although the vault,
///         the oracle and the transformer's own leverageUp/leverageDown treat WETH as the native alias.
/// @dev Fork-free. The PositionManager is redeployed with a real WETH9 so the transformer knows the wrapped
///      native token; the vault lends WETH, the pool is ETH/token.
contract LeverageTransformerNativeLeverageInTest is BaseTest {
    using EasyPosm for IPositionManager;

    uint256 internal constant Q32 = 2 ** 32;

    WETH internal weth;
    MockERC20 internal token;
    PoolKey internal poolKey;
    MockV4Oracle internal oracle;
    V4Vault internal vault;
    LeverageTransformer internal transformer;

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
        vm.deal(address(this), 5000 ether);
        positionManager.mint(
            poolKey, -887220, 887220, 1000e18, 1001e18, 1001e18, address(this), block.timestamp, V4Constants.ZERO_BYTES
        );

        oracle = new MockV4Oracle(positionManager);
        oracle.setMockPositionValue(1000 ether);
        vault = new V4Vault(
            "WETH vault", "rlWETH", address(weth), positionManager, new InterestRateModel(0, 0, 0, 0), oracle, IWETH9(address(weth))
        );
        vault.setTokenConfig(address(0), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setTokenConfig(address(token), uint32(Q32 * 9 / 10), type(uint32).max);
        vault.setLimits(0, 1e30, 1e30, 1e30, 1e30);
        vault.setHookAllowList(address(0), true);

        weth.deposit{value: 500 ether}();
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(500 ether, address(this));

        transformer = new LeverageTransformer(positionManager, address(swapRouter), address(0), permit2);
        vault.setTransformer(address(transformer), true);
        transformer.setVault(address(vault));

        token.transfer(user, 1000e18);
    }

    function _params(uint256 initialAmount, uint256 borrowAmount)
        internal
        view
        returns (LeverageTransformer.LeverageInParams memory)
    {
        return LeverageTransformer.LeverageInParams({
            vault: address(vault),
            token0: poolKey.currency0,
            token1: poolKey.currency1,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hook: address(0),
            tickLower: -600,
            tickUpper: 600,
            initialAmount: initialAmount,
            borrowAmount: borrowAmount,
            amountIn: 0,
            amountOutMin: 0,
            swapData: "",
            swapDirection: true,
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: user,
            deadline: block.timestamp,
            mintHookData: "",
            mintFinalHookData: "",
            decreaseLiquidityHookData: ""
        });
    }

    function testLeverageInAcceptsNativePoolForWethVault() public {
        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        vm.startPrank(user);
        token.approve(address(transformer), 100e18);
        uint256 tokenId = transformer.leverageIn(_params(100e18, 50e18));
        vm.stopPrank();

        assertEq(vault.ownerOf(tokenId), user, "loan belongs to the user");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault), "NFT held by the vault");
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        assertTrue(key.currency0.isAddressZero(), "position lives in the native pool");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "position has liquidity");
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        assertEq(debt, 50e18, "borrowed WETH backs the position");
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore - 50e18, "vault lent the WETH");

        // the transformer ends flat: the unwrapped borrow went into the position or back to the user
        assertEq(address(transformer).balance, 0, "no native left in the transformer");
        assertEq(weth.balanceOf(address(transformer)), 0, "no WETH left in the transformer");
        assertEq(token.balanceOf(address(transformer)), 0, "no token left in the transformer");
        assertGt(user.balance + token.balanceOf(user), 0, "leftovers reach the recipient");
    }

    function testLeverageInStillRejectsPoolsWithoutTheLendToken() public {
        MockERC20 other = deployToken();
        LeverageTransformer.LeverageInParams memory params = _params(1e18, 1e18);
        (address a, address b) = address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        params.token0 = Currency.wrap(a);
        params.token1 = Currency.wrap(b);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("InvalidToken()"));
        transformer.leverageIn(params);
    }
}
