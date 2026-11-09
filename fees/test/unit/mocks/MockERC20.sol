// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Test ERC-20 with a settable "lie" mode: return false instead of reverting, and a
/// settable "revert on transfer to X" so the splitter's accrual path can be exercised.
contract MockERC20 {
    string public name = "Mock";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public returnFalse;       // if true, transfer AND transferFrom return false (no revert)
    bool public lieTransfersOnly;  // if true, only `transfer` lies; `transferFrom` stays honest

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function setLieTransfersOnly(bool v) external {
        lieTransfersOnly = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnFalse || lieTransfersOnly) return false;
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
