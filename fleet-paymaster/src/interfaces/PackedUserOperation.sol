// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev The packed UserOperation struct, ERC-4337 v0.7 (final).
///      Two "packed" 32-byte words carry (a) verification+call gas limits and
///      (b) maxFeePerGas+maxPriorityFeePerGas. The paymaster fields carry an
///      optional paymaster address plus its own verification/call gas limits and
///      a 32-byte data blob (which for a verifying paymaster is the signature).
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits; // bytes32(uint256(verificationGasLimit) << 128 | callGasLimit)
    uint256 preVerificationGas;
    bytes32 gasFees; // bytes32(uint256(maxPriorityFeePerGas) << 128 | maxFeePerGas)
    bytes paymasterAndData; // address(paymaster) ++ abi.encode(paymasterVerificationGasLimit, paymasterPostOpGasLimit) ++ data
    bytes signature;
}

library UserOperationLib {
    /// @dev Offset (from the 0x-prefixed bytes start) at which the paymaster
    ///      gas-limit pair begins: 20-byte address + 16-byte verify + 16-byte postOp.
    uint256 internal constant PAYMASTER_ADDRESS_OFFSET = 20;
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52; // 20 + 16 + 16

    /// @notice The paymaster address encoded in `paymasterAndData`, or address(0).
    function paymaster(PackedUserOperation calldata userOp) internal pure returns (address) {
        bytes calldata p = userOp.paymasterAndData;
        if (p.length < 20) return address(0);
        return address(bytes20(p[0:20]));
    }

    /// @notice The paymaster's own verification/postOp gas limits (0 if absent, matching v0.7).
    function unpackPaymasterStaticFields(PackedUserOperation calldata userOp)
        internal
        pure
        returns (address _paymaster, uint256 validationGasLimit, uint256 postOpGasLimit)
    {
        bytes calldata p = userOp.paymasterAndData;
        if (p.length < PAYMASTER_DATA_OFFSET) return (address(0), 0, 0);
        _paymaster = address(bytes20(p[0:20]));
        validationGasLimit = uint256(bytes32(p[20:36]));
        postOpGasLimit = uint256(bytes32(p[36:52]));
    }

    /// @notice The fee to charge for `gasUsed` at the op's effective gas price.
    function gasPrice(PackedUserOperation calldata userOp) internal view returns (uint256) {
        unchecked {
            uint256 maxFee = uint256(userOp.gasFees);
            uint256 maxPriority = uint256(userOp.gasFees << 128);
            uint256 baseFee = block.basefee;
            if (baseFee > maxFee) baseFee = maxFee;
            return baseFee + maxPriority;
        }
    }
}
