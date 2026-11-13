// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ITollRegistry} from "./interfaces/ITollRegistry.sol";

/// @title TolledConsumer — the reference shape for reading a toll from the registry SAFELY.
/// @notice This is not the registry; it is the ~20 lines a NEW product copies to be a registry
///         consumer. It exists so the AC explains the two rules that matter, both from scope §3/§4:
///
///         RULE 1 — PROVENANCE (#134/#135). The consumer pins the registry's EXTCODEHASH at
///         construction and re-checks it on every read. It asks the thing it already trusts
///         (its own compiled-in codehash) rather than the thing it is checking (the address it was
///         handed). An immutable ctor ARG alone is NOT provenance — any address can be passed.
///
///         RULE 2 — DENOMINATOR (#144). Fee math divides by the LITERAL `10_000`, never by a
///         borrowed `MAX_FEE_BPS` (which is 500 on Registry/StreamFactory/EscrowFactory — a 20× lie).
///
///         RULE 3 — NO FALLBACK (scope §4). A `live=false` product REVERTS; it does not silently
///         substitute a compiled default, because a default is a second source of truth that can
///         disagree with the registry.
///
///         NOTE: like the registry, this carries NO immutables — `REGISTRY`/`REGISTRY_CODEHASH` are
///         `constant`-style only via storage here anyway; the pin value is a literal compiled in.
contract TolledConsumer {
    /// @dev Literal denominator. NOT `MAX_FEE_BPS` (#144).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Pinned at construction, re-checked at every read. Not discovered at runtime.
    address public registry;
    bytes32 public registryCodehash;

    error RegistryNotOurs(address registry, bytes32 have, bytes32 want);
    error ProductNotRegistered(bytes32 product);
    error ZeroRegistry();

    constructor(address registry_, bytes32 registryCodehash_) {
        if (registry_ == address(0)) revert ZeroRegistry();
        registry = registry_;
        registryCodehash = registryCodehash_;
    }

    /// @notice The fee owed on `amount` at `product`'s rate, and where to send it.
    /// @dev The whole tuple is read in ONE call (no tear between recipient and bps), provenance is
    ///      re-checked, and an unset product reverts rather than defaulting.
    ///      A pin of `bytes32(0)` means "unpinned" (allowlist-only) — the pin can be dropped, which
    ///      is the assertion that proves the pin is load-bearing rather than decorative.
    function _toll(bytes32 product, uint256 amount) internal view returns (address recipient, uint256 fee) {
        // RULE 1 — provenance. Ask our OWN compiled-in codehash, not the address we hold.
        if (registryCodehash != bytes32(0)) {
            bytes32 have = registry.codehash;
            if (have != registryCodehash) revert RegistryNotOurs(registry, have, registryCodehash);
        }

        (address r, uint16 b, bool live) = ITollRegistry(registry).toll(product);
        if (!live) revert ProductNotRegistered(product); // RULE 3 — revert, no fallback

        // RULE 2 — literal 10_000 denominator.
        return (r, (amount * b) / BPS_DENOMINATOR);
    }

    /// @notice Public entry so a test (and a real product) can read the guarded toll.
    function quotedToll(bytes32 product, uint256 amount) external view returns (address recipient, uint256 fee) {
        return _toll(product, amount);
    }
}
