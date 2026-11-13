// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @dev ERC-4337 v0.7 paymaster interface. `validatePaymasterUserOp` runs in
///      validation and must return a `context` blob handed back to `postOp`
///      unchanged after the op executes (or reverts). It returns a packed
///      validationData: `abi.encodePacked(aggregator, validUntil, validAfter)`,
///      `0` meaning "valid now, no aggregator".
interface IPaymaster {
    enum PostOpMode {
        opSucceeded, // op executed successfully
        opReverted, // op reverted but the EntryPoint calls postOp anyway (inner call)
        postOpReverted // postOp itself reverted; a second call with this mode follows
    }

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData);

    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external;
}
