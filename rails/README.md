# products/rails/ — the BUILD WAVE 1 shared interface package (LANE 1, exec1)

FROZEN interface-only package. **No implementation.** Other lanes (fees, fleet-executor,
fleet-paymaster, settlement, sdk, x402, mcp-server) import these shapes and must not be broken
silently — so the ABI is pinned by `test/unit/InterfaceIds.t.sol`.

Source: `Path to Volume — Technical Roadmap for the DEX Fleet.pdf` p.6 (IPaymentRail, verbatim) and
p.7 (IEscrowRail / IEscrowHook / IStreamRail from the Phase-2 tables).

## Files

| file | role |
|---|---|
| `src/IPaymentRail.sol` | the common payment interface (roadmap p.6, verbatim) — fee rate read LIVE |
| `src/IEscrowRail.sol`  | escrow shape: `createFor(Deal, referrer)` + `outcome() -> uint8 {0,1,2}` |
| `src/IStreamRail.sol`  | mandate shape: signed `setMandateFor`, permissionless `executeLap`, `dueLaps`, `mandatesOf` |
| `src/IEscrowHook.sol`  | `onEscrowSettled(escrow, outcome, amount)` — try/catch + 100k gas cap |
| `test/unit/InterfaceIds.t.sol` | pins every selector + event topic0 to a hardcoded, `cast`-derived value |

## The freeze, and how it is enforced

Every selector and event topic0 is asserted against a value derived INDEPENDENTLY with
`cast sig` / `cast keccak` (not with the compiler's own `.selector`, which would be self-consistent
under a rename). 9/9 tests. Positive control: renaming `feeBps`→`feeRate` reddens the suite
(`0x978bbdb9 != 0x24a9d853`); reordering the `Deal` tuple reddens it too (`0x96c150eb != 0xd9b22c47`).

**If a lane needs a signature change: change it HERE first, update the expected value in the test,
and ping dex-critic.** Never work around a mismatch at the call site.

## Fee model (unequivocal for integrators)

`feeBps()` is PER-PRODUCT and READ LIVE. It is not a fixed 100/150/50 and not a compile-time
constant; a rail whose registry rate is raised reports the new value from the next call. `minFee(token)`
is a separate per-token FLOOR, not the rate. Call `quote()` per payment; do not cache across a rate change.

## Out of scope here

No `foundry` deploy, no addresses — fixture-only (`address(this)`, `vm.addr`). Nothing deployed.
