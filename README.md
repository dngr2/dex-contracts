# dex-contracts

The Solidity source of nine contract products **live on Base mainnet (chain 8453)** and, for the
core factories, byte-identically across eight further chains (see "Multi-chain footprint" below).
Published so anyone can verify the deployed code: compile each product with standard settings and the
runtime reproduces the on-chain bytecode.

- **License:** MIT (see `LICENSE`).
- **Compiler:** `solc 0.8.34`, optimizer on (`runs = 200`), `evm_version = cancun`, default IPFS
  metadata. Each product has its own `foundry.toml`. `forge build` inside a product dir is enough —
  no external libraries.
- **What revision:** the **deployed-matching** source, which predates a later shared-`FeeMath`/`minFee`
  refactor. Read `SOURCES.md` first — it names the delta exactly.

> **This is `main`, the default branch, and it is NOT the newest line.** It documents the **v1**
> source of nine contracts still live on Base and eight further chains. Two later generations are
> live and are on the **`v2` branch**, which is where to start if you want current code: the
> audit-fixed **v2** set (nine products, fresh Base addresses) and the **v2.2** chain-invariant
> relaunch (Base + Optimism + Unichain). **Every contract in the table below that has a pause gate now
> reads `paused()==true`** — frozen 2026-11-11, create paths closed, existing vaults and escrows still
> paying out; the other six (`f1a` RequestRegistry, `g3a` SponsorTarget, `g4b` ReceiptNFT, `p3` Router,
> `p3c` P3cDelegate, `f1c` DustSweeper) carry no `paused()` at all. Nothing here is deleted: `main`
> repoints only at a deploy, and these addresses stay verifiable. Source on `main` is untouched by that
> rule; this paragraph is prose only.

## Live contracts → source → byte-match

Everything below was checked cold: fetch the live runtime with `eth_getCode`, strip the CBOR metadata
trailer, compare against a fresh compile of the source in this repo. Two independent RPCs
(`mainnet.base.org`, `base-rpc.publicnode.com`) agreed byte-for-byte on every runtime before comparing.

| product | role | live address (Base) | source | verdict |
|---|---|---|---|---|
| p2-forwarder | Registry — deposit-address forwarder factory | `0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` | `p2-forwarder/src/Registry.sol` | BODY+META |
| f1a-payment-links | RequestRegistry — payable-request links (rides p2) | `0x9651cD591cFe33E1b684e5d8541940e78724c749` | `f1a-payment-links/src/RequestRegistry.sol` | IMM |
| g3a-sponsorship | SponsorTarget — the EIP-7702 delegate | `0x83303e59d4F9798C3B49f9D4C6E522FfeC05f2A5` | `g3a-sponsorship/src/SponsorTarget.sol` | BODY |
| g2b-escrow | EscrowFactory — hashlock escrow factory | `0x80793a7d35f735bc76BeAf22B1f413926818f410` | `g2b-escrow/src/EscrowFactory.sol` | BODY+META |
| g2a-streams | StreamFactory — vesting-stream factory | `0x2bB5b763a8A85e446909674177e65cb6F1052b4F` | `g2a-streams/src/StreamFactory.sol` | BODY+META |
| g4b-receipts | ReceiptNFT — ERC-721 settlement receipt | `0x6d140b934a06410a8C36eEe926c967467ab6d46f` | `g4b-receipts/src/ReceiptNFT.sol` | BODY |
| p3-router | Router — fee-on-input DEX router | `0xEB28D5cA0783D01dd2E4bF86AD7024ca156aB047` | `p3-router/src/Router.sol` | IMM |
| p3c-7702 | P3cDelegate — EIP-7702 swapper delegate | `0x70744664505D07B3e7A20B14665211b22176029E` | `p3c-7702/src/P3cDelegate.sol` | BODY |
| f1c-duster | DustSweeper — dust → native sweeper | `0x5F6f5dee0c371ed13D9151B9C64d9fBf30245800` | `f1c-duster/src/DustSweeper.sol` | BODY |

No contract here failed to match. Verdict legend is in `SOURCES.md`. In short: **BODY** and
**BODY+META** mean the executable runtime is byte-identical and only the metadata trailer differs
(metadata is not executed); **IMM** means the sole difference is the constructor-set immutable slots,
which a fresh compile leaves zeroed and the chain has filled — decoded values below.

### Live runtime keccak256 (what you are matching against)

```
p2-forwarder Registry        0x6f7767cc453929a778cac1ef1914d74ee3ae42f55d19d71b752705ef01247879
f1a RequestRegistry          0x67b0802bb91cbf86965456422ff6f236dae89ae3a95533f728493a7bf7532c1b
g3a SponsorTarget            0x0e6a0dc714aeb9d8a2befd4d0496353e8d4d1eb1fae0cb1f5475bf130ba77670
g2b EscrowFactory            0x44fe6680d73692076e00e5168a8172e28076df8c5fd6e1a628e49546ead0b49f
g2a StreamFactory            0x22d7f7892470ff764d9378f9b990eaf4f34fd9bd3a12bcc4f5f917b6990aea1e
g4b ReceiptNFT               0x0f39b1928259271d3c29071f406b389eaeba3c8a91be8b5b41d3c77451cef0f0
p3 Router                    0x19c987eab0287a4d158a0efbc34a75b12d2b8cb4b115782cb0417c5d6242bf0f
p3c P3cDelegate              0xd539adeb7a7ecf3921676c6dc5f83f78b182178fbc20aad6adbe0b7c9c65a045
f1c DustSweeper              0xff12d4f7171202d9fe97c7aafc1a16e014469353ee7eb5fb6ca3dc324e5a3f84
```

## Multi-chain footprint — same runtime, same keccak

The nine Base deployments above are **not Base-only**. The g2b EscrowFactory runtime is replicated
byte-identically (`keccak 0x3394a7f223542a1480e22c131f48b02a1c1eee09859be5831b774d43e785aedb`, 7,794 B)
on **eight further chains**, and the g2a StreamFactory (`0x6dfe06ec…1afb7`, 9,385 B) on four of them.
`CREATE` addresses are a function of (deployer key, nonce) and **chain-independent**, so each key/nonce
group landed at one address everywhere; `owner() == feeRecipient()` is the orphan treasury
`0xe218E382F28A094f9f64E903ee3cb1750A7f204B` on every site. Every code read below was taken cold
(`eth_getCode`, ≥1 independent RPC per chain) and matches the Base reference keccak **exactly**.

| chain | chainId | g2b EscrowFactory | g2a StreamFactory |
|---|---:|---|---|
| Base (native deploy) | 8453 | `0x80793a7d35f735bc76BeAf22B1f413926818f410` | `0x2bB5b763a8A85e446909674177e65cb6F1052b4F` |
| Optimism | 10 | `0x80793a7d35f735bc76BeAf22B1f413926818f410` | `0x61AB1942a6779D392922cfcd20BA6D7dc36FDe15` |
| opBNB | 204 | `0x715114076a45c0102Ae3cb38Bcb89B3211ce591f` | `0xAdB743dA4A5419C62BCc2cF027da6478Ae70f228` |
| Gnosis | 100 | `0x715114076a45c0102Ae3cb38Bcb89B3211ce591f` | `0xAdB743dA4A5419C62BCc2cF027da6478Ae70f228` |
| Scroll | 534352 | `0x715114076a45c0102Ae3cb38Bcb89B3211ce591f` | `0xAdB743dA4A5419C62BCc2cF027da6478Ae70f228` |
| Celo | 42220 | `0x809c4054292550405509373afb1605eCE7200D3D` | — |
| Avalanche C-Chain | 43114 | `0x809c4054292550405509373afb1605eCE7200D3D` | — |
| Monad | 143 | `0x809c4054292550405509373afb1605eCE7200D3D` | — |
| Robinhood Chain | 4663 | `0x809c4054292550405509373afb1605eCE7200D3D` | — |

The three distinct EscrowFactory addresses are the same `CREATE` at three (key, nonce) pairs —
**g2b key nonce 0** for Base/OP, **orphan nonce 3** for opBNB/Gnosis/Scroll, **orphan nonce 0** for the
four 2026-11-09 chains. Group members share an address because they share the key+nonce, not by hand.
`p4-atomic` (SHA-256 escrow) has a sibling port on opBNB / Gnosis / Scroll at
`0x8D794b5d0e3BCB22706C1198fa65F0C837bdd893`.

**Fee is live state, read per site (#162).** `feeBps()` currently reads **500** on Base/OP/opBNB/
Gnosis/Scroll and **25** on Celo/Avalanche/Monad/Robinhood (raised vs. the deploy-time literal; all
`MAX_FEE_BPS == 500`, owner == orphan, so a one-tx `setFeeBps` closes any gap). Deploy receipts and the
full cold readback: `products/g2b-escrow/MULTICHAIN-DEPLOY-EVIDENCE.md`,
`products/g2b-escrow/RECEIPTS-chain-wave-2026-11-09.md`.

## The two IMM cases — decoded immutable args

- **p3-router / Router** — `constructor(uint256 feeBps_, address treasury_)`. Live `feeBps = 5`,
  `treasury = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B`. The contract is otherwise immutable:
  no owner, no setter.
- **f1a-payment-links / RequestRegistry** — `constructor(address p2Registry_, address owner_)`. Live
  `p2Registry = 0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` (the live P2 Registry above),
  `owner` = the deploy key.

## Products not deployed from this tree

`shared/FeeMath.sol` is the shared toll library referenced by current upstream `src/`; the v1 code
in this tree predates it and inlines the same arithmetic (see `SOURCES.md`). `p4-atomic`
(SHA-256 escrow, a g2b variant) is built and tested but **not deployed** anywhere — the live hashlock
escrow is the **keccak** g2b factory `0x80793a7d35f735bc76BeAf22B1f413926818f410` (Base + Optimism,
both paused), so a p4 escrow and a Solana `OP_SHA256` leg cannot open each other.

## Layout

```
<p2-forwarder|f1a-payment-links|g2b-escrow|g2a-streams|g3a-sponsorship|
 g4b-receipts|p3-router|f1c-duster|p3c-7702>/   each: foundry.toml + src/
shared/FeeMath.sol                              reference (HEAD's shared toll)
SOURCES.md   deployed-vs-HEAD delta + verdict legend + settings
LICENSE      MIT
```

Third-party router/router interfaces (`IUniswapV3Router`, `IAerodrome`, `IPermit2`, `IQuoterV2`) and
the g2b copy vendored for g4b fork tests live under each product's own `src/interfaces` and
`src/vendor`. They are interfaces/vendored copies, not the subject of the byte-match table.
