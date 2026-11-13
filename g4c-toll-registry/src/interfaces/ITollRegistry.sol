// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ITollRegistry — one address, per chain, to look up a product's toll.
/// @notice A `bytes32 product` id (e.g. `keccak256("g2b-escrow")`) maps to the WHOLE tuple
///         `(recipient, feeBps, live)` in ONE call, so a consumer never mixes two reads and can
///         never be torn by a mid-read change.
///
///         THE FEE DENOMINATOR IS `10_000` AND IT IS SPELLED LITERALLY, NOT `MAX_FEE_BPS`.
///         Fleet-wide `MAX_FEE_BPS` means two incompatible things (#144): a 500 bps CEILING in
///         Registry/StreamFactory/EscrowFactory, and the 10_000 DENOMINATOR in Router. A consumer
///         doing fee math must write `amount * feeBps / 10_000` and NOT borrow a sibling's constant.
///         (Scope §2 design decision, §3 finding.)
///
///         `live=false` for an unset product — a consumer can then tell "0 bps on purpose" (a
///         registered product whose fee is genuinely zero) apart from "we never registered this".
///         A consumer MUST revert on `live=false`; it must NOT substitute a compiled default
///         (Scope §4: a fallback default is a second source of truth that can silently disagree).
interface ITollRegistry {
    /// @notice The toll for `product`.
    /// @return recipient the address a toll on this product is paid to
    /// @return feeBps    the fee in basis points; a consumer divides by the LITERAL 10_000
    /// @return live      false iff `product` was never registered (`recipient`/`feeBps` are then 0)
    function toll(bytes32 product) external view returns (address recipient, uint16 feeBps, bool live);
}
