// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title FeeMath — THE single definition of a fleet toll, in ONE place.
/// @notice Every product toll site (P2 Forwarder, G2-a StreamVault ×2, G2-b Escrow) calls
///         `FeeMath.toll(...)`. There is exactly one copy of this arithmetic in the fleet; the
///         recurring failure mode this prevents is "three copies drift" (GOTCHAS #131/#144 family:
///         a rule re-implemented from a sibling source diverges from it).
///
/// WHY A LIBRARY AND NOT A COPY (or a vendored copy)
///   g4b vendors whole CONTRACTS because it needs them as real deployed dependencies for fork tests.
///   A pure fee formula needs neither storage nor a constructor, so it is a `library` imported by
///   RELATIVE path (`../../shared/FeeMath.sol`) from all three products with NO remapping. One file,
///   three importers, zero copies to drift. If a product ever needs a different shape it must
///   override a seam (see the negcontrols), not re-type the formula.
///
/// ============================ THE DESIGN DECISION (dust below minFee) ============================
///   The brief: `fee = max(amount * bps / 10_000, minFee)` "fixes small tickets", BUT a naive
///   `max()` BREAKS the existing dust-safety property ("fee==0 when tiny -> skip") AND can even
///   underflow (`amount < minFee` => `amount - fee` underflows). So `max()` alone is wrong.
///
///   Two candidate rules for the band `amount <= minFee`:
///     (A) CLAMP: fee = min(amount, minFee) = amount; destination gets 0. The sub-minFee deposit is
///         still TOLLED, and the toll it pays is `amount` — which is >= the ticket, so it still loses
///         gas: a $0.0005 deposit against a $0.00104 gas cost LOSES $0.00054, AND the destination
///         receives nothing. Worst of both.
///     (B) SKIP:  fee = 0; destination forwards in FULL. Net 0 against gas (nothing collected, nothing
///         spent collecting), and the destination is not cannibalised. CHOSEN.
///
///   minFee means "the smallest toll worth COLLECTING" — i.e. it encodes the keeper's gas cost. If a
///   ticket is smaller than that toll, collecting it would take the whole ticket (clamp) for a
///   collection that still costs more than it yields; so DON'T COLLECT, forward whole.
///
///   THE RULE (boundary at `<=`):
///       amount <= minFee  ->  fee = 0,        out = amount      (untolled, forwards whole)
///       amount  > minFee  ->  fee = max(bps-fee, minFee), out = amount - fee   (at least 1 wei out)
///   `<=` (not `<`) is deliberate: at `amount == minFee`, clamp would hand the destination exactly 0.
///   Skipping there guarantees the INVARIANT below: **a tolled forward always leaves >= 1 wei for the
///   destination, and an untolled forward leaves all of it.** Nothing is ever silently delivered as 0
///   (except a 0 ticket, which the callers short-circuit before we are reached).
///   The step from 0 to `minFee` across the line is inherent to a floor and is STATED, not hidden.
///
/// INVARIANTS (pinned by test/unit/FeeMath.t.sol in each consumer + asserted at the seams)
///   1. `fee + out == amount`            (conservation — no wei created or lost)
///   2. `fee == 0 || fee >= minFee`      (a collected toll is never below the floor)
///   3. `out > 0 whenever amount > 0`    (never deliver 0 to the destination)
///   4. `minFee == 0` => `fee == amount * bps / 10_000` and `out == amount - fee`
///                                        (the DEPLOY DEFAULT is byte-behaviour identical to the
///                                         pre-change inline formula — proven, not asserted)
///
/// ================= THE SECOND SHAPE: rate x TIME, not rate x amount (P1 mgmt fee) ================
///   `toll()` splits a TICKET and needs the ticket to arrive. A management fee is the ETF model:
///   an annualized bps on TVL that accrues per unit of TIME the assets were managed, so the vault
///   earns on a flat market — while `toll()`-shaped perf fees earn only on gains. Both live HERE so
///   the fleet keeps ONE fee convention rather than a second copy of "bps x something over 10_000".
///
///   THE ROUNDING / DUST RULE — answered explicitly, because it is the whole design risk:
///     `mgmtFee` FLOOR-divides (like every other fee in this library) and therefore returns 0 for a
///     tiny vault over a short window. The trap is a vault that HARVESTS OFTEN: if the caller also
///     resets its accrual clock on every zero fee, a small vault pays 0 WEI FOREVER (elapsed never
///     grows past the rounding threshold). The rule, therefore, lives in the CALLER and is:
///
///        **advance the accrual clock when the fee is > 0, OR the base is 0 — freeze ONLY when
///          `base > 0 && fee == 0`.**
///
///     A zero fee AT A NONZERO BASE (the floor) leaves `elapsed` intact, so the sub-wei claim keeps
///     building until it crosses one wei and is charged. Consequence, stated: a tiny vault pays 0 for
///     the first window (≈18 days for 1000 wei of LP at 2%/yr) and then pays — never "0 forever", and
///     never a sub-wei charge. This is the SAME philosophy as `toll()`'s dust SKIP (don't collect
///     what is below the line), one level down: the claim is kept, not the dust.
///
///   THE EMPTY-BASE CARVE-OUT (GOTCHA #156) — a time accrual's zero is AMBIGUOUS without it:
///     `mgmtFee(tvl=0, …)` and `mgmtFee(tvl=big, …)`-that-floors BOTH return 0, but they mean
///     OPPOSITE things. A fencepost vault (empty while a gauge is dead) must NOT freeze its clock on
///     the empty window, or the FIRST depositor is billed the whole dead gap as if it had been
///     managed. `toll()` needs no such carve-out: an amount-based call always has `amount > 0` (the
///     callers short-circuit 0 before we are reached), so its zero is never "empty" — only "below the
///     line". So the width test is one rule, `collect <=> basis > 0 AND fee > 0`, and the carve-out
///     lives ONLY on the time side, because only there can the basis be 0 while the clock runs.
///
///   CAP: the result is capped at `tvl`. Reachable only when a single harvest spans a MULTI-YEAR gap
///   at a high rate (e.g. 6 years untouched at 20%/yr = 120% of TVL), where paying more LP than the
///   vault holds would otherwise revert `strategy.withdrawTo`.
///
/// @dev INTEGER ONLY, FLOOR division. Flooring matches the pre-change code and all three consumers
///      (GOTCHAS #144: name the divisor literally — `MAX_FEE_BPS` is a 500-bps CEILING in these
///      contracts but the 10_000 DENOMINATOR in the Router, so `/ 10_000` is written out, never a
///      borrowed constant).
library FeeMath {
    /// @notice Seconds in the accrual year. `365 days` is Solidity's literal, not an approximation.
    uint256 internal constant YEAR = 365 days;
    /// @notice A toll collected before the amount is split: `fee` to the treasury, `out` to the user.
    /// @param amount the gross amount in TOKEN BASE UNITS (so minFee is per-token — see below)
    /// @param bps    the rate, in basis points (25 = 0.25%). Callers clamp to their own ceiling first.
    /// @param minFee the per-token minimum toll in BASE UNITS. 0 => legacy behaviour exactly.
    /// @return fee the toll (0 when below the minFee line)
    /// @return out what the user/recipient receives (`amount - fee`, always >= 0)
    function toll(uint256 amount, uint16 bps, uint256 minFee)
        internal
        pure
        returns (uint256 fee, uint256 out)
    {
        // (B) SKIP: a ticket no larger than the smallest worthwhile toll is forwarded untolled.
        // With minFee == 0 this is unreachable for any amount >= 1 (callers already handled 0), so
        // the branch is inert on the deploy default -> byte-behaviour identical to the old formula.
        if (amount <= minFee) return (0, amount);
        fee = bpsFee(amount, bps);
        if (fee < minFee) fee = minFee;   // the FLOOR
        out = amount - fee;               // safe: amount > minFee >= fee, so out >= 1
        // invariant 1 holds by construction; 3 by the line above.
    }

    /// @notice The raw bps split, floored — the OLD fleet formula, kept nameable so (a) the
    ///         no-minFee equivalence proof can call it as the reference and (b) a rate x time
    ///         consumer (p1 mgmt fee) can reuse the split half without the floor.
    /// @dev NEVER use a sibling's `MAX_FEE_BPS` for the divisor (#144) — it is a ceiling elsewhere.
    function bpsFee(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /// @notice A MANAGEMENT fee: annualized `annualBps` on `tvl`, pro-rated over `elapsed` seconds.
    ///         The ETF shape — accrues whether or not the vault made money.
    /// @param tvl        the managed base in TOKEN BASE UNITS (the vault's totalAssets at accrual)
    /// @param annualBps  the annualized rate in basis points (200 = 2%/yr). Caller clamps first.
    /// @param elapsed    seconds since the last ACCRUED point (see the caller rule in the header)
    /// @return fee the fee in the same units as `tvl`; 0 when the pro-rated claim floors to 0
    /// @dev Compose with `bpsFee`: `bpsFee(tvl, annualBps)` is the WHOLE-year fee, and the elapsed
    ///      factor scales it. Integer floor twice (bps first, then the time proration) — so the
    ///      result is <= floor(tvl * annualBps / 10_000 * elapsed / YEAR), never above it.
    ///      Capped at `tvl` so a long-gap harvest can never ask for more LP than exists.
    function mgmtFee(uint256 tvl, uint16 annualBps, uint256 elapsed) internal pure returns (uint256 fee) {
        if (tvl == 0 || annualBps == 0 || elapsed == 0) return 0;
        fee = (bpsFee(tvl, annualBps) * elapsed) / YEAR;
        if (fee > tvl) fee = tvl;
    }
}
