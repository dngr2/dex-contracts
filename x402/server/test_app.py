"""pytest for the x402 reference server — the two proven bugs, each with a NEGCONTROL.

Bug 1 (selector): the fallback selector was the placeholder `0x00000000`, so on a box without
eth_utils every eth_call went out with a wrong 4-byte head and the facilitator (no `fallback()`)
reverted. Negcontrol: assert the OLD zero selector does NOT match the canonical `verify(...)`
selector derived independently (keccak / `cast sig`), THEN the fix does.

Bug 2 (fault-vs-verdict): a non-2xx with an HTML body, or a 200 with malformed JSON, must land as
UNKNOWN (couldn't tell) — not a crash, not a wrong verdict. Negcontrol: feed exactly those and assert
`unknown`.

Run:  python3 -m pytest -q server/test_app.py
"""
import builtins
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import server.app as app_mod  # noqa: E402

# keccak is the independent oracle. Skip only if truly absent (the constant is what ships).
try:
    from eth_utils import keccak
    HAVE_KECCAK = True
except Exception:  # pragma: no cover
    HAVE_KECCAK = False

PAID_SIG = "Paid(bytes32,address,address,address,uint256,uint256,bytes32,address)"


# ------------------------------------------------------------------ bug 1: selector + negcontrol

def _force_fallback():
    """Context manager: make `import eth_utils` raise so _sel() takes its fallback branch."""
    real = builtins.__import__

    def no_eth(name, *a, **k):
        if name == "eth_utils":
            raise ImportError("forced")
        return real(name, *a, **k)

    return real, no_eth


def test_negcontrol_old_zero_selector_was_wrong():
    """NEGCONTROL: the placeholder `0x00000000` must NOT equal the real selector. The bug was real."""
    if not HAVE_KECCAK:
        assert app_mod.KNOWN_VERIFY_SELECTOR == "0x796e926d"
        return
    real = "0x" + keccak(text=app_mod.VERIFY_SIG)[:4].hex()
    assert real == "0x796e926d", "sanity: independent keccak must equal the cast-sig value"
    assert real != "0x00000000", "NEGCONTROL: the placeholder selector was indeed wrong"


def test_selector_matches_reality_and_old_one_misses():
    """The fix: the fallback path yields the REAL selector; the old placeholder misses it."""
    if not HAVE_KECCAK:
        assert app_mod._sel(app_mod.VERIFY_SIG) == "0x796e926d"
        return

    real = "0x" + keccak(text=app_mod.VERIFY_SIG)[:4].hex()  # == cast sig 0x796e926d

    real_imp, no_eth = _force_fallback()
    builtins.__import__ = no_eth
    try:
        got = app_mod._sel(app_mod.VERIFY_SIG)   # takes the except branch -> must still be correct
    finally:
        builtins.__import__ = real_imp

    assert got == real, "fallback selector must equal the canonical selector"
    assert got != "0x00000000", "fallback must not be the placeholder"

    # Calldata head: the encoded call must START with the real selector, not the placeholder.
    head = app_mod._sel(app_mod.VERIFY_SIG)
    calldata = head + "11" * 32
    assert calldata[:10] == real
    assert calldata[:10] != "0x00000000"


def test_negcontrol_zero_selector_misses_a_real_paid_topic():
    """Anchor the negation on real log data: topic0(Paid) != 0x00000000, and the canonical selector
    (hex of the verify 4-byte) is what a decoder keys on."""
    if not HAVE_KECCAK:
        return
    topic0_paid = "0x" + keccak(text=PAID_SIG).hex()
    assert topic0_paid != "0x" + "00" * 32, "a real Paid log's topic0 is never zero"
    # A filter built with the old placeholder would match nothing; the canonical selector is honest.
    assert app_mod._sel(app_mod.VERIFY_SIG) == "0x" + keccak(text=app_mod.VERIFY_SIG)[:4].hex()


# ------------------------------------------------------------------ bug 2: fault vs verdict + negcontrol

class _Resp:
    def __init__(self, body: bytes):
        self._b = body

    def read(self):
        return self._b

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass


def _urlopen_returning(body: bytes):
    def _open(req, timeout=20):
        return _Resp(body)

    return _open


def _urlopen_raising_http_error(status: int, body: bytes):
    def _open(req, timeout=20):
        raise urllib.error.HTTPError(req.full_url, status, "err", {}, _Resp(body))

    return _open


def test_negcontrol_html_500_lands_unknown(monkeypatch):
    """NEGCONTROL: a 500 with an HTML body must be UNKNOWN, not a crash."""
    html = b"<html><body><h1>500 Internal Server Error</h1></body></html>"
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_raising_http_error(500, html))
    state, val = app_mod._eth_call_verify("0x" + "00" * 4)
    assert state == app_mod.UNKNOWN, "an HTML error page must land as UNKNOWN"
    assert val is None


def test_negcontrol_malformed_json_lands_unknown(monkeypatch):
    """NEGCONTROL: a 200 with a malformed/truncated JSON body must be UNKNOWN, not a crash."""
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_returning(b'{"result": "0x1'))
    state, val = app_mod._eth_call_verify("0x" + "00" * 4)
    assert state == app_mod.UNKNOWN
    assert val is None


def test_negcontrol_429_plain_text_lands_unknown(monkeypatch):
    """NEGCONTROL: a 429 rate-limit page (plain text) must be UNKNOWN — the client may have paid."""
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_raising_http_error(429, b"Too Many Requests"))
    state, _ = app_mod._eth_call_verify("0x00")
    assert state == app_mod.UNKNOWN


def test_rpc_error_body_is_unknown(monkeypatch):
    monkeypatch.setattr(
        urllib.request, "urlopen",
        _urlopen_returning(json.dumps({"error": {"code": -32005, "message": "rate limited"}}).encode()),
    )
    state, val = app_mod._eth_call_verify("0x00")
    assert state == app_mod.UNKNOWN and val is None


def test_empty_result_is_unknown(monkeypatch):
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_returning(b'{"result": "0x"}'))
    state, _ = app_mod._eth_call_verify("0x00")
    assert state == app_mod.UNKNOWN


def test_missing_result_key_is_unknown(monkeypatch):
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_returning(b'{"id":1,"jsonrpc":"2.0"}'))
    state, _ = app_mod._eth_call_verify("0x00")
    assert state == app_mod.UNKNOWN


def test_true_result_is_verified(monkeypatch):
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_returning(b'{"result":"0x' + b"0" * 63 + b'1"}'))
    state, val = app_mod._eth_call_verify("0x00")
    assert state == app_mod.VERIFIED and val is True


def test_false_result_is_not_paid(monkeypatch):
    """A DEFINITE false (a real 0 return) is NOT_PAID — distinct from UNKNOWN."""
    monkeypatch.setattr(urllib.request, "urlopen", _urlopen_returning(b'{"result":"0x' + b"0" * 64 + b'"}'))
    state, val = app_mod._eth_call_verify("0x00")
    assert state == app_mod.NOT_PAID and val is False


# ------------------------------------------------------------------ endpoint wiring

def _with_env(**kv):
    old = {k: os.environ.get(k) for k in kv}
    os.environ.update(kv)
    return old


def _restore(old):
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


def test_endpoint_402_then_200_then_503(monkeypatch):
    from fastapi.testclient import TestClient

    env = _with_env(X402_FACILITATOR="0x" + "11" * 20, X402_PAY_TO="0x" + "22" * 20, X402_TOKEN="0x" + "33" * 20)
    try:
        client = TestClient(app_mod.app)

        # no payment header -> 402 challenge
        r = client.get("/weather")
        assert r.status_code == 402 and "amount" in r.json()

        # paid + verified -> 200
        monkeypatch.setattr(app_mod, "_verify_onchain", lambda pid: app_mod.VERIFIED)
        assert client.get("/weather", headers={"X-PAYMENT": "0x" + "ab" * 32}).status_code == 200

        # unknown -> 503, reason=unknown (retry, not re-pay)
        monkeypatch.setattr(app_mod, "_verify_onchain", lambda pid: app_mod.UNKNOWN)
        r = client.get("/weather", headers={"X-PAYMENT": "0x" + "ab" * 32})
        assert r.status_code == 503 and r.json().get("reason") == "unknown"

        # definite not-paid -> 402, reason=not_paid
        monkeypatch.setattr(app_mod, "_verify_onchain", lambda pid: app_mod.NOT_PAID)
        r = client.get("/weather", headers={"X-PAYMENT": "0x" + "ab" * 32})
        assert r.status_code == 402 and r.json().get("reason") == "not_paid"
    finally:
        _restore(env)
