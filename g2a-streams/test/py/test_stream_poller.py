#!/usr/bin/env python3
"""Unit + NEGCONTROL tests for the G2-a daemon pillar 4 (keeper/stream_poller.py).

House bar (fleet rule 5): unit + negcontrol before any claim of done. The poller is PURE (no RPC),
so it is tested directly and deterministically — no mock chain needed.

The negcontrol here follows GOTCHAS #62: a negcontrol must drive the REAL path, not a restatement.
So each NC deploys a MUTANT of the decision (a rival function with one plausible bug) and asserts it
DIFFERS from the real one on a case chosen to expose exactly that bug. A mutant that agrees on every
input proves nothing.

Run:  python3 -I -m pytest test/py/test_stream_poller.py -q
  or  python3 -I test/py/test_stream_poller.py        (stdlib unittest runner)
"""
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_KEEPER = os.path.normpath(os.path.join(_HERE, "..", "..", "keeper"))
sys.path.insert(0, _KEEPER)

import stream_poller as sp  # noqa: E402

# A representative native stream: 1 ETH over 30 days, starting at T0.
T0 = 1_000_000
DUR = 30 * 24 * 3600
AMOUNT = 10**18
END = T0 + DUR
GAS_COST = 77_204 * 6_000_000      # 77,204 gas @ 0.006 gwei, in wei (SCOPE §4 measured pull)
FEE_BPS = 25
KAPPA = 10


class Unit(unittest.TestCase):

    # ---- threshold_for ------------------------------------------------------
    def test_threshold_formula(self):
        # w·bps/1e4 >= kappa·gas  ->  w >= kappa·gas·1e4/bps
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        self.assertEqual(th, KAPPA * GAS_COST * 10_000 // FEE_BPS)
        assert th == 1_852_896_000_000_000, th    # 0.001852896 ETH — pin the exact number

    def test_threshold_fee_free_when_bps_zero(self):
        # bps=0 -> no fee -> any nonzero pull is "worth it"; threshold must be 0 (not div-by-zero).
        self.assertEqual(sp.threshold_for(GAS_COST, 0, KAPPA), 0)

    def test_threshold_scales_linearly_with_kappa(self):
        a = sp.threshold_for(GAS_COST, FEE_BPS, 10)
        b = sp.threshold_for(GAS_COST, FEE_BPS, 100)
        self.assertEqual(b, a * 10)

    # ---- next_pull_at -------------------------------------------------------
    def test_next_pull_at_matches_hand_computation(self):
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        t = sp.next_pull_at(AMOUNT, T0, END, 0, th)
        # accrual(t) = AMOUNT·(t-T0)/DUR >= th  ->  t-T0 >= th·DUR/AMOUNT
        expect = T0 + -(-(th * DUR) // AMOUNT)
        self.assertEqual(t, expect)
        assert t - T0 == 4803, t - T0            # ~80 min: matches SCOPE §4's $3k/mo figure

    def test_next_pull_at_is_earliest_crossing(self):
        """At t-1 the accrual is BELOW the threshold; at t it is AT/ABOVE. This is the boundary the
        whole feature hinges on, so assert both sides rather than trusting the arithmetic."""
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        t = sp.next_pull_at(AMOUNT, T0, END, 0, th)
        below = AMOUNT * (t - 1 - T0) // DUR
        at = AMOUNT * (t - T0) // DUR
        self.assertLess(below, th)
        self.assertGreaterEqual(at, th)

    def test_next_pull_at_capped_at_end(self):
        """A dust stream whose whole amount is under the threshold must not compute a t past `end`
        and then never fire. It caps at `end` so post-end is ALWAYS due."""
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        tiny = th // 2
        self.assertEqual(sp.next_pull_at(tiny, T0, END, 0, th), END)

    def test_next_pull_at_accounts_for_already_withdrawn(self):
        """With `withdrawn` already at half, only (threshold) more must accrue — the solve uses
        withdrawn+threshold, so the second pull is further out than the first."""
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        first = sp.next_pull_at(AMOUNT, T0, END, 0, th)
        second = sp.next_pull_at(AMOUNT, T0, END, AMOUNT // 2, th)
        self.assertGreater(second, first)

    # ---- should_pull: the two independent gates ----------------------------
    def test_should_pull_requires_both_gates(self):
        self.assertEqual(sp.should_pull(T0 + 10**6, T0, 10**18), (True, "due"))
        self.assertEqual(sp.should_pull(T0, T0 + 10, 10**18), (False, "not-due"))
        # NC-relevant: due time passed but NOTHING accrued -> must not pull (this is the
        # "not waste gas" gate from the work order).
        self.assertEqual(sp.should_pull(T0 + 10**6, T0, 0), (False, "zero-accrual"))

    def test_zero_accrual_and_not_due_both_reported(self):
        ok, why = sp.should_pull(T0, T0 + 10, 0)
        self.assertFalse(ok)
        self.assertEqual(why, "zero-accrual")   # zero-accrual is checked first

    # ---- plan_pull end to end ----------------------------------------------
    def test_plan_pull_before_and_after_due(self):
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        due = sp.next_pull_at(AMOUNT, T0, END, 0, th)
        before = sp.plan_pull(due - 1, AMOUNT, T0, END, 0, AMOUNT * (due - 1 - T0) // DUR,
                              GAS_COST, FEE_BPS, KAPPA)
        after = sp.plan_pull(due, AMOUNT, T0, END, 0, AMOUNT * (due - T0) // DUR,
                             GAS_COST, FEE_BPS, KAPPA)
        self.assertFalse(before["should"])
        self.assertTrue(after["should"])
        self.assertEqual(before["due_at"], after["due_at"])

    def test_plan_pull_after_cancel_is_noop(self):
        """A canceled vault reports withdrawable()==0 forever (the vault's cancel guard). The poller
        must therefore be silent on it — no gating needed in the daemon."""
        pl = sp.plan_pull(END + 10**6, AMOUNT, T0, END, AMOUNT, 0, GAS_COST, FEE_BPS, KAPPA)
        self.assertFalse(pl["should"])
        self.assertEqual(pl["reason"], "zero-accrual")

    # ---- discovery ----------------------------------------------------------
    def test_discover_stream_decodes_a_real_shaped_log(self):
        # Shape copied from the LIVE Sepolia StreamCreated (tx 0x0c056eef…, blk 54978781):
        # topics [sig, payer, recipient, vault], data [token, amount, start, end, salt, index].
        payer = "0x85c6764d55d647663e19465fde80df58638bbed6"
        recip = "0x0000000000000000000000000000000000000b0b"
        vault = "0x97a7c0d5e99f6eb6afd2fb0ddd322e98bda29f75"
        data = ("0x" + "0" * 64 + "9184e72a000".rjust(64, "0") +
                hex(0x6aed023f)[2:].rjust(64, "0") + hex(0x6aed032f)[2:].rjust(64, "0") +
                "ab" * 32 + "0" * 64)
        log = dict(topics=[sp.TOPIC_STREAM_CREATED,
                           "0x" + payer[2:].rjust(64, "0"),
                           "0x" + recip[2:].rjust(64, "0"),
                           "0x" + vault[2:].rjust(64, "0")], data=data)
        st = sp.discover_stream(log)
        self.assertIsNotNone(st)
        self.assertEqual(st["vault"], vault)
        self.assertEqual(st["recipient"], sp.addr_from_topic(log["topics"][2]))
        self.assertEqual(st["amount"], 0x9184e72a000)

    def test_discover_stream_rejects_wrong_topic(self):
        log = dict(topics=["0xdeadbeef" + "0" * 56, "0" * 64, "0" * 64, "0" * 64], data="0x" + "0" * 256)
        self.assertIsNone(sp.discover_stream(log))

    def test_discover_stream_rejects_short_data(self):
        log = dict(topics=[sp.TOPIC_STREAM_CREATED, "0" * 64, "0" * 64, "0" * 64], data="0x" + "0" * 64)
        self.assertIsNone(sp.discover_stream(log))

    # ---- helpers ------------------------------------------------------------
    def test_parse_registries_dedupes_and_preserves_order(self):
        self.assertEqual(sp.parse_registries(" a , b ,a, c "), ["a", "b", "c"])
        self.assertEqual(sp.parse_registries(""), [])
        self.assertEqual(sp.parse_registries(None), [])

    def test_token_word_native_and_erc20(self):
        self.assertEqual(sp.token_word("native"), "0" * 64)
        self.assertEqual(sp.token_word(sp.ZERO_ADDR), "0" * 64)
        w = sp.token_word("0x" + "ab" * 20)
        self.assertEqual(len(w), 64)
        self.assertTrue(w.endswith("ab" * 20))

    def test_ceil_div(self):
        self.assertEqual(sp._ceil_div(10, 3), 4)
        self.assertEqual(sp._ceil_div(9, 3), 3)


# ===========================================================================
# NEGCONTROLS — rivals with one plausible bug each; each MUST differ on a
# case built to expose precisely that bug (GOTCHAS #62).
# ===========================================================================
class NegControls(unittest.TestCase):

    def test_nc1_unguarded_withdrawable_repulls_a_canceled_stream(self):
        """NC1: drop the `withdrawable > 0` gate (an event-driven mindset: 'the time passed, pull').
        A canceled/zero-accrual vault, past due, WOULD be pulled -> wasted-gas call. The real
        decision must differ."""
        def mutant(now, due_at, withdrawable):
            return int(now) >= int(due_at)          # no zero-accrual gate
        now, due, w = T0 + 10**6, T0, 0
        self.assertTrue(mutant(now, due, w))
        self.assertFalse(sp.should_pull(now, due, w)[0])

    def test_nc2_unguarded_pulls_before_due(self):
        """NC2: drop the due-time gate (pull every tick). Before due it fires; the real one waits."""
        def mutant(now, due_at, withdrawable):
            return int(withdrawable) > 0            # no time gate
        now, due, w = T0, T0 + 10_000, 10**18
        self.assertTrue(mutant(now, due, w))
        self.assertFalse(sp.should_pull(now, due, w)[0])

    def test_nc3_first_divide_drifts_the_boundary(self):
        """NC3: compute t as start + (need*dur/amount) with FLOOR instead of CEIL — a classic
        off-by-one that pulls one second EARLY, i.e. below the fee margin. Must differ at the
        exact boundary."""
        def mutant(amount, start, end, withdrawn, threshold):
            dur = end - start
            return start + ((withdrawn + threshold) * dur // amount)
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        real = sp.next_pull_at(AMOUNT, T0, END, 0, th)
        mut = mutant(AMOUNT, T0, END, 0, th)
        self.assertNotEqual(mut, real)
        self.assertLess(mut, real)                  # floor is early, exactly one unit or more
        # and the mutant really is below the bar at its own chosen time:
        self.assertLess(AMOUNT * (mut - T0) // DUR, th)

    def test_nc4_off_by_one_in_threshold_moves_boundary(self):
        """NC4: threshold off by one wei. Subtle — many inputs agree; own the case that exposes it."""
        def mutant(gas, bps, k):
            return (int(k) * int(gas) * 10_000) // int(bps) + 1
        real = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        self.assertEqual(mutant(GAS_COST, FEE_BPS, KAPPA), real + 1)
        # the +1 must be able to move next_pull_at on SOME amount (it does not always, which is the
        # point: a test that always differs would not prove subtlety).
        t_real = sp.next_pull_at(AMOUNT, T0, END, 0, real)
        t_mut = sp.next_pull_at(AMOUNT, T0, END, 0, mutant(GAS_COST, FEE_BPS, KAPPA))
        self.assertGreaterEqual(t_mut, t_real)

    def test_nc5_div_by_zero_when_fee_bps_zero(self):
        """NC5: a naive threshold divides by bps unconditionally -> ZeroDivisionError at bps=0 (the
        fee-free case the contract permits: setFeeBps(0)). The real one returns 0."""
        def mutant(gas, bps, k):
            return (int(k) * int(gas) * 10_000) // int(bps)   # crashes at 0
        with self.assertRaises(ZeroDivisionError):
            mutant(GAS_COST, 0, KAPPA)
        self.assertEqual(sp.threshold_for(GAS_COST, 0, KAPPA), 0)

    def test_nc6_not_capped_at_end_never_fires_for_dust(self):
        """NC6: omit the `min(.., end)` cap. A dust stream computes t > end and, combined with a
        `now >= due` gate, would look not-due FOREVER — the abandoned-stream leak."""
        def mutant(amount, start, end, withdrawn, threshold):
            dur = end - start
            return start + sp._ceil_div((withdrawn + threshold) * dur, amount)   # no cap
        th = sp.threshold_for(GAS_COST, FEE_BPS, KAPPA)
        tiny = th // 2
        self.assertGreater(mutant(tiny, T0, END, 0, th), END)
        self.assertEqual(sp.next_pull_at(tiny, T0, END, 0, th), END)


class UnitTokenUnits(unittest.TestCase):
    """THE ERC20 UNIT BUG (found live on Base 2026-11-07).

    `threshold_for` compares its result against `withdrawable`, which is in the STREAM TOKEN's smallest
    unit. The daemon's gas basis is NATIVE wei. For native streams those coincide. For an ERC20 they do
    NOT: wei vs 6-dec USDC differ by ~1e12, so the bar lands ~1e12 too high, exceeds the whole stream
    amount, and `next_pull_at` caps due_at to `end` — the poller then never settles mid-stream, only at
    the very end. Live proof: two 6-dec USDC base vaults, amount=500000 (0.5 USDC) vs bar 1.85e15."""

    # live base numbers: 77,204 gas @ 0.006 gwei, ETH ~$3400, USDC ~$1
    GAS_WEI = 77_204 * 6_000_000
    ETH_USD_E6 = 3_400_000_000
    USDC_USD_E6 = 1_000_000
    USDC_DEC = 6

    def test_conversion_is_the_right_magnitude(self):
        out = sp.gas_cost_in_token_units(self.GAS_WEI, self.USDC_DEC, self.ETH_USD_E6, self.USDC_USD_E6)
        # 4.63e11 wei / 1e12 (scale) * 3400 = ~1575 USDC-units = ~$0.0016 of gas — sane.
        self.assertTrue(1000 < out < 2000, out)
        # and the resulting bar is a FEW USDC, not more than a 0.5 USDC stream
        bar = sp.threshold_for(out, FEE_BPS, KAPPA)
        self.assertTrue(bar < 50_000_000, bar)        # < 50 USDC
        self.assertGreater(bar, 0)

    def test_wei_bar_would_swallow_a_real_stream_midstream(self):
        """The bug, stated as the failure it causes: with the wei bar, a 120-second 100 USDC stream
        can only ever be pulled at `end`; with the converted bar it is due mid-stream."""
        amount, start = 100 * 10**6, 1_794_079_759     # 100 USDC, 6-dec
        end = start + 120
        wei_bar = sp.threshold_for(self.GAS_WEI, FEE_BPS, KAPPA)
        tok_bar = sp.threshold_for(
            sp.gas_cost_in_token_units(self.GAS_WEI, self.USDC_DEC, self.ETH_USD_E6, self.USDC_USD_E6),
            FEE_BPS, KAPPA)
        self.assertEqual(sp.next_pull_at(amount, start, end, 0, wei_bar), end, "wei bar -> END only")
        self.assertLess(sp.next_pull_at(amount, start, end, 0, tok_bar), end, "token bar -> mid-stream")

    def test_nc7_nc_the_old_native_only_path(self):
        """NC7 (negcontrol): the REAL fix must differ from the pre-fix (pass-wei) behaviour on an
        ERC20 case, and AGREE with it on a native case (native gas IS wei, so conversion is a no-op).
        A fix that changed native behaviour too would be its own bug."""
        # native: decimals 18, native/token price ratio 1 -> conversion is identity
        self.assertEqual(sp.gas_cost_in_token_units(self.GAS_WEI, 18, 1_000_000, 1_000_000), self.GAS_WEI)
        # erc20 6-dec $1 token against $3400 native -> differs from pass-through by ~1e8+ (the
        # 1e12 scale AND the ~$3400 price ratio combine; ~2.9e8 measured)
        conv = sp.gas_cost_in_token_units(self.GAS_WEI, 6, self.ETH_USD_E6, self.USDC_USD_E6)
        self.assertNotEqual(conv, self.GAS_WEI)
        self.assertGreater(self.GAS_WEI // conv, 10**8)

    def test_nc8_nc_unknown_price_falls_back_to_wei(self):
        """NC8: an untabulated token (no price) must FALL BACK to the raw wei, not invent a ratio and
        silently over- or under-state the bar."""
        self.assertEqual(sp.gas_cost_in_token_units(self.GAS_WEI, 6, 0, 0), self.GAS_WEI)
        self.assertEqual(sp.gas_cost_in_token_units(self.GAS_WEI, 6, None, None), self.GAS_WEI)


if __name__ == "__main__":
    unittest.main(verbosity=2)
