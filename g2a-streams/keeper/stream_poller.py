#!/usr/bin/env python3
"""stream_poller.py — G2-a daemon pillar 4: the STANDING-STATE poller for StreamVaults.

WHY THIS EXISTS (the load-bearing catch, stated plainly)
  P2's daemon is EVENT-DRIVEN: it watches a Deposit log and forwards. A stream is funded ONCE, so an
  event-driven watcher would fire one useless pull at t≈0 and then go silent while value accrued for
  months — because **accrual emits no event**. Eligibility is a standing STATE (GOTCHAS #39/#48/#65).
  So the fix is not a new event; it is a POLLER that recomputes, locally, when each vault next
  crosses the fee-worth margin and calls withdrawable() then.

  This module is PURE (no RPC, no I/O) so it is unit-testable and so the daemon's loop stays thin.
  The daemon supplies a `state()` read per known vault and this decides pull / wait.

DISCOVERY (also corrected against the chain, not assumed)
  The vault's constructor emits `Registered` — so that log's ADDRESS is the VAULT, not the factory.
  P2's daemon filters `Registered` by `--registry` (the Registry address, which DOES emit its own
  Registered per forwarder). Pointed at a StreamFactory that filter finds NOTHING (verified on
  Sepolia: empty). The factory emits its OWN `StreamCreated(payer,recipient,vault,...)` at the
  FACTORY address, which IS address-filterable — that is the clean discovery feed for vaults.
  `discover_stream()` decodes it; both maps (forwarders via Registered, vaults via StreamCreated)
  ride the same tick.

THE MARGIN (SCOPE §4, unchanged)
  Pull when `withdrawable >= κ × gas_cost × 10_000 / feeBps`. κ defaults to 10, so the fee is 10×
  the gas — gas is a constant 0.025% of value moved, independent of stream size. gas_cost is in the
  STREAM'S token smallest-unit for native; for ERC20 it is the caller's job to convert (v1 uses the
  native gas cost as the conservative placeholder and SAYS SO — flagged, not hidden).
"""
import argparse  # noqa: F401  (re-exported convenience for the daemon's arg wiring)

ZERO_ADDR = "0x" + "0" * 40


# ---------------------------------------------------------------------------
# small pure helpers
# ---------------------------------------------------------------------------
def addr_from_topic(t):
    """20-byte address from a 32-byte log topic."""
    return "0x" + t[-40:]


def parse_registries(arg):
    """Comma-list -> ordered, de-duped, non-empty address list. One watch target -> many.

    WHY: a stream's discovery feed is a SECOND address (the factory); the daemon already takes
    `--registry` for P2's Registry. Rather than a parallel flag, `--registry` takes a comma-list so
    one run watches every target. Order preserved; duplicates dropped (a factory listed twice must
    not double-scan)."""
    if not arg:
        return []
    out = []
    for part in str(arg).split(","):
        a = part.strip()
        if a and a not in out:
            out.append(a)
    return out


def threshold_for(gas_cost, fee_bps, kappa):
    """Smallest withdrawable worth a pull: fee (= w·bps/1e4) must be >= κ·gas_cost.

    Solve w·bps/1e4 >= κ·gas  ->  w >= κ·gas·1e4/bps. Floor (never overstate the bar).
    Returns 0 when fee_bps is 0 (every nonzero pull is fee-free-worth).

    UNIT CONTRACT (the load-bearing one): `gas_cost` MUST be in the SAME units as the `withdrawable`
    it will be compared against — i.e. the STREAM TOKEN's smallest unit. For a NATIVE stream that is
    wei, and the daemon already computes gas as wei·gasPrice, so native is correct as-is. For an
    ERC20 stream it is NOT: native wei and 6-dec USDC units differ by ~1e12, so passing wei here
    inflates the bar until it exceeds the whole amount and `next_pull_at` caps due_at to `end` — the
    poller then only ever settles at stream END and never mid-stream. Use
    `gas_cost_in_token_units` to convert before calling this for an ERC20."""
    if fee_bps <= 0:
        return 0
    return (int(kappa) * int(gas_cost) * 10_000) // int(fee_bps)


def gas_cost_in_token_units(gas_native_wei, token_decimals, native_usd_e6, token_usd_e6):
    """Convert a NATIVE-wei gas cost into a stream TOKEN's smallest units, so it is comparable to
    `withdrawable` (SCOPE §4). Integer-only (no float drift).

    gas_token = gas_wei · (native_usd / token_usd) / 10^(18 - token_decimals)
              = gas_wei · native_usd_e6 // token_usd_e6 // 10^(18 - dec)

    For USDC (dec 6, ~$1) against $3400 native: 4.63e11 wei -> ~1575 USDC-units (~$0.0016 of gas),
    i.e. the true ~2× the gas bar is a few USDC, NOT 1.85e15 the whole-stream bar the wei form gave.
    Falls back to the raw native wei (flagged by the caller) when a price is unknown, matching the
    pre-fix behaviour for an untabulated token rather than inventing a ratio."""
    try:
        g = int(gas_native_wei)
        if not native_usd_e6 or not token_usd_e6:
            return g
        dec = int(token_decimals)
        if dec < 0 or dec > 36:
            return g
        out = (g * int(native_usd_e6)) // int(token_usd_e6)
        if dec < 18:
            out //= 10 ** (18 - dec)
        else:
            out *= 10 ** (dec - 18)
        return out
    except Exception:
        return int(gas_native_wei)


def _ceil_div(n, d):
    return -(-int(n) // int(d))


def next_pull_at(amount, start, end, withdrawn, threshold):
    """Earliest timestamp at which accrual-minus-paid-out first reaches `threshold`, capped at `end`.

    accrual streamedAt(t) = amount·(t-start)/duration, so we solve
        streamedAt(t) - withdrawn >= threshold  ->  t = start + ceil((withdrawn+threshold)·dur/amount)
    CAP AT `end`: past the end nothing more accrues, so a stream whose whole amount is under the
    threshold would otherwise compute a t beyond `end` and never fire. Capping makes post-end
    ALWAYS due — an abandoned/expired stream still gets settled."""
    amount = int(amount)
    start = int(start)
    end = int(end)
    if amount <= 0 or end <= start:
        return end
    dur = end - start
    need = int(withdrawn) + int(threshold)
    if need <= 0:
        return start
    if need >= amount:
        return end                      # cannot reach the threshold before the stream ends
    t = start + _ceil_div(need * dur, amount)
    return min(t, end)


def should_pull(now, due_at, withdrawable):
    """THE decision. Two independent gates, both required:
      1. `withdrawable > 0` — never spend gas on a zero-accrual (or already-drained, or canceled)
         vault. This is the "must not waste gas" gate.
      2. `now >= due_at` — the fee-margin/time gate. Below it, accrued dust waits.
    Returns (bool, reason) so the daemon's log says WHY, not just that."""
    if int(withdrawable) <= 0:
        return False, "zero-accrual"
    if int(now) < int(due_at):
        return False, "not-due"
    return True, "due"


def plan_pull(now, amount, start, end, withdrawn, withdrawable, gas_cost, fee_bps, kappa):
    """Full per-vault decision from a `state()` read. Pure; the daemon's loop is a thin wrapper."""
    th = threshold_for(gas_cost, fee_bps, kappa)
    due_at = next_pull_at(amount, start, end, withdrawn, th)
    ok, reason = should_pull(now, due_at, withdrawable)
    return dict(should=ok, reason=reason, due_at=due_at, threshold=th)


# ---------------------------------------------------------------------------
# discovery: decode the factory's StreamCreated feed
# ---------------------------------------------------------------------------
# StreamCreated(address indexed payer, address indexed recipient, address indexed vault,
#               address token, uint256 amount, uint64 start, uint64 end, bytes32 salt, uint256 index)
# topics: [sig, payer, recipient, vault]   data: token, amount, start, end, salt, index
TOPIC_STREAM_CREATED = "0xa844bb0b1151841641a3ce5a94169e016356d1b1be5d6cace67723c5b9eeb173"


def discover_stream(log):
    """One StreamCreated log -> dict(vault, recipient, token, amount, start, end). None if malformed.

    topics[2] = recipient, topics[3] = vault (both indexed in the event). data[0:32]=token,
    data[32:64]=amount, data[64:96]=start, data[96:128]=end (all 32-byte ABI words)."""
    try:
        topics = log["topics"]
        if len(topics) < 4 or topics[0].lower() != TOPIC_STREAM_CREATED:
            return None
        data = log["data"]
        if data.startswith("0x"):
            data = data[2:]
        words = [data[i:i + 64] for i in range(0, len(data), 64)]
        if len(words) < 4:
            return None
        return dict(
            vault=addr_from_topic(topics[3]).lower(),
            recipient=addr_from_topic(topics[2]),
            token="0x" + words[0][-40:],              # address(0) == native
            amount=int(words[1], 16),
            start=int(words[2], 16),
            end=int(words[3], 16),
        )
    except Exception:
        return None


def token_word(token):
    """'native' / address -> 32-byte ABI word for the daemon's _send(token_word, depositor) calldata.
    The vault's forward(address,address) IGNORES both words, but the ledger line needs the token."""
    if not token or token == ZERO_ADDR or token == "native":
        return "0" * 64
    a = token[2:] if token.startswith("0x") else token
    return a.rjust(64, "0")


if __name__ == "__main__":
    # tiny self-check / demo of the pure decision (no RPC)
    p = argparse.ArgumentParser()
    p.add_argument("--gas-cost", type=int, default=77_204 * 6_000_000)  # 77k gas @ 0.006 gwei (wei)
    p.add_argument("--fee-bps", type=int, default=25)
    p.add_argument("--kappa", type=int, default=10)
    a = p.parse_args()
    th = threshold_for(a.gas_cost, a.fee_bps, a.kappa)
    print(f"threshold = {th} token-units (kappa={a.kappa}, gas_cost={a.gas_cost}, fee_bps={a.fee_bps})")
    # a $3000/mo-ish native stream: 1e18/30d rate, 30-day window
    amount, start = 10**18, 1_000_000
    end = start + 30 * 24 * 3600
    dur = end - start
    for poll in (0, 60, 3600, 4802, 4803, 20 * 3600):
        t = start + poll
        streamed = 0 if t <= start else (amount if t >= end else amount * (t - start) // dur)
        pl = plan_pull(t, amount, start, end, 0, streamed, a.gas_cost, a.fee_bps, a.kappa)
        print(f"  now=start+{poll:>6}s  withdrawable={streamed:>21}  due_at=+{pl['due_at']-start}s  "
              f"should={pl['should']} ({pl['reason']})")
