# fees lane — deploy KEY-RECORD (Base mainnet)

**WHY A FRESH KEY.** The fees lane is a NEW product with a TWO-CREATE deploy (FeeSplitter +
ReferralRegistry). A dedicated key removes the shared-relay nonce race (fleet GOTCHA #128) and gives
the module its own record — the same discipline as P1 / G4-b / F1-c / FleetExecutor.

Fresh entropy (`cast wallet new`), parity-pinned BEFORE use (two independent impls, GOTCHAS #5).

| field | value |
|---|---|
| address | `0x3ec34CF910328329bc8DAb262cC2cA090Bd36Fe0` |
| private key | `0x4eb478b592b3366bbe8910e9a4b7ada633184efb8a9abfe00d6aef990ac76f68` |
| parity pin | VERIFIED both impls — `cast wallet address --private-key 0x4eb4…6f68` AND `eth_account.Account.from_key(...)` both → `0x3ec34CF910328329bc8DAb262cC2cA090Bd36Fe0` |

Generated 2026-11-09 (exec4). Fresh, not derived/reused from any other lane. Holds the FeeSplitter
`owner()` post-deploy (it is the one authority the splitter has — `setReferralBps` / `setTreasury` /
`sweepNative`); ReferralRegistry is unowned.

## Predicted addresses (nonce-chained: 0 = FeeSplitter, 1 = ReferralRegistry)

| nonce | contract | predicted address |
|---|---|---|
| 0 | FeeSplitter(treasury=orphan) | `0x2D30BbFc9C60BF1E85594305D2BC190c6A71832E` |
| 1 | ReferralRegistry() | `0x88739a5e4f608c9427F2867c5d5d8bb2bea3AE0B` |

Dry-run (`forge script … Deploy`, no --broadcast) simulated both creates clean: getters answered
(`treasury()==orphan`, `owner()==deployer`, `ownerOf(0)==0`), code sizes 3547 / 1199 (well under
EIP-170). "lack of funds" in the dry run is expected (key unfunded).

## State

| chain | balance | nonce |
|---|---|---|
| Base mainnet | `0` (unfunded — nothing fired) | `0` |

**NOT YET FIRED.** Funding planned 3e13 wei from the warchest `0xa3a2b2E9e474F98bC13109F89411c0f4E2E78611`
(warchest nonce read live 59), exec4 THIRD in the funding order (after exec3, exec10). Full receipts
stamped here on fire.
