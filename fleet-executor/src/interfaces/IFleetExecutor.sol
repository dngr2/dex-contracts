// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IFleetExecutor — the shape consumers (SDK, mcp-server, relay) code against.
/// @dev A 65-byte EIP-712 sig over the `Execute` typed-data; verify by calling `digest` ON the
///      delegated EOA (the domain's verifyingContract is the EOA, not this interface's impl address).
interface IFleetExecutor {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Run a user-signed batch in the user's frame. Permissionless to carry.
    function execute(Call[] calldata calls, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        payable;

    /// @notice Run a batch with no signature (msg.sender must be the EOA itself).
    function executeSelf(Call[] calldata calls) external payable;

    /// @notice The GATED 7821 default: self, or use the 5-arg intent overload below.
    function execute(bytes32 mode, bytes calldata executionData) external payable;

    /// @notice ERC-7821 with an EIP-712 intent (the relayable 7821 door).
    function execute(
        bytes32 mode,
        bytes calldata executionData,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external payable;

    /// @notice Explicit opt-in to the always-permissionless bare 7821 door (no auth, no nonce).
    function executeBare(bytes32 mode, bytes calldata executionData) external payable;

    function digest(Call[] calldata calls, uint256 nonce, uint256 deadline) external view returns (bytes32);
    function domain() external view returns (bytes32);
    function nonces() external view returns (uint256);
    function nonceOf(address account) external view returns (uint256);
}
