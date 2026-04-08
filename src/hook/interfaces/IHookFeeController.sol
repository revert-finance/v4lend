// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IHookFeeController {
    function protocolFeeRecipient() external view returns (address);
    function lpFeeBps() external view returns (uint16);
    function autoLendFeeBps() external view returns (uint16);
    function swapFeeBps(PoolId swapPoolId, uint8 mode) external view returns (uint16);
}
