// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @dev A CONTRACT that sends native with `.transfer()` — the exact sender shape that makes the
///      clone-vs-full choice load-bearing (2300 stipend < 2600 cold-delegatecall). Regression pin.
contract TransferSender {
    function send(address to) external payable {
        payable(to).transfer(msg.value);
    }
}

/// @title StreamFactory + StreamVault unit tests
/// @dev The parity pin (`predict` == actual CREATE2) is the point of the creation tests: it catches
///      any drift between off-chain derivation and the chain, the "hand-typed crypto emits
///      plausible-but-wrong output" class (GOTCHAS #5).
contract StreamVaultTest is Test {
    StreamFactory f;
    MockERC20 usdc;

    address owner = address(0x0117);
    address feeRcpt = address(0xFEE0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 constant AMT = 100_000e6;      // 100k USDC over the window
    uint256 constant FEE_BPS = 25;   // uint256 so `X ether * FEE_BPS` folds without a uint16 overflow
    uint64 START;
    uint64 END;
    uint64 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_000_000);                 // a non-zero, non-trivial clock
        START = uint64(block.timestamp);
        END = START + DURATION;

        f = new StreamFactory(owner, feeRcpt, uint16(FEE_BPS));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(alice, 10_000_000e6);
        vm.deal(alice, 10_000 ether);

        // CLEAN THE TEST ADDRESSES. When this suite is ALSO run with `--fork-url` (our house bar is
        // unit + negcontrol + FORK, and they share these literal addresses) the named addresses are
        // NOT clean on a real chain: verified live, `0x0B0b` holds 4 wei and `0xcA401` holds 1e14
        // wei on Base Sepolia. That leaked into 7 absolute-balance asserts. `vm.deal` sets an exact
        // balance (unlike a fork's inherited state), so doing it here makes EVERY assertion below
        // true on both an anvil run and a fork run — the deltas stay honest either way.
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 0);
        vm.deal(carol, 0);
        vm.deal(feeRcpt, 0);
    }

    function _mk(address payer, address rcpt, address token, uint256 amt)
        internal
        returns (address vault)
    {
        vm.startPrank(payer);
        if (token == address(0)) {
            vault = f.createStream{value: amt}(rcpt, token, amt, START, END);
        } else {
            usdc.approve(address(f), amt);
            vault = f.createStream(rcpt, token, amt, START, END);
        }
        vm.stopPrank();
    }

    // ---- creation + parity ----

    function test_createNativeFundsVault() public {
        address v = _mk(alice, bob, address(0), 10 ether);
        assertEq(v.balance, 10 ether, "vault must hold exactly the streamed amount");
        assertEq(address(f).balance, 0, "factory must hold nothing");
        StreamVault sv = StreamVault(payable(v));
        assertEq(sv.payer(), alice);
        assertEq(sv.recipient(), bob);
        assertEq(sv.amount(), 10 ether);
        assertEq(sv.withdrawn(), 0);
        assertFalse(sv.canceled());
    }

    /// @dev THE PARITY PIN. `predict` must equal the actual CREATE2 address or an integrator shows
    ///      the wrong address in the UI and funds a hole.
    function test_predictMatchesActual() public {
        address predicted = f.predict(alice, bob, address(0), 1 ether, START, END);
        address actual = _mk(alice, bob, address(0), 1 ether);
        assertEq(actual, predicted, "predict must equal actual (client-side derivation parity)");
    }

    /// @dev `amt` is a constructor arg (an immutable is written at construction), so it MUST enter
    ///      the address. Fuzzing it is the point — the non-fuzzed case above passed at `1 ether` for
    ///      the wrong reason in my first draft.
    function testFuzz_predictMatchesActual(uint96 amt, uint64 startOff, address rcpt) public {
        vm.assume(rcpt != address(0) && rcpt != alice);
        vm.assume(amt > 0);
        vm.assume(startOff <= 3650 days);
        uint64 s = uint64(block.timestamp) + startOff;
        uint64 e = s + DURATION;

        vm.deal(alice, uint256(amt));
        address predicted = f.predict(alice, rcpt, address(0), uint256(amt), s, e);
        vm.prank(alice);
        address actual = f.createStream{value: amt}(rcpt, address(0), uint256(amt), s, e);
        assertEq(actual, predicted, "parity must hold for any window, amount and recipient");
    }

    /// @dev A predict with the WRONG amount must NOT match — proves `amount` is load-bearing in the
    ///      derivation rather than incidentally agreeing.
    function test_predictWrongAmountDiverges() public {
        address right = f.predict(alice, bob, address(0), 1 ether, START, END);
        address wrong = f.predict(alice, bob, address(0), 2 ether, START, END);
        assertTrue(right != wrong, "amount must change the derived address");
    }

    function test_uniqueAddressesAcrossPayersAndNonce() public {
        address v1 = _mk(alice, bob, address(0), 1 ether);
        // NOTE: the hedge cursor makes a SAME-window re-create for the same (payer,recipient,token) a
        // replay (start < hedgeEnd). resetHedge opens a 2nd independent reel on the same window.
        vm.prank(alice);
        f.resetHedge(bob, address(0));
        address v2 = _mk(alice, bob, address(0), 1 ether);   // same payer, next nonce
        vm.deal(bob, 1 ether);
        address v3 = _mk(bob, bob, address(0), 1 ether);     // different payer
        assertTrue(v1 != v2 && v2 != v3 && v1 != v3, "every stream gets a distinct address");
    }

    function test_erc20CreatePullsFundsExactly() public {
        uint256 before = usdc.balanceOf(alice);
        address v = _mk(alice, bob, address(usdc), AMT);
        assertEq(usdc.balanceOf(v), AMT, "vault holds the full amount");
        assertEq(usdc.balanceOf(alice), before - AMT);
        assertEq(usdc.balanceOf(address(f)), 0, "factory holds nothing");
    }

    // ---- accrual curve ----

    function test_accrualZeroBeforeStart() public {
        vm.warp(START - 100);
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        assertEq(v.withdrawable(), 0, "nothing accrues before start");
        assertEq(v.streamedAt(block.timestamp), 0);
    }

    function test_accrualLinearAtMidpoint() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        assertEq(v.withdrawable(), 5 ether, "half the time == half the money");
    }

    function test_accrualCapsAtEndAndStaysFlat() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(END);
        assertEq(v.withdrawable(), 10 ether, "at end, full amount");
        vm.warp(END + 3650 days);
        assertEq(v.withdrawable(), 10 ether, "past end it must NOT keep growing");
    }

    /// @dev A stream can be created with a FUTURE start; nothing accrues until then.
    ///      NOTE the `_mk`-free construction: `_mk` uses the setUp `START`, so this test needs the
    ///      amount to be dropped here since `_mk`'s helper — it does `{value: amt}` from msg.sender.
    function test_futureStartAccruesOnlyFromStart() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        address v = f.createStream{value: 1 ether}(bob, address(0), 1 ether, START + 10 days, END + 10 days);
        assertEq(StreamVault(payable(v)).withdrawable(), 0, "no accrual before a future start");
        vm.warp(START + 10 days + 5 days);                   // 5 of the 30 streamed days elapsed
        // 5 of 30 streamed days == exactly 1/6 of the amount (1e18/6 floors in the contract too)
        assertEq(StreamVault(payable(v)).withdrawable(), uint256(1 ether) / 6, "accrues from START, not creation");
    }

    // ---- withdrawal ----

    function test_withdrawPaysRecipientMinusExactFee() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);                     // 5 ether withdrawable
        uint256 bobBefore = bob.balance;
        uint256 feeBefore = feeRcpt.balance;

        (uint256 out, uint256 fee) = v.withdraw();

        assertEq(fee, 5 ether * FEE_BPS / 10_000, "fee exactly 25 bps of withdrawable");
        assertEq(out, 5 ether - fee, "recipient gets the rest");
        assertEq(bob.balance - bobBefore, out);
        assertEq(feeRcpt.balance - feeBefore, fee);
        assertEq(v.withdrawn(), 5 ether);
        assertEq(v.withdrawable(), 0, "nothing left pullable in this block");
    }

    function test_withdrawIsPermissionless() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        uint256 bobBefore = bob.balance;

        uint256 carolBefore = carol.balance;
        vm.prank(carol);                                   // a STRANGER pulls
        v.withdraw();

        assertGt(bob.balance, bobBefore, "stranger's pull must pay the RECIPIENT, not the caller");
        assertEq(carol.balance, carolBefore, "caller is not paid (only gas)");
    }

    /// @dev The 2-arg form exists so P2's keeper `_send()` works unchanged. It must behave identically.
    function test_withdrawTwoArgFormMatchesBackdoorFreeform() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        uint256 bobBefore = bob.balance;
        (uint256 out, uint256 fee) = v.withdraw(address(0), carol);
        assertEq(fee, 5 ether * FEE_BPS / 10_000);
        assertEq(out, 5 ether - fee);
        assertEq(bob.balance - bobBefore, out, "pays recipient even when a 2nd arg is supplied");
    }

    function test_repeatedWithdrawAccruesCorrectly() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 4);
        v.withdraw();                                       // 25%
        vm.warp(START + DURATION / 2);
        v.withdraw();                                       // to 50% total
        assertEq(v.withdrawn(), 5 ether, "withdrawn tracks cumulative, not per-call");

        vm.warp(END + 1 days);
        v.withdraw();                                       // drain the rest
        assertEq(v.withdrawn(), 10 ether);
        assertEq(v.withdrawable(), 0);
    }

    function test_withdrawNothingIsNoopNotRevert() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START - 10);
        (uint256 out, uint256 fee) = v.withdraw();
        assertEq(out, 0);
        assertEq(fee, 0);
        assertEq(bob.balance, 0, "no-op must not pay anything (bob starts at exactly 0)");
    }

    /// @dev Withdrawing twice in the SAME block must not double-pay.
    function test_doubleWithdrawSameBlockIsNoop() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        (uint256 o1, ) = v.withdraw();
        (uint256 o2, ) = v.withdraw();
        assertGt(o1, 0);
        assertEq(o2, 0, "second pull in the same block pays nothing");
    }

    /// @dev END-TO-END EXACTNESS: drain a stream over its whole life and assert the recipient
    ///      received EXACTLY amount - sum(fees). Catches any accrual drift or fee leakage.
    function test_fullDrainRecipientReceivesAmountMinusFees() public {
        uint256 amt = 10 ether;
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), amt)));
        uint256 feeTotal;
        uint256 bobBefore = bob.balance;
        uint256 feeBefore = feeRcpt.balance;

        for (uint256 i = 1; i <= 10; i++) {
            vm.warp(START + (DURATION * i) / 10);
            (, uint256 f1) = v.withdraw();
            feeTotal += f1;
        }
        vm.warp(END + 1);
        (, uint256 f2) = v.withdraw();
        feeTotal += f2;

        assertEq(bob.balance - bobBefore, amt - feeTotal, "recipient total == amount - all fees");
        assertEq(feeRcpt.balance - feeBefore, feeTotal, "feeRecipient total == all fees");
        assertEq(v.withdrawn(), amt);
        assertEq(address(v).balance, 0, "vault fully drained");
    }

    /// @dev DUST: a tiny amount over a long window must not revert and must floor the fee to 0
    ///      (skipping the fee transfer). 25 bps of 100 wei is 0 wei.
    function test_dustDoesNotRevertAndFloorsFeeToZero() public {
        uint256 tiny = 100;                                  // wei-scale
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), tiny)));
        vm.warp(END);
        uint256 bobBefore = bob.balance;
        (uint256 out, uint256 fee) = v.withdraw();
        assertEq(fee, 0, "25 bps of 100 wei floors to 0");
        assertEq(out, tiny);
        assertEq(bob.balance - bobBefore, tiny, "recipient still gets everything");
    }

    function test_transferSenderStipend() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 1 ether)));
        TransferSender s = new TransferSender();
        vm.deal(address(s), 1 ether);
        (bool ok, ) = address(s).call(abi.encodeCall(TransferSender.send, (address(v))));
        assertTrue(ok, "full contract accepts a .transfer() send");
    }

    // ---- cancel ----

    function test_cancelSplitsAccruedToRecipientRestToPayer() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 4);                       // 2.5 ether accrued
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        uint256 feeBefore = feeRcpt.balance;

        vm.prank(alice);
        v.cancel();

        uint256 accrued = 2.5 ether;
        uint256 fee = accrued * FEE_BPS / 10_000;
        assertEq(bob.balance - bobBefore, accrued - fee, "recipient gets accrued minus fee");
        assertEq(feeRcpt.balance - feeBefore, fee);
        assertEq(alice.balance - aliceBefore, 10 ether - accrued, "payer refunded the UNVESTED remainder");
        assertTrue(v.canceled());
        assertEq(address(v).balance, 0, "vault fully drained on cancel");
    }

    function test_cancelBeforeStartRefundsEverythingToPayer() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + 5);                                  // ~0 accrued
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        v.cancel();
        assertEq(alice.balance - aliceBefore, 10 ether - (5 * 10 ether / DURATION), "payer gets it all back");
    }

    function test_cancelAfterPreviousWithdraw() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 4);
        v.withdraw();                                        // pull 2.5
        uint256 bobAfterPull = bob.balance;

        vm.warp(START + DURATION / 2);                       // 5 accrued total, 2.5 still owed
        vm.prank(alice);
        v.cancel();

        uint256 owed = 2.5 ether;
        uint256 fee = owed * FEE_BPS / 10_000;
        assertEq(bob.balance - bobAfterPull, owed - fee, "cancel pays only the NOT-YET-pulled part");
        assertEq(v.withdrawn(), 5 ether, "withdrawn is cumulative across pull + cancel");
    }

    function test_cancelIsPayerOnly() public {
        address v = _mk(alice, bob, address(0), 10 ether);
        vm.warp(START + DURATION / 2);
        vm.prank(carol);
        vm.expectRevert(StreamVault.NotPayer.selector);
        StreamVault(payable(v)).cancel();
    }

    function test_doubleCancelReverts() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        vm.startPrank(alice);
        v.cancel();
        vm.expectRevert(StreamVault.AlreadyCanceled.selector);
        v.cancel();
        vm.stopPrank();
    }

    /// @dev THE BUG THIS TEST EXISTS FOR: after `cancel()` empties the vault, `streamedAt(t)` keeps
    ///      growing with time (it is a pure function of `t`). A naive `withdrawable()` without a
    ///      `canceled` guard would report a fresh positive number and a later `withdraw()` would pay
    ///      out of already-refunded money. Assert the guard, and that the vault balance covers it.
    function test_withdrawAfterCancelIsNoop() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 4);
        vm.prank(alice);
        v.cancel();

        uint256 bobAfter = bob.balance;
        vm.warp(START + DURATION / 2);                       // naive streamedAt would say 5 ether
        assertEq(v.streamedAt(block.timestamp), 5 ether, "sanity: the un-guarded formula DID grow");
        assertEq(v.withdrawable(), 0, "post-cancel nothing is claimable");

        vm.prank(carol);
        (uint256 out, ) = v.withdraw();
        assertEq(out, 0, "a post-cancel pull must pay nothing");
        assertEq(bob.balance, bobAfter);
        assertEq(address(v).balance, 0, "no money invented out of an empty vault");
    }

    function test_cancelERC20Split() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(usdc), AMT)));
        vm.warp(START + DURATION / 2);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 usdcBeforeBob = usdc.balanceOf(bob);
        uint256 usdcBeforeFee = usdc.balanceOf(feeRcpt);

        vm.prank(alice);
        v.cancel();

        uint256 accrued = AMT / 2;
        uint256 fee = accrued * FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(bob) - usdcBeforeBob, accrued - fee);
        assertEq(usdc.balanceOf(feeRcpt) - usdcBeforeFee, fee);
        assertEq(usdc.balanceOf(alice) - aliceBefore, AMT - accrued, "unvested refunded in full, no fee on refund");
        assertEq(usdc.balanceOf(address(v)), 0);
    }

    // ---- guards ----

    function test_badWindowReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(StreamFactory.BadWindow.selector);
        f.createStream(bob, address(0), 1 ether, START, START);
        vm.expectRevert(StreamFactory.BadWindow.selector);
        f.createStream(bob, address(0), 1 ether, START + 1, START);
        vm.stopPrank();
    }

    function test_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(StreamFactory.ZeroArg.selector);
        f.createStream(bob, address(0), 0, START, END);
    }

    function test_wrongMsgValueReverts() public {
        vm.prank(alice);
        vm.expectRevert(StreamFactory.FundingFailed.selector);
        f.createStream{value: 2 ether}(bob, address(0), 1 ether, START, END);
    }

    function test_pausedBlocksCreation() public {
        vm.prank(owner);
        f.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(StreamFactory.Paused.selector);
        f.createStream{value: 1 ether}(bob, address(0), 1 ether, START, END);
    }

    function test_adminGuards() public {
        vm.prank(carol);
        vm.expectRevert(StreamFactory.NotOwner.selector);
        f.setFeeBps(50);

        vm.prank(owner);
        vm.expectRevert(StreamFactory.BadFee.selector);
        f.setFeeBps(501);

        // M-5: setFeeBps now STAGES. The live rate is untouched until commit, which is only legal
        // at/after the 48h ETA. (Pre-M-5 this took effect on the same tx.)
        vm.prank(owner);
        f.setFeeBps(50);
        assertEq(f.feeBps(), 25, "staged, not applied, on the set tx");
        assertEq(f.pendingFeeBps(), 50, "the pending value is recorded and readable");
        assertEq(f.feeBpsEta(), block.timestamp + f.TIMELOCK(), "eta = now + 48h");

        vm.expectRevert(StreamFactory.TimelockNotElapsed.selector);
        f.commitFeeBps();                                   // too early
        vm.warp(f.feeBpsEta());
        f.commitFeeBps();                                   // permissionless nudge at the ETA
        assertEq(f.feeBps(), 50, "applied once the 48h clock ran");
        assertEq(f.feeBpsEta(), 0, "stage cleared after commit");
    }

    /// @dev M-5: the timelock is real — a stage will NOT commit one second early, and can be canceled.
    function test_M5_commitOnlyAfterEta_cancelWorks() public {
        vm.prank(owner);
        f.setMinFee(1234);

        vm.warp(f.minFeeEta() - 1);
        vm.expectRevert(StreamFactory.TimelockNotElapsed.selector);
        f.commitMinFee();

        vm.prank(owner);
        f.cancelMinFee();
        assertEq(f.minFeeEta(), 0, "cancel clears the stage");
        vm.expectRevert(StreamFactory.NotStaged.selector);
        f.commitMinFee();                                   // nothing to commit now
        assertEq(f.minFee(), 0, "a canceled stage never landed");
    }

    /// @dev M-5: re-staging REPLACES the pending value and RESTARTS the clock (no stale-ETA surprise).
    function test_M5_restageReplacesAndRestartsClock() public {
        vm.prank(owner);
        f.setFeeBps(100);
        uint64 firstEta = f.feeBpsEta();
        vm.warp(firstEta - 1000);
        vm.prank(owner);
        f.setFeeBps(250);                                   // re-stage a DIFFERENT value
        assertEq(f.pendingFeeBps(), 250, "pending value replaced");
        assertGt(f.feeBpsEta(), firstEta, "clock restarted from the second stage");
        vm.warp(f.feeBpsEta());
        f.commitFeeBps();
        assertEq(f.feeBps(), 250, "the SECOND value is what lands");
    }

    /// @dev M-5 refinement (critic design call): re-staging the IDENTICAL value KEEPS the running
    ///      clock — a no-op touch must not push the eta out — while a value CHANGE restarts it.
    function test_M5_restageSameValueKeepsClock_changeRestarts() public {
        vm.prank(owner);
        f.setFeeBps(100);
        uint64 eta = f.feeBpsEta();

        vm.warp(eta - 10_000);
        vm.prank(owner);
        f.setFeeBps(100);                                   // same value, later touch
        assertEq(f.feeBpsEta(), eta, "same-value re-stage KEEPS the original eta (no-op cannot drift)");

        vm.warp(eta - 5_000);
        vm.prank(owner);
        f.setFeeBps(250);                                   // a real change
        assertGt(f.feeBpsEta(), eta, "a value change restarts the clock (per-value notice)");
    }

    /// @dev M-5: Ownable2Step — transferOwnership only stages; the NEW key must accept; a wrong
    ///      caller cannot accept. Protects against a typo'd one-step handoff orphaning the factory.
    function test_M5_ownershipIsTwoStep() public {
        vm.prank(owner);
        f.transferOwnership(carol);
        assertEq(f.owner(), owner, "owner unchanged until accept");
        assertEq(f.pendingOwner(), carol);

        vm.prank(bob);
        vm.expectRevert(StreamFactory.NotPendingOwner.selector);
        f.acceptOwnership();                               // only the pending owner may accept

        vm.prank(carol);
        f.acceptOwnership();
        assertEq(f.owner(), carol, "handoff completed by the new key");
        assertEq(f.pendingOwner(), address(0), "pending cleared");

        // the OLD owner is now powerless; the new one governs
        vm.prank(owner);
        vm.expectRevert(StreamFactory.NotOwner.selector);
        f.setFeeBps(1);
        vm.prank(carol);
        f.setFeeBps(1);
        assertEq(f.pendingFeeBps(), 1, "new owner's stage lands");
    }

    /// @dev A fee change applies to an EXISTING stream from the next pull, but never touches
    ///      escrowed principal — the payer's refund on cancel stays whole.
    /// @dev M-1: the toll RATE is SNAPSHOTTED at creation. A later factory fee change no longer
    ///      retro-taxes a locked stream; only NEW streams take the new rate. (Pre-M-1 this asserted
    ///      the reverse — the new bps applied to the next pull of an EXISTING stream.)
    function test_feeChangeDoesNotRetroTaxExistingStream_onlyNewStreamsTakeIt() public {
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        vm.prank(owner);
        f.setFeeBps(100);                                    // STAGE 1% -- committed below (M-5)
        vm.warp(f.feeBpsEta());
        f.commitFeeBps();                                    // now live at 100 bps
        vm.warp(START + DURATION / 2);                       // rewind to the exact half for an exact assert

        uint256 bobBefore = bob.balance;
        (, uint256 fee) = v.withdraw();
        // NOTE the operand TYPES: `uint16(FEE_BPS)` would type the literal 5e18 as uint64, and
        // 5e18*25=1.25e20 overflows uint64 -> panic 0x11. Multiplying by the uint256 FEE_BPS
        // keeps the whole expression uint256. (Same footgun the header comment warns about.)
        assertEq(fee, (5 ether * FEE_BPS) / 10_000, "EXISTING stream pays its SNAPSHOT rate (25 bps)");
        assertEq(bob.balance - bobBefore, 5 ether - fee, "payer's pull paid the recipient exactly once");

        // a NEW stream takes the new rate
        vm.deal(alice, 1 ether);
        address v2 = _mk(alice, carol, address(0), 1 ether);
        assertEq(StreamVault(payable(v2)).feeBpsSnap(), 100, "new stream snapshots the new rate");

        uint256 bobAfterPull = bob.balance;
        vm.prank(alice);
        v.cancel();
        assertEq(address(v).balance, 0, "vault drained: 5 pulled + 5 refunded == the whole 10");
        assertEq(v.withdrawn(), 5 ether, "withdrawn counts only what was PAID OUT, never the refund");
        assertEq(bob.balance, bobAfterPull, "cancel paid bob NOTHING extra - the pull already took it all");
    }

    function test_streamCountAndViews() public {
        _mk(alice, bob, address(0), 1 ether);
        _mk(alice, carol, address(0), 1 ether);
        assertEq(f.streamCount(alice), 2);

        // a SECOND (alice,bob) create on the same window is a hedge replay -> resetHedge first
        vm.prank(alice);
        f.resetHedge(bob, address(0));
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 10 ether)));
        vm.warp(START + DURATION / 2);
        (uint256 amt, uint256 wd, uint256 w, uint256 rate, uint64 t) = v.state();
        assertEq(amt, 10 ether);
        assertEq(wd, 0);
        assertEq(w, 5 ether);
        assertEq(rate, 10 ether / DURATION, "rate is wei per second");
        assertEq(t, uint64(block.timestamp));
    }

    /// @dev INDEPENDENT REFERENCE: recompute accrual in 1e18 fixed point (a different expression
    ///      from the contract's integer `* then /`) over many points and assert agreement. This is
    ///      the tooth against a precision bug that hand-written round numbers would miss.
    function testFuzz_accrualMatchesIndependentFixedPointReference(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, DURATION));
        StreamVault v = StreamVault(payable(_mk(alice, bob, address(0), 1_000_000e6)));
        vm.warp(START + elapsed);

        uint256 ref = (uint256(1_000_000e6) * 1e18 * elapsed) / (uint256(DURATION) * 1e18);
        if (elapsed >= DURATION) ref = 1_000_000e6;
        assertEq(v.withdrawable(), ref, "accrual must match an independent fixed-point reference");
    }
}
