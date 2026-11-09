# FEE MATRIX — (product × chain) — the #162 artifact

**STATUS: verified live, 2026-11-08; §1 VALUES RE-READ 2026-11-09 (fleet re-rated 100 → 500).**
No broadcast, no write. Every cell below is a live `eth_getCode` + `eth_call` read, taken from files,
addresses COPIED from KEY-RECORDs (never retyped — #73).

**WHY THIS EXISTS (GOTCHA #162).** The 2026-11-07 fee raise 25 → 100 was planned as a *list of CHAINS*.
But a raise is a **MATRIX**: a product × chain grid. Enumerating "the chains" and raising "the fleet"
on each silently MISSES a `(product, chain)` cell that was never on the list — which is exactly what
happened: `g2b EscrowFactory` on **Optimism** was deployed, byte-identical to Base, and the raise
skipped it (exec4 has since fixed it — cell now reads 100, evidence below). A per-chain list cannot
see a whole missing COLUMN/SITE; only a per-cell matrix can. This file is that matrix.

**THE RULE THIS ENCODES:** every cell must be one of exactly three verdicts, and **ABSENT is a
verdict, not a skip.** A cell that is not probed reads as "fine" when it may be a missed deploy.

| verdict | meaning | a naive sweep does |
|---|---|---|
| **LIVE(value)** | code present AND kind-probe confirms it is OUR contract | compares value |
| **ABSENT** | 0 bytes at the create-invariant address, on a chain the product is NOT on | must NOT probe-and-pass; record "not deployed" |
| **COLLISION** | code present at that address but it is a DIFFERENT contract (#95) | a revert reads as drift-or-absent; must be named |
| **UNPROBED** | chain reachable but the read failed (transport) — never counted as OK | must re-probe |

Kind-probe (the #95 guard): the address must answer its OWN kind selector and, where cheaply
checkable, NOT the sibling kind. `router` answers `treasury()`, NOT `feeRecipient()`; `factory`
answers `feeRecipient()`, NOT `treasury()`.

---

## 1. THE MATRIX (live, 2026-11-08)

Legend: `.` = ABSENT (0 bytes) · `!` = COLLISION (code, wrong contract) · `N` = LIVE, value shown.

| product \ chain | base | optimism | arbitrum | linea | polygon | bsc | opbnb | mantle | gnosis | scroll | base_sepolia |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **p2-registry**  | N 500 | N 500 | N 500 | N 500 | N 500 | N 500 | N 500 | N 500 | N 500 | N 500 | N 100 |
| **g2a-factory** | N 500 | N 500 | ! | . | ! | . | . | ! | ! | . | N 25‡ |
| **g2b-factory** | N 500 | N 500 | . | . | . | . | . | . | . | . | N 25* |
| **p3-router**   | N 5†  | N 5   | N 5   | N 5   | N 5   | N 5   | N 5   | N 5   | N 5   | N 5   | ! |
| **g4b-receipt** | F 5e13 | . | . | . | . | . | . | . | . | . | . |
| **g4c-registry**| . | . | . | . | . | . | . | . | . | . | . | (scope-only, not deployed) |

> **VALUES UPDATED 2026-11-09 — the fleet re-rated 100 → 500 again** (the §1 column above was written
> at 100 on 2026-11-08; before that it was 25, before that the doc's own §0.1 snapshot). This is the
> #162/#164/#165 class the doc predicts, hitting the doc itself: a table that pins a mutable rate WILL
> disagree with the chain. Re-derived live this session via `tools/toll_drift_sweep.py` (14 DRIFT rows,
> all `500 != expected 100`) across every mainnet chain. The MAINNET p2/g2a/g2b cells moved to **500**
> (the `MAX_FEE_BPS` CEILING value — see §3, the fleet saturates its own cap); the p3 router's
> IMMUTABLE **5** is unchanged (it is compiled in, §5); the base_sepolia testnet cells are unchanged
> (p2 100, g2a/g2b 25). g4b is a WEI row (`F`), unchanged. **This column is STILL a snapshot** —
> `tools/toll_drift_sweep.py` is the live source; prefer it over this table.

`F` = a **wei-denominated** fee row (`mintFeeWei`), not bps — different units, do NOT compare to the bps rows.
`*` g2b base_sepolia `feeRecipient()` == `owner()` == the g2b TEST key `0xac15652c740b08e469ed0aa6925aecdd78502235`
(NOT the orphan `0xe218E382…204B`) — correct, a testnet deploy keyed off its own key (LIVE-PROOF.md). Read with
the correct selector `feeRecipient()` = `0x46904840` (NOT `0xe74b981b`, which belongs to a different contract).
`†` p3-router/base is at a DIFFERENT address (`0xEB28D5cA…`) — see §2.
`‡` g2a-factory/base_sepolia is ALSO at a non-invariant address: `0x83303e59d4F9798C3B49f9D4C6E522FfeC05f2A5`
(9,385 B, `feeBps()` 25, `minFee()` 500 — the Sepolia StreamFactory). The invariant `0x61AB1942…` is EMPTY
there. Same #95 class as §2c — a per-cell address, see §2d.

**ASSERTED ZERO-DRIFT RESULT (2026-11-08 run, values then 100):** the two cells an EARLIER raise MISSED
and that were then fixed — `g2b-factory/optimism` (raised 25 → 100 at OP block 159247935, tx
`0xa196ce1b…`, 2026-11-07T23:37:27Z) and `g2a-factory/base`+`g2b-factory/base` (raised earlier) — all
read 100 AT THAT TIME. **UPDATED 2026-11-09:** every MAINNET p2/g2a/g2b cell has since moved to **500**;
see the dated block above. No live mainnet cell is at 25 except the p3 router's IMMUTABLE 5, and the
two base_sepolia testnet cells (g2a, g2b) stay at 25.

**THE ONLY REMAINING "25" ON A MAINNET CELL IS ZERO.** The base_sepolia g2b=25 and g2a=25 are TESTNET
deploys made before the raise and are expected — pin them as EXPECTs, do not "fix" them. (Their
recipient is the testnet deploy key, NOT the orphan — see the `*`/`‡` footnotes, still true at 500.)

---

## 2. THE COLLISION COHORT — the cells a value-only sweep gets wrong

These are the cells that make a bare-address sweep lie. Each is a same-CREATE address (#95) that is a
different contract on that chain.

### 2a. `g2a-factory` at `0x61AB1942…` on arbitrum / polygon / mantle / gnosis — COLLISION

`0x61AB1942a6779D392922cfcd20BA6D7dc36FDe15` = `CREATE(deployKey, nonce 2)` — chain-independent. On
**Optimism** that is our StreamFactory (9,385 B). On arb/polygon/mantle/gnosis the address holds a
**5,143-byte DIFFERENT contract** that reverts `streamCount()`, `feeBps()`, `feeRecipient()`,
`MAX_FEE_BPS()`, `minFee()` — but ANSWERS `owner()` = the deploy key `0xDB6A5eAf…6d92`.

Selector scan of that runtime: `AAVE_POOL()`, `BALANCER_VAULT()`, `receiveFlashLoan(...)`,
`executeOperation(...)`, `sweep(address,address)`, `lastOk()`, `lastProfit()`, `NotOwner()`,
`BadSource()`, `NotSource()` → an **Aave/ERC-4626-style flash-loan vault**, not a StreamFactory.

**Consequence:** a sweep that keys `g2a-factory` to `0x61AB1942` on ALL chains and probes `feeBps()`
gets a REVERT on 4 chains. A naive `revert → drift` OR `revert → skip` is BOTH wrong: it is neither
drift nor absent — it is a **collision**, and the honest verdict is "g2a is not deployed here; this
address is some other contract". Fix: per-(product,chain) address OR a kind-probe that fails loudly.

### 2b. `p3-router/base_sepolia` at `0x9651cD59…` — COLLISION (the F1-a RequestRegistry)

`0x9651cD591cFe33E1b684e5d8541940e78724c749` = `CREATE(deployKey, nonce 1)`. It is the p3 Router
(4,270 B) on **nine** chains. On **Base** it is the F1-a `RequestRegistry` (2,772 B, answers
`nextId()` not `treasury()`); on **base_sepolia** the same 2,772-B RequestRegistry sits there. The
REAL base router is `0xEB28D5cA0783D01dd2E4bF86AD7024ca156aB047`. Same class as §2a, and already the
`BASE_OVERRIDE` in `tools/toll_drift_sweep.py`.

### 2c. `p3-router/base` — LIVE but at a NON-invariant address (not a collision)

`0x9651cD59` on Base is §2b's RequestRegistry, so the router is pinned to `0xEB28D5cA…` there. A
matrix keyed on the invariant address alone would report base as a collision AND miss the real router.

### 2d. `g2a-factory/base_sepolia` — LIVE at a NON-invariant address (`0x83303e59…`)

`0x83303e59d4F9798C3B49f9D4C6E522FfeC05f2A5` on **base_sepolia** is the g2a StreamFactory (9,385 B ==
the Base/OP artefact; answers `feeBps()` = 25, `minFee()` = 500, `owner()` = the Sepolia key
`0x85C6764D…`). The invariant `0x61AB1942…` is **empty on base_sepolia** (`cast code` = `0x`). The
reason is KEY-RECORD §"WHY this address differs": on Sepolia the factory deploy was nonce 0 of ITS key,
while on OP it was nonce 2 of the fleet exec key — different (key,nonce) ⇒ different CREATE (#95).

**This is the §2c class, mirrored:** a matrix keyed on `0x61AB1942` for `g2a-factory` on ALL chains
marks base_sepolia ABSENT (it is not — the factory is live at another address) AND would probe the
empty invariant. Fix: a per-cell ADDRESS, exactly like p3-router/base.

---

## 3. PRESENCE TABLE (the "who is on which chain" spine)

Derived live from §1; this is the enumeration that a per-chain list lacks — it is per-CELL.

```
p2-registry : base optimism arbitrum linea polygon bsc opbnb mantle gnosis scroll base_sepolia   (11)
g2a-factory : base optimism base_sepolia                                                          (3)
g2b-factory : base optimism base_sepolia                                                          (3)
p3-router   : base optimism arbitrum linea polygon bsc opbnb mantle gnosis scroll                 (10)
g4b-receipt : base                                                                                (1)
g4c-registry: (none — scope only)                                                                 (0)
```

**Load-bearing use:** `PRESENT` drives which cells MUST produce a row. A product present on a chain
whose row is missing is a COVERAGE GAP (§5), distinct from drift. `g4c` has ZERO live cells by design —
a sweep must record "not deployed", not silently pass.

---

## 4. WHAT THE SWEEP'S `EXPECT` MUST BECOME (input to exec1's re-key)

The current `tools/toll_drift_sweep.py` `EXPECT` is shaped `product → {kind, feeBps, recipient}` with a
per-(product,chain) OVERRIDE. That is CORRECT in shape but its VALUE LIST was enumerated per-CHAIN, so
it could not express a whole missing column. The matrix needs the EXPECT keyed per-CELL with the
three-verdict logic:

```python
# per-cell: the verdict IS the expectation. feeBps None => the cell must be ABSENT.
EXPECT_CELL = {
  ("p2-registry","base"):         {"kind":"factory","feeBps":100,"recipient":ORPHAN},
  ("g2a-factory","arbitrum"):     {"kind":None,     "feeBps":None,"recipient":None},  # COLLISION -> assert NOT a factory
  ("g2b-factory","optimism"):     {"kind":"factory","feeBps":100,"recipient":ORPHAN}, # the #162 cell
  ("g4b-receipt","base"):         {"kind":"receipt","mintFeeWei":50_000_000_000_000}, # wei row, not bps
  ("g4c-registry","base"):        {"kind":None,"feeBps":None},                        # not deployed
  ...
}
```

**Coordinates needed from exec1 (value lists), not from me:** the exact `feeBps` EXPECT per cell is
exec1's re-key; this file supplies the CELL SET and the ABSENT/COLLISION verdicts. The two must agree
or the sweep fires — so they should be generated from ONE table. Recommendation: this matrix becomes
the generator input, and exec1's sweep imports it rather than re-listing (GOTCHA #131: a list
re-typed from a sibling diverges).

**g4b is a WEI row.** `mintFeeWei` is not bps and must not be range-checked against `MAX_FEE_BPS`
(which it does not have). Its cell value is `50000000000000` wei.

---

## 5. VERDICT CODES for the sweep (so a missing column is LOUD)

- `OK` — LIVE cell, value == EXPECT.
- `DRIFT` — LIVE cell, value != EXPECT.
- `ABSENT_EXPECTED` — 0 bytes, cell correctly not-deployed. NOT a red.
- `ABSENT_UNEXPECTED` — 0 bytes but EXPECT said LIVE. **This is the #162 failure**: a raise that
  reached the list but a deploy that never happened / was missed. RED.
- `COLLISION` — code present, kind-probe fails on an EXPECT-absent cell. Recorded, named, not red.
- `COLLISION_UNEXPECTED` — code present but kind-probe fails on an EXPECT-LIVE cell. RED.
- `UNPROBED` — transport fault; never OK. Re-probe.

**The failure #162 names is `ABSENT_UNEXPECTED` + `COLLISION_UNEXPECTED`**: a whole site/column the
per-chain list never had a row for. Under a per-chain EXPECT these were invisible; under a per-cell
matrix they are two named reds.

---

## 6. PROVENANCE

Every address COPIED from a KEY-RECORD (`p2-forwarder`, `g2a-streams`, `g2b-escrow`, `g4b-receipts`)
and `cast`-verified live this run. Reads: `eth_getCode` (byte length) + `eth_call` (value + kind-probe)
across base, optimism, arbitrum, linea, polygon, bsc, opbnb, mantle, gnosis, scroll, base_sepolia.
The feeBps values were cross-read in the same sweep that produced §1. The g2b-OP raise tx and the
base `FeeBpsSet` tx are cited inline. No write; no key; no broadcast.
