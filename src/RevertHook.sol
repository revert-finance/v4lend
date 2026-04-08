// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./shared/math/LiquidityCalculator.sol";
import {IV4Oracle} from "./oracle/interfaces/IV4Oracle.sol";
import {IHookFeeController} from "./hook/interfaces/IHookFeeController.sol";
import {RevertHookAutoLendActions} from "./hook/RevertHookAutoLendActions.sol";
import {RevertHookAutoLeverageActions} from "./hook/RevertHookAutoLeverageActions.sol";
import {RevertHookBase} from "./hook/RevertHookBase.sol";
import {RevertHookCallbacks} from "./hook/RevertHookCallbacks.sol";
import {RevertHookPositionActions} from "./hook/RevertHookPositionActions.sol";

/// @title RevertHook
/// @notice Uniswap V4 hook enabling automated LP position management features
/// @dev The concrete hook is intentionally thin. Source-level responsibilities live in:
///      - RevertHookViews: read API
///      - RevertHookConfig: configuration setters and validation
///      - RevertHookImmediate: immediate trigger execution helpers
///      - RevertHookExecution: action dispatch and delegatecall entrypoints
///      - RevertHookCallbacks: hook callback flow and fee accounting
contract RevertHook is RevertHookCallbacks {
    constructor(
        address owner_,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        IHookFeeController _hookFeeController,
        RevertHookPositionActions _positionActions,
        RevertHookAutoLeverageActions _autoLeverageActions,
        RevertHookAutoLendActions _autoLendActions
    )
        RevertHookBase(
            owner_,
            _permit2,
            _v4Oracle,
            _liquidityCalculator,
            _hookFeeController,
            _positionActions,
            _autoLeverageActions,
            _autoLendActions
        )
    {}
}
