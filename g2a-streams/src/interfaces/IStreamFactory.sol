// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The only surface a vault needs from its factory. Kept minimal on purpose: a vault lives for
///      years and the factory is the ONE thing it must keep reading, so this interface is the
///      blast radius if the factory is ever upgraded.
interface IStreamFactory {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    /// @dev Per-withdraw minimum toll in token base units; 0 = legacy (no floor).
    function minFee() external view returns (uint256);
    /// @dev Self-funding create (spends the FACTORY's own balance). Vaults do not call it, but the
    ///      frontend/keeper hits it on the address `factory` already points at, so it belongs here.
    function createStreamSelfFunded(address, address, address, uint256, uint64, uint64) external payable returns (address);
}
