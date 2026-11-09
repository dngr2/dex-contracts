// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The slice of Registry that a Forwarder clone needs. Kept as a separate interface so
///      Forwarder and Registry do not import each other (no cycle).
interface IRegistry {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
}
