// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {ILiquidityCalculator} from "./LiquidityCalculator.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";
import {RevertHookAutoLendActions} from "./RevertHookAutoLendActions.sol";
import {RevertHookAutoLeverageActions} from "./RevertHookAutoLeverageActions.sol";
import {RevertHookBase} from "./RevertHookBase.sol";
import {RevertHookCallbacks} from "./RevertHookCallbacks.sol";
import {RevertHookPositionActions} from "./RevertHookPositionActions.sol";

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
        address protocolFeeRecipient_,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        ILiquidityCalculator _liquidityCalculator,
        RevertHookPositionActions _positionActions,
        RevertHookAutoLeverageActions _autoLeverageActions,
        RevertHookAutoLendActions _autoLendActions
    )
        RevertHookBase(
            owner_,
            protocolFeeRecipient_,
            _permit2,
            _v4Oracle,
            _liquidityCalculator,
            _positionActions,
            _autoLeverageActions,
            _autoLendActions
        )
    {}
}
