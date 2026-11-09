// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "../interfaces/IERC20.sol";

/// @dev Minimal mintable ERC20 for unit tests (no deps).
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }

    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        return _move(msg.sender, to, v);
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= v, "allowance");
            allowance[from][msg.sender] = a - v;
        }
        return _move(from, to, v);
    }

    function _move(address from, address to, uint256 v) internal returns (bool) {
        require(balanceOf[from] >= v, "balance");
        balanceOf[from] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev Fee-on-transfer token: takes `feeBps` off EVERY transfer, so the recipient receives less
///      than sent. Used to prove the Escrow credits the RECEIVED amount, not the asserted one.
contract MockFoT is IERC20 {
    string public name = "FoT";
    string public symbol = "FOT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public immutable feeBps;   // taken from the recipient's side
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 feeBps_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }

    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        return _move(msg.sender, to, v);
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= v, "allowance");
            allowance[from][msg.sender] = a - v;
        }
        return _move(from, to, v);
    }

    function _move(address from, address to, uint256 v) internal returns (bool) {
        require(balanceOf[from] >= v, "balance");
        uint256 cut = (v * feeBps) / 10_000;
        balanceOf[from] -= v;
        balanceOf[to] += (v - cut);       // recipient gets less
        totalSupply -= cut;               // burned
        return true;
    }
}

/// @dev The classic non-standard token: transfer/transferFrom return NOTHING (empty returndata),
///      exactly like MAINNET USDT. Base's bridged USDT actually returns a bool (see the fork test),
///      so this mock is the only way to exercise `_pay`'s empty-return arm — and a mutant that
///      assumes a bool must fail here. NB: these functions are declared with NO return in the mock,
///      but the shared IERC20 declares `returns (bool)`; that mismatch is the point.
contract MockNoReturn {
    string public name = "NoReturn";
    string public symbol = "NRET";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        totalSupply += v;
    }

    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        return true;
    }

    /// @dev Declared with NO `returns` — so the ABI returndata is EMPTY, exactly like mainnet USDT.
    ///      The shared IERC20 declares `returns (bool)`; the caller's low-level `call` sees the mock's
    ///      real (empty) returndata, which is the mismatch this mock exists to create.
    function transfer(address to, uint256 v) external {
        _move(msg.sender, to, v);
    }

    function transferFrom(address from, address to, uint256 v) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= v, "allowance");
            allowance[from][msg.sender] = a - v;
        }
        _move(from, to, v);
    }

    function _move(address from, address to, uint256 v) internal {
        require(balanceOf[from] >= v, "balance");
        balanceOf[from] -= v;
        balanceOf[to] += v;
    }
}
