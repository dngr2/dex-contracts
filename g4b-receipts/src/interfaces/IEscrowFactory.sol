// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The slice of EscrowFactory this module reads. Two jobs:
///      * `feeBps`/`feeRecipient` — identical in shape to P2's IRegistry (fee-ledger tooling parity).
///      * `escrowCount`/`escrowsOf` — the PROVENANCE oracle: a factory pushes a CREATE2 child into
///        `escrowsOf[payer]` the instant it deploys it, so membership here is first-party proof that
///        an escrow really came from this factory. See ReceiptNFT for why membership (not a bytecode
///        blob scan) is the gate.
interface IEscrowFactory {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function escrowCount(address payer) external view returns (uint256);
    function escrowsOf(address payer, uint256 idx) external view returns (address);
}
