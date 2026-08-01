// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {V4Utils} from "../src/transformers/V4Utils.sol";
import {Constants} from "../src/utils/Constants.sol";
import "./V4TestBase.sol";

/**
 * @title V4UtilsH1AccessControlTest
 * @notice Regression tests for audit finding H-1 (fee theft via swapAndIncreaseLiquidity).
 * @dev  Before the fix, swapAndIncreaseLiquidity performed no caller check. Because position
 *       owners grant V4Utils a standing operator approval on the v4 PositionManager (required
 *       by the compound flow), ANY caller could invoke it for ANY approved position: a
 *       decrease-liquidity-by-0 settles the position's accrued fees to V4Utils, which are then
 *       optionally swapped and the leftovers forwarded to a caller-chosen `recipient`. Principal
 *       is never at risk (the decrease amount is hardcoded to 0), but the fees are drained.
 *
 *       The fix adds `_validateCaller(positionManager, params.tokenId)` as the first statement,
 *       mirroring execute(), so only the position owner (directly, or via an allowlisted vault
 *       transform) can call it.
 *
 *       These tests use the local (non-fork) V4 deployment from V4TestBase, so they need no RPC.
 */
contract V4UtilsH1AccessControlTest is V4TestBase {
    address internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
    }

    /// @dev Minimal no-swap params that, pre-fix, would have harvested `tokenId`'s fees to `recipient`.
    function _harvestParams(uint256 tokenId, address recipient)
        internal
        view
        returns (V4Utils.SwapAndIncreaseLiquidityParams memory params)
    {
        params = V4Utils.SwapAndIncreaseLiquidityParams({
            tokenId: tokenId,
            amount0: 0,
            amount1: 0,
            recipient: recipient,
            deadline: block.timestamp,
            swapSourceToken: CurrencyLibrary.ADDRESS_ZERO,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            amountAddMin0: 0,
            amountAddMin1: 0,
            decreaseLiquidityHookData: "",
            increaseLiquidityHookData: ""
        });
    }

    /// @notice H-1 core: a third party cannot harvest an approved position's fees.
    /// @dev The victim has granted the standing setApprovalForAll that the real exploit relied on,
    ///      so the ONLY thing stopping the attacker is the new caller check (asserted via the
    ///      exact Unauthorized selector).
    function testAttackerCannotHarvestFees() public {
        uint256 tokenId = _createTestPosition(user1);

        vm.prank(user1);
        IERC721(address(positionManager)).setApprovalForAll(address(v4Utils), true);

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        // Attacker attempts to route the victim's fees to themselves.
        V4Utils.SwapAndIncreaseLiquidityParams memory params = _harvestParams(tokenId, attacker);

        vm.prank(attacker);
        vm.expectRevert(Constants.Unauthorized.selector);
        v4Utils.swapAndIncreaseLiquidity(params);

        // Nothing moved: the position stays with the owner, liquidity is untouched, attacker gets nothing.
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "position must stay with owner");
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidityBefore, "liquidity must be untouched");
        assertEq(token0.balanceOf(attacker), 0, "attacker must not receive token0");
        assertEq(token1.balanceOf(attacker), 0, "attacker must not receive token1");
        assertEq(token0.balanceOf(address(v4Utils)), 0, "no token0 stranded in V4Utils");
        assertEq(token1.balanceOf(address(v4Utils)), 0, "no token1 stranded in V4Utils");
    }

    /// @notice H-1 variant: a per-token ERC721 approval (not just setApprovalForAll) also doesn't help.
    function testAttackerCannotHarvestWithPerTokenApproval() public {
        uint256 tokenId = _createTestPosition(user1);

        vm.prank(user1);
        IERC721(address(positionManager)).approve(address(v4Utils), tokenId);

        V4Utils.SwapAndIncreaseLiquidityParams memory params = _harvestParams(tokenId, attacker);

        vm.prank(attacker);
        vm.expectRevert(Constants.Unauthorized.selector);
        v4Utils.swapAndIncreaseLiquidity(params);
    }

    /// @notice H-1 variant: the attacker cannot bypass the check by naming the owner as recipient either.
    function testAttackerCannotCallEvenWithOwnerAsRecipient() public {
        uint256 tokenId = _createTestPosition(user1);

        vm.prank(user1);
        IERC721(address(positionManager)).setApprovalForAll(address(v4Utils), true);

        V4Utils.SwapAndIncreaseLiquidityParams memory params = _harvestParams(tokenId, user1);

        vm.prank(attacker);
        vm.expectRevert(Constants.Unauthorized.selector);
        v4Utils.swapAndIncreaseLiquidity(params);
    }

    /// @notice Positive control: the fix is surgical — the owner can still compound their own position.
    function testOwnerCanStillCompound() public {
        uint256 tokenId = _createTestPosition(user1);

        // Owner-side approvals, as the compound flow would set up.
        vm.startPrank(user1);
        IERC721(address(positionManager)).setApprovalForAll(address(v4Utils), true);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(positionManager), uint160(1000 ether), uint48(block.timestamp + 1 days));
        permit2.approve(address(token1), address(positionManager), uint160(1000 ether), uint48(block.timestamp + 1 days));
        token0.approve(address(v4Utils), 10 ether);
        token1.approve(address(v4Utils), 10 ether);
        vm.stopPrank();

        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        V4Utils.SwapAndIncreaseLiquidityParams memory params = _harvestParams(tokenId, user1);
        params.amount0 = 10 ether;
        params.amount1 = 10 ether;

        vm.prank(user1);
        (uint128 liquidityAdded,,) = v4Utils.swapAndIncreaseLiquidity(params);

        assertGt(liquidityAdded, 0, "owner compound should add liquidity");
        assertGt(positionManager.getPositionLiquidity(tokenId), liquidityBefore, "position liquidity should increase");
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "owner keeps the position");
    }
}
