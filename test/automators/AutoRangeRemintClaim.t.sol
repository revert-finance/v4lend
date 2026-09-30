// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";
import {AutoRange} from "src/automators/AutoRange.sol";

/// @notice External audit V4LE-115: AutoRange forwarded the operator's `mintHookData` into the replacement mint
///         without binding a tagged RevertHook remint claim to the token being range-changed. Owners grant the
///         deployed AutoRange a blanket `setApprovalForAll`, so a claim naming another owner's drained hooked
///         position passed the hook's locker-approval check and migrated that owner's hook config, swap
///         protection and carried fee onto the replacement minted for the executed position. The claim must
///         name `params.tokenId`.
contract AutoRangeRemintClaimTest is RevertHookTest {
    using EasyPosm for IPositionManager;

    AutoRange internal autoRange;
    address internal operator = makeAddr("operator");
    address internal victim = makeAddr("victim");
    uint256 internal victimTokenId;

    function _remintClaim(uint256 oldTokenId) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256("RevertHookRemintMigration(uint256)")), oldTokenId);
    }

    function _exitConfig() internal view returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            // a wide window so the migrated trigger is not already satisfied on the replacement range
            autoExitTickLower: tickLower2 - 30000,
            autoExitTickUpper: tickUpper2 + 30000,
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

    function _setUpAutoRange() internal {
        autoRange = new AutoRange(
            positionManager, address(swapRouter), address(0), permit2, IV4Oracle(address(v4Oracle)), operator, protocolFeeRecipient
        );

        // the victim: a hooked position with automation, drained through the normal standalone flow, and the
        // blanket AutoRange approval every standalone user grants
        (victimTokenId,) = positionManager.mint(
            poolKey, tickLower2, tickUpper2, 10e18, type(uint256).max, type(uint256).max, victim, block.timestamp, Constants.ZERO_BYTES
        );
        vm.startPrank(victim);
        hook.setPositionConfig(victimTokenId, _exitConfig());
        positionManager.decreaseLiquidity(
            victimTokenId, positionManager.getPositionLiquidity(victimTokenId), 0, 0, victim, block.timestamp, Constants.ZERO_BYTES
        );
        IERC721(address(positionManager)).setApprovalForAll(address(autoRange), true);
        vm.stopPrank();
        assertEq(positionManager.getPositionLiquidity(victimTokenId), 0, "victim drained");
        (uint8 victimFlags,,,,,,,,,,,,) = hook.positionConfigs(victimTokenId);
        assertEq(victimFlags, PositionModeFlags.MODE_AUTO_EXIT, "victim automation configured");

        // the executed position (this test's token3Id): standalone AutoRange config plus blanket approval
        autoRange.configToken(
            token3Id,
            address(0),
            AutoRange.PositionConfig({
                lowerTickLimit: 1,
                upperTickLimit: 1,
                lowerTickDelta: 60,
                upperTickDelta: 300,
                token0SlippageBps: 10000,
                token1SlippageBps: 10000,
                maxRewardX64: 0,
                onlyFees: false
            })
        );
        IERC721(address(positionManager)).setApprovalForAll(address(autoRange), true);

        // move the price below token3Id's range so the range change is ready (position is all token0,
        // the planned replacement above the price needs only token0)
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _params(bytes memory mintHookData) internal view returns (AutoRange.ExecuteParams memory) {
        return AutoRange.ExecuteParams({
            tokenId: token3Id,
            swap0To1: false,
            amountIn: 0,
            amountOutMin: 0,
            swapData: "",
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: "",
            mintHookData: mintHookData,
            rewardX64: 0
        });
    }

    function testV4LE115_AutoRangeRefusesAClaimNamingAnotherOwnersToken() public {
        _setUpAutoRange();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        autoRange.execute(_params(_remintClaim(victimTokenId)));

        assertEq(positionManager.nextTokenId(), nextId, "nothing minted");
        assertGt(positionManager.getPositionLiquidity(token3Id), 0, "executed position untouched");
        (uint8 victimFlags,,,,,,,,,,,,) = hook.positionConfigs(victimTokenId);
        assertEq(victimFlags, PositionModeFlags.MODE_AUTO_EXIT, "victim automation stays on the victim's token");
    }

    /// @dev Positive control: a claim naming the executed position itself is forwarded and honoured by the
    ///      hook (the new token is minted to AutoRange, the approved locker, and the old one is drained).
    function testV4LE115_AutoRangeForwardsAClaimNamingTheExecutedToken() public {
        _setUpAutoRange();
        uint256 newTokenId = positionManager.nextTokenId();

        vm.prank(operator);
        autoRange.execute(_params(_remintClaim(token3Id)));

        assertEq(positionManager.getPositionLiquidity(token3Id), 0, "old position drained");
        assertGt(positionManager.getPositionLiquidity(newTokenId), 0, "replacement minted");
        assertEq(IERC721(address(positionManager)).ownerOf(newTokenId), address(this), "replacement reaches the owner");
        (uint8 victimFlags,,,,,,,,,,,,) = hook.positionConfigs(victimTokenId);
        assertEq(victimFlags, PositionModeFlags.MODE_AUTO_EXIT, "victim automation untouched");
        (uint8 newFlags,,,,,,,,,,,,) = hook.positionConfigs(newTokenId);
        assertEq(newFlags, PositionModeFlags.MODE_NONE, "no foreign automation on the replacement");
    }
}
