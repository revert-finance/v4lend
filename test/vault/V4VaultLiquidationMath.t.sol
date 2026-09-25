// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {NativeWrapper} from "@uniswap/v4-periphery/src/base/NativeWrapper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {MockV4Oracle} from "test/utils/MockV4Oracle.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {IV4Oracle} from "src/oracle/interfaces/IV4Oracle.sol";

contract V4VaultLiquidationMathHarness is V4Vault {
    constructor(address asset, IPositionManager posm, InterestRateModel irm, IV4Oracle oracle, IWETH9 weth_)
        V4Vault("harness", "H", asset, posm, irm, oracle, weth_)
    {}

    function calculateLiquidation(uint256 debt, uint256 fullValue, uint256 collateralValue)
        external
        pure
        returns (uint256 liquidationValue, uint256 liquidatorCost, uint256 reserveCost)
    {
        return _calculateLiquidation(debt, fullValue, collateralValue);
    }
}

/// @notice External audit V4LE-88: `_calculateLiquidation` interpolated the penalty with
///         `debt * fullValue / collateralValue`, a checked product that overflows for a valid
///         large position (each factor around 2^144) even though the quotient fits, so loanInfo()
///         and liquidate() reverted for the unhealthy loan. Full-precision division must keep the
///         liquidation terms computable for every representable value.
contract V4VaultLiquidationMathTest is BaseTest {
    uint256 constant Q32 = 2 ** 32;
    V4VaultLiquidationMathHarness harness;

    function setUp() public {
        deployArtifactsAndLabel();
        (Currency asset,) = deployCurrencyPair();
        InterestRateModel irm = new InterestRateModel(0, 0, 0, 0);
        harness = new V4VaultLiquidationMathHarness(
            Currency.unwrap(asset),
            positionManager,
            irm,
            IV4Oracle(address(new MockV4Oracle(positionManager))),
            NativeWrapper(payable(address(positionManager))).WETH9()
        );
    }

    function testLargeValidCollateralLiquidationTermsDoNotOverflow() public view {
        // 90% collateral factor, debt just above the collateral value, full value above debt*(1+maxPenalty)
        uint256 collateralValue = 2 ** 144;
        uint256 fullValue = collateralValue * 10 / 9;
        uint256 debt = collateralValue + collateralValue / 200; // 0.5% into unhealthy territory
        assertGt(debt, collateralValue);
        assertGe(fullValue, debt * (Q32 + harness.MAX_LIQUIDATION_PENALTY_X32()) / Q32, "partial-liquidation band");

        // the auditor's premise: the checked product does not fit even though the quotient does
        (bool ok,) = Math.tryMul(debt, fullValue);
        assertFalse(ok, "debt * fullValue overflows uint256");

        (uint256 liquidationValue, uint256 liquidatorCost, uint256 reserveCost) =
            harness.calculateLiquidation(debt, fullValue, collateralValue);
        assertEq(liquidatorCost, debt, "standard liquidation: liquidator pays the debt");
        assertEq(reserveCost, 0);
        uint256 minValue = debt * (Q32 + harness.MIN_LIQUIDATION_PENALTY_X32()) / Q32;
        uint256 maxValue = debt * (Q32 + harness.MAX_LIQUIDATION_PENALTY_X32()) / Q32;
        assertGe(liquidationValue, minValue, "penalty at least the minimum");
        assertLe(liquidationValue, maxValue, "penalty at most the maximum");
    }

    function testOrdinaryValuesMatchPlainArithmetic() public view {
        uint256 collateralValue = 1_000e6;
        uint256 fullValue = collateralValue * 10 / 9;
        uint256 debt = 1_005e6;
        (uint256 liquidationValue,,) = harness.calculateLiquidation(debt, fullValue, collateralValue);
        uint256 maxPenaltyValue = debt * (Q32 + harness.MAX_LIQUIDATION_PENALTY_X32()) / Q32;
        uint256 start = debt * fullValue / collateralValue;
        uint256 fraction = 2 ** 96 - (fullValue - maxPenaltyValue) * 2 ** 96 / (start - maxPenaltyValue);
        uint256 penalty = harness.MIN_LIQUIDATION_PENALTY_X32()
            + (harness.MAX_LIQUIDATION_PENALTY_X32() - harness.MIN_LIQUIDATION_PENALTY_X32()) * fraction / 2 ** 96;
        assertEq(liquidationValue, debt * (Q32 + penalty) / Q32, "identical to the plain formula in range");
    }
}
