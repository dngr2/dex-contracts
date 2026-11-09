// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal ERC20 surface. Hand-rolled (no OpenZeppelin dependency) — same choice as P1.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}
