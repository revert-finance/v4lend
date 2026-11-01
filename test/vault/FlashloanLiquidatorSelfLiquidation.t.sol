// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {V4VaultLocalBase} from "test/vault/support/V4VaultLocalBase.sol";
import {FlashloanLiquidator, IUniswapV3Pool, IUniswapV3FlashCallback} from "src/vault/liquidation/FlashloanLiquidator.sol";
import {IVault} from "src/vault/interfaces/IVault.sol";
import {Swapper} from "src/shared/swap/Swapper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashLoanPool is IUniswapV3Pool {
    address public override token0;

    constructor(address _token0) {
        token0 = _token0;
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override {
        uint256 amount = amount0 > 0 ? amount0 : amount1;
        if (amount > 0) {
            IERC20(token0).transfer(recipient, amount);
        }
        IUniswapV3FlashCallback(recipient).uniswapV3FlashCallback(0, 0, data);
    }
}

/// @notice V4LE-97: the flash-loan helper is the vault's caller and collateral recipient and pays whoever
///         called it, so it must refuse the loan owner like the vault does.
contract FlashloanLiquidatorSelfLiquidationTest is V4VaultLocalBase {
    FlashloanLiquidator internal helper;
    MockFlashLoanPool internal flashPool;

    function setUp() public override {
        super.setUp();
        helper = new FlashloanLiquidator(positionManager, makeAddr("router"), makeAddr("allowanceHolder"));
        flashPool = new MockFlashLoanPool(address(asset));
        asset.mint(address(flashPool), 1000e18);
        _deposit(lender, 1000e18);
        oracle.setMockPositionValue(1000e18);
    }

    function _params(uint256 tokenId) internal view returns (FlashloanLiquidator.LiquidateParams memory) {
        return FlashloanLiquidator.LiquidateParams({
            tokenId: tokenId,
            vault: IVault(address(vault)),
            flashLoanPool: IUniswapV3Pool(address(flashPool)),
            amount0In: 0,
            swapData0: "",
            amount1In: 0,
            swapData1: "",
            minReward: 0,
            deadline: block.timestamp,
            decreaseLiquidityHookData: ""
        });
    }

    function _callbackData(uint256 tokenId, uint256 liquidationCost, address recipient)
        internal
        view
        returns (bytes memory)
    {
        Swapper.RouterSwapParams memory emptySwap = Swapper.RouterSwapParams({
            tokenIn: Currency.wrap(address(asset)),
            tokenOut: Currency.wrap(address(asset)),
            amountIn: 0,
            amountOutMin: 0,
            swapData: ""
        });
        return abi.encode(
            FlashloanLiquidator.FlashCallbackData({
                tokenId: tokenId,
                liquidationCost: liquidationCost,
                vault: IVault(address(vault)),
                asset: Currency.wrap(address(asset)),
                swap0: emptySwap,
                swap1: emptySwap,
                liquidator: recipient,
                minReward: 0,
                deadline: block.timestamp,
                decreaseLiquidityHookData: ""
            })
        );
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

    function testV4LE97_CallbackRefusesLoanOwnerViaDirectPoolFlash() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);
        // Make loan underwater so it is liquidatable
        oracle.setMockPositionValue(400e18);
        (,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfo(id);
        assertGt(liquidationValue, 0);
        asset.mint(address(helper), liquidationCost);

        // Borrower bypassing helper.liquidate() via direct flashPool.flash(...) with data.liquidator = borrower is refused
        bytes memory data = _callbackData(id, liquidationCost, borrower);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        flashPool.flash(address(helper), liquidationCost, 0, data);
    }

    function testV4LE97_CallbackRefusesLoanOwnerAsDirectCaller() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);
        oracle.setMockPositionValue(400e18);
        (,,, uint256 liquidationCost,) = vault.loanInfo(id);

        asset.mint(address(helper), liquidationCost);
        bytes memory data = _callbackData(id, liquidationCost, liquidator);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        helper.uniswapV3FlashCallback(0, 0, data);
    }

    function testV4LE97_IndependentLiquidatorSucceeds() public {
        uint256 id = _createLoan(10e18);
        _borrow(id, 500e18);
        oracle.setMockPositionValue(400e18);
        (,,, uint256 liquidationCost,) = vault.loanInfo(id);
        asset.mint(address(helper), liquidationCost);

        vm.prank(liquidator);
        helper.liquidate(_params(id));

        (uint256 debt,,,,) = vault.loanInfo(id);
        assertEq(debt, 0);
    }
}
