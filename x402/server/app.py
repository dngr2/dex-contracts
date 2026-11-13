"""Minimal x402 REFERENCE server (FastAPI).

This is a reference, not a product. It shows the full 402 loop in ~120 lines:

    GET /weather  (or any protected path)
      -> 402 Payment Required, JSON body {rail, to, token, amount, memo, paymentId?}
      client pays via IPaymentRail.pay(...)  ->  yields a paymentId (from the Paid event)
      client retries with header  X-PAYMENT: <paymentId>
      server calls x402Facilitator.verify(paymentId, to, token, amount) on-chain
      -> 200 with the resource, or 402 again if the id doesn't verify.

Nothing here holds funds: the rail settles to `to`; the facilitator only *reads* settlement state.

Run:
    pip install fastapi uvicorn web3
    X402_RAIL=0x... X402_FACILITATOR=0x... X402_PAY_TO=0x... X402_TOKEN=0x... \
        uvicorn server.app:app --port 8402

Env:
    X402_RPC          JSON-RPC url (default: base mainnet public)
    X402_FACILITATOR  deployed x402Facilitator address
    X402_RAIL         deployed IPaymentRail address (advertised in the 402 so clients know where to pay)
    X402_PAY_TO       recipient address the resource expects payment to
    X402_TOKEN        ERC-20 token address (USDC). Use the zero address for native.
    X402_AMOUNT       integer amount in token base units (e.g. 10000 = 0.01 USDC)
    X402_MEMO         bytes32 memo advertised to clients (optional)
"""
from __future__ import annotations

import os
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="x402 reference server", version="0.1.0")

# --- tiny verified-ABI: x402Facilitator.verify(bytes32,address,address,uint256) ---
VERIFY_SIG = "verify(bytes32,address,address,uint256)"

# keccak256(VERIFY_SIG)[0:4] == 0x796e926d, derived with `cast sig` (test asserts _sel() == this).
# Hard-coded so the fallback path (no eth_utils) STILL sends a correct selector — a placeholder here
# made every eth_call revert on a box without eth_utils.
KNOWN_VERIFY_SELECTOR = "0x796e926d"

ZERO = "0x0000000000000000000000000000000000000000"


def _cfg() -> dict:
    return {
        "rpc": os.environ.get("X402_RPC", "https://mainnet.base.org"),
        "facilitator": os.environ.get("X402_FACILITATOR", ZERO),
        "rail": os.environ.get("X402_RAIL", ZERO),
        "pay_to": os.environ.get("X402_PAY_TO", ZERO),
        "token": os.environ.get("X402_TOKEN", ZERO),
        "amount": int(os.environ.get("X402_AMOUNT", "10000")),
        "memo": os.environ.get("X402_MEMO", "0x" + "00" * 32),
    }


def _challenge(path: str) -> dict:
    """The 402 body a client uses to build the payment."""
    c = _cfg()
    return {
        "x402Version": 2,
        "resource": path,
        "rail": c["rail"],          # where to call pay()
        "to": c["pay_to"],          # who gets paid
        "token": c["token"],        # what to pay in
        "amount": str(c["amount"]),  # how much (base units)
        "memo": c["memo"],          # bytes32 correlation tag
        "facilitator": c["facilitator"],
    }


def _sel(sig: str) -> str:
    """4-byte selector. Prefer eth_utils (keccak); fall back to the hard-coded constant so the
    dependency-light path still emits a CORRECT selector. A test asserts these agree."""
    try:
        from eth_utils import keccak  # type: ignore

        return "0x" + keccak(text=sig)[:4].hex()
    except Exception:
        return KNOWN_VERIFY_SELECTOR


# verify() outcomes — THREE, and the third is the point. A transport fault (429 / 500 / HTML error
# page / malformed body) is NOT the same as "not paid": the client may have settled and the RPC merely
# failed. So a definite `false` verdict and a `couldn't tell` are different states, and only a real
# `false` should invite a re-pay. UNKNOWN is the third verdict.
VERIFIED = "verified"
NOT_PAID = "not_paid"
UNKNOWN = "unknown"


def _eth_call_verify(data: str) -> tuple[str, Optional[bool]]:
    """Return (state, value). state is VERIFIED / NOT_PAID / UNKNOWN; value is the bool when decidable.

    Transport-fault-vs-verdict (GOTCHA #147 family): a non-2xx status, an HTML error page, malformed
    JSON, a JSON-RPC `error`, or an empty ("0x") result all land as UNKNOWN — never a crash and never
    a wrong verdict.
    """
    import json
    import urllib.error
    import urllib.request

    c = _cfg()
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
         "params": [{"to": c["facilitator"], "data": data}, "latest"]}
    ).encode()
    req = urllib.request.Request(
        c["rpc"], body, {"Content-Type": "application/json", "User-Agent": "x402-ref"}
    )
    try:
        # read the body even on a non-2xx so a 500-with-HTML is diagnosable, and never raises out
        try:
            raw_body = urllib.request.urlopen(req, timeout=20).read()
        except urllib.error.HTTPError as e:
            raw_body = e.read()          # e.g. a 429/500 page — body is HTML, not JSON
    except Exception:
        return UNKNOWN, None             # connection refused / timeout / DNS

    try:
        res = json.loads(raw_body)       # HTML page or truncated body raises here
    except (ValueError, TypeError):
        return UNKNOWN, None

    if not isinstance(res, dict):
        return UNKNOWN, None
    if "error" in res or "result" not in res:
        return UNKNOWN, None
    raw = res.get("result")
    if raw is None or raw == "0x":       # revert with no return data / empty
        return UNKNOWN, None
    try:
        ok = int(raw, 16) == 1
    except (TypeError, ValueError):
        return UNKNOWN, None
    return (VERIFIED if ok else NOT_PAID), ok


def _verify_onchain(payment_id: str) -> str:
    """Call x402Facilitator.verify(...) and return VERIFIED / NOT_PAID / UNKNOWN."""
    c = _cfg()
    if c["facilitator"] == ZERO:
        return UNKNOWN

    pid = payment_id if payment_id.startswith("0x") else "0x" + payment_id
    pid = pid[2:].rjust(64, "0")[-64:]  # bytes32, hex body

    def word(v: str) -> str:
        if v.startswith("0x"):
            return v[2:].lower().rjust(64, "0")
        return hex(int(v))[2:].rjust(64, "0")

    data = _sel(VERIFY_SIG) + pid + word(c["pay_to"]) + word(c["token"]) + word(str(c["amount"]))
    state, _ = _eth_call_verify(data)
    return state


@app.get("/")
def root() -> dict:
    return {"service": "x402 reference server", "protected": ["/weather"], "challenge": _challenge("/weather")}


@app.get("/weather")
def weather(request: Request, x_payment: Optional[str] = Header(default=None)):
    """A protected resource: 402 unless a settled paymentId verifies on-chain."""
    if not x_payment:
        return JSONResponse(status_code=402, content=_challenge("/weather"))

    state = _verify_onchain(x_payment)
    if state != VERIFIED:
        body = _challenge("/weather")
        if state == UNKNOWN:
            # couldn't tell: the RPC faulted (non-2xx / HTML / malformed). The client may have settled,
            # so RETRY rather than re-pay. 503 (transient) is more honest than 402 here.
            body["error"] = "could not verify on-chain (rpc fault); retry"
            body["reason"] = "unknown"
            return JSONResponse(status_code=503, content=body)
        body["error"] = "payment not verified (unknown id, wrong recipient/token, or under-amount)"
        body["reason"] = "not_paid"
        return JSONResponse(status_code=402, content=body)

    return {
        "ok": True,
        "resource": "/weather",
        "paymentId": x_payment,
        "data": {"city": "Baseville", "tempC": 21, "cloudy": False},
    }


@app.get("/healthz")
def healthz() -> dict:
    c = _cfg()
    return {"ok": True, "facilitator": c["facilitator"], "rail": c["rail"], "amount": c["amount"]}
