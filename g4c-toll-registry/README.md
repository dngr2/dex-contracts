# g4c-toll-registry

Per-chain, constructor-set lookup table for a product's toll:
`product:bytes32 -> (recipient:address, feeBps:uint16, live:bool)` in ONE call.

Scope: [`SCOPE-TOLL-REGISTRY.md`](SCOPE-TOLL-REGISTRY.md) (read it — §2/§4/§6 are the build contract).
Matrix this mirrors: [`MATRIX-product-by-chain.md`](MATRIX-product-by-chain.md).
Off-chain drift sweep it cross-refs: [`../tools/toll_drift_sweep.py`](../tools/toll_drift_sweep.py).

> **THE SCOPE'S OWN NUMBERS ARE STALE — AND THAT IS THE POINT (scope §0.1).** The doc pins `feeBps`
> 100 (it had already gone 25 → 100 when written). A live read this session shows the fleet re-rated
> again, to **500** (Base p2/g2a/g2b all read 500; the p3 router's *immutable* 5 is unchanged). A doc
> that pins a mutable rate is a second source of truth that WILL disagree with the chain. So the tests
> **derive** the rate live (fork) rather than snapshot it — see `test/fork/RegistryFork.t.sol`, whose
> `_deployLive()` reads `feeBps()`/`feeRecipient()` off the chain and registers those. The `500` above
> is itself a snapshot as of 2026-11-09 and may move again.

## What is here

| file | role |
|---|---|
| `src/interfaces/ITollRegistry.sol` | the frozen shape a consumer codes against |
| `src/TollRegistry.sol` | the registry: one per chain, set at construction, **no owner, no setter, no immutables** |
| `src/TolledConsumer.sol` | the ~20-line reference a NEW product copies to be a consumer |
| `test/unit/TollRegistry.t.sol` | §6 item 1 — tuple round-trips; unset product reads `live=false` (not a silent 0) |
| `test/unit/Negcontrols.t.sol` | §6 items 2 & 3 — the #134 and #144 re-injects |
| `test/fork/RegistryFork.t.sol` | §6 item 4 — fork: live-value tie, codehash pin, one-byte sabotage |

## The three rules a consumer MUST hold (scope §3/§4)

1. **Provenance (#134/#135).** Pin the registry's `EXTCODEHASH` at construction, re-check on every
   read. An immutable ctor ARG alone is NOT provenance — any address can be passed. `live` is a
   convenience; the pin is the guard.
2. **Denominator (#144).** Divide by the **literal `10_000`**. Never borrow a sibling's `MAX_FEE_BPS`
   — it is 500 (a CEILING) on `Registry`/`StreamFactory`/`EscrowFactory`, so borrowing it is a 20×
   error (25× at tiny amounts, where the floor bites). See `Negcontrols.t.sol`.
3. **No fallback (scope §4).** `live=false` ⇒ **revert**. Do not substitute a compiled default — a
   default is a second source of truth that can silently disagree with the registry.

## Why "no immutables" is load-bearing

All toll data is STORAGE. So every instance's runtime bytecode is identical, and `codehash` is the
same on every chain. That makes a consumer's `bytes32` pin a **cross-chain constant** — the same pin
works everywhere and survives a change to the ctor list. The moment the registry gains a ctor-set
immutable, the runtime varies per deploy and the pin must move from a compile constant to a per-deploy
input. `Negcontrols.t.sol::test_precondition_immutableRegistryBreaksCodehashStability` proves this is
not vacuous.

`BPS_DENOMINATOR = 10_000` is a `constant` (inlined), so it does not perturb the runtime either.

### RULE (not a test): the codehash pin is a frozen ABI/compile contract

**The registry's runtime bytecode is a published constant, and any source change moves it.** A
consumer compiles the pin in; a deploy that changes the code silently invalidates every existing pin.

- **No immutables — ever** (see above). If it needs one, the pin migrates from a compile constant to a
  per-deploy input, deliberately.
- **`BPS_DENOMINATOR` must stay `constant` (compile-time).** If it is ever changed to a storage var,
  an immutable, or made settable, the runtime hash moves. (The registry's own `toll()` arithmetic does
  not use it at read time — but its DECLARATION is part of the code.)
- **No `receive()` / `fallback()` / `selfdestruct` / upgrade proxy.** Each one either adds runtime
  bytes (moving the hash) or allows code to change under a live pin.
- **The compiler/optimizer settings are part of the hash too**: `solc 0.8.34`, `optimizer = true`,
  `optimizer_runs = 200`, `evm_version = "cancun"` (see `foundry.toml`). A rebuild under different
  settings yields a different runtime and therefore a different pin — even from identical source.

The discipline: **the pin is copied from a file, never recomputed by eye** (#73). Before a deploy,
re-derive it from the artifact:
`cast keccak $(jq -r .deployedBytecode.object out/TollRegistry.sol/TollRegistry.json)` → record it
in the KEY-RECORD. Current value:
`0x6f9c78032a4cdc803d743cdfa2864349f6ef6a695d1d2c3da7a72d7937561b2e` (335-byte runtime).

## Adoption is OPT-IN — and retro-fit needs REDEPLOYS

**Nothing live is changed by this directory. Nothing is deployed.**

The toll read (`factory.feeBps()` / `registry.feeBps()`) is *compiled into* each of the 23 live
instances. Deployed bytecode cannot be taught a new read path, so the registry's benefit lands **only
on future deploys** written to read it.

| step | cost |
|---|---|
| write the registry + tests | done here |
| deploy it, ~10 chains | real gas (deploy key + user word) |
| teach a NEW contract to read it | free — bundle into a deploy already happening |
| retro-fit an EXISTING contract | a redeploy of that contract, per chain — ≈ **23 redeploys** wholesale |

So: adopt it the next time a toll-carrying product is deployed on ≥2 chains. The natural first adopter
is the next P3 revision (it redeploys anyway; its toll is currently immutable).

## The registry does NOT replace the drift sweep

The registry converges *future* writes. The 23 instances that exist *right now* are governed by
[`../tools/toll_drift_sweep.py`](../tools/toll_drift_sweep.py) (scope §10) — the cheaper, higher-value
deliverable for the installed base. The registry and the sweep address different halves of the problem.

## Build / test

```
forge build
forge test                      # unit + negcontrols (fixtures; no RPC)
forge test --match-path test/fork/*   # needs Base RPC
```
