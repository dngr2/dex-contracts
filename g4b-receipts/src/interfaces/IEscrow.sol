// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The ONLY slice of the g2b Escrow a receipt reads. Vendored (not imported) so this module is
///      self-contained and touches no g2b file — the p3c-7702 module idiom. Signatures are
///      byte-identical to g2b `Escrow`'s public immutable getters, so a real escrow satisfies it
///      with no adapter. Read-only: the receipt NEVER writes to or calls into the escrow.
interface IEscrow {
    function factory() external view returns (address);
    function payer() external view returns (address);
    function counterparty() external view returns (address);
    function token() external view returns (address);
    function amount() external view returns (uint256);
    function deadline() external view returns (uint64);
    function hash() external view returns (bytes32);
    function settled() external view returns (bool);
}
