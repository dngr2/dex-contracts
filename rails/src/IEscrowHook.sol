// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IEscrowHook — post-settlement notifier for escrow rails
/// @notice An optional hook an escrow calls on RELEASE and REFUND so a marketplace (order book) or a
///         receipt minter can update its own state without the escrow knowing that state.
///
/// @dev SOURCE: roadmap p.7 (`hook.onEscrowSettled(escrow, outcome, amount)` in try/catch, gas cap 100k).
///      FROZEN for BUILD WAVE 1.
///
///      SAFETY CONTRACT FOR IMPLEMENTORS OF THE HOOK ADDRESS:
///      1. The escrow calls this INSIDE A try/catch, so a reverting hook can never block settlement.
///      2. The escrow forward-caps gas to 100_000, so a hook that burns gas cannot grief settlement.
///      3. Therefore the hook MUST be safe to cheaply fail: do no work that needs > 100k, and treat a
///         missed callback as "re-derive from chain", never as "assume the default outcome".
///
///      `outcome` uses the SAME encoding as `IEscrowRail.outcome()`: 0 = open (not passed to the hook),
///      1 = released, 2 = refunded. `amount` is the settled (post-fee) amount moved to the payee.
interface IEscrowHook {
    /// @notice Called by an escrow after it settles (release or refund). MUST be cheap and MUST NOT be
    ///         relied on for the source of truth (the escrow's `outcome()` is).
    /// @param escrow the escrow that settled
    /// @param outcome 1 = released, 2 = refunded
    /// @param amount  the settled amount the payee received, in the escrow token's units
    function onEscrowSettled(address escrow, uint8 outcome, uint256 amount) external;
}
