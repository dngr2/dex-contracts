// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

contract Forwarder {
    IRegistry public immutable registry;
    address public immutable destination;
    uint256 private _lock;

    event Deposit(address indexed depositor, address indexed token, uint256 amount);
    event Forwarded(
        address indexed depositor,
        address indexed destination,
        address indexed token,
        uint256 amountIn,
        uint256 fee,
        uint256 amountOut,
        address ref
    );

    error ZeroArg();
    error Locked();

    modifier nonReentrant() {
        if (_lock != 1) revert Locked();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address registry_, address destination_) {
        if (registry_ == address(0) || destination_ == address(0)) revert ZeroArg();
        registry = IRegistry(registry_);
        destination = destination_;
        _lock = 1;
    }

    receive() external payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }

    fallback() external payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }

    function forward(address token, address depositor) external nonReentrant returns (uint256 amountOut, uint256 fee) {
        uint256 amount = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        if (amount == 0) return (0, 0);

        fee = (amount * registry.feeBps()) / 10_000;
        amountOut = amount - fee;

        if (amountOut > 0) _pay(token, destination, amountOut);
        if (fee > 0) _pay(token, registry.feeRecipient(), fee);

        emit Forwarded(depositor, destination, token, amount, fee, amountOut, msg.sender);
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "native send failed");
        } else {
            (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 transfer failed");
        }
    }
}
