// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal ERC20 for tests (no OZ). Hand-rolled like everything else in this lane.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        emit Approval(msg.sender, sp, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "balance");
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amt, "allowance");
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
        return true;
    }
}

/// @dev A token whose `transfer` returns NOTHING (USDT class) — proves `_pay` tolerates the
///      empty-return shape rather than decoding a bool that isn't there (a real mainnet class).
contract MockERC20NoReturn {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }
}
