// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal transient-free reentrancy guard matching the house pattern.
abstract contract ReentrancyGuard {
    uint256 private _lock = 1;

    error Locked();

    modifier nonReentrant() {
        if (_lock != 1) revert Locked();
        _lock = 2;
        _;
        _lock = 1;
    }
}
