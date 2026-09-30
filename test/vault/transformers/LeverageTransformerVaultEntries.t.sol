// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
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

/// @dev A contract that merely owns a PositionManager NFT and answers the two vault calls the transformer
///      makes (`asset`, a no-op `borrow`), the shape V4LE-117 uses to pose as a vault.
contract NftOwnerPosingAsVault is IERC721Receiver {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }

    receive() external payable {}

    function borrow(uint256, uint256) external {}

    function repay(uint256, uint256, bool) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function approveNft(IERC721 nft, address to, uint256 tokenId) external {
        nft.approve(to, tokenId);
    }

    function callLeverageInTransform(LeverageTransformer t, LeverageTransformer.LeverageInTransformParams memory p)
        external
    {
        t.leverageInTransform(p);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Vault-callback entries of the LeverageTransformer (leverageUp / leverageDown / leverageInTransform).
///         Fork-free: a WETH vault serves a native-ETH pool, the shape the native alias (V4LE-84, V4LE-110)
///         is about, and the caller binding (V4LE-117) is exercised with an NFT-owning impostor.
contract LeverageTransformerVaultEntriesTest is BaseTest {
    using EasyPosm for IPositionManager;

    uint256 internal constant Q32 = 2 ** 32;

    WETH internal weth;
    MockERC20 internal token;
    PoolKey internal poolKey;
    MockV4Oracle internal oracle;
    V4Vault internal vault;
    LeverageTransformer internal transformer;

    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");

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

    // --- helpers ---

    /// @dev Opens a leveraged position for `user`: the range [600, 1200] sits above the 1:1 price, so it holds
    ///      only native ETH and the borrowed WETH must be unwrapped into it (the user's tokens come back).
    function _openNativeOnlyLeveragedPosition(uint256 borrowAmount) internal returns (uint256 tokenId) {
        vm.startPrank(user);
        token.approve(address(transformer), 100e18);
        tokenId = transformer.leverageIn(
            LeverageTransformer.LeverageInParams({
                vault: address(vault),
                token0: poolKey.currency0,
                token1: poolKey.currency1,
                fee: poolKey.fee,
                tickSpacing: poolKey.tickSpacing,
                hook: address(0),
                tickLower: 600,
                tickUpper: 1200,
                initialAmount: 100e18,
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
            })
        );
        vm.stopPrank();
        assertEq(vault.ownerOf(tokenId), user, "loan belongs to the user");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "leveraged position has liquidity");
    }

    function _leverageUpParams(uint256 tokenId, uint256 borrowAmount, uint256 amountAddMin0)
        internal
        view
        returns (LeverageTransformer.LeverageUpParams memory)
    {
        return LeverageTransformer.LeverageUpParams({
            tokenId: tokenId,
            borrowAmount: borrowAmount,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: amountAddMin0,
            amountAddMin1: 0,
            recipient: user,
            deadline: block.timestamp,
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: ""
        });
    }

    function _leverageDownParams(uint256 tokenId, uint128 liquidity)
        internal
        view
        returns (LeverageTransformer.LeverageDownParams memory)
    {
        return LeverageTransformer.LeverageDownParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            recipient: user,
            deadline: block.timestamp,
            decreaseLiquidityHookData: ""
        });
    }

    function _assertTransformerFlat() internal view {
        assertEq(address(transformer).balance, 0, "no native left in the transformer");
        assertEq(weth.balanceOf(address(transformer)), 0, "no WETH left in the transformer");
        assertEq(token.balanceOf(address(transformer)), 0, "no token left in the transformer");
    }

    // --- V4LE-117 ---

    /// @notice V4LE-117: `leverageInTransform` authenticated through the generic `_validateCaller`, which also
    ///         admits the NFT owner. A contract owning any small PositionManager NFT could therefore pose as
    ///         the vault (a no-op `borrow`, any `asset`) and have the transformer drain the NFT plus any balance
    ///         it happened to hold to an attacker-chosen recipient. Only a registered vault may call it.
    function testV4LE117_LeverageInTransformRejectsNftOwnerPosingAsVault() public {
        NftOwnerPosingAsVault impostor = new NftOwnerPosingAsVault(address(weth));
        (uint256 tokenId,) = positionManager.mint(
            poolKey, -600, 600, 1e18, 2e18, 2e18, address(impostor), block.timestamp, V4Constants.ZERO_BYTES
        );
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(impostor));
        impostor.approveNft(IERC721(address(positionManager)), address(transformer), tokenId);

        // a balance retained in the transformer from an earlier operation is what the impostor is after
        token.transfer(address(transformer), 5e18);

        LeverageTransformer.LeverageInTransformParams memory p = LeverageTransformer.LeverageInTransformParams({
            tokenId: tokenId,
            token0: poolKey.currency0,
            token1: poolKey.currency1,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hook: address(0),
            tickLower: -600,
            tickUpper: 600,
            borrowAmount: 0,
            amountIn: 0,
            amountOutMin: 0,
            swapData: "",
            swapDirection: true,
            amountAddMin0: 0,
            amountAddMin1: 0,
            recipient: attacker,
            deadline: block.timestamp,
            mintHookData: "",
            decreaseLiquidityHookData: ""
        });

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        impostor.callLeverageInTransform(transformer, p);

        assertEq(token.balanceOf(address(transformer)), 5e18, "retained balance untouched");
        assertEq(token.balanceOf(attacker), 0, "nothing reached the attacker");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(impostor), "NFT not moved");
        assertGt(positionManager.getPositionLiquidity(tokenId), 0, "NFT not drained");
    }

    /// @notice V4LE-117: the same binding applies to leverageUp / leverageDown, which borrow from and repay to
    ///         `msg.sender` as if it were the vault. A plain NFT owner is refused up front with `Unauthorized`
    ///         rather than failing (or not) somewhere inside the fake vault calls.
    function testV4LE117_LeverageUpAndDownRejectNftOwner() public {
        (uint256 tokenId,) = positionManager.mint(
            poolKey, -600, 600, 1e18, 2e18, 2e18, address(this), block.timestamp, V4Constants.ZERO_BYTES
        );
        IERC721(address(positionManager)).approve(address(transformer), tokenId);

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        transformer.leverageUp(_leverageUpParams(tokenId, 0, 0));

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        transformer.leverageDown(_leverageDownParams(tokenId, 1));
    }

    // --- V4LE-110 ---

    /// @notice V4LE-110: leverageUp compared the vault asset (WETH) with the raw pool currencies, so in a
    ///         native pool the borrowed WETH matched neither leg and was swept to the recipient as a "third
    ///         token" while the debt stayed with the position. The borrow must join the native leg.
    function testV4LE110_LeverageUpUnwrapsBorrowIntoNativePool() public {
        uint256 tokenId = _openNativeOnlyLeveragedPosition(50e18);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        uint256 userWethBefore = weth.balanceOf(user);
        uint256 userEthBefore = user.balance;

        // require nearly the whole borrow to land in the position: a swept borrow would add nothing
        vm.prank(user);
        vault.transform(
            tokenId, address(transformer), abi.encodeCall(transformer.leverageUp, (_leverageUpParams(tokenId, 10e18, 9.9e18)))
        );

        assertGt(positionManager.getPositionLiquidity(tokenId), liquidityBefore, "borrow added as liquidity");
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        assertEq(debt, 60e18, "debt grew by the borrow");
        assertEq(weth.balanceOf(user), userWethBefore, "no borrowed WETH swept to the recipient");
        assertLt(user.balance - userEthBefore, 0.1e18, "at most rounding dust returned");
        _assertTransformerFlat();
    }

    /// @notice V4LE-110 (same root cause on the way down): leverageDown found no lend leg in a native pool, so
    ///         the removed ETH could not repay the WETH debt and was handed to the recipient instead. The native
    ///         leg is wrapped and repaid; only what exceeds the debt goes back to the recipient as ETH.
    function testV4LE110_LeverageDownRepaysFromNativeLeg() public {
        uint256 tokenId = _openNativeOnlyLeveragedPosition(50e18);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        uint256 userEthBefore = user.balance;
        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        vm.prank(user);
        vault.transform(
            tokenId, address(transformer), abi.encodeCall(transformer.leverageDown, (_leverageDownParams(tokenId, liquidity / 2)))
        );

        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);
        uint256 repaid = debtBefore - debtAfter;
        assertGt(repaid, 20e18, "removed native leg repaid the WETH debt");
        assertEq(weth.balanceOf(address(vault)) - vaultWethBefore, repaid, "vault received the wrapped repayment");
        assertEq(user.balance, userEthBefore, "nothing left over below the debt");
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - liquidity / 2, "half removed");
        _assertTransformerFlat();
    }
}
