// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The only surface a vault needs from its factory. Kept minimal on purpose: a vault lives for
///      years and the factory is the ONE thing it must keep reading, so this interface is the
///      blast radius if the factory is ever upgraded.
interface IStreamFactory {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    /// @dev Per-withdraw minimum toll in token base units; 0 = legacy (no floor).
}
