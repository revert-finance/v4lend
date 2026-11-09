// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {V4VaultLocalBase} from "test/vault/support/V4VaultLocalBase.sol";
import {FlashloanLiquidator, IUniswapV3Pool} from "src/vault/liquidation/FlashloanLiquidator.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";

/// @notice V4LE-97: the flash-loan helper is the vault's caller and collateral recipient and pays whoever
///         called it, so it must refuse the loan owner like the vault does.
contract FlashloanLiquidatorSelfLiquidationTest is V4VaultLocalBase {
    FlashloanLiquidator internal helper;

    function setUp() public override {
        super.setUp();
        helper = new FlashloanLiquidator(positionManager, makeAddr("router"), makeAddr("allowanceHolder"));
        _deposit(lender, 1000e18);
        oracle.setMockPositionValue(1000e18);
    }

    function _params(uint256 tokenId) internal returns (FlashloanLiquidator.LiquidateParams memory) {
        return FlashloanLiquidator.LiquidateParams({
            tokenId: tokenId,
            vault: IVault(address(vault)),
            flashLoanPool: IUniswapV3Pool(makeAddr("flashPool")),
            amount0In: 0,
            swapData0: "",
            amount1In: 0,
            swapData1: "",
            minReward: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: ""
        });
    }

    function testV4LE97_HelperRefusesLoanOwner() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        helper.liquidate(_params(id));
    }

    function testV4LE97_HelperStillRejectsHealthyLoanForOthers() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);
        // an unrelated caller passes the owner check and reaches the vault's own quote
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSignature("NotLiquidatable()"));
        helper.liquidate(_params(id));
    }
    function _callbackData(uint256 tokenId, address recipient) internal view returns (bytes memory) {
        return abi.encode(
            FlashloanLiquidator.FlashCallbackData({
                tokenId: tokenId,
                liquidationCost: 0,
                vault: IVault(address(vault)),
                asset: Currency.wrap(address(token0)),
                swap0: FlashloanLiquidator.RouterSwapParams(
                    Currency.wrap(address(0)),
                    Currency.wrap(address(0)),
                    0,
                    0,
                    ""
                ),
                swap1: FlashloanLiquidator.RouterSwapParams(
                    Currency.wrap(address(0)),
                    Currency.wrap(address(0)),
                    0,
                    0,
                    ""
                ),
                liquidator: recipient,
                minReward: 0,
                deadline: block.timestamp,
                decreaseLiquidityHookData: ""
            })
        );
    }

    function testV4LE97_CallbackRefusesLoanOwnerAsLiquidatorRecipient() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);

        bytes memory callbackData = _callbackData(id, borrower);
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        helper.uniswapV3FlashCallback(0, 0, callbackData);
    }

    function testV4LE97_CallbackRefusesLoanOwnerAsDirectCaller() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);

        bytes memory callbackData = _callbackData(id, liquidator);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        helper.uniswapV3FlashCallback(0, 0, callbackData);
    }
}

