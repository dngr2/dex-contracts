# G4-c TOLL REGISTRY — scope (recommendation 4)

**STATUS: SCOPE ONLY. Nothing written, nothing broadcast, no key allocated.** Report-then-wait.
All numbers below are LIVE reads taken 2026-11-07, chain-scoped, from files — EXCEPT where marked
"UPDATED 2026-11-08", which re-read after the fleet's 25 → 100 re-rate landed.

> **THE FEE LITERAL IN THIS DOC IS A SNAPSHOT, AND IT WENT STALE.** §0.1 (below) said `feeBps` 25 when
> written; the fleet re-rated to **100** the same day (p2/g2a/g2b, all mainnets + Base; the g4c doc's
> own consumer formula is unaffected — it reads `feeBps` live and divides by a LITERAL `/10_000`,
> which is exactly the #144-safe shape §3 argues for). A doc that hardcodes the number is a second
> expectation source that can disagree with the live chain — see the note there.

---

## 0. THE VERDICT (read this first)

**Document-first, build-later — and the "later" is SMALLER than the recommendation implies.**

Three live findings drove that verdict, and all three cut against a contract:

1. **The fleet is already consistent to the wei.** Live sweep across 10 mainnet chains: every toll
   site reads `feeBps` 25 (P2/g2a/g2b) or 5 (P3), every `feeRecipient`/`treasury` is the identical
   orphan address `0xe218E382F28A094f9f64E903ee3cb1750A7f204B`. There is **no drift to fix today**.
   A registry would converge something that is already converged.
   **UPDATED 2026-11-08 (the snapshot went stale — this is the doc's own bug shape):** the fleet then
   re-rated p2/g2a/g2b **25 → 100** on every mainnet chain (g2b's OP instance was MISSED by the
   per-CHAIN plan and caught only by a per-(product,chain) sweep — the very "matrix, not list" gap this
   exercise is about). The "5 (P3)" and the treasury address are unchanged; P3's bps is IMMUTABLE. So
   the ONE number this doc quotes is itself a stale expectation — a LIVE read today says 100, this
   prose says 25, and **neither is wrong, they are different TIMES**. That is the #162/#164/#165 class:
   a doc that pins a mutable rate is a second source of truth that WILL disagree with the chain.
   **The registry would not have fixed this either** (§0.2): the consumer's `feeBps` read is compiled
   in. What fixes it is reading live + pinning the value per-(product,chain) with a date.
2. **A registry cannot retro-fit a single one of the 23 live instances.** The toll read
   (`factory.feeBps()` / `registry.feeBps()`) is *compiled into* each consumer. Deployed bytecode
   can't be taught a new read path. So the registry's marginal benefit lands **only on future
   deploys** — and only on ones written to read it.
3. **The real defect we found is not an address problem, and a registry would not fix it.** It is a
   NATSPEC/semantics split (§3). That is a doc + convention fix.

**What is actually worth building, in order:**
- **(a) NOW, off-chain, zero contracts:** a drift-alarm that sweeps the 23 instances and shouts on
  divergence. ~80% of the registry's value, no redeploy, no key, no gas.
- **(b) WHEN a new product is deployed anyway:** have it read a registry natively (the smallest
  shape, §2). Bundle it into a deploy that was already going to happen.
- **(c) NOT NOW:** a standalone registry contract for its own sake, §7.

---

## 1. The problem, stated honestly

Named in the recommendation as "a meta-product / toll registry". What it is really for:

- one address to change a treasury once, instead of N retypes;
- one source of truth for what our fee *is*, per product, per chain;
- a cheap drift check across chains.

The fleet's actual exposure today is **retype surface**, not missing machinery:

| artefact | count |
|---|---|
| `.sol` files containing the orphan-treasury literal | **5** |
| `script/*.sol` files that re-state a treasury/fee | **11** |
| `.md` files containing the treasury literal | **12** |

(counts are FILE counts, `grep -rl`, not matching-line counts — the two differ 12-vs-16 on the `.md`
row and mixing them is exactly the kind of quiet off-by-N the doc is about.)

Every one of those is a GOTCHA #73 opportunity (a hand-typed address one char off). But note: they
are *already* all correct, and the copies are checked by parity-pins (`pk→addr` AND `mnemonic→addr`)
at every fire. So the retype risk is largely **mitigated by process today**.

---

## 2. SMALLEST USEFUL VERSION — and the design decision (marked)

### The shape

One contract, deployed **per chain, once**, no owner, no upgrade path:

```solidity
interface ITollRegistry {
    /// @notice the toll for `product` (bytes32 id, e.g. keccak("g2b-escrow")).
    ///         returns the whole tuple in ONE call so a consumer never mixes two reads.
    function toll(bytes32 product) external view returns (address recipient, uint16 feeBps, bool live);
}
```

That is the whole thing. `live=false` for an unset product, so a consumer can tell "0 bps on purpose"
from "we never registered this".

### DESIGN DECISION (marked): the fee denominator is `10_000` — and it is NOT spelled `MAX_FEE_BPS`

Consumer-side rule, and this is the part that matters:

```solidity
uint256 fee = (amount * feeBps) / 10_000;   // the DENOMINATOR, named literally
```

See §3 for why `MAX_FEE_BPS` must never be used as the divisor.

### DESIGN DECISION (marked): the registry is per-chain, and product ids are chain-agnostic

`keccak("g2b-escrow")` is the same id on every chain (so integrator config is portable), but the
registry *contract* is per-chain (because a cross-chain registry is a bridge problem, and a bridge
is not the smallest thing). Pinned rather than discovered, §4.

### DESIGN DECISION (marked): `recipient` and `feeBps` travel TOGETHER

A tuple return, not two getters. A consumer that reads `feeBps` from one place and `feeRecipient`
from another can be torn by a mid-read change — the same class as the g2a nonce race (#128), one
level up. One call, no tear.

### What it deliberately does NOT have

- No owner / no Ownable. A toll change = redeploy the registry (it's one tx, ~30KB of nothing).
  Removing the admin key removes an attack surface, matching P3's own reasoning (Router.sol:30).
- No per-chain fee overrides, no tiers, no schedules. Add when a second real case exists.
- No on-chain consumer enforced through it. Adoption is opt-in.

---

## 3. FINDING (real, live): `MAX_FEE_BPS` means TWO INCOMPATIBLE THINGS

Found while surveying the reuse set. This is the sharpest thing in this doc.

| contract | `MAX_FEE_BPS` value | what it *is* | use |
|---|---|---|---|
| `p2-forwarder/src/Registry.sol:28` | `500` | a **CEILING** (5%) | `if (bps > MAX_FEE_BPS) revert` |
| `g2a-streams/src/StreamFactory.sol:32` | `500` | a **CEILING** | same |
| `g2b-escrow/src/EscrowFactory.sol` | `500` | a **CEILING** | same |
| `p3-router/src/Router.sol:39` | `10_000` | the **DENOMINATOR** | `fee = received * feeBps / MAX_FEE_BPS` |

Live confirmation of the split, same block window:

```
cast call 0xe9515881… 'MAX_FEE_BPS()(uint16)'  ->  500
cast call 0xEB28D5cA… 'MAX_FEE_BPS()(uint256)' ->  10000
```

The same name on two live contracts, same fleet, meaning a ceiling in one and a basis-points
denominator in the other. A reader who carries the P2 habit into P3 writes `/500` and is **20× out on
the exact value** — and 20× out is a *plausible-looking* number, so no revert catches it. This is the
#131 trap family: a rule re-implemented from a sibling source, diverging silently.

Measured, so the trap is pinned by numbers and not by prose (`cast`/integer math, floored exactly as
Solidity floors):

| amount | feeBps | `x*bps/10_000` (right) | `x*bps/500` (wrong) | ratio |
|---|---|---|---|---|
| 1_000 | 25 | `2` (exact 2.5 → 2) | `50` | 25× — **floor bites** |
| 100_000 | 25 | `250` | `5_000` | **20× exactly** |

The divergence is exactly 20× wherever the floor does not bite; at tiny amounts the floor distorts
the ratio (25×, not 20×, on the 1_000 example) — so a negcontrol that asserts "20×" on small numbers
would itself be subtly wrong. Pin both rows.

**A registry does not fix this** (the constant is compiled in). The fix is a NATSPEC ruling + a
convention, and it belongs in GOTCHAS. Proposed, not written:

> **#144-class.** `MAX_FEE_BPS` is overloaded fleet-wide. `Registry`/`StreamFactory`/`EscrowFactory`
> use it as a 500 bps CEILING; `Router` uses it as the 10_000 DENOMINATOR. New code must not reuse
> the name for a third meaning; a consumer doing fee math should name the divisor literally
> (`/ 10_000`) rather than borrow a constant from a sibling contract. Cite the live pair above.

**DONE — landed as GOTCHA #144** in `fleet-shared/docs/GOTCHAS.md` (dup-swept first: 142/143 taken,
144 free, 145 was the max when written; #144 is now the max). Framed as drafted: overloaded constant,
live pair cited, rule "name the divisor / 10_000 literally; don't borrow a sibling's constant", and
the floor caveat (a "20×" assert on small numbers is itself wrong — pin absolute values).


---

## 4. PROVENANCE GUARD — the #134/#135 pattern, applied

If a consumer reads a registry, the consumer must know the registry is *ours*. Same discipline as
the receipt-NFT factory gate: **ask the thing you already trust, not the thing you're checking.**

```solidity
// pinned at construction, not discovered at runtime
address immutable REGISTRY;
bytes32 immutable REGISTRY_CODEHASH;

function _toll(bytes32 product) internal view returns (address, uint16) {
    require(REGISTRY.codehash == REGISTRY_CODEHASH, "registry not our registry");  // #134
    (address r, uint16 b, bool live) = ITollRegistry(REGISTRY).toll(product);
    require(live, "product not registered");
    return (r, b);
}
```

- **Codehash pin, not a ctor-arg immutable alone.** GOTCHA #134: an immutable ctor arg is NOT
  provenance — any address can be passed. #135: a runtime blob scan is bypassable. The pin works
  here *specifically because* the registry has **no immutables and no per-instance state that
  varies** — its vars are STORAGE, so its runtime hash is stable across instances (the identical
  property that made the factory pin valid in G4-b).
- **REQUIREMENT on the registry (not a hope): NO IMMUTABLES.** This is load-bearing. The moment the
  registry gains a ctor-set immutable, its runtime is patched per-deploy and the codehash pin stops
  being a cross-chain constant — every consumer's pin must then be recomputed per instance, which is
  a different design. So "no immutables" is a constraint the registry MUST hold, stated up front,
  to keep the pin valid. (If it ever needs one, the pin isn't wrong — it just moves from a compile
  constant to a per-deploy input, and that migration must be deliberate.)
- **`live` flag, and what a consumer does when `live=false`: REVERT, do not fall back.** A consumer
  must `require(live)` (as the snippet does) rather than silently substituting a compiled default.
  Rationale: a fallback default is a second source of truth that can silently disagree with the
  registry — exactly the divergence this whole exercise is about. Better a loud revert on an
  unregistered product than a quiet wrong number. Stated, pinned.
- Registry instances get their own `registryCodehashOf` in a KEY-RECORD so the pin is copied from a
  file, never retyped (#73).

---

## 5. REUSE COUNT — the honest number

**Products that carry a toll and could read a registry: 4.**

| product | toll shape | mutable? | live on |
|---|---|---|---|
| `p2-forwarder` `Registry.sol` | `owner`/`feeBps`/`feeRecipient`, owner-settable | **yes** | Base, OP, Arb, Linea, Polygon, BSC, opBNB, Mantle, Gnosis, Scroll, +Sepolia |
| `g2a-streams` `StreamFactory.sol` | same block, owner-settable | **yes** | Base, OP, +Sepolia |
| `g2b-escrow` `EscrowFactory.sol` | same block (self-declared "copied from P2") | **yes** | Base, +Sepolia |
| `p3-router` `Router.sol` | `feeBps`/`treasury` **immutable** | no (redeploy to change) | Base, OP, Arb, Linea, Polygon, BSC, opBNB, Mantle, Gnosis, Scroll, +Sepolia |

Adjacent, not payers: `f1a` `RequestRegistry` (owner only, no feeBps of its own);
`g4b` `ReceiptNFT` (owner + `mintFeeWei`, default 0); `g3a` (lease/relay, no toll in `src/*.sol`);
`p1-lp-vault` (vault strategy, `owner` only); `f1c` duster (by design 0 fee).

**Live instances of a toll-carrying contract: 23 on mainnet** (Base 4, OP 3, and 2 each on Arb,
Linea, Polygon, BSC, opBNB, Mantle, Gnosis, Scroll). Plus 4 on Base Sepolia. None of them can read
a registry without a redeploy.

### Honest migration cost

| step | cost | who pays |
|---|---|---|
| write the registry (≈60 LoC + tests) | hours | us, once |
| deploy it, 10 mainnet chains | ~0.00001 ETH/chain + gas, **real money** | warchest, needs user word |
| teach a NEW contract to read it | free (bundled into a deploy already happening) | n/a |
| retro-fit an EXISTING contract | **a redeploy of that contract, per chain** — p2 Registry ×10, g2a ×2, g2b ×1, p3 ×10 ≈ **23 redeploys** if done wholesale | real money, real risk |

**So: the honest migration cost of full adoption is ~23 redeploys.** The per-product cost of *any*
adoption is one redeploy. That is the number the recommendation was missing.

---

## 6. TESTS + NEGCONTROL (what "done" would mean)

House bar: unit + negcontrol + fork, negcontrol re-injecting the bug through the REAL path
(#20/#62). For a module this small, a short and *pointed* list:

- **unit.** `toll()` returns the tuple; unset product → `live=false` (not a silent 0).
- **negcontrol (the #134 re-inject).** A `LyingRegistry` that answers the correct getters and the
  correct `toll()` shape from an address we never pinned must still be rejected. Same shape as the
  proven G4-b lookalike test. Then — the part that makes it load-bearing — **remove the codehash
  pin and confirm the lookalike is ADMITTED**, so the assert can actually fail.
- **negcontrol (the #144 re-inject).** A consumer that divides by a borrowed `MAX_FEE_BPS` must be
  shown 20× wrong: assert `1000 * 25 / 500 == 50` while `1000 * 25 / 10_000 == 2` on the SAME
  inputs, so the trap is pinned by numbers, not prose.
- **fork.** Read the LIVE registry on Base and assert the tuple equals the on-chain reality; and
  assert `REGISTRY.codehash == pin` against the live chain.
- **sabotage.** Mangle one byte of the pinned codehash and confirm the guard fires (mutation test on
  our own test).

Not built yet; this is the acceptance bar, not a result.

---

## 7. BUILD vs DOCUMENT — final verdict, with the trigger

**Do not build the standalone registry now. Do write the convention now.**

Reasons, in weight order:

1. Zero live drift (proven, §0.1) → the registry fixes nothing today.
2. Zero retro-fit (§0.2) → its value is deferred to future deploys.
3. The single sharpest defect found (§3) is a *naming* defect that a registry cannot touch.
4. 23 instances → a wholesale migration is 23 redeploys for a convenience gain. Bad ratio *today*.

**The trigger that flips this to BUILD:** the next time a contract is deployed that (a) carries a
toll and (b) is going to be deployed on ≥2 chains, deploy the registry alongside it and have it
read natively. At that moment adoption is free. Concretely, candidates already on the board: an
F1-a Base-mainnet RequestRegistry deploy, or the next P3 revision (P3b/P3c are expected to redeploy
anyway per Router.sol:30 — that is the natural first adopter, and its toll is currently immutable,
so it is *already* paying the redeploy cost for other reasons).

**Cheapest highest-value thing to do THIS WEEK, if anything:** item (a) — the off-chain drift sweep.
**BUILT AND GREEN — see §10.** No contract, no key, no gas, no user word needed. It catches the
failure the registry was invented to prevent, and it catches it on the 23 instances that exist
*right now* rather than the ones we might write later.

---

## 8. What is NOT in scope

- No broadcast, no key allocated, no address predicted yet (nothing to predict).
- No change to any live contract.
- No Arb leg. Arb's guard (g2b key Arb nonce 0) is untouched by all of the above.
- No ownership/admin design beyond "no owner".

## 9. Provenance of every number here

Read live 2026-11-07 via publicnode RPCs, chain-scoped, `cast call` against deployed code:
`feeBps`/`feeRecipient`/`treasury`/`MAX_FEE_BPS`/`nextId` reads across Base, OP, Arb, Linea,
Polygon, BSC, opBNB, Mantle, Gnosis, Scroll, and Base Sepolia; address/codehash/byte-length checks
per instance. The `0x9651cD59` Base reading (2772 B, `nextId()=3`, `owner()`=orphan) is a **live
same-CREATE collision**, not a typo: that address is the P3 Router on nine chains and the F1-a
RequestRegistry on Base. Anything keying on a bare address without a chain scope and a kind-check is
wrong (#95) — and a registry keyed by bare product id must therefore be **per-chain**, which was
design decision §2.

---

## 10. DELIVERABLE (a) — THE OFF-CHAIN DRIFT SWEEP, BUILT AND GREEN

`tools/toll_drift_sweep.py` (repo root, beside the products). Read-only: no key, no gas, no
broadcast. Sweeps all 23 live instances + the Sepolia lanes, prints a per-chain table, and **exits
NONZERO on any drift, 2 on an unattributable RPC fault** (distinct codes so a supervisor can tell
"the fleet diverged" from "the RPC blinked").

It asserts more than equality, because a bare address is not a kind (#95):
- `feeBps` equals the fleet expectation, per product;
- `feeRecipient`/`treasury` equals the orphan treasury, per product;
- **kind**: a `router` address must answer `treasury()` and NOT `feeRecipient()`; a `factory`
  address must answer `feeRecipient()` and NOT `treasury()`. Both live on the same selector space.

### Result, live, this session

`instances probed: 23   DRIFT: 0   RPC-FAULT: 0` → exit `0`.

### SABOTAGE — proves the green is not vacuous

A no-drift result is worthless unless the check can fail. `--sabotage` forks Base, writes the
Registry's **real packed slot 0** to feeBps=26 via `anvil_setStorageAt`, and requires a DRIFT naming
`base/p2-registry`. Slot 0 is `(feeBps<<160)|owner` — verified by hand from the live storage word
(`0x…64e218…204b`, the `0x64` is 100), not guessed. Owner is preserved.

```
live feeBps=100 -> sabotaged feeBps=26  (owner preserved: 0xe218…204b)
SABOTAGE PASS: 1 DRIFT row(s) appeared; base/p2-registry named.
    p2-registry/base: feeBps 26 != expected 100 (bps)
```

Passed 3/3 repeatably. The exit-1 path is separately proven by stubbing the expectation to 26 against
the real chain and requiring a red row. **NOTE (2026-11-08):** the sabotage's job is only to be
DIFFERENT from the live value — it writes 26 against a fleet now at 100, so it reddens on a 74-bps gap
rather than the 1-bps gap it was written for. Still a valid mutation (26 != 100); it does not need to
track the fleet's current rate.

### TWO THINGS THE SWEEP CAUGHT ON ITS FIRST LIVE RUN (both real, both kept as evidence)

1. **`p3-router` on Base is NOT at the create-invariant address.** The sweep's first run reddened on
   `p3-router/base` — because `0x9651cD59…`, the router everywhere else, is on Base the **F1-a
   RequestRegistry** (2,772 B, answers `nextId()=3`, reverts `feeBps()`). The real Base router is
   `0xEB28D5cA…` (deployed on a different key/nonce). This is the §9 collision biting in the wild: a
   sweep that assumed address-invariance would have reported a phantom drift on a correct fleet.
   Carried as an explicit per-chain override in the tool.
2. **`anvil_setStorageAt` needs a FULL 32-byte word.** `hex(n)` on a value whose top byte is `0x1a`
   yields a 21-byte string, which anvil silently accepts and does not apply — the sabotage then
   "failed" with the original value intact. `0x%064x`, not `hex()`. A short-word write that reads as
   success is the #136/#143 family; it is exactly the kind of thing sabotage exists to surface, and
   here it surfaced the *harness's own* bug, not the target's.

### What it does NOT do (honest boundary)

- It checks that the fleet AGREES, not that the agreed value is *desirable*. A deliberate fleet-wide
  change (every chain's fee moved together) reads as "no drift" and needs a human to update
  `EXPECT`. That is correct — it is a drift alarm, not a policy engine.
- It is a point-in-time read. Wiring it as a periodic supervisor row (the exit code is already
  supervisor-shaped) is a follow-up, not part of this deliverable.
