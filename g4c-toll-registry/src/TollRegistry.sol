// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ITollRegistry} from "./interfaces/ITollRegistry.sol";

/// @title TollRegistry — a per-chain, set-at-construction table of `product -> toll`.
/// @notice One contract, deployed PER CHAIN, once. Answers a product's `(recipient, feeBps, live)`
///         in a single call. The toll is set in the CONSTRUCTOR; there is NO setter and NO owner.
///
/// STATE-SETTER CHOICE (marked, per scope §2): CONSTRUCTOR-ONLY, no setter, no owner.
///   * "no owner" is the scope's explicit design (removing the admin key removes an attack surface,
///     matching P3 Router.sol:30's own reasoning).
///   * "A toll change = redeploy the registry" is the scope's explicit consequence. A redeploy is
///     one clean tx; a setter would instead re-introduce a writer key to gate.
///   * Consequence, stated not hidden: a redeploy lands at a NEW address, so a consumer that pinned
///     the old address must re-point (see §4/README). That is the accepted cost of "no owner".
///
/// NO IMMUTABLES (load-bearing, scope §4). All product data lives in STORAGE, so the RUNTIME CODE
/// (and therefore `codehash`) is IDENTICAL for every instance regardless of which products a given
/// chain registered. That is exactly what makes a consumer's `codehash` pin a CROSS-CHAIN CONSTANT:
/// the same `bytes32` pin is valid on every chain and stays valid even if the ctor list changes.
/// `BPS_DENOMINATOR` below is a `constant` (inlined, not storage/immutable) and so does NOT perturb
/// the runtime — the pin survives it too.
///
/// THE DENOMINATOR IS SPELLED `10_000`, NOT `MAX_FEE_BPS` (#144). `BPS_DENOMINATOR` is added only as
/// a named literal for the sanity cap below; it is deliberately NOT called `MAX_FEE_BPS`.
contract TollRegistry is ITollRegistry {
    /// @dev The basis-points denominator. A consumer divides by the LITERAL 10_000 — never by a
    ///      borrowed `MAX_FEE_BPS`, which means a 500 bps CEILING on sibling contracts (#144).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev One storage slot: address(20) + uint16(2) + bool(1) = 23 bytes <= 32.
    ///      `live` is explicit so a registered product with feeBps 0 ("0 bps on purpose") is
    ///      distinguishable from an unset product, which reads `(0, 0, false)`.
    struct Toll {
        address recipient;
        uint16 feeBps;
        bool live;
    }

    mapping(bytes32 => Toll) private _tolls;

    error LengthMismatch();
    error ZeroRecipient(bytes32 product);
    error FeeBpsTooHigh(bytes32 product, uint16 feeBps);
    error DuplicateProduct(bytes32 product);

    event Registered(bytes32 indexed product, address indexed recipient, uint16 feeBps);

    /// @param products   the `bytes32` product ids (e.g. keccak256("g2b-escrow")) — chain-agnostic.
    /// @param recipients the toll recipient per product; must be nonzero.
    /// @param feeBpsList the fee in basis points per product; 0 is legal, > 10_000 is not.
    ///                    Array lengths must match; a repeated product id reverts (no silent last-wins).
    constructor(bytes32[] memory products, address[] memory recipients, uint16[] memory feeBpsList) {
        uint256 n = products.length;
        if (recipients.length != n || feeBpsList.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _register(products[i], recipients[i], feeBpsList[i]);
        }
    }

    function _register(bytes32 product, address recipient, uint16 feeBps) private {
        if (_tolls[product].live) revert DuplicateProduct(product);
        if (recipient == address(0)) revert ZeroRecipient(product);
        if (feeBps > BPS_DENOMINATOR) revert FeeBpsTooHigh(product, feeBps);
        _tolls[product] = Toll({recipient: recipient, feeBps: feeBps, live: true});
        emit Registered(product, recipient, feeBps);
    }

    // ---- read side (the whole point) ----

    /// @inheritdoc ITollRegistry
    function toll(bytes32 product) external view returns (address recipient, uint16 feeBps, bool live) {
        Toll storage t = _tolls[product];
        return (t.recipient, t.feeBps, t.live);
    }

    /// @notice Convenience: true iff `product` was registered at construction.
    function isLive(bytes32 product) external view returns (bool) {
        return _tolls[product].live;
    }
}
