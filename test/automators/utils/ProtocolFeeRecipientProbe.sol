// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Test helper that observes automator state during native protocol-fee callbacks
/// and optionally attempts a reentrant call back into the automator.
contract ProtocolFeeRecipientProbe {
    address public callbackTarget;
    bytes public callbackData;
    address public observeTarget;
    bytes public observeData;
    uint256 public observeWordIndex;

    bool public attemptedReentry;
    bool public reentrySucceeded;
    uint256 public totalNativeReceived;
    bytes32 public observedWord;

    function configure(address newObserveTarget, bytes calldata newObserveData, uint256 newObserveWordIndex) external {
        observeTarget = newObserveTarget;
        observeData = newObserveData;
        observeWordIndex = newObserveWordIndex;
        observedWord = bytes32(0);
        callbackTarget = address(0);
        delete callbackData;
        attemptedReentry = false;
        reentrySucceeded = false;
        totalNativeReceived = 0;
    }

    function setReentry(address newCallbackTarget, bytes calldata newCallbackData) external {
        callbackTarget = newCallbackTarget;
        callbackData = newCallbackData;
        attemptedReentry = false;
        reentrySucceeded = false;
    }

    receive() external payable {
        totalNativeReceived += msg.value;

        if (observeTarget != address(0)) {
            (bool ok, bytes memory data) = observeTarget.staticcall(observeData);
            require(ok, "observe failed");

            uint256 start = observeWordIndex * 32;
            require(data.length >= start + 32, "observe data too short");

            bytes32 word;
            assembly {
                word := mload(add(add(data, 0x20), start))
            }
            observedWord = word;
        }

        if (callbackTarget != address(0)) {
            attemptedReentry = true;
            (reentrySucceeded,) = callbackTarget.call(callbackData);
        }
    }
}
