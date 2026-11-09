// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ISettlementRegistry — the fleet's SETTLEMENT READ SIDE.
/// @notice Integrators (SDK, x402 facilitator, merchant pages) call `paid()` to prove a payment
/// happened. The registry HOLDS NO FUNDS: it is a write-once ledger of `paymentId → (amount, at)`
/// written by an owner-approved allow-list of RAIL contracts at the moment a rail settles.
interface ISettlementRegistry {
    /// @notice Was `paymentId` settled? Returns the settled amount and the settle timestamp.
    /// @return amount the settled amount (0 if unknown)
    /// @return at the unix second the id was first marked (0 if unknown — `at != 0` is the
    ///         "is settled" signal, so a legitimate 0-amount mark is still distinguishable)
    function paid(bytes32 paymentId) external view returns (uint256 amount, uint64 at);

    /// @notice Mark `paymentId` settled for `amount`. Callable ONLY by an allow-listed writer.
    /// @dev IDEMPOTENT: a second call with the same id AND the same amount is a no-op (no event).
    ///      A second call with the same id but a DIFFERENT amount reverts `AmountMismatch`.
    function markPaid(bytes32 paymentId, uint256 amount) external;

    /// @notice True if `who` may call `markPaid`.
    function isWriter(address who) external view returns (bool);

    event Settled(bytes32 indexed paymentId, uint256 amount, uint64 at);
    event WriterSet(address indexed writer, bool allowed);
    event OwnerSet(address indexed owner);
}
