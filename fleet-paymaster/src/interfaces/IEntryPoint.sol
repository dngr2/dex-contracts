// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @dev Minimal ERC-4337 v0.7 EntryPoint surface the paymaster touches:
///      deposit custody + the UserOperationEvent for postOp accounting.
interface IEntryPoint {
    /// @notice Add to this paymaster's (or an account's) deposit balance.
    function depositTo(address account) external payable;

    /// @notice This contract's current EntryPoint deposit (gas prefund held).
    function balanceOf(address account) external view returns (uint256);

    /// @notice Withdraw from this contract's deposit to `withdrawAddress`.
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;

    /// @notice Add stake for this paymaster (unbonded relay protection).
    function addStake(uint32 unstakeDelaySec) external payable;

    /// @notice The deposit + stake tuple EntryPoint tracks for `addr`.
    function getDepositInfo(address account)
        external
        view
        returns (uint112 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint256 withdrawTime);

    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
}
