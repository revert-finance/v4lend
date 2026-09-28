// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
interface IPositionFeeQuoter {
    function hook() external view returns (address);
    /// @notice Total current obligation, including carried fees, in raw pool currency units.
    function quoteProtocolFees(uint256 tokenId, uint128 grossFees0, uint128 grossFees1)
        external view returns (uint256 owed0, uint256 owed1);
}
