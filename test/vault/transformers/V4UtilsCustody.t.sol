// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import "test/vault/support/V4TestBase.sol";

/// @notice External audit V4LE-29: `Transformer._validateCaller` accepted any caller once V4Utils itself was
///         the NFT owner. That branch existed for the safeTransferFrom callback flow, but a plain
///         `transferFrom` also parks the NFT in V4Utils without a callback, and then the first arbitrary
///         caller could run `execute` against it and drain the position to a recipient of their choice.
///         Public `execute` must only accept the NFT owner (or a vault in transform); the callback flow
///         runs an internal path bound to the token just received.
contract V4UtilsCustodyTest is V4TestBase {
    function _drainInstructions(uint256 tokenId, address recipient) internal view returns (V4Utils.Instructions memory) {
        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(token0),
            positionManager.getPositionLiquidity(tokenId),
            block.timestamp,
            recipient
        );
        return instructions;
    }

    function testNftParkedByTransferFromCannotBeExecutedByAnyone() public {
        uint256 tokenId = _createTestPosition(user1);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        assertGt(liquidity, 0);

        vm.prank(user1);
        IERC721(address(positionManager)).transferFrom(user1, address(v4Utils), tokenId);
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(v4Utils), "V4Utils holds the NFT");

        // a stranger
        V4Utils.Instructions memory strangerInstructions = _drainInstructions(tokenId, user2);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        v4Utils.execute(tokenId, strangerInstructions);

        // custody is not authority for the previous owner either: the public path is closed
        V4Utils.Instructions memory ownerInstructions = _drainInstructions(tokenId, user1);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        v4Utils.execute(tokenId, ownerInstructions);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "position untouched");
        assertEq(token0.balanceOf(user2), USER_BALANCE, "nothing drained");
    }

    function testSafeTransferCallbackStillExecutesAndReturnsTheNft() public {
        uint256 tokenId = _createTestPosition(user1);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 balanceBefore = token0.balanceOf(user1) + token1.balanceOf(user1);

        V4Utils.Instructions memory instructions = _createInstructions(
            V4Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, address(token0), liquidity / 2, block.timestamp, user1
        );
        _executeInstructions(tokenId, instructions, user1);

        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), user1, "NFT returned to the sender");
        assertLt(positionManager.getPositionLiquidity(tokenId), liquidity, "half the liquidity was withdrawn");
        assertGt(token0.balanceOf(user1) + token1.balanceOf(user1), balanceBefore, "proceeds reached the owner");
    }
}
