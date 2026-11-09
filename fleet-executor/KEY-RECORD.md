# FleetExecutor — deploy KEY-RECORD (Base mainnet)

**WHY A FRESH KEY.** The shared relay `0x85C6764D…BbeD6` (fleet GOTCHA #128) is nearly drained
(≈5.3e10 wei — under the ~2.98e13 a deploy needs), and the wave's other product keys are each
scoped to their own product. This is a NEW product with a ONE-tx deploy, so a dedicated key removes
the nonce race outright and gives the module its own record — the same discipline as P1 / G4-b / F1-c.

Fresh entropy (`cast wallet new`), parity-pinned BEFORE use (two independent impls, GOTCHAS #5).

| field | value |
|---|---|
| address | `0xe41F97bbda680B6afc1f16AAf828978A23c95779` |
| private key | `0x149f075f7b1fe1ced48ce5adbfcfcd4bc890b7ec7bbf309aed78b3a3e705c7c6` |
| parity pin | VERIFIED both impls — `cast wallet address --private-key 0x149f…c7c6` AND `eth_account.Account.from_key(...)` both → `0xe41F97bb…5779` |

Generated 2026-11-09 (exec5). Fresh, not derived/reused from any other lane. Holds no authority
post-deploy (FleetExecutor has NO owner, NO admin, NO immutables — an unowned, non-upgradeable delegate).

## State

| chain | balance | nonce |
|---|---|---|
| Base mainnet | `0` (unfunded — nothing fired) | `0` |

**FIRED 2026-11-09.** Funded 3e13 wei from the warchest `0xa3a2b2E9…8611` (tx `0x443b65cf…ff7913`,
warchest nonce 53 → 54). Deployed at nonce 0 → `0x8943793970d2B29180A1B30166c0e326Bc94d2D4`
(tx `0x7e004b83…b29ccd`), then the deploy key served as the E2E relayer (nonce 1..8, proof txs).
Residue after deploy + proof: `1.733e13` wei. Full receipts: `DEPLOY-EVIDENCE.md`.

## The installed delegate form

A user authority EOA installs this delegate with ONE type-4 authorization setting its code to
`0xef0100 || address(FleetExecutor)`. After that, a call to the authority runs `FleetExecutor` code in
the authority's frame (`address(this) == authority`), so the authority stays the acting identity while
a relayer pays gas. To un-delegate: send a type-4 auth naming `delegate = 0x0`.
