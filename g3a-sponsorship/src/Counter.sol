// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
contract Counter { uint256 public n; address public lastCaller; address public lastOrigin;
  function bump() external { n++; lastCaller = msg.sender; lastOrigin = tx.origin; } }
