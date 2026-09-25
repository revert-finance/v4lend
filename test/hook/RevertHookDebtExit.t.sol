// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RevertHookTest} from "./RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @notice Exercises real vault debt repayment and hook swaps without an RPC fork.
contract RevertHookDebtExitTest is RevertHookTest {
    function testDebtExitAllDirectionsAndLendAssets() public {
        for (uint256 i; i < 8; ++i) {
            uint256 snapshot = vm.snapshotState();
            _assertDebtExit(i & 1 != 0, i & 2 != 0, i & 4 != 0, true);
            vm.revertToState(snapshot);
        }
    }

    function testFuzzDebtExitReturnsConfiguredToken(bool upper, bool lendIsToken0, bool needsRepaymentSwap) public {
        _assertDebtExit(upper, lendIsToken0, needsRepaymentSwap, true);
    }

    function testFuzzDebtExitWithoutSwapPreservesResidualTokens(bool upper, bool lendIsToken0) public {
        _assertDebtExit(upper, lendIsToken0, false, false);
    }

    function _assertDebtExit(bool upper, bool lendIsToken0, bool needsRepaymentSwap, bool swapOnExit) internal {
        Currency lendCurrency = lendIsToken0 ? currency0 : currency1;
        IERC20 asset = IERC20(Currency.unwrap(lendCurrency));
        InterestRateModel rates = new InterestRateModel(0, 0, 0, 1 << 63);
        V4Vault vault = new V4Vault(
            "Test Lending Vault", "TLV", address(asset), positionManager, rates, v4Oracle, IWETH9(address(0))
        );
        uint32 collateralFactor = uint32((uint256(1) << 32) * 9 / 10);
        vault.setTokenConfig(Currency.unwrap(currency0), collateralFactor, type(uint32).max);
        vault.setTokenConfig(Currency.unwrap(currency1), collateralFactor, type(uint32).max);
        vault.setLimits(0, 100 ether, 100 ether, 100 ether, 100 ether);
        vault.setHookAllowList(address(hook), true);
        vault.setTransformer(address(hook), true);
        hook.setVault(address(vault));
        asset.approve(address(vault), 1 ether);
        vault.deposit(1 ether, address(this));
        IERC721(address(positionManager)).approve(address(vault), token3Id);
        vault.create(token3Id, address(this));
        vault.approveTransform(token3Id, address(hook), true);

        // The position holds approximately 0.03 of each token at the initial 1:1 price.
        // Exercise both sufficient lend balance and a required initial repayment swap.
        uint256 debt = needsRepaymentSwap ? 0.04 ether : 0.005 ether;
        vault.borrow(token3Id, debt);
        hook.setSwapProtectionConfig(token3Id, 10000, 10000);
        uint256 before0 = currency0.balanceOf(address(this));
        uint256 before1 = currency1.balanceOf(address(this));
        uint256 vaultBalance = asset.balanceOf(address(vault));

        RevertHookState.PositionConfig memory config;
        config.modeFlags = PositionModeFlags.MODE_AUTO_EXIT;
        config.autoExitTickLower = upper ? type(int24).min : int24(0);
        config.autoExitTickUpper = upper ? int24(0) : type(int24).max;
        config.autoExitSwapOnLowerTrigger = swapOnExit;
        config.autoExitSwapOnUpperTrigger = swapOnExit;
        hook.setPositionConfig(token3Id, config);

        assertEq(vault.loans(token3Id), 0, "all debt repaid");
        assertEq(asset.balanceOf(address(vault)) - vaultBalance, debt, "vault received repayment");
        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "position exited");
        uint256 received0 = currency0.balanceOf(address(this)) - before0;
        uint256 received1 = currency1.balanceOf(address(this)) - before1;
        if (!swapOnExit) {
            assertGt(received0, 0, "preserve existing token0 residual");
            assertGt(received1, 0, "preserve existing token1 residual");
        } else if (upper) {
            assertGt(received0, 0, "upper exit settles in token0");
            assertEq(received1, 0, "upper exit must sell token1 residual");
        } else {
            assertGt(received1, 0, "lower exit settles in token1");
            assertEq(received0, 0, "lower exit must sell token0 residual");
        }
        assertEq(currency0.balanceOf(address(hook)), 0, "no stranded token0");
        assertEq(currency1.balanceOf(address(hook)), 0, "no stranded token1");
    }
}
