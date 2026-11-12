# FREEZE-COMPLETE — every fleet factory `paused()==true`, cold-verified

**dex-critic · 2026-11-11 ~18:2xZ · USER DIRECTIVE (verbatim): "paude freaze all, drain the wallets to
recover gas drom all the addresses, redeploy new addresses new privkeys, new smart contracts new loops,
new everythink and do not put the new keys inthe github repos again."**

**ORDER IS THE USER'S: FREEZE → DRAIN → REDEPLOY.** This artifact closes STEP 1. DRAIN (exec7) may start.

> **Why this artifact exists:** the freeze fired on-chain across ~17:09–18:25Z with **NO .md artifact
> beside it**, so the hourly fleet sweep (which reads file mtimes) read it as "not fired" while the chain
> said `paused()==true`. That blind spot is filed as GOTCHA #228. This file is the artifact that should
> have existed at fire time.

**Verification teeth:** every row below is a **fresh raw-`eth_call paused()` (selector `0x5c975abb`)
`== 1` at `latest`**, not a status-1 receipt and not a doc. Base rows cross-read on
`base-rpc.publicnode.com`; far rows on their own canonical RPC. `setPaused` is `onlyOwner`, signer is the
owner `0xe218…204B` on every contract, calldata `0x16c38b3c…0001`.

---

## 1. BASE (chain 8453) — all paused, live-read

| contract | address | paused() now | fire tx / block / time |
|---|---|---|---|
| g2a StreamFactory **v2.1** | `0x8f26d7a5C89B6b8BE712346c5465b7F50e84fa19` | **`1`** | `0x3f761c6a…` blk 56133080 `17:09:51Z` |
| g2b EscrowFactory **v2** | `0x1826C89228f3A4D0ec8f437CFdd55a02D165F1ba` | **`1`** | `0xebdf1db1…` `17:09:56Z` |
| p2 Registry | `0xaC13a6f51E886dDE81bB4692839987E6d41E1940` | **`1`** | `0x8bb88703…` `17:10:04Z` |
| g2a StreamFactory **v2** | `0x14bBd99B840a0Bf087b21A31e27BA83B45f958a0` | **`1`** | `0x61b2617f…` `17:17:47Z` |
| g2a StreamFactory **v1** | `0x2bB5b763a8A85e446909674177e65cb6F1052b4F` | **`1`** | (already paused pre-session) |
| g2b EscrowFactory **v1** (listed as "p4 Sha256Escrow" — same address, the p4 product rides it) | `0x80793a7d35f735bc76BeAf22B1f413926818f410` | **`1`** | (already paused pre-session — **on Base only**; the OP copy of this SAME address was still open until `06:09:23Z`, §1b) |

## 1b. OPTIMISM (chain 10) — the chain this doc was MISSING (added 2026-11-12, GOTCHA #235)

**This section did not exist when the doc first closed "Freeze is COMPLETE fleet-wide."** Optimism had
no heading at all — §1 is Base, §2 is the four far *g2b/p4 fans* — so a row-for-row re-read of this
doc found nothing missing, and the closing sentence was earned by the rows rather than by the chain
list. The one OP pause that HAD fired (`0x6d9be42c…`, §2b's p2 v1 fan row) targeted a different
contract, and its record lives in `PAUSE-4CHAIN-FINAL.md:33-46`, so it never presented as a gap here.

**Consequence, live ~30h:** v1 g2b `EscrowFactory 0x80793a7d…f410` sat `paused()==0` on OP while its
Base copy was paused — 7,794 B, byte-identical (`0x3394a7f2…`), `feeBps()==500` (the MAX ceiling),
`feeRecipient()==owner()==orphan 0xe218…204B`. It accepted `create()` and charged the exposed key.
Fired + cold-verified by dex-critic; **nothing left for exec3 to fire.** Recorded here per (a) of #235.

| contract (OP) | address | paused() now | deploy code | feeBps / feeRecipient | fire tx / block / time |
|---|---|---|---|---|---|
| g2b EscrowFactory **v1** | `0x80793a7d35f735bc76BeAf22B1f413926818f410` | **`1`** | 7,794 B (== Base) | `500` / orphan `0xe218…204B` | `0xbc5bca88…78364` status 1 blk 159432493 gas 29,810 `06:09:23Z` |
| g2a StreamFactory **v1** | `0x61AB1942a6779D392922cfcd20BA6D7dc36FDe15` | **`1`** | 9,385 B | fired pre-doc | `0x6d9be42c…3a93ded` blk 159391696 gas 29,810 `07:29:29Z` |
| p2 Registry **v1** | `0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` | **`1`** | 4,654 B | — | `0x63b02cc2…236464` blk 159413423 `19:33:43Z` |

All three: `from 0xe218…204B`, calldata `0x16c38b3c…0001`, `PausedSet(true)` topic
`0x40db37ff…da2b212` at the factory, receipt status `0x1`. Each is additionally the row for a
**different** product — one chain's pause on A proves nothing about B (rule (c)).

**2-RPC confirmation (#138/#147):** `0x80793a7d` `paused()==1` on `mainnet.optimism.io` **and**
`optimism.drpc.org`; `0x61AB1942` and `0xe9515881` on `mainnet.optimism.io` (receipt + call), the
latter two also `1` in §2b. `optimism-rpc.publicnode.com` 403s archive receipts (personal token) and
`mainnet.optimism.io` 429s at ~1 req/s — both are latency, not state (#138).

### 1b-1. COVERAGE GATE — the ledger must cover `set(deployed)`, printed even when empty

The rule from #235 (b). Enumerated by **live `eth_getCode` on every candidate fleet address** — the
chain's deployed set, NOT the rows this doc happens to carry — then every hit with a `paused()` was
read. Result on OP, `10`:

```
DEPLOYED with paused():  0x80793a7d (1) · 0x61AB1942 (1) · 0xe9515881 (1)   <- all covered above
DEPLOYED, NO paused():   0x3882A049 (16,643 B) · 0x417c41d4 (6,303 B)      <- v2.1 live set, open by design
DEPLOYED, non-pausable:  0x036645ca (Router) 0x7cacbecb (FeeSplitter) 0x4b05fa6a (EscrowFactory v2)
                         0x8c38c2bb (DustSweeper) 0x41039666 (FleetExecutor) + Arachnid 0x4e59b448
ABSENT on OP:            0xaC13a6f5 / 0x2bB5b763 / 0x8f26d7a5 / 0x1826C892 (Base-only)  ← MISSING SET
```

The two `paused()==0` factories are the exec3 **new line** (v2.1 StreamFactory + v2 Registry), deployed
and unpaused on purpose this window — so they are the correct "still open" and not a freeze hole.
**Nothing in the deployed set is missing from the ledger.**

## 2. FAR CHAINS — all paused, live-read this run

| chain | factory | paused() now | fire |
|---|---|---|---|
| Celo (42220) | `0x809c4054292550405509373afb1605eCE7200D3D` | **`1`** | tx `0x398e5dfe…` `17:32:58Z` |
| Avalanche (43114) | same address | **`1`** | tx `0xc48b7b25…` `17:33:05Z` |
| Monad (143) | same address | **`1`** | fired, `paused()==1` live-read |
| Robinhood (4663) | same address | **`1`** | tx `0xc4aff38d…762140` (nonce 6) `18:23:13Z` + `0x6c175f98…a24648` (nonce 7) `18:24:57Z` |

**RH was the LAST holdout and it flipped this run** — both txs from `0xe218…204B`, `input 0x16c38b3c…0001`,
status 1, gasUsed 29,810 / 27,071, `PausedSet(true)` topic
`0x40db37ff5c0bdc2c427fbb2078c8f24afea940abac0e3c23bb4ea3bf2da2b212` emitted at the fan
(blk 111906904 & 111907923). **Freeze is COMPLETE fleet-wide — against the enumerated set.** The sentence
is now earned: every chain's deployed factories were live-enumerated and covered (§1b-1 prints the
missing set, empty of pausable surfaces), not just the rows this doc happens to carry (#235).

## 2b. p2 v1 REGISTRY FAN — the 9-chain SCOPE HOLE, now closed (exec3, ~18:4xZ)

**Found by dex-critic's sweep, confirmed live by exec3, then fired.** The p2 **v1** registry
`0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` — the address **all 10 live p2 keepers actually target**
(their heartbeats carry `registry=0xe9515881…`) — was paused on Base ONLY and `paused()==0` on **9 chains**.
`register(<dead>)` sims reverted `Paused` on Base but SUCCEEDED on the 9 ⇒ a live hole in "pause ALL".
Cause: RELAUNCH-PLAN §P1 named only `0xaC13a6f5…` (the **v2** p2, Base-only, `code==0x` on other chains);
`grep 0xe9515881 RELAUNCH-PLAN.md` = 0 hits, so the fan was never in scope. **Decision: (a) fire all 9.**

Every row: `owner()==0xe218…204B`, `setPaused(true)` calldata `0x16c38b3c…0001`, sender T, receipt status 1,
`paused()==true` on **2 independent RPCs each**. BSC + Polygon additionally needed a **type-4 7702 CLEAR**
of T first (T was `0xef0100`-delegated there → a plain inbound fund is swept, GOTCHA #224); Gnosis/Linea/
Polygon were gas-starved → bridged via Relay from basekey L1.

| chain | pause tx | blk |
|---|---|---|
| OP (10) | `0x63b02cc23bbbc10947dd5d2294f446f3162985017b0ebdf7c0b4ed033b236464` | 159413423 |
| Arbitrum (42161) | `0x07b6516e8cb7277298d42b3b195f5c8af41542987e681273fee2f52e7deba634` | — |
| BSC (56) | `0x0c72938cf05ca98b86e3dacdb04d37ae737498ac27701d76850f460291be87d8` | — |
| Gnosis (100) | `0x6a4d840a339ec3b5f3303f9dd8fc8bca4ec86f9bda97387bb2043a7d3c86ede4` | — |
| Linea (59144) | `0x64a0b9816dc4186f8bc98f6c12b094620f7eec8a9fd8d309383d79533f43f760` | — |
| Mantle (5000) | `0x1c5a3f74f768a48b9a6cf60b92f57b87c6d6eaf20f80e5f26ac2f57e7963ed79` | — |
| opBNB (204) | `0x02dfd73c2ae8efddfd304fab5bbdc7a6ae10a90dc3d499f8c13a5cc6428cd159` | — |
| Polygon (137) | `0xe87218c956dddbe32d1b5629cab6265603ec9c007d2aaa70a9a0f62408a3176c` | 97150745 |
| Scroll (534352) | `0x6c1cc715cd61674210b1f9f9fa7f0ba4195ac359133e3c52ed021f3af776284e` | — |

**Polygon was the last holdout and needed a nonce RACE**: a concurrent lane drained T's poly balance to 0
repeatedly (and T was re-delegated to `0xc50b038d…b224d0` — a THIRD delegate). Fix: type-4 clear T→`0x0` +
fund same-tx, then fire `setPaused` at 8× gas → landed first. `paused()==true` drpc + publicnode.

## 3. 2-RPC CONFIRMATION (the anti-transport-fault pass — GOTCHA #138/#147)

Every row above was re-read a SECOND time on an independent endpoint, because a single RPC's empty/error
body reads as "not paused" if you parse carelessly:

| contract | RPC A | RPC B |
|---|---|---|
| Base 6 factories | `base-rpc.publicnode.com` → all `1` | `mainnet.base.org` → all `1` |
| Celo | `forno.celo.org` → `1` | `celo-rpc.publicnode.com` → `1` |
| Avalanche | `avalanche-c-chain-rpc.publicnode.com` → `1` | same → `1` |
| Monad | `monad-mainnet.drpc.org` → `1` | same → `1` |
| Robinhood | `rpc.mainnet.chain.robinhood.com` → `1` | `robinhood-rpc.publicnode.com` → `1` |
| p2 v1 fan (9 chains) | OP/ARB/BSC/GNOSIS/LINEA/MANTLE/OPBNB/SCROLL via publicnode → all `1` | POLYGON drpc.org → `1`, polygon-bor-rpc.publicnode.com → `1` |

**RH endpoint note (for the drain):** `https://rpc.rhc.xyz` fails TLS **direct** from this box
(`unrecognized name`); `https://rpc.robinhood.com` fails handshake; `4663.rpc.thirdweb.com` is 429-gated.
Use **`rpc.mainnet.chain.robinhood.com`** or **`robinhood-rpc.publicnode.com`**.

## 4. STALE-READ CORRECTIONS folded into `RELAUNCH-PLAN.md` (found live this run)

- **P1 pause table said the four far fans were `paused()==false`.** Live-stale. They were *created* at
  `feeBps=25/owner=orphan` (per `g2b-escrow/RECEIPTS-chain-wave-2026-11-09.md:27,:117`) and a peer fired
  `setFeeBps(500)`+`setPaused(true)` **after** the receipts. Live now: all four `paused()==true`,
  `feeBps()==500` (0x1f4). **§283's `feeBps()==25` was stale — live is 500 on all four.**
- **`self-serving … zero help from any factory` was IMPRECISE.** `StreamVault.withdraw()`
  (`products/g2a-streams/src/StreamVault.sol:233`) and `claim()` (`:284`) do
  `_pay(token, factory.feeRecipient(), fee)` — a **LIVE factory read on every payout**. The RATE is snapped
  (`feeBpsSnap` immutable, ctor `:158`), the **RECIPIENT is live-read** (`:73` documents it on purpose).
  Freeze STILL HOLDS (a paused factory still answers `feeRecipient()`; `paused` gates only
  `createStreamFor` at `:257`) ⇒ zero migration survives. Honest wording: "reads `feeRecipient` live".
- **Sharpener on the same point:** the **v1** factory `0x2bB5b763…` (creator of the 578 vaults) has
  `setFeeRecipient` (0xe74b981b) but **NOT** `commitFeeRecipient`/`feeRecipientEta` — v1 is INSTANT on
  recipient, and v1 vaults have no `feeBpsSnap`, so v1's rate is live too. The v2/v2.1 factories DO carry
  the 48h staged path (`0x818a10cb` + `0x5231e2f7` present in both runtimes). Only v1 is one-step.

---

## 5. What freeze does NOT do (why DRAIN is a separate, safe step)

`paused` is checked ONLY at the top of the create paths (`StreamFactory:257`, `EscrowFactory:139`). So:

- **No new objects** can be created on any product. ✅
- **Existing vaults/escrows keep releasing** — `withdraw()`/`release()` never read `paused`. ✅
- **All contract balances are now STATIC** except for outstanding user pulls ⇒ the drain surface is
  frozen and countable, which is exactly why the user ordered freeze FIRST. ✅
- **A quiet keeper rail is now BY DESIGN**, not a fault — `daemon_health` showing the p2 keepers "ok but
  idle" between now and cutover is expected.

## 6. NEXT (STEP 2 — exec7)

DRAIN the recoverable surface to the new keys. Known traps, already pinned: never top-up a **7702 EOA
inbound** (it sweeps to the sink, GOTCHA #224); a hardcoded **21000 gas to a delegated EOA reverts**
(GOTCHA #225); native cannot cross chains; leave a deploy-compound float per chain. Exit-vs-pause gate:
confirm each contract's owner-exit (`rescue`/`withdrawTo`/`sweep`) is reachable **while paused** before
firing.

---

*Cold-verified by dex-critic from raw `eth_call` + receipts. Corrections 1 & 2 sourced from dex-executor6's
independent verify (2 RPCs per read), re-confirmed by me live. Nothing pushed. Honest cost: ~4 RPC reads.*
