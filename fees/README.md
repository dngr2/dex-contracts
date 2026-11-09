# products/fees — referral + fee-split money (BUILD WAVE 1, lane 4)

Greenfield foundry project. Non-custodial, non-upgradeable, no `selfdestruct`. Nothing deployed.

## What this is (and is NOT)

A pure **pass-through splitter**. A rail has already CHARGED a fee; these contracts divide whatever
fee arrives between a referrer and the treasury **in the same call**, and keep a claimable bucket
for any payee whose inline transfer fails. They do NOT set the fee level — that stays with the rail
and the live `feeBps` (see `fees.json`). The only "fee" number hardcoded here is `referralBps`
(default **2500** = 25% of the fee), and its bound (`<= 10_000`).

This matches the user's override on Wave-1: the fee stays 500 bps; this lane only splits the
existing fee.

## Contracts

- `src/FeeSplitter.sol` — `split(token, fee, product, payer, referrer)` (ERC-20, pulls the fee via
  `transferFrom` then fans out) and `splitNative(product, payer, referrer)` (msg.value path).
  `referralBps` settable by owner `<= 10_000`. Emits
  `FeeSplit(product, payer, referrer, fee, referrerCut)`. A stray bare `send` to `receive()` is
  recoverable via owner-gated `sweepNative()` (see below).
- `src/ReferralRegistry.sol` — `bytes32 code -> address`, first-come (`register(code)` binds
  msg.sender if free), non-transferable except by the code owner (`transferCode`), `burn()` frees a
  code, `resolve(code)` view.

## Native strand — the `receive()` fix (GOTCHA #204)

`receive()` accepts native (e.g. from a rail forwarding value), but a *bare* `send` is NOT split —
it just lands on the contract's balance and would otherwise be stranded. The fix keeps the
pass-through promise:

- `nativeRecoverable()` returns `balance - nativeOwed` — the excess held over what payees are owed.
- `sweepNative()` (owner-gated, `nonReentrant`) forwards **only** that excess to `treasury`, reverting
  with `NothingToSweep` when there is none. It never touches native owed via `claimable`.
- `nativeOwed` is a running total, incremented when a native payout reverts (accrues) and decremented
  on `claim(address(0))`. This is the cap that guarantees a sweep cannot steal a pending payee claim.

Prefer `splitNative{value: ...}` so the fee is divided on receipt; `receive()` is a safety net for a
plain `send`, not the primary path.

## The invariant that matters

```
fee == referrerCut + treasuryCut      (treasuryCut is the REMAINDER — no rounding leak)
```

`referrerCut = fee * referralBps / 10_000` (floored); `treasuryCut = fee - referrerCut`. A zero
referrer sends the whole fee to treasury (`referrerCut == 0`). Tested exactly, including a fuzz over
odd amounts, and on the **referrer-reverts** path where BOTH cuts accrue.

## Why the accrual exists (the safety net)

If a payee's inline transfer reverts OR returns `false` (a lying token), the split **does not
brick**. The owed amount is booked in `claimable[who][token]` and pullable later with `claim(token)`
(`token == address(0)` = native). Nothing is ever lost. The `test/negcontrol/` suite proves this has
teeth: a deliberately-broken twin that DROPS the cut instead of accruing fails the `claimable == rc`
assertion the good contract passes.

## Non-custodial guarantees

- Holds no fee beyond the transaction, except (a) a failed payout sitting in `claimable`, and (b) a
  stray bare `send`, which is recoverable by the owner via `sweepNative()` — never permanent.
- `nonReentrant` on every value path (`split`, `splitNative`, `claim`, `sweepNative`);
  effects-before-interaction in `claim`.
- No owner funds, no upgrade, no delegatecall. Owner can only sweep the *excess* — pending native
  owed to payees is untouchable by the owner.

## Test

```
forge test          # 51 tests, 0 fail (unit + negcontrol)
forge build         # green
```

Unit: `test/unit/FeeSplitter.t.sol` (conservation fuzz, zero-referrer, zero-fee, odd-amount,
native, reverting-referrer accrual, both-revert accrual, false-returning token, bps bounds, event,
bare-send strand + `sweepNative` cap). `test/unit/ReferralRegistry.t.sol` (first-come, transfer,
burn, release-prior).
Negcontrol: `test/negcontrol/NegControl.t.sol` (broken twin loses the fee).

## Ownership

exec4 (lane 4). Owner is an address; the caller (Safe/timelock) is out of scope here.
