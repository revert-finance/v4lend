// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Constants as V4Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";

import {V4Vault} from "src/vault/V4Vault.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @notice Fork-free V4Vault harness: real PoolManager / PositionManager (BaseTest), a hook-less pool over two
///         mock tokens, a separate mock lend asset, a mock oracle whose position value is set per test, no
///         interest. Positions are minted by the test contract and handed to the vault with `borrower` as the
///         loan owner; `lender` funds the vault and `liquidator` is an unrelated third party.
abstract contract V4VaultLocalBase is BaseTest {
    using EasyPosm for IPositionManager;

    uint256 internal constant Q32 = 2 ** 32;
    uint32 internal constant COLLATERAL_FACTOR_X32 = uint32(Q32 * 9 / 10);

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    MockERC20 internal asset;
    MockV4Oracle internal oracle;
    V4Vault internal vault;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public virtual {
        // sane UTC-day arithmetic for the daily limit tests
        vm.warp(30 days);

        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        asset = deployToken();

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(poolKey, V4Constants.SQRT_PRICE_1_1);

        oracle = new MockV4Oracle(positionManager);
        vault = new V4Vault(
            "Revert Lend Test",
            "rlTEST",
            address(asset),
            positionManager,
            new InterestRateModel(0, 0, 0, 0),
            oracle,
            IWETH9(address(0))
        );
        vault.setTokenConfig(Currency.unwrap(currency0), COLLATERAL_FACTOR_X32, type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), COLLATERAL_FACTOR_X32, type(uint32).max);
        vault.setLimits(0, 1e30, 1e30, 1e30, 1e30);
        vault.setHookAllowList(address(0), true);
    }

    function _deposit(address from, uint256 amount) internal {
        asset.mint(from, amount);
        vm.startPrank(from);
        asset.approve(address(vault), amount);
        vault.deposit(amount, from);
        vm.stopPrank();
    }

    /// @dev Mints a position around the current price and adds it to the vault as `borrower`'s loan.
    function _createLoan(uint128 liquidity) internal returns (uint256 tokenId) {
        (tokenId,) = positionManager.mint(
            poolKey,
            -600,
            600,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            block.timestamp,
            V4Constants.ZERO_BYTES
        );
        IERC721(address(positionManager)).approve(address(vault), tokenId);
        vault.create(tokenId, borrower);
    }

    function _borrow(uint256 tokenId, uint256 amount) internal {
        vm.prank(borrower);
        vault.borrow(tokenId, amount);
    }

    function _liquidateAs(address who, uint256 tokenId, address recipient) internal returns (uint256, uint256) {
        (,,, uint256 cost,) = vault.loanInfo(tokenId);
        asset.mint(who, cost);
        vm.startPrank(who);
        asset.approve(address(vault), cost);
        (uint256 amount0, uint256 amount1) =
            vault.liquidate(IVault.LiquidateParams(tokenId, 0, 0, recipient, block.timestamp, ""));
        vm.stopPrank();
        return (amount0, amount1);
    }
}
