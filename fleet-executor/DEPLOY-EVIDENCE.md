# FleetExecutor — LIVE DEPLOY + E2E EVIDENCE (Base mainnet)

Author: dex-executor5 · 2026-11-09 · status: **DEPLOYED + proven live, byte-identical to source**.
Chain 8453 (Base mainnet). Everything below is a live receipt / live byte pin / live readback — not prose.

**Nothing broadcasst beyond this lane.** One deploy + one install + the proof txs. No relay in PHONE-QA sense.

---

## The shipped delegate

| field | value |
|---|---|
| address | `0x8943793970d2B29180A1B30166c0e326Bc94d2D4` — **copy this, never retype (GOTCHA #73)** |
| deploy tx | `0x7e004b83d4c49d3ba7550ea04ae2be0153ccef63733a41ad2180e95f99b29ccd` (block `0x34807a0`, status 1, type 2) |
| deployer | `0xe41F97bbda680B6afc1f16AAf828978A23c95779` (fresh key, nonce 0 — see `KEY-RECORD.md`) |
| runtime | 5,641 B — **BYTE-IDENTICAL** to the local artifact (`out/FleetExecutor.sol/FleetExecutor.json` `.deployedBytecode`) |
| code keccak | `0xfa2bdce24083f8cd236e6c53c575db81289421c4ea42398216ac286c825688f8` |
| code sha256 | `794e4fe44ec62dafc190122a8fce5790269acf52f2ee3389e79c08b3a2871e1f` |
| gasUsed | 1,272,340 (`0x136d14`), effGasPrice 6e6 wei ⇒ **~0.00000763 ETH** |
| ctor / owner / immutables | none / none / none — unowned, non-upgradeable, chain- & account-independent |

Live readbacks: `domain()` = `0xb050ba3ebf9247cca9dda63b386fe02f17954145eaa1d7202f0b0ea65049dbdd` (chainId 8453 +
verifyingContract bound), `nonces()` = 0, `nonceOf(deployer)` = 0.

---

## Live E2E — install via real type-4 auth, then a signed batch carried by a relayer

Throwaway authority `0x4b19Ece77d3B1D8D9fd655F72f8A16eb317C5E61` (fresh, **holds 0 ETH**, parity-pinned
two impls). This proves the whole point: the authority acts, a relayer pays.

| # | step | tx | status | result |
|---|---|---|---|---|
| A | relayer installs delegation (type-4 auth, `0xef0100‖delegate`) | `0x2fee55d7…f8e61d` | **0x0**\* | AUTH code = `0xef01008943793970d2b29180a1b30166c0e326bc94d2d4` |
| B | **SIGNED BATCH**: authority signs EIP-712 off-chain, relayer carries | `0xeb86d42c…706deba` | **0x1** | AUTH WETH **0 → 1e12**, AUTH ETH stays **0**, `nonces()` 0 → 1 |

\*TX A's status-0 is expected and correct: FleetExecutor has no `receive`/fallback, so a 0-value
empty-calldata self-send has nothing to dispatch. The auth side-effect still installs the code (verified
by the exact `0xef0100‖delegate` code bytes above).

**TX B is the whole claim, live:** digest computed ON the authority (`FleetExecutor(AUTH).digest(...)`,
delegate code running in AUTH's frame), signed by the AUTH key, carried by the relayer, `ecrecover ==
address(this) == AUTH` in the trace. WETH `deposit()` minted 1e12 wei **into AUTH**, paid for entirely
by the relayer — AUTH's own ETH balance never left 0.

## Live adversarial teeth (reject-what-should-fail, on the DEPLOYED contract)

| probe | tx | status | decoded revert (from `cast run` trace) |
|---|---|---|---|
| REPLAY the same signature/nonce | `0xf110f7b1…2a3950` | **0x0** | `BadNonce()` — WETH unchanged (no double-mint), monotonic guard holds |
| #203 GATE: stranger sends unsigned 2-arg `execute(bytes32,bytes)` | `0xc135add3…c62f4a210` | **0x0** | `NotSelfOrIntent()` — the drain door is closed |

## Live negative controls (the SAME stranger + SAME batch, proven to still work)

| probe | tx | status | result |
|---|---|---|---|
| NC1 — `executeBare` (opt-in raw door) | `0x1ce59c10…f6e50198` | **0x1** | AUTH WETH 1e12 → 2e12 (permissionless opt-in preserved) |
| NC2a — 5-arg signed intent, WRONG nonce (passed 1, state 1) | `0xe5bc64f9…f3b167d8ae48` | **0x0** | `BadNonce()` (strict `nonce > nonce()`) |
| NC2b — 5-arg signed intent, correct nonce (2) | `0xc21c9c32…18bac07e2c772` | **0x1** | AUTH WETH 2e12 → 3e12, `nonces()` 1 → 2 (no replay) |

NC1+NC2 together prove the gate is not "reject strangers": the identical stranger+batch succeeds on both
the explicit raw door and the signed door, while failing only on the gated default door.

---

## Funding
Warchest `0xa3a2b2E9e474F98bC13109F89411c0f4E2E78611` → fresh key, `0x443b65cf…ff7913` (status 1,
21,000 gas, exactly 3e13 wei). Deployer residue after deploy + proof txs: 1.733e13 wei.

## Reproduce
```
PRIVATE_KEY=<fresh> forge script script/Deploy.s.sol:Deploy --rpc-url https://mainnet.base.org --broadcast
cast code 0x8943793970d2B29180A1B30166c0e326Bc94d2D4 --rpc-url https://mainnet.base.org   # 5,641 B
```
