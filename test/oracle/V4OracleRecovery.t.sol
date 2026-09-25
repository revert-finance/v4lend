// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
import {V4OracleSequencerGuardTest} from "./V4OracleSequencerGuard.t.sol";
import {V4Oracle, AggregatorV3Interface} from "src/oracle/V4Oracle.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
contract V4OracleRecoveryTest is V4OracleSequencerGuardTest {
    function testBorrowWaitsForBothFreshRoundsAndFullTwapWindow() public {
        address token = Currency.unwrap(currency0);
        oracle.setTokenConfig(token, AggregatorV3Interface(address(feed0)), 1 days, twapPool, address(0), 1800, V4Oracle.Mode.CHAINLINK_TWAP_VERIFY, 200);
        uint256 restart = START_TIME - 601;
        sequencerFeed.setRoundTimes(restart,restart);
        feed0.setRoundTimes(restart-1,restart-1);
        feed1.setRoundTimes(restart-1,restart-1);
        (uint256 value,,,) = oracle.getValue(tokenId,Currency.unwrap(currency1));
        assertGt(value,0,"ordinary liquidation valuation remains available after common grace");
        vm.expectRevert(abi.encodeWithSelector(V4Oracle.SourceNotRecovered.selector,token));
        oracle.validateBorrow(tokenId,Currency.unwrap(currency1));
        feed0.setRoundTimes(START_TIME,START_TIME);
        vm.expectRevert(abi.encodeWithSelector(V4Oracle.SourceNotRecovered.selector,Currency.unwrap(currency1)));
        oracle.validateBorrow(tokenId,Currency.unwrap(currency1));
        feed1.setRoundTimes(START_TIME,START_TIME);
        vm.expectRevert(abi.encodeWithSelector(V4Oracle.SourceNotRecovered.selector,token));
        oracle.validateBorrow(tokenId,Currency.unwrap(currency1));
        vm.warp(restart+1800);
        oracle.validateBorrow(tokenId,Currency.unwrap(currency1));
    }
    function testRiskReducingChangeDoesNotRequirePostRestartRound() public {
        address token = Currency.unwrap(currency0);
        _configure(token,feed0,V4Oracle.Mode.CHAINLINK);
        uint256 restart = START_TIME-601;
        sequencerFeed.setRoundTimes(restart,restart);
        feed0.setRoundTimes(restart-1,restart-1);
        uint256 beforeRisk = oracle.getRiskScore(tokenId,Currency.unwrap(currency1),100);
        oracle.validateRiskChange(tokenId,Currency.unwrap(currency1),99,beforeRisk);
        vm.expectRevert(abi.encodeWithSelector(V4Oracle.SourceNotRecovered.selector,token));
        oracle.validateRiskChange(tokenId,Currency.unwrap(currency1),101,beforeRisk);
    }
}
