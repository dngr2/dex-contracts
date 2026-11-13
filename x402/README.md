# x402 — on-chain settlement gate for a 402 flow

**LANE 9** of BUILD-WAVE-1. A tiny, non-custodial reference for the x402 pattern where the *facilitator
is on-chain*: the server returns `402 Payment Required`; the client pays through the rail; the server
verifies the settlement with a **view call** and then serves the resource. Nothing here holds funds.

## Files

```
src/interfaces/IPaymentRail.sol   vendored copy of lane 1's frozen interface (self-contained)
src/x402Facilitator.sol           the gate: markPaid (gated writer) + verify() (view)
test/unit/x402Facilitator.t.sol   unit + fuzz tests (17)
test/unit/X402Adversarial.t.sol   dex-critic's adversarial probes (cross-check)
server/app.py                     minimal FastAPI reference server (~130 lines)
server/test_app.py                tiny pytest (selector canonicality + fault-vs-not-paid)
```

## The flow

1. Client `GET /weather` with no payment → **402** JSON naming `{rail, to, token, amount, memo, facilitator}`.
2. Client calls `IPaymentRail.pay(to, token, amount, memo, referrer)` → the rail settles on-chain and
   its `Paid(bytes32 paymentId, ...)` event yields the `paymentId`.
3. A **writer** (the rail, or a relayer watching `Paid`) calls `x402Facilitator.markPaid(paymentId, to, token, amount)`.
4. Client retries `GET /weather` with header `X-PAYMENT: <paymentId>`.
5. Server calls `x402Facilitator.verify(paymentId, to, token, amount)` — a **view** — and returns the
   resource on `true`, else 402 again.

`verify(paymentId, to, token, minAmount)` returns true iff `to`, `token` match exactly and
`settledAmount >= minAmount`, for a known `paymentId`. `markPaid` is idempotent (identical re-mark is a
no-op; a conflicting re-mark reverts), so an id can never silently change meaning. `markPaid` is gated
by an owner-managed writer allow-list.

## Why on-chain, and what it is *not*

- The settle is the rail's; this contract only *reads* it. No custody, no upgrade, no `selfdestruct`.
- `verify` emits nothing and consumes nothing — one settled payment can unlock more than once. Replay
  policy is the server's (optional per-request nonce in `memo`). Deliberately tiny: a REFERENCE.
- No value path ⇒ no `nonReentrant` needed (all writes are plain storage, all checks are views).
- `paid(paymentId)` mirrors lane 10's `SettlementRegistry` read shape, so a deployment may point at
  that contract instead.

## `pay_for_402` — the client snippet

```python
# client.py — pay a 402 and retry. Uses web3.py; the rail ABI is just `pay`.
from web3 import Web3

def pay_for_402(w3: Web3, rail_addr: str, rail_abi: list, challenge: dict, key: str) -> str:
    """Pay the 402 challenge through the rail; return the resulting paymentId (from the Paid event).
    `challenge` is the server's 402 body: {to, token, amount, memo, ...}."""
    acct = w3.eth.account.from_key(key)
    rail = w3.eth.contract(address=Web3.to_checksum_address(rail_addr), abi=rail_abi)
    toks = w3.eth.contract(
        address=Web3.to_checksum_address(challenge["token"]),
        abi=[{"name":"approve","type":"function","inputs":[{"name":"s","type":"address"},{"name":"a","type":"uint256"}],"outputs":[{"type":"bool"}]}],
    )
    amt = int(challenge["amount"])
    # 1) approve the rail to pull (skip if already approved)
    if toks.functions.allowance(acct.address, rail.address).call() < amt:
        tx = toks.functions.approve(rail.address, amt).build_transaction(
            {"from": acct.address, "nonce": w3.eth.get_transaction_count(acct.address, "pending")})
        w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(
            acct.sign_transaction(tx).rawTransaction))
    # 2) pay -> receipt's Paid event carries the paymentId
    memo = bytes.fromhex(challenge.get("memo", "0x" + "00"*32)[2:])
    tx = rail.functions.pay(challenge["to"], challenge["token"], amt, memo, acct.address).build_transaction(
        {"from": acct.address, "nonce": w3.eth.get_transaction_count(acct.address, "pending")})
    rcpt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(acct.sign_transaction(tx).rawTransaction))
    paid = rail.events.Paid().process_receipt(rcpt)[0]
    return paid["args"]["paymentId"].hex()   # 3) send this back as X-PAYMENT
```

Server side is in `server/app.py`; the fault-vs-not-paid distinction means a rate-limited node returns
`402 {"reason":"rpc_fault"}` (retry), not `not_paid` (which would invite a duplicate payment).

## Build & test (nothing deployed)

```sh
forge test -vv                 # contract: 17 own + adversarial probes
python3 -m pytest -q server    # server: selector canonicality + fault handling
```

## Run the reference server

```sh
X402_RAIL=0x… X402_FACILITATOR=0x… X402_PAY_TO=0x… X402_TOKEN=0x… X402_AMOUNT=10000 \
  uvicorn server.app:app --port 8402
```
