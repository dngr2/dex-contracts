# Source-vs-deployed revisions — READ THIS BEFORE VERIFYING

This repo publishes the **deployed-matching source** for nine live Base-mainnet contracts, so that a
stranger (or Sourcify / a block explorer) can reproduce each live runtime **byte-for-byte from the
source in this tree** with standard settings. It is deliberately **not** the latest `src/` HEAD of the
upstream product: the live bytecode predates a later refactor, and HEAD would fail the byte-match.

## The one delta: the shared-FeeMath / minFee refactor

Every live contract here was deployed **before** the fleet moved its toll arithmetic into a single
shared library (`FeeMath.toll`) and added an owner-settable `minFee` floor on the factory contracts
(p2 Registry, g2a StreamFactory, g2b EscrowFactory, p2 Forwarder, g2a StreamVault, g2b Escrow).

So this tree carries the **pre-refactor** revision:

- `Registry`/`Forwarder`/`StreamFactory`/`StreamVault`/`EscrowFactory`/`Escrow` compute the toll
  **inline**: `fee = (amount * feeBps) / 10_000` — there is **no `minFee()` getter and no
  `setMinFee()` setter** on the live contracts.
- The per-product `src/` upstream has since advanced to call `FeeMath.toll(amount, feeBps, minFee)`.
  With `minFee == 0` the two are numerically identical; the deployed bytecode is the inline form.

**Proof it is the right revision, not a stale copy:** the live p2 Registry has **no** `minFee()`
selector in its runtime (selector scan of the deployed code), and recompiling the pre-refactor source
in this tree reproduces the live runtime exactly (metadata-normalized). `shared/src/FeeMath.sol` is
included for reference (it is what HEAD calls); it is **not** linked into any deployed bytecode here.

## Settings (every product)

`solc 0.8.34`, `optimizer = true`, `optimizer_runs = 200`, `evm_version = "cancun"`,
`metadata.bytecode_hash = "ipfs"` (default). Each product ships its own `foundry.toml` with these,
`src = "src"`. No external libs: every file is self-contained (`lib/forge-std` is not needed to build
`src/`). Build: `cd <product> && forge build`.

The 64-byte CBOR metadata trailer (which embeds the per-source keccaks and the compiler version) is
reproduced identically for the metadata-independent cases; where a contract carries **immutables** or
**embeds a child contract's creation code**, the live runtime differs from a fresh compile only in
those specific slots — see the verdict column in README. Verdict legend:

- **FULL** — compiled `deployedBytecode` is identical to the live runtime, metadata included.
- **BODY** — runtime body identical; only the CBOR metadata trailer differs (source paths / urls).
- **BODY+META** — body identical after normalizing the metadata hashes of the top contract **and** of
  any child creation-code it embeds; the difference is metadata only.
- **IMM** — identical after zeroing immutable slots; live has real ctor args, the artifact has
  placeholders. `IMM+META` = both at once. The decoded live values are the recorded deploy args.
