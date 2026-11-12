// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice A referrer whose ERC-20 `transfer` receipt reverts — models a referrer contract that
/// rejects the token (wrong-hook, pausable, or a token that reverts for some senders). The
/// splitter must NOT brick; it must accrue.
contract RevertingReceiver {
    bool public rejectToken;
    bool public rejectNative;

    constructor(bool _rejectToken, bool _rejectNative) {
        rejectToken = _rejectToken;
        rejectNative = _rejectNative;
    }

    function setRejectToken(bool v) external {
        rejectToken = v;
    }

    function setRejectNative(bool v) external {
        rejectNative = v;
    }

    /// @dev called by the token's `transfer` — we simply revert to simulate a rejecting holder.
    function onTokenReceived() external view {
        if (rejectToken) revert("no token");
    }

    receive() external payable {
        if (rejectNative) revert("no native");
    }
}

/// @notice A token that reverts on `transfer` when the recipient has opted in via `willRevert`.
contract PickyToken {
    string public name = "Picky";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public reject;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setReject(address who, bool v) external {
        reject[who] = v;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (reject[to]) revert("recipient rejects");
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
