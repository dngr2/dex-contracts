// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The slice of Registry that a Forwarder clone needs. Kept as a separate interface so
///      Forwarder and Registry do not import each other (no cycle).
interface IRegistry {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    /// @dev Per-forward minimum toll in token base units; 0 = legacy (no floor).
    function minFee() external view returns (uint256);
}
