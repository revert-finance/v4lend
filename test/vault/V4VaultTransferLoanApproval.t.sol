// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Vm} from "forge-std/Vm.sol";

import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";

/// @notice External audit V4LE-76: `transferLoan` moved the loan but left the former owner's transform
///         approval for the pool hook behind. The hook's automation is keyed by token id and stayed armed,
///         while every hook transform now resolved the new owner and failed `Unauthorized`, consuming the
///         trigger. The hook's approval has to follow the loan (and leave the former owner).
/// @dev Fork-free: local PoolManager, real RevertHook stack and a real V4Vault lending currency0.
contract V4VaultTransferLoanApprovalTest is RevertHookTest {
    address internal newOwner = makeAddr("newOwner");
    address internal operator = makeAddr("operator");

    function _deployLendVault(Currency lendCurrency) internal returns (V4Vault lendVault) {
        lendVault = new V4Vault(
            "Local lending vault",
            "lLOCAL",
            Currency.unwrap(lendCurrency),
            positionManager,
            new InterestRateModel(0, 0, 0, 0),
            v4Oracle,
            NativeWrapper(payable(address(positionManager))).WETH9()
        );
        uint32 collateralFactor = uint32(uint256(2 ** 32) * 9 / 10);
        lendVault.setTokenConfig(Currency.unwrap(currency0), collateralFactor, type(uint32).max);
        lendVault.setTokenConfig(Currency.unwrap(currency1), collateralFactor, type(uint32).max);
        lendVault.setHookAllowList(address(hook), true);
        lendVault.setTransformer(address(hook), true);
        lendVault.setLimits(0, 10e18, 10e18, 10e18, 10e18);
        hook.setVault(address(lendVault));
    }

    function _autoExitConfig(int24 lower, int24 upper) internal pure returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: lower,
            autoExitTickUpper: upper,
            autoExitSwapOnLowerTrigger: false,
            autoExitSwapOnUpperTrigger: false,
            autoRangeLowerLimit: 0,
            autoRangeUpperLimit: 0,
            autoRangeLowerDelta: 0,
            autoRangeUpperDelta: 0,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: 0
        });
    }

    /// @dev Vault-held position with an armed exit trigger, approved for the hook, then transferred.
    function _armedTransferredLoan() internal returns (V4Vault lendVault) {
        lendVault = _deployLendVault(currency0);
        hook.setPositionConfig(token2Id, _autoExitConfig(tickLower2 - poolKey.tickSpacing, tickUpper2));
        IERC721(address(positionManager)).approve(address(lendVault), token2Id);
        lendVault.create(token2Id, address(this));
        lendVault.approveTransform(token2Id, address(hook), true);
        lendVault.approveTransform(token2Id, operator, true);

        lendVault.transferLoan(token2Id, newOwner);
        assertEq(lendVault.ownerOf(token2Id), newOwner);
    }

    function testTransferLoanMovesTheHookApprovalToTheNewOwner() public {
        V4Vault lendVault = _armedTransferredLoan();
        assertTrue(lendVault.transformApprovals(newOwner, token2Id, address(hook)), "hook approval follows the loan");
        assertFalse(
            lendVault.transformApprovals(address(this), token2Id, address(hook)), "former owner's approval is gone"
        );
        // an operator approval is a relationship of the former owner and does not follow
        assertFalse(lendVault.transformApprovals(newOwner, token2Id, operator), "operator approval stays behind");
    }

    function testArmedAutomationKeepsWorkingAfterTransferLoan() public {
        _armedTransferredLoan();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(token2Id);
        assertGt(liquidityBefore, 0);

        // a public swap crosses the exit trigger; the hook transforms through the vault as the new owner's approved caller
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 7e17,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawActionFailed(logs, token2Id), "the exit must not fail on a stale approval");
        assertEq(positionManager.getPositionLiquidity(token2Id), 0, "auto-exit executed for the transferred loan");
        assertGt(
            IERC20(Currency.unwrap(currency0)).balanceOf(newOwner) + IERC20(Currency.unwrap(currency1)).balanceOf(newOwner),
            0,
            "proceeds reach the new owner"
        );
    }

    function _sawActionFailed(Vm.Log[] memory logs, uint256 forTokenId) internal pure returns (bool) {
        bytes32 topic = RevertHookState.HookActionFailed.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == forTokenId) {
                return true;
            }
        }
        return false;
    }
}
