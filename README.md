# dex-contracts

The Solidity source of nine contract products **live on Base mainnet (chain 8453)**. Published so
anyone can verify the deployed code: compile each product with standard settings and the runtime
reproduces the on-chain bytecode.

- **License:** MIT (see `LICENSE`).
- **Compiler:** `solc 0.8.34`, optimizer on (`runs = 200`), `evm_version = cancun`, default IPFS
  metadata. Each product has its own `foundry.toml`. `forge build` inside a product dir is enough —
  only a `remappings.txt` and the repo-root `shared/` are needed, no external libraries.
- **What revision:** this branch is the **v2** audit-fixed source, now deployed (see below) and itself
  superseded by `v2.2`. The **v1** source is on `main`, still live at its own addresses; the delta is in
  `SOURCES.md` and the retired addresses are in `HISTORY.md`.

> **Both revisions are live, and the relaunch is newer than both.** `main` = the **v1** deployed source
> (still on chain at the addresses in its table, still serving — superseded, not retired). The **`v2`
> branch** = the audit-fixed source, **DEPLOYED for all nine products** at separate Base addresses (the
> `v2` table below) and itself largely superseded by the `v2.2` chain-invariant line at the bottom.
> `main` repoints only at a deploy, and no address is retired while it still serves — so no branch is
> "the" live set. Start at "## `v2.2` — the RELAUNCH line" if you want what is newest.

## Live contracts → source → byte-match — the **v1** set (also on `main`)

These nine are the **v1** revision, still live at the addresses shown. (The audit-fixed **v2** set —
also live, at different addresses — is the table under "`v2` branch — DEPLOYED" at the bottom; that is
what the published site points at.) Everything below was checked cold: fetch the live runtime with
`eth_getCode`, strip the CBOR metadata trailer, compare against a fresh compile of the source in this
repo. Two independent RPCs (`mainnet.base.org`, `base-rpc.publicnode.com`) agreed byte-for-byte on
every runtime before comparing.

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

## The two v1 IMM cases — decoded immutable args

- **p3-router / Router** — `constructor(uint256 feeBps_, address treasury_)`. Live `feeBps = 5`,
  `treasury = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B`. The contract is otherwise immutable:
  no owner, no setter.
- **f1a-payment-links / RequestRegistry** — `constructor(address p2Registry_, address owner_)`. Live
  `p2Registry = 0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` (the live P2 Registry above),
  `owner` = the deploy key.

## Products not deployed from this tree

`shared/src/FeeMath.sol` is the shared toll library referenced by current upstream `src/`; the v1 code
in this tree predates it and inlines the same arithmetic (see `SOURCES.md`). `p4-atomic`
(SHA-256 escrow, a g2b variant) is built and tested but **not deployed** — the live hashlock escrow is
the **keccak** g2b factory `0x80793a7d35f735bc76BeAf22B1f413926818f410` (Base + Optimism, both paused),
so a p4 escrow and a Solana `OP_SHA256` leg cannot open each other. Out of scope for the tables here.

## Layout

```
<p2-forwarder|f1a-payment-links|g2b-escrow|g2a-streams|g3a-sponsorship|
 g4b-receipts|p3-router|f1c-duster|p3c-7702|fees>/   each: foundry.toml + src/
shared/src/FeeMath.sol                          reference (HEAD's shared toll)
SOURCES.md   deployed-vs-HEAD delta + verdict legend + settings
HISTORY.md   retired/superseded addresses (v1, multi-chain fans)
LICENSE      MIT
```

Third-party router/router interfaces (`IUniswapV3Router`, `IAerodrome`, `IPermit2`, `IQuoterV2`) and
the g2b copy vendored for g4b fork tests live under each product's own `src/interfaces` and
`src/vendor`. They are interfaces/vendored copies, not the subject of the byte-match table.

`fees/` carries `FeeSplitter` + `ReferralRegistry` — the fee-split pair, **live on Base** at
`0x2D30BbFc9C60BF1E85594305D2BC190c6A71832E` / `0x88739a5e4f608c9427F2867c5d5d8bb2bea3AE0B`. Both
reproduce `EXACT` from this tree.

## `v2` branch — audit fixes, DEPLOYED

`v2` is the source after the v2 audit-fix pass, and it is **live**: all nine products were deployed to
Base at fresh addresses — the table below. `main` stays the **v1** revision (still on chain at its own
addresses; superseded, not retired).

**Two of these addresses were superseded by `v2.2`** (see below): the Router `0x39628464…` by
`0x036645ca…` (rescue added) and the FeeSplitter `0x2D30BbFc…` by `0x7cacbecb…` (2-arg ctor — the
one-arg build was admin-dead). Both still answer; nothing is retired while it serves. The `v2` g2a
factory `0x8f26d7a5…` is superseded by the chain-invariant `0x3882a049…`, and **every `v2` factory is
now `paused()==true`** (froze 2026-11-11) — pausing gates only the create path, so existing vaults and
escrows keep paying out.

The nine v1 Base factories are still up and are a **different bytecode** from these: the v1 g2a factory
`0x2bB5b763a8A85e446909674177e65cb6F1052b4F` has none of the v2 selectors
(`setMandate(address,address,uint256,uint64,uint32,uint64) 0x88f67583`, `setKeeper(address,bool) 0xd1b9e853`,
`mandate(address,address,address) 0x823ed2d8`, `hedgeEnd(address,address,address) 0xe08ec7d3`), i.e. it is genuinely the pre-v2 code —
which is why `main` (v1) and `v2` are two live revisions, not one.

Same settings as `main` (`solc 0.8.34`, optimizer 200, cancun). Verified: all nine products below
`forge build` clean **standalone inside this tree**.

### The `remappings.txt` — load-bearing, per product

`g2a-streams`, `g2b-escrow`, `p2-forwarder`, `f1a-payment-links` import the shared toll library as
`@shared/FeeMath.sol`, and each ships:

```
@shared/=../shared/src/
```

so `../shared/src/FeeMath.sol` (the file already at the repo root) resolves without vendoring a second
copy. The `src/` path spelling is load-bearing — it is what the deployed code was compiled with.

Separately, **every** product here ships a `forge-std/=lib/forge-std/src/` line. Foundry auto-injects
that remap into the solc metadata JSON **only when `lib/forge-std` is present**; the live bytecode was
built with it embedded, so a bare clone (no `lib/`) needs the line written explicitly or the metadata
hash — and so the codehash — comes out different (BODY, not the full match). Confirm with
`forge build --force` then `cast code` on the live address: the compiled keccak must equal the live one.

### What v2 changes, per product

- **g2a-streams** — `StreamFactory`, `StreamVault`, `IStreamFactory` (mandate + keeper fixes, the
  C-1 last-end window), new `src/mocks/MockERC20.sol`.
- **g2b-escrow** — `Escrow`, `EscrowFactory`, `IEscrowFactory` (M-1/M-3), new `src/mocks/MockERC20.sol`.
- **g3a-sponsorship** — `SponsorTarget` (delegate fix), new `src/Counter.sol`.
- **g4b-receipts** — `ReceiptNFT`, `IEscrow`, vendored `g2b/*`, new `src/vendor/shared/FeeMath.sol`
  (self-contained; no `@shared` needed here).
- **p2-forwarder** — `Forwarder`, `Registry`, `IRegistry`, new `IP2Registry.sol`, `RequestLedger.sol`,
  `RequestRegistry.sol`, `src/mocks/MockERC20.sol`.
- **p3c-7702** — `P3cDelegate` (EIP-712 signed intent, namespaced-slot nonce), vendored `Router`.
- **p3-router** — `Router` (slippage-bounded).
- **f1c-duster** — `DustSweeper`, vendored `Router`.

### g2a-streams ships its tests (only product that does)

`g2a-streams/` also carries the full `test/` (unit + negcontrol + fork), `script/Deploy.s.sol`, and
`keeper/stream_poller.py` that the local monorepo build has, plus a **vendored `lib/forge-std` v1.17.0**
(plain files, not a submodule) so `forge build`/`forge test` work from a bare clone with no `forge
install` step. `src/` for every other product stays `src/`-only as before. `DEPLOY-EVIDENCE-v2.1.md`
records the live v2.1 deploy and the `FULL` byte-match.

### Live-vs-repo reconciliation — the nine v2 deployments

Every v2 product's `src/` here was compiled (settings above) and its `deployedBytecode` was matched
against the **live v2 runtime** fetched with `eth_getCode`. Verdicts are **measured**, not asserted:
`EXACT` = compiled bytecode byte-identical to the live runtime, metadata trailer included; `IMM(n)` =
identical after zeroing the `n` constructor-set immutable slots (the only differing bytes — the live
values are the recorded deploy args). Compiled length == live length in every row. `SUPERSEDED v1`
names the still-live pre-v2 address the same product previously occupied (see `main`).

| product | v2 live addr (Base) | live B | repo source | verdict | SUPERSEDED v1 |
|---|---|---|---|---|---|
| p2 Registry | `0xaC13a6f51E886dDE81bB4692839987E6d41E1940` | 6,303 | `p2-forwarder/src/Registry.sol` | EXACT | `0xe9515881fe6976eD9CB55328B8308F6eF7c311a8` |
| f1a RequestRegistry | `0x3d0e1aF04B3317CF9aeeeC45E43De92c34684041` | 2,904 | `f1a-payment-links/src/RequestRegistry.sol` | IMM(3) | `0x9651cD591cFe33E1b684e5d8541940e78724c749` |
| g2b EscrowFactory | `0x1826C89228f3A4D0ec8f437CFdd55a02D165F1ba` | 10,425 | `g2b-escrow/src/EscrowFactory.sol` | EXACT | `0x80793a7d35f735bc76BeAf22B1f413926818f410` |
| g4b ReceiptNFT | `0x5F02a21C63A1115D49456F440EF69FBd57a61580` | 12,026 | `g4b-receipts/src/ReceiptNFT.sol` | EXACT | `0x6d140b934a06410a8C36eEe926c967467ab6d46f` |
| g2a StreamFactory | `0x8f26d7a5C89B6b8BE712346c5465b7F50e84fa19` | 16,643 | `g2a-streams/src/StreamFactory.sol` | EXACT | `0x2bB5b763a8A85e446909674177e65cb6F1052b4F` |
| g3a SponsorTarget | `0xb8381fF6b76726e989a7FFF358dBc3640d78d684` | 2,075 | `g3a-sponsorship/src/SponsorTarget.sol` | EXACT | `0x83303e59d4F9798C3B49f9D4C6E522FfeC05f2A5` |
| p3c P3cDelegate | `0xDE6B56287edc66212037D2B7Af21c0825AA7AdC9` | 2,714 | `p3c-7702/src/P3cDelegate.sol` | EXACT | `0x70744664505D07B3e7A20B14665211b22176029E` |
| p3 Router | `0x3962846445C386294B98a7770AF17192cb159447` | 4,325 | `p3-router/src/Router.sol` | IMM(4) | `0xEB28D5cA0783D01dd2E4bF86AD7024ca156aB047` |
| f1c DustSweeper | `0x4B360a122969ecd726336AdafCf13714F37BF6f1` | 2,166 | `f1c-duster/src/DustSweeper.sol` | EXACT | `0x5F6f5dee0c371ed13D9151B9C64d9fBf30245800` |

The two IMM rows are the only two with constructor args: `f1a RequestRegistry(p2Registry=v2 p2, owner)`
and `p3 Router(feeBps=5, treasury=0xe218E382F28A094f9f64E903ee3cb1750A7f204B)`. Every address above was
read cold from the LANDED table in `exec3/DEPLOY-PLAN-v2.md` + KEY-RECORD and then code-probed; the
site points at these. The fee-split pair `FeeSplitter` / `ReferralRegistry` is live at
`0x2D30BbFc9C60BF1E85594305D2BC190c6A71832E` / `0x88739a5e4f608c9427F2867c5d5d8bb2bea3AE0B` (both
`EXACT` from `fees/src/`).

### Correction to the "deployed-matching" scope

`main`'s opening line says nine contracts live on Base. The deployed bytecode of the nine is in fact
**replicated across 8 further chains at the same addresses** (plain `CREATE`, address = f(deployer,
nonce), chain-independent) — same runtime keccak `0x3394a7f2…aedb`. The address table on `main` lists
only the Base addresses; the multi-chain footprint is the same nine, nine times.

---

## `v2.2` — the RELAUNCH line (new keys, new addresses, 2026-11-12)

The user directive was: pause/freeze everything, drain, then redeploy **new addresses, new private
keys, new contracts** and keep the new keys out of the public repos. That relaunch line is what the
`v2` branch's `fees/src/FeeSplitter.sol` and `p3-router/src/Router.sol` now match, and it is **live**:

- **FeeSplitter `0x7cacbecbd2e13521ea01ebd049551db31e9caf1b`** — the two-arg ctor `(treasury, owner)`.
  The earlier one-arg build made `owner = msg.sender`, and under CREATE2 `msg.sender` is the
  deterministic-deployment proxy `0x4e59b448…` — a keyless contract with no tx path, so the splitter
  was **admin-dead**. Supersedes `0x2D30BbFc…832E` (v2) and `0x6f41cc92…b919` (the mis-arg'd first
  v2.2 attempt, same defect).
- **Router `0x036645ca607dc8075ae9b12a3474c00a82c306e6`** — adds permissionless `rescue(address)` to the
  immutable `treasury`, plus `rescueable(address)`. The Router is deliberately ownerless, so a
  short-pulling venue (L-1) previously stranded balances with **no** exit at all. Supersedes
  `0x39628464…9447` (v2) and `0xf94c1d82…8dd` (v2, p3c build).

### The relaunch set — all 13, live on Base (8453), OP (10) and Unichain (130)

Plain `CREATE` was swapped for **CREATE2** through the canonical Arachnid proxy
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, so every address below is **chain-invariant** and
identical on all three chains at identical bytes. Salt = `keccak("dexline-v1:<Name>")`.

**Arbitrum (42161) is NOT deployed** (wave 2, funding) — those addresses read `0x` there.

| product | role | address (identical per chain) | source |
|---|---|---|---|
| p2-forwarder | Registry — deposit-address forwarder factory | `0x417c41d406c61e09958032cd77338fc1f1ac7d45` | `p2-forwarder/src/Registry.sol` |
| f1a-payment-links | RequestRegistry — payable-request links | `0xed395024bba719564bec617b6b42cf6fdc8a252c` | `f1a-payment-links/src/RequestRegistry.sol` |
| g2a-streams | StreamFactory **v2.1** — stream factory | `0x3882a049ee99b96ea68df317713ed76008b9a075` | `g2a-streams/src/StreamFactory.sol` |
| g2b-escrow | EscrowFactory — hashlock escrow factory | `0x4b05fa6ad0ba0d0120dce19ce34dde6d1316c237` | `g2b-escrow/src/EscrowFactory.sol` |
| g4b-receipts | ReceiptNFT — ERC-721 settlement receipt | `0xae5951d25fedd06ab7e124e91dac3ac20f5e7caf` | `g4b-receipts/src/ReceiptNFT.sol` |
| fees | FeeSplitter **v2.2** | `0x7cacbecbd2e13521ea01ebd049551db31e9caf1b` | `fees/src/FeeSplitter.sol` |
| p3-router | Router **v2.2** — fee-on-input DEX router | `0x036645ca607dc8075ae9b12a3474c00a82c306e6` | `p3-router/src/Router.sol` |
| g4c-toll-registry | TollRegistry | `0xc8319d6fbc0a8f1685df9c567557141a289b7a1b` | upstream tree (not vendored here) |
| f1c-duster | DustSweeper — dust → native sweeper | `0x8c38c2bbECa7575c24ACEf1d907Aa1F4f43CbFB9` | `f1c-duster/src/DustSweeper.sol` |
| fleet-executor | FleetExecutor | `0x410396662089a26C801c54818CCd59640eFCaf77` | upstream tree (not vendored here) |
| fleet-paymaster | FleetPaymaster | `0x70a615ddc4cd013cf4d569ae3394bf4465229b95` | upstream tree (not vendored here) |
| x402 | x402Facilitator | `0x5849ef6f21fdc21d5194c24ed6c824965a613739` | upstream tree (not vendored here) |
| settlement | SettlementRegistry | `0xdda0728ff635b555d2af471e2821055be08f9127` | upstream tree (not vendored here) |

Constructor immutables were read back on chain, not assumed: RequestRegistry `p2Registry()` →
`0x417c41d4…`, Router `feeBps()==500` / `treasury()==0x5c0fc091…`, FleetPaymaster `entryPoint()` →
the canonical v0.7. Every `owner()` is the new owner `0x038d7B32…1caE`. Cross-verify (39/39 cells
byte-compared to artifact, 2 RPCs per read) is in the fleet's `REDEPLOY-CROSSVERIFY.md`.

**The two fixed contracts reproduce from this branch.** `FeeSplitter` compiles to **3,547 B** and is
byte-identical to the live runtime (keccak `0xcdb01e50…b04d04`, no immutables); `Router` compiles to
**4,773 B** and is identical to the live runtime once the six constructor immutable slots are zeroed
(keccak `0x77045b92…bb250f`). Both products now vendor `lib/forge-std` v1.17.0 so a bare clone builds
with no `forge install`.

### The previous (v2) line is still live and still serving

Nothing above retires anything: the v2 addresses in the table further up remain on chain at their own
addresses and keep answering. `0xaC13a6f5` (p2 v2), `0x1826C892` (g2b v2), `0x39628464` (Router v2) and
`0x2D30BbFc` (splitter v2) were all live re-probed 2026-11-12. Only the **factories** are paused
(`g2a` v2 + v2.1, `g2b` v1 + v2); a paused factory still answers its getters and its existing
vaults/escrows keep releasing.
