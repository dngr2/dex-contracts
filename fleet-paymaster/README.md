# FleetPaymaster — ERC-4337 v0.7 verifying paymaster

BUILD-WAVE-1 LANE 8. A paymaster that sponsors UserOps which call a **fleet contract**,
and charges the sponsorship back as a **small addition to the rail fee** — not in ETH.

## What it does

- **Allow-list.** An op is sponsored only if its call targets an allowed `(target, selector)`
  pair, an allowed whole target, or a `bytes4(0)` wildcard entry on an allowed target.
- **Surcharge rides the rail fee.** `sponsorBps` (default **10 bps**, owner-settable, cap 1000 bps)
  is applied to the op's base amount and **accrued** against the sender. It is a *separate*,
  *additive* charge — it does **not** re-rate the rail's own fee (which stays whatever the rail
  charges, e.g. 500 bps). `previewSponsorFee(x) == x * sponsorBps / 10_000`.
- **Snapshot.** `sponsorBps` is captured into the `postOp` context during validation, so an owner
  change mid-flight cannot move the price of an in-flight op.
- **Per-sender rate limit.** At most `maxOpsPerWindow` ops per `rateWindowSeconds`; `0` = unlimited.
  The window is bumped in `postOp` so an op that reverts later still consumes its slot.
- **EntryPoint deposit.** `deposit()` funds the EP deposit that prefunds gas; `withdrawTo(to, amt)`
  is owner-only; `addStake` relays the relay-protection stake.
- **Non-custodial, non-upgradeable, no selfdestruct.** `nonReentrant` on deposit/withdraw.

## Self-contained

`IPaymaster`, `IEntryPoint`, `PackedUserOperation` are **vendored** under `src/interfaces/` —
no `lib` import in `src/` (only `forge-std` in tests). Owner + guard are the house-minimal
shapes (`src/utils/`), two-step ownership.

## The callData convention

`validatePaymasterUserOp` understands a 3-word head after the account-fn selector:

```
callData = <4-byte account fn> ++ abi.encode(
    address target,        // word 0 — the fleet contract the op calls
    uint256 sponsorBase,   // word 1 — the amount the surcharge rides (e.g. the pay amount)
    bytes   innerCall      // word 2 — head of the call; bytes4 = matched on the allow-list
)
```

A callData with no `innerCall` (2 words) is a target-only call: selector = `bytes4(0)`. That
form therefore needs a whole-target allow or a `bytes4(0)` wildcard entry — an `(target, selector)`
entry alone will **not** match it (nothing supplies the selector). (Probe:
`test_probe_twoWordFormNeedsWholeTargetOrWildcard`.)

> **The declared target is a CLAIM, not a verified callee.** The paymaster reads the
> `target` word the op supplies; it does not inspect what the account actually calls. So an
> account that *declares* an allowed target is sponsored **even if it then calls an enemy
> contract**. That is by design (validate is a `view` with no callee round-trip), but it means
> the allow-list is a *declaration* gate — a "declare rail, call enemy" op is funded. If the
> callee must be pinned, the account's callData has to be built to match. (Probe:
> `test_probe_declaredTargetIsTrustedNotVerified`.)

## ERC-4337 semantics

- `validatePaymasterUserOp` is `view`, `onlyEntryPoint`, returns `(context, 0)`
  (`validationData = 0` ⇒ valid now, no aggregator, no time bounds).
- `postOp` accrues the surcharge on **every** mode: `opSucceeded`/`opReverted` are the op's own
  outcome (gas is owed either way); `postOpReverted` is the EntryPoint's **retry after a first
  postOp reverted** — that attempt's state rolled back, so charging again is correct, not a double.

## Tests — `test/unit/FleetPaymaster.t.sol` + `test/unit/PaymasterAdversarial.t.sol`

No live EntryPoint; `MockEntryPoint` drives validate→postOp exactly as the EP would.
**32 tests / 0 failed** (28 in the lane's own suite + 4 adversarial probes by dex-critic).
Covers allow-list hit/miss/wildcard/whole-target, sender gate, rate-limit exceeded / roll /
per-sender / unlimited / reverted-mode bump, `sponsorBps` default + exact accrual + mid-flight
snapshot + bound, `previewSponsorFee` == accrual, `clearAccrual`, postOp accrual + emit +
onlyEntryPoint, deposit/withdraw/stake, ownership, bad callData, ctor zero-check; adversarially:
declared-target-trusted-not-verified, unlisted-declared-target refused, selector-from-head-only,
2-word form needs whole-target-or-wildcard.

```bash
forge build && forge test
```

Nothing deployed. Owner is an address (Safe/timelock out of scope).
