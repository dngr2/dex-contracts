// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The slice of EscrowFactory that an Escrow needs — deliberately identical in shape to P2's
///      IRegistry (feeBps/feeRecipient) so the fleet's fee-ledger tooling reads both unchanged.
interface IEscrowFactory {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    /// @dev Per-release minimum toll in token base units; 0 = legacy (no floor).
    function minFee() external view returns (uint256);
}
