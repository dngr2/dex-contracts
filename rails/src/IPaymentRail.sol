// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IPaymentRail — the common payment rail interface (FROZEN)
/// @notice ONE interface implemented by the fleet's payment entry points (the forwarder registry,
///         the request registry, the stream factory). Integrators and agents code against this one
///         shape so a rail is swappable without an ABI rewrite.
///
/// @dev SOURCE: `Path to Volume — Technical Roadmap for the DEX Fleet.pdf`, p.6, verbatim. This file
///      is FROZEN for BUILD WAVE 1 — do not change member names or signatures; other lanes import it.
///
///      FEE RATE IS PER-PRODUCT AND READ LIVE. `feeBps()` returns whatever the implementing rail's
///      registry is set to AT CALL TIME — it is NOT a fixed 100/150/50 and NOT a compile-time constant.
///      The roadmap's p.9 "parameters at launch" table (25/50/5) is the per-product rate each ENTRY
///      POINT carries, not a value baked here; a rail whose owner raises its registry rate reports the
///      new value from the very next `feeBps()` call. Callers must therefore `quote()` (or read
///      `feeBps()`+`minFee()`) per payment and never cache across a rate change.
///      `minFee(token)` is a SEPARATE concept: a per-token floor that bounds the fee from below on
///      dust-sized payments; it is not the rate.
interface IPaymentRail {
    /// @notice The live fee rate in basis points for the product behind this rail. Owner-settable on
    ///         the underlying registry; read it live, do not assume a constant.
    function feeBps() external view returns (uint16);

    /// @notice Per-token minimum fee (in the token's own units), the floor below which the bps rate
    ///         is not allowed to fall on a small payment. A floor, not the rate.
    function minFee(address token) external view returns (uint256);

    /// @notice Preview a payment: the `fee` the rail would take and the `out` the recipient would
    ///         receive, for `amount` of `token` at the CURRENT live rate. Agents and UIs call this
    ///         before `pay`.
    function quote(address token, uint256 amount) external view returns (uint256 fee, uint256 out);

    /// @notice Pay `to` `amount` of `token`, tagging the payment with `memo` and crediting `referrer`.
    ///         `payable`: a rail may accept native ETH where `token == address(0)`.
    /// @return paymentId A stable id for this payment (the SettlementRegistry read key).
    function pay(address to, address token, uint256 amount, bytes32 memo, address referrer)
        external
        payable
        returns (bytes32 paymentId);

    /// @notice Emitted on every successful `pay`. `paymentId`, `payer` and `to` are indexed so an
    ///         integrator can filter by any of them without decoding the tail.
    event Paid(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed to,
        address token,
        uint256 amount,
        uint256 fee,
        bytes32 memo,
        address referrer
    );
}
