// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal ERC20 surface. Hand-rolled (no OpenZeppelin) — same choice as P2/P1.
///      Adds `transferFrom` (+ `approve` for tests) over P2's slice: the factory pulls the payer's
///      funds via transferFrom at creation, exactly like a deposit address is funded by a send.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}
