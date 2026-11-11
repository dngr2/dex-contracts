// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Minimal ERC-20 surface. transfer/transferFrom return bool (some real tokens lie and
/// return false instead of reverting — the splitter treats false as "failed" and accrues).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
