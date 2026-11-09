// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title RequestLedger — the "HOW MUCH arrived" tally for F1-a payment links.
/// @notice A THIN contract on top of F1-a: it does NOT touch Registry.sol / Forwarder.sol /
///         RequestRegistry.sol (all stay byte-for-byte as deployed). It only records, per deposit
///         address, how much has arrived, so a chain-only reader can see the settled AMOUNT and not
///         just the settled FLAG.
///
/// WHY A SEPARATE CONTRACT (Shape-B doctrine — link, don't inherit)
///   The v2 TODO wanted `amountReceived` per request. A stock P2 Forwarder has no callback into the
///   F1-a layer (its immutable `registry` is the P2 Registry), so the tally cannot be accrued
///   inside RequestRegistry without the daemon pushing it anyway. So the tally lives in its own
///   contract and RequestRegistry stays frozen.
///
/// WHO WRITES IT, AND THE TRUST MODEL (read before relying on the number)
///   `noteReceived` is PERMISSIONLESS and called by the keeper when it sees the Forwarder's
///   `Forwarded` log (it already decodes that). The AUTHORITATIVE per-forward amount remains the
///   `Forwarded` log on the Forwarder; this ledger is a convenience INDEX of it. Because the writer
///   is unverified on-chain, a griefer could over-report a deposit — so treat the tally as
///   daemon-reported, and reconcile against `Forwarded` when the exact figure matters.
///
/// IDEMPOTENT BY (depositAddr, ref) — mirrors the keeper's fee-ledger key
///   A `--from-block 0` replay re-submits `forward()`; on a drained deposit that is an on-chain
///   no-op (`amount == 0`). Keying on the SOURCE deposit (`ref` = the deposit tx hash) makes a
///   replay not double-count, exactly like `fee_ledger.idem_key`. Note: `ref` is caller-supplied,
///   so idempotence is against the caller's key, not a chain-enforced one.
///
/// deposit addr ↔ request id is 1:1 (each `request()` mints a fresh deposit via the Registry's
/// nonce), so a reader resolves id -> depositAddr from the RequestCreated log and reads `received`.
/// `receivedFor` does that join in one call for convenience.
interface IRequestRegistryView {
    function request_(uint256 id)
        external
        view
        returns (
            address merchant,
            address payer,
            address destination,
            address token,
            uint256 amount,
            bytes32 memo,
            address depositAddr,
            uint64 createdAt,
            bool settled,
            uint64 settledAt
        );
}

contract RequestLedger {
    struct Tally {
        uint256 amount; // gross received on this deposit addr, in token base units
        uint32 count;   // number of distinct source deposits counted
    }

    /// @notice depositAddr => running tally. Public getter returns (amount, count).
    mapping(address => Tally) public received;
    /// @dev keccak(depositAddr, ref) => already counted (replay guard).
    mapping(bytes32 => bool) private _counted;

    /// @dev Emitted once per NEW source deposit. `total` is the running tally AFTER this add, so a
    ///      log-only reader gets the amount and the running total from one event.
    event Received(
        address indexed depositAddr,
        uint256 amount,
        uint256 total,
        uint32 count,
        bytes32 ref
    );

    error ZeroDeposit();

    /// @notice Record `amount` arrived at `depositAddr`, once per (depositAddr, ref).
    /// @param depositAddr the F1-a request's deposit address (the stock P2 Forwarder)
    /// @param amount gross amount that arrived, in the token's base units
    /// @param ref opaque idempotence key for the SOURCE deposit (keeper passes the deposit tx hash)
    function noteReceived(address depositAddr, uint256 amount, bytes32 ref) external {
        if (depositAddr == address(0)) revert ZeroDeposit();
        if (amount == 0) return; // a drained-deposit replay forwards 0; nothing to add

        bytes32 k = keccak256(abi.encodePacked(depositAddr, ref));
        if (_counted[k]) return; // replay of the same source deposit — idempotent
        _counted[k] = true;

        Tally storage t = received[depositAddr];
        t.amount += amount;
        t.count += 1;
        emit Received(depositAddr, amount, t.amount, t.count, ref);
    }

    /// @notice One-call join for a chain-only reader: resolve `id` on `requestRegistry` to its
    ///         deposit address, then return the tally. Reverts if the request does not exist.
    function receivedFor(address requestRegistry, uint256 id)
        external
        view
        returns (uint256 amount, uint32 count, address depositAddr)
    {
        (, , , , , , address dep, , , ) = IRequestRegistryView(requestRegistry).request_(id);
        depositAddr = dep;
        Tally memory t = received[dep];
        return (t.amount, t.count, dep);
    }
}
