// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal call target for tests: records the last caller/value/data and accumulates value.
///      `msg.sender` inside here is whoever the delegate's `.call` used — with the delegate running
///      in the USER's frame, that is the USER, which is the sponsorship proof.
contract Counter {
    uint256 public count;
    uint256 public received;
    address public lastCaller;
    bytes32 public lastData;

    function inc() external payable {
        count += 1;
        received += msg.value;
        lastCaller = msg.sender;
    }

    function record(bytes32 tag) external {
        lastData = tag;
        lastCaller = msg.sender;
    }

    function boom() external pure {
        revert("BOOM");
    }
}
