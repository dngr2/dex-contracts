// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEntryPoint} from "../../src/interfaces/IEntryPoint.sol";
import {IPaymaster} from "../../src/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";

/// @dev Unit-test EntryPoint: holds deposits, and drives the paymaster's
///      validate → postOp lifecycle exactly as the real EntryPoint does, so the
///      paymaster is exercised end-to-end without a live EP or an account.
contract MockEntryPoint is IEntryPoint {
    mapping(address => uint112) public deposit;
    mapping(address => uint32) public unstakeDelay;

    error DepositTooLow();

    function depositTo(address account) external payable override {
        deposit[account] += uint112(msg.value);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return deposit[account];
    }

    function withdrawTo(address payable to, uint256 amount) external override {
        if (deposit[msg.sender] < amount) revert DepositTooLow();
        deposit[msg.sender] -= uint112(amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw send failed");
    }

    function addStake(uint32 unstakeDelaySec) external payable override {
        unstakeDelay[msg.sender] = unstakeDelaySec;
    }

    function getDepositInfo(address)
        external
        pure
        override
        returns (uint112, bool, uint112, uint32, uint256)
    {
        return (0, false, 0, 0, 0);
    }

    /// @notice Drive validation: call the paymaster and return its context.
    function callValidate(
        address paymaster,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        return IPaymaster(paymaster).validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    /// @notice Drive postOp as the EP would.
    function callPostOp(
        address paymaster,
        IPaymaster.PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external {
        IPaymaster(paymaster).postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    receive() external payable {}
}
