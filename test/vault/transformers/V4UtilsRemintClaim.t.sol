// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {V4Utils} from "src/vault/transformers/V4Utils.sol";

/// @notice External audit V4LE-9: V4Utils forwarded caller-chosen hookData into every mint and increase. A
///         tagged remint claim `abi.encodePacked(REMINT_MIGRATION_TAG, oldTokenId)` is honoured by the hook
///         when the PositionManager locker (V4Utils) is approved on the old token, so after a victim used the
///         documented direct range-change flow (approve V4Utils, drain) anyone could mint a small position
///         through the permissionless `swapAndMint` and claim the victim's automation. V4Utils must only
///         forward a claim that names the token its own range change is draining for the authorized caller.
contract V4UtilsRemintClaimTest is RevertHookTest {
    using EasyPosm for IPositionManager;

    address internal attacker = makeAddr("attacker");

    function _remintClaim(uint256 oldTokenId) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256("RevertHookRemintMigration(uint256)")), oldTokenId);
    }

    function _exitConfig() internal view returns (RevertHookState.PositionConfig memory) {
        return RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_EXIT,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: false,
            autoExitTickLower: tickLower2 - poolKey.tickSpacing,
            autoExitTickUpper: tickUpper2,
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

    /// @dev The victim (this) configures automation, approves V4Utils for a direct range change and removes
    ///      the liquidity: the drained NFT keeps the approval, the normal post-withdrawal state.
    function _victimDrainedWithApproval(V4Utils v4Utils) internal {
        hook.setPositionConfig(token2Id, _exitConfig());
        IERC721(address(positionManager)).approve(address(v4Utils), token2Id);
        positionManager.decreaseLiquidity(
            token2Id,
            positionManager.getPositionLiquidity(token2Id),
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        assertEq(positionManager.getPositionLiquidity(token2Id), 0);
        assertEq(IERC721(address(positionManager)).getApproved(token2Id), address(v4Utils));
    }

    function _mintParams(V4Utils, bytes memory hookData) internal view returns (V4Utils.SwapAndMintParams memory) {
        return V4Utils.SwapAndMintParams({
            token0: currency0,
            token1: currency1,
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            tickLower: tickLower2,
            tickUpper: tickUpper2,
            amount0: 1e18,
            amount1: 1e18,
            recipient: attacker,
            recipientNFT: attacker,
            deadline: block.timestamp,
            swapSourceToken: currency0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 0,
            amountAddMin1: 0,
            returnData: "",
            hook: address(hook),
            mintHookData: hookData
        });
    }

    function _fundAttacker(V4Utils v4Utils) internal {
        IERC20(Currency.unwrap(currency0)).transfer(attacker, 2e18);
        IERC20(Currency.unwrap(currency1)).transfer(attacker, 2e18);
        vm.startPrank(attacker);
        IERC20(Currency.unwrap(currency0)).approve(address(v4Utils), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(v4Utils), type(uint256).max);
        vm.stopPrank();
    }

    function testSwapAndMintRefusesARemintClaim() public {
        V4Utils v4Utils = new V4Utils(positionManager, address(swapRouter), address(0), permit2);
        _victimDrainedWithApproval(v4Utils);
        _fundAttacker(v4Utils);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        v4Utils.swapAndMint(_mintParams(v4Utils, _remintClaim(token2Id)));

        (uint8 victimFlags,,,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(victimFlags, PositionModeFlags.MODE_AUTO_EXIT, "victim automation untouched");
    }

    function testSwapAndMintWithoutAClaimStillWorks() public {
        V4Utils v4Utils = new V4Utils(positionManager, address(swapRouter), address(0), permit2);
        _fundAttacker(v4Utils);
        uint256 expectedId = positionManager.nextTokenId();
        vm.prank(attacker);
        (uint256 tokenId,,,) = v4Utils.swapAndMint(_mintParams(v4Utils, ""));
        assertEq(tokenId, expectedId);
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), attacker);
    }

    /// @dev A range change of the caller's own position may only name that position.
    function testChangeRangeRefusesAClaimNamingAnotherToken() public {
        V4Utils v4Utils = new V4Utils(positionManager, address(swapRouter), address(0), permit2);
        _victimDrainedWithApproval(v4Utils);
        // the attacker owns token3Id-like position: mint one for them
        _fundAttacker(v4Utils);
        vm.prank(attacker);
        (uint256 ownTokenId,,,) = v4Utils.swapAndMint(_mintParams(v4Utils, ""));
        vm.prank(attacker);
        IERC721(address(positionManager)).approve(address(v4Utils), ownTokenId);

        V4Utils.Instructions memory instructions = V4Utils.Instructions({
            whatToDo: V4Utils.WhatToDo.CHANGE_RANGE,
            targetToken: currency0,
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            tickLower: tickLower2 - poolKey.tickSpacing,
            tickUpper: tickUpper2 + poolKey.tickSpacing,
            liquidity: positionManager.getPositionLiquidity(ownTokenId),
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            recipient: attacker,
            recipientNFT: attacker,
            returnData: "",
            swapAndMintReturnData: "",
            hook: address(hook),
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: _remintClaim(token2Id)
        });
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        v4Utils.execute(ownTokenId, instructions);

        (uint8 victimFlags,,,,,,,,,,,,) = hook.positionConfigs(token2Id);
        assertEq(victimFlags, PositionModeFlags.MODE_AUTO_EXIT, "victim automation untouched");
    }
}
