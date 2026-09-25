// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
import {V4VaultLiquidationCapTest} from "./V4VaultLiquidationCap.t.sol";
import {LiquidationEscrow} from "src/vault/LiquidationEscrow.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract V4VaultSurplusEscrowTest is V4VaultLiquidationCapTest {
    function testRejectedSurplusIsClaimableAndRecipientIsCapped() public {
        uint256 id = _partialLiquidationSetup();
        _movePoolUp(plainKey, 150, DEEP_LIQUIDITY + 1e22);
        (,,,, uint256 quote) = vault.loanInfo(id);
        (,, uint256 p0, uint256 p1) = oracle.getValue(id, asset);
        // Model a token that rejects transfers to its blocklisted owner while allowing liquidator.
        vm.mockCallRevert(
            Currency.unwrap(currency0),
            abi.encodeWithSelector(IERC20.transfer.selector, borrower),
            abi.encode("blocked")
        );
        vm.mockCallRevert(
            Currency.unwrap(currency1),
            abi.encodeWithSelector(IERC20.transfer.selector, borrower),
            abi.encode("blocked")
        );
        (uint256 a0, uint256 a1) = _liquidateAs(liquidator, id);
        uint256 quotedPayout = _oracleValue(a0, a1, p0, p1);
        uint256 actualPayout = _oracleValue(currency0.balanceOf(liquidator), currency1.balanceOf(liquidator), p0, p1);
        assertLe(quotedPayout, quote);
        assertLe(actualPayout, quote);
        assertEq(actualPayout, quotedPayout);
        LiquidationEscrow escrow = vault.liquidationEscrow();
        address token = Currency.unwrap(currency0);
        uint256 credit = escrow.claimable(token, borrower);
        assertGt(credit, 0);
        assertEq(IERC20(token).balanceOf(address(escrow)), credit);
        vm.prank(borrower);
        vm.expectRevert();
        escrow.claim(token, borrower);
        assertEq(escrow.claimable(token, borrower), credit);
        address recovery = makeAddr("recovery");
        vm.prank(borrower);
        escrow.claim(token, recovery);
        assertEq(IERC20(token).balanceOf(recovery), credit);
        assertEq(escrow.claimable(token, borrower), 0);
        assertEq(vault.loans(id), 0);
    }
}
