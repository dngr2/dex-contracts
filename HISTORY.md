# HISTORY — retired / superseded addresses

Base mainnet (8453) unless noted. Every address here was read cold with `eth_getCode` and is **still
on chain** — "retired" means superseded by a newer deployment, not self-destructed. The v1 source for
all of these is on `main`; the v2 source is on `v2`.

| product | v1 address (Base) | runtime B | v2 address (supersedes) | status |
|---|---|---|---|---|
| p2 Registry | `0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` | 4,654 | `0xaC13a6f51E886dDE81bB4692839987E6d41E1940` | superseded |
| f1a RequestRegistry | `0x9651cD591cFe33E1b684e5d8541940e78724c749` | 2,772 | `0x3d0e1aF04B3317CF9aeeeC45E43De92c34684041` | superseded |
| g2b EscrowFactory | `0x80793a7d35f735bc76BeAf22B1f413926818f410` | 7,794 | `0x1826C89228f3A4D0ec8f437CFdd55a02D165F1ba` | superseded |
| g4b ReceiptNFT | `0x6d140b934a06410a8C36eEe926c967467ab6d46f` | 10,106 | `0x5F02a21C63A1115D49456F440EF69FBd57a61580` | superseded |
| g2a StreamFactory | `0x2bB5b763a8A85e446909674177e65cb6F1052b4F` | 9,385 | `0x8f26d7a5C89B6b8BE712346c5465b7F50e84fa19` | **FROZEN** — paused, holds 5.01 USDC |
| g2a StreamFactory (v2) | `0x14bBd99B840a0Bf087b21A31e27BA83B45f958a0` | 15,479 | `0x8f26d7a5C89B6b8BE712346c5465b7F50e84fa19` | superseded by v2.1 |
| g3a SponsorTarget | `0x83303e59d4F9798C3B49f9D4C6E522FfeC05f2A5` | 594 | `0xb8381fF6b76726e989a7FFF358dBc3640d78d684` | superseded |
| p3c P3cDelegate | `0x70744664505D07B3e7A20B14665211b22176029E` | 1,119 | `0xDE6B56287edc66212037D2B7Af21c0825AA7AdC9` | superseded |
| p3 Router | `0xEB28D5cA0783D01dd2E4bF86AD7024ca156aB047` | 4,270 | `0x3962846445C386294B98a7770AF17192cb159447` | superseded |
| f1c DustSweeper | `0x5F6f5dee0c371ed13D9151B9C64d9fBf30245800` | 1,910 | `0x4B360a122969ecd726336AdafCf13714F37BF6f1` | superseded |
| f1c DustSweeper (pre-fix fire) | `0x6f21409A89C1d7002CdC5F4cadBb929b3BBBb893` | 1,910 | `0x4B360a122969ecd726336AdafCf13714F37BF6f1` | superseded — body == v1 |

## Multi-chain v1 fans (superseded, NOT redeployed)

The v1 g2b EscrowFactory and g2a StreamFactory were replicated on further chains (see `main` README
"Multi-chain footprint"). Those copies are **still the v1 shape** — v2 shipped to Base only, so OP /
opBNB / Gnosis / Scroll etc. stay on v1 deliberately.

- g2a StreamFactory v1 shape on **Optimism** `0x61AB1942a6779D392922cfcd20BA6D7dc36FDe15`,
  opBNB/Gnosis/Scroll `0xAdB743dA4A5419C62BCc2cF027da6478Ae70f228` — 9,385 B, same runtime keccak as
  the Base v1 (`0x6dfe06ec…1afb7`). All four: `paused() == false`, `owner() ==` orphan treasury.
  These are the pause candidates in audit **C-1** (see below).

## Why v1 stays

`main` is not deleted because the v1 addresses are still serving (the keeper/subscription rail, the
f1a settle path). `main` repoints only at a deploy; nothing is retired while it still answers.

## Known stranded value on v1

- **g2a StreamFactory v1 `0x2bB5b763…2b4F` holds 5,010,000 USDC** (a bulk under-fund left as factory
  balance). v1 has no `rescue` and is **not a proxy**, so it cannot be recovered in place — write-off.
  Fixed in v2.1 (`receive`/`fallback` + `rescue` + `createStreamSelfFunded`). See
  `g2a-streams/DEPLOY-EVIDENCE-v2.1.md` and the fleet dead-drop audit.
