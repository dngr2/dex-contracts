// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal ERC20 surface. Hand-rolled (no OpenZeppelin dependency) — same choice as P1.
///      `approve` is included for the FACTORY (which pulls via transferFrom); the vault itself only
///      ever calls balanceOf/transfer, so the vault-side surface stays as small as P2's.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}
