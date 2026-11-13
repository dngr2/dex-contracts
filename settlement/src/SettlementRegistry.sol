// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ISettlementRegistry} from "./interfaces/ISettlementRegistry.sol";

/// @title SettlementRegistry — the fleet's settlement READ SIDE.
/// @notice A write-once ledger that lets any integrator prove "was X paid" with one `view` call,
/// without holding a single wei. Rail contracts (the only writers) call `markPaid(paymentId,
/// amount)` when they settle; the registry records `(amount, at)` forever and emits `Settled`.
///
/// WHY IT HOLDS NO FUNDS: rails already move the money. A settlement proof must not become a
/// second place money can be stuck (the #187 pull-rail/verb class), so this contract is pure
/// bookkeeping — `marked` state only, no ERC-20 interaction, no payable path, no receive().
///
/// TRUST MODEL (deliberately thin):
///   * `owner` is an address; the caller (Safe/timelock) is out of scope. Owner may add/remove
///     writers and transfer ownership once.
///   * Writers are an allow-list of RAIL contracts. A writer is trusted to report its own
///     settlements truthfully — the registry cannot re-derive a rail's internal state, so it
///     records what its writers assert. This is why the set is gated, not permissionless.
///   * Idempotent by design: a retried/duplicated `markPaid` must not corrupt the record, and a
///     CONFLICTING second amount must be loud (revert) rather than silently overwrite.
///
/// Non-custodial, non-upgradeable, no selfdestruct, no admin fund path.
contract SettlementRegistry is ISettlementRegistry {
    /// @dev `at != 0` is the "settled" predicate, so a 0-amount mark is still distinguishable from
    /// an unknown id (which is `(0, 0)`). Both are only ever reachable via a real `markPaid`.
    struct Record {
        uint256 amount;
        uint64 at;
    }

    address public owner;
    mapping(address => bool) public isWriter;
    mapping(bytes32 => Record) private _records;

    error NotOwner();
    error NotWriter();
    error ZeroArg();
    error AlreadyOwner();
    error AmountMismatch(bytes32 paymentId, uint256 recorded, uint256 incoming);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroArg();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    // ---- read side (the whole point) ----

    /// @inheritdoc ISettlementRegistry
    function paid(bytes32 paymentId) external view returns (uint256 amount, uint64 at) {
        Record storage r = _records[paymentId];
        return (r.amount, r.at);
    }

    /// @notice Convenience: true iff `paymentId` has been marked settled.
    function isPaid(bytes32 paymentId) external view returns (bool) {
        return _records[paymentId].at != 0;
    }

    // ---- write side (writers only) ----

    /// @inheritdoc ISettlementRegistry
    function markPaid(bytes32 paymentId, uint256 amount) external {
        if (!isWriter[msg.sender]) revert NotWriter();

        Record storage r = _records[paymentId];
        if (r.at == 0) {
            // First mark wins and is final.
            _records[paymentId] = Record({amount: amount, at: uint64(block.timestamp)});
            emit Settled(paymentId, amount, uint64(block.timestamp));
        } else if (r.amount != amount) {
            // Same id, different amount: a real disagreement — never silently overwrite.
            revert AmountMismatch(paymentId, r.amount, amount);
        }
        // else: identical re-mark -> no-op (no event).
    }

    // ---- owner admin ----

    function setWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroArg();
        isWriter[writer] = allowed;
        emit WriterSet(writer, allowed);
    }

    function setWriters(address[] calldata writers, bool allowed) external onlyOwner {
        for (uint256 i; i < writers.length; ++i) {
            address w = writers[i];
            if (w == address(0)) revert ZeroArg();
            isWriter[w] = allowed;
            emit WriterSet(w, allowed);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroArg();
        if (newOwner == owner) revert AlreadyOwner();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }
}
