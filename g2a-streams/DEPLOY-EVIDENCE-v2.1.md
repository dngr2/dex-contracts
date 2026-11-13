# g2a-streams — v2.1 DEPLOY EVIDENCE (DEAD-DROP fix, LIVE on Base)

**Status: DEPLOYED.** Written when this was the only product on the `v2` branch whose audit-fixed
source had gone on chain; every other product has since followed (README `v2` table), so the
"still pending" framing in the body is historical. `v2.1` itself is now frozen and create-superseded by
`0x3882a049…`, though the byte-match below stands and remains the way to verify this address.

The `v2` branch carried a **latent dead-drop hole** in `src/StreamFactory.sol`. `v2.1` closes it, and
the source in this directory **is** the source v2.1 was deployed from — recompiled here it reproduces
the live runtime **byte-for-byte, metadata included** (`FULL` parity, not merely `BODY`).

## The hole this fixes (one line)

`createStreamFor` funds by PULL (`transferFrom` payer → vault directly) and the factory held nothing by
design — so a bare `USDC.transfer(factory, x)`, or a bare native send, **stuck**: there was no
`receive()`/`fallback()` and no function touching the factory's own balance. The token credited the
factory; the factory could never move it.

- **v1 stranded 5,010,000 USDC this way** at `0x2bB5b763a8A85e446909674177e65cb6F1052b4F` —
  live-proven, and **`v1` is not a proxy**, so no new function can patch it: **write-off, not recovery**.
- v2 inherited the identical hole.

## The fix (additive; no storage-slot change)

`receive()` / `fallback()` (a bare native send no longer reverts) · `rescue(token, to) onlyOwner`
(`token == 0` ⇒ native; owner drains the factory's own balance) · `createStreamSelfFunded(...)`, the
self-fund create that spends the factory's OWN balance instead of pulling the payer.

## Deployed v2.1 — cold-verified record

| field | value |
|---|---|
| **address** | `0x8f26d7a5C89B6b8BE712346c5465b7F50e84fa19` |
| chain | Base mainnet (8453) |
| runtime keccak256 (the pin) | `0xa4798afcb277754b4bc6232981f29bb569a84d0801f455ff0a8ab79e2b3a6761` |
| runtime size | 16,643 B — **reproduces from this `src/` exactly** (see byte-match below) |
| deploy tx | `0x5fa89c1821720f1dc83c04112e5214a890fb52b2aba6640e965ef605959a97c2` |
| block | 55483090 (status 1) |
| Sourcify | `exact_match` (creation + runtime), matchId `58972476` |
| supersedes | v2 `0x14bBd99B840a0Bf087b21A31e27BA83B45f958a0` (kept live, un-paused, for history) |

## Byte-match: this tree → the live v2.1 runtime

Build settings are the repo standard (`solc 0.8.34`, optimizer on `runs = 200`, `evm_version = cancun`).
`forge build` in this directory, then compare `out/StreamFactory.sol/StreamFactory.json` →
`deployedBytecode` against the live runtime fetched with `eth_getCode`:

```
live    16,643 B   keccak 0xa4798afcb277754b4bc6232981f29bb569a84d0801f455ff0a8ab79e2b3a6761
compiled 16,643 B   keccak 0xa4798afcb277754b4bc6232981f29bb569a84d0801f455ff0a8ab79e2b3a6761  ← same
```

The two are **byte-for-byte identical**, body AND metadata trailer — so the compiled keccak reproduces
the live runtime keccak exactly.

**`FULL`, not `BODY`** — even the CBOR metadata hash matches, because the source here is exactly the
revision deployed (no post-deploy text edit). That is the same reason Sourcify returned `exact_match`
rather than the weaker `match`.

The shared toll library resolves as `@shared/FeeMath.sol` → `../shared/src/FeeMath.sol` via this
product's `remappings.txt`; that path spelling is load-bearing for the metadata hash and is why the
source path is `../shared/src/FeeMath.sol` and not `../shared/FeeMath.sol`.

## Live acceptance (receipts, not balances alone)

Three legs, each an on-chain receipt; token moves read from `Transfer` logs:

1. bare ERC20 `transfer(factory, 250000)` STICKS, then owner `rescue(USDC, …)` drains it.
2. bare NATIVE send is ACCEPTED (v1 reverted), then owner `rescue(0x0, …)` drains it.
3. `createStreamSelfFunded(...)` mints a vault funded **factory → vault** with the payer's allowance
   at **0** — decisive proof the factory spends its own balance.

## What v2.1 does NOT fix

The **5,010,000 USDC already stranded on v1** stays stranded (v1 is immutable). v2.1 is
future-immunity.

**v2.1 is now itself frozen** — `paused()==1` on both live copies (`0x8f26d7a5…` Base, `0x3882A049…`
OP/Uni, 2026-11-11/12), and superseded as the *create* target by the chain-invariant `0x3882a049…`.
Pausing gates only `createStreamFor`; every existing vault still pays out, so no position is stranded by
the pause. "Do not pause v2.1" was written before the relaunch.

## Later revisions from this tree are DEPLOYED

This section was written when v2.1 was the only landed fix. It is now stale as a status claim: the `v2`
revisions of `g2b-escrow`, `p2-forwarder`, `g3a-sponsorship`, `g4b-receipts`, `p3c-7702`, `p3-router`,
`f1c-duster` and `f1a-payment-links` all went to Base at fresh addresses (the README's `v2` table), and
the `v2.2` relaunch line landed chain-invariantly on Base, OP and Unichain. `main` still carries the v1
/deployed-matching source, and remains the right place to verify the **v1** bytecode.
