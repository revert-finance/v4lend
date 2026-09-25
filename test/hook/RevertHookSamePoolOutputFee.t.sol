// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RevertHookAuditFixesTest} from "test/hook/RevertHookAuditFixes.t.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {Vm} from "forge-std/Vm.sol";

contract RevertHookSamePoolOutputFeeTest is RevertHookAuditFixesTest {
    using EasyPosm for IPositionManager;
    using CurrencyLibrary for Currency;

    function _verify21SamePoolLeftover(uint16 feeBps, bool zeroForOne) internal returns (uint256 totalLeftover) {
        hook.setMaxTicksFromOracle(1000);
        feeController.setDefaultSwapFeeBps(uint8(RevertHookState.Mode.AUTO_RANGE), feeBps);
        (uint256 id,) = positionManager.mint(
            poolKey, -60, 60, 100e18, type(uint256).max, type(uint256).max, address(this), block.timestamp, ""
        );
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);
        hook.setPositionConfig(id, _rangeConfig(0, 0, -60, 60));
        uint256 nextId = positionManager.nextTokenId();
        vm.recordLogs();
        _swap(poolKey, zeroForOne, zeroForOne ? 45e16 : 12e17);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(positionManager.nextTokenId(), nextId + 1);
        assertGt(positionManager.getPositionLiquidity(nextId), 0);
        (uint256 left0, uint256 left1) = _leftoverFor(logs, id);
        totalLeftover = left0 + left1;
        emit log_named_uint("unused_input", totalLeftover);
    }

    function testSamePoolOutputFeeBalancesMintAmounts() public {
        uint256 leftover = _verify21SamePoolLeftover(1000, true);
        assertLt(leftover, 1e9, "output fee accounted for in the minted ratio");
    }

    function testVerify21SamePoolZeroFeeNegativeControl() public {
        uint256 leftover = _verify21SamePoolLeftover(0, true);
        assertLt(leftover, 3e15, "zero fee balances liquidity sides");
    }
    function testSamePoolOutputFeeReverseDirection() public {
        assertLt(_verify21SamePoolLeftover(1000, false), 1e9);
    }
    function testSamePoolDefaultOutputFee() public {
        assertLt(_verify21SamePoolLeftover(100, true), 1e9);
    }
}
