// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
import {RevertHookTest} from "./RevertHook.t.sol";
import {V4Oracle,AggregatorV3Interface,IUniswapV3Pool} from "src/oracle/V4Oracle.sol";
import {MutableChainlinkFeed} from "test/oracle/support/OracleMocks.sol";
import {Currency,CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
contract RevertHookNetCollateralTest is RevertHookTest {
    using CurrencyLibrary for Currency;
    function _netOracle() internal returns (V4Oracle oracle) {
        oracle = new V4Oracle(positionManager,Currency.unwrap(currency1),address(0xdead));
        oracle.setMaxPoolPriceDifference(200);
        MutableChainlinkFeed feed = new MutableChainlinkFeed(1e8,8);
        oracle.setTokenConfig(Currency.unwrap(currency0),AggregatorV3Interface(address(feed)),1 days,IUniswapV3Pool(address(0)),address(0),0,V4Oracle.Mode.CHAINLINK,200);
        oracle.setTokenConfig(Currency.unwrap(currency1),AggregatorV3Interface(address(feed)),1 days,IUniswapV3Pool(address(0)),address(0),0,V4Oracle.Mode.CHAINLINK,200);
        oracle.setHookFeeQuoter(address(hook),address(feeController));
    }
    function testNetFeeValueMatchesActualCollection() public {
        hook.setPositionConfig(token2Id,_buildNonVaultModeConfig(PositionModeFlags.MODE_AUTO_COLLECT,false,false,type(int24).min,type(int24).max));
        _swapHookedPoolBothWays(1e17);
        vm.warp(block.timestamp+1 days);
        feeController.setLpFeeBps(5000);
        V4Oracle oracle = _netOracle();
        (,uint256 netFees,,) = oracle.getValue(token2Id,Currency.unwrap(currency1));
        uint256 before0 = currency0.balanceOf(address(this));
        uint256 before1 = currency1.balanceOf(address(this));
        _collectNetFees(token2Id);
        assertEq(currency0.balanceOf(address(this))-before0+currency1.balanceOf(address(this))-before1,netFees);
    }
    function testCarriedFeeReducesPrincipalValueWithZeroGrossFees() public {
        (uint128 owed0,uint128 owed1) = _collectFeesOnlyAndCarryProtocolFee();
        V4Oracle oracle = _netOracle();
        (uint256 netValue,uint256 feeValue,,) = oracle.getValue(token2Id,Currency.unwrap(currency1));
        assertEq(feeValue,0);
        _collectNetFees(token2Id); // settle the legacy debt from the owner's wallet
        (uint256 cleanValue,,,) = oracle.getValue(token2Id,Currency.unwrap(currency1));
        assertEq(cleanValue-netValue,uint256(owed0)+owed1);
    }
    function testUnknownHookCannotBeValuedAsFeeFree() public {
        V4Oracle oracle = _netOracle();
        oracle.setHookFeeQuoter(address(hook),address(0));
        vm.expectRevert(abi.encodeWithSelector(V4Oracle.HookFeeQuoterNotConfigured.selector,address(hook)));
        oracle.getValue(token2Id,Currency.unwrap(currency1));
    }
    function testLiquidationSizingIncludesFixedPrincipalFees() public {
        _collectFeesOnlyAndCarryProtocolFee();
        _collectNetFees(token2Id);
        V4Oracle oracle = _netOracle();
        (,,,uint128 allLiquidity,uint256 principal0,uint256 principal1,,) = oracle.getPositionBreakdown(token2Id);
        _seedLegacyFees(token2Id,uint128(principal0/10),uint128(principal1/10));
        (uint256 value,,uint256 p0,uint256 p1) = oracle.getValue(token2Id,Currency.unwrap(currency1));
        uint256 target = value/5;
        uint128 liquidity = oracle.getLiquidityForValue(token2Id,Currency.unwrap(currency1),target);
        assertGt(liquidity,allLiquidity/5,"fixed fees require more than proportional net principal");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(token2Id,0,type(uint128).max,type(uint128).max,bytes(""));
        params[1] = abi.encode(token2Id,liquidity,0,0,bytes(""));
        params[2] = abi.encode(currency0,currency1,address(this));
        uint256 before0 = currency0.balanceOf(address(this));
        uint256 before1 = currency1.balanceOf(address(this));
        positionManager.modifyLiquidities(abi.encode(abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.DECREASE_LIQUIDITY),uint8(Actions.TAKE_PAIR)),params),block.timestamp);
        uint256 paid = (currency0.balanceOf(address(this))-before0)*p0/(2**96)
            + (currency1.balanceOf(address(this))-before1)*p1/(2**96);
        // Oracle-price versus spot-price settlement may differ slightly; a proportional net
        // quote underpays by about 44% in this case, far outside this 0.1% tolerance.
        assertApproxEqRel(paid,target,1e15);
        (uint128 remaining0,uint128 remaining1) = hook.pendingProtocolFees(token2Id);
        assertEq(uint256(remaining0)+remaining1,0);
    }
}
