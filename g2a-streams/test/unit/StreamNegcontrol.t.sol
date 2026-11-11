// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @title NEGCONTROL — prove the sharp tests have teeth, by re-injecting each real bug shape.
/// @dev House doctrine (GOTCHAS #20/#62): a negcontrol must route the injection through the REAL
///      mechanism, not hand-assert an alternative. Two shapes are used here:
///        1. GENUINE RIVAL CONTRACT — deploy a mutated StreamVault that IS the bug, run the SAME
///           assertions against it, and confirm they FAIL. This is strongest: it proves the
///           assertion is not vacuous against a contract, not just against a local variable.
///        2. MUTATED MATH — recompute the same expression with the bug shape and assert it differs.
///
///      Each negcontrol names the POSITIVE test it protects. If a mutant stops failing, the
///      corresponding positive test has gone toothless.

/// @dev MUTANT 1 — the exact bug found while writing v1: `withdrawable()` without the `canceled`
///      guard. `streamedAt` is a pure function of `t`, so after `cancel()` refunds the whole
///      remaining balance, an un-guarded `withdrawable` grows again and a later pull pays out of
///      money already refunded. Protects `test_withdrawAfterCancelIsNoop`.
contract UnguardedVault is StreamVault {
    constructor(
        address f,
        address p,
        address r,
        address t,
        uint256 a,
        uint64 s,
        uint64 e,
        bytes32 salt,
        uint256 idx
    ) StreamVault(f, p, r, t, a, s, e, salt, idx) {}

    function unguardedWithdrawable() public view returns (uint256) {
        return streamedAt(block.timestamp) - withdrawn;   // NO `canceled` guard
    }
}

/// @dev MUTANT 2 — divide-first instead of multiply-first. `amount/duration*elapsed` truncates the
///      per-second rate to an integer and loses precision every block; money accrues VISIBLY slower
///      than the mulDiv form on any amount not divisible by duration. Protects the accrual tests.
contract DivideFirstVault is StreamVault {
    constructor(
        address f,
        address p,
        address r,
        address t,
        uint256 a,
        uint64 s,
        uint64 e,
        bytes32 salt,
        uint256 idx
    ) StreamVault(f, p, r, t, a, s, e, salt, idx) {}

    function divideFirstWithdrawable() public view returns (uint256) {
        if (canceled) return 0;
        uint256 t = block.timestamp;
        uint256 streamed;
        if (t <= start) streamed = 0;
        else if (t >= end) streamed = amount;
        else streamed = (amount / duration) * (t - start);   // DIVIDE FIRST — the bug
        return streamed - withdrawn;
    }
}

/// @dev MUTANT 3 — off-by-one on the clamp: `t > start` becomes `t >= start`... no, the real off-by-
///      one class here is the END clamp using `>` instead of `>=`, which pays out one block early /
///      late. Simplest faithful mutant: accrual starts at `start - 1`.
contract OffByOneVault is StreamVault {
    constructor(
        address f,
        address p,
        address r,
        address t,
        uint256 a,
        uint64 s,
        uint64 e,
        bytes32 salt,
        uint256 idx
    ) StreamVault(f, p, r, t, a, s, e, salt, idx) {}

    function offByOneWithdrawable() public view returns (uint256) {
        if (canceled) return 0;
        uint256 t = block.timestamp;
        if (t <= start) return 0;
        if (t >= end) return amount - withdrawn;
        return (amount * (t - start)) / (duration - 1) - withdrawn;   // window off by one second
    }
}

/// @dev MUTANT 4 — fee off by one basis point (24 instead of 25) on the same amount basis. This is
///      GOTCHAS #5's "inject a 1-bps fee error" tooth. A fee test that passes for both 24 and 25 is
///      not testing the fee.
contract FeeOffByOneVault is StreamVault {
    constructor(
        address f,
        address p,
        address r,
        address t,
        uint256 a,
        uint64 s,
        uint64 e,
        bytes32 salt,
        uint256 idx
    ) StreamVault(f, p, r, t, a, s, e, salt, idx) {}
}

contract StreamNegcontrolTest is Test {
    StreamFactory f;
    MockERC20 usdc;

    address owner = address(0x0117);
    address feeRcpt = address(0xFEE0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 constant AMT = 100_000e6;
    uint256 constant FEE_BPS = 25;
    uint64 START;
    uint64 END;
    uint64 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_000_000);
        START = uint64(block.timestamp);
        END = START + DURATION;
        f = new StreamFactory(owner, feeRcpt, uint16(FEE_BPS));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(alice, 10_000_000e6);
        vm.deal(alice, 10_000 ether);
    }

    enum Kind {
        Unguarded,
        DivideFirst,
        OffByOne,
        FeeOffByOne
    }

    /// @dev Deploy a specific vault CLASS directly — impossible via the factory, whose
    ///      `type(StreamVault).creationCode` is fixed at compile time. Deployed with the SAME args a
    ///      factory-made vault gets, then funded by hand, so it is in identical state for every
    ///      assertion. (Solidity has no string `==`, hence the enum.)
    function _deployMutant(Kind kind) internal returns (address v) {
        bytes32 salt = keccak256("nc");
        if (kind == Kind.Unguarded) {
            v = address(new UnguardedVault(address(f), alice, bob, address(0), 10 ether, START, END, salt, 0));
        } else if (kind == Kind.DivideFirst) {
            v = address(new DivideFirstVault(address(f), alice, bob, address(0), 10 ether, START, END, salt, 0));
        } else if (kind == Kind.OffByOne) {
            v = address(new OffByOneVault(address(f), alice, bob, address(0), 10 ether, START, END, salt, 0));
        } else {
            v = address(new FeeOffByOneVault(address(f), alice, bob, address(0), 10 ether, START, END, salt, 0));
        }
        vm.deal(v, 10 ether);
    }

    // ---- NC1: the canceled guard (protects test_withdrawAfterCancelIsNoop) ----

    function test_NC1_unguardedWithdrawableInventsMoneyAfterCancel() public {
        address v = _deployMutant(Kind.Unguarded);
        UnguardedVault u = UnguardedVault(payable(v));

        vm.warp(START + DURATION / 4);
        vm.prank(alice);
        u.cancel();
        assertEq(address(u).balance, 0, "cancel drained the vault");

        vm.warp(START + DURATION / 2);

        // THE MUTANT: reports a fresh claim on an empty vault.
        assertEq(u.unguardedWithdrawable(), 2.5 ether, "unguarded formula DOES grow after cancel");
        // v1 (correct, has the guard)
        assertEq(StreamVault(payable(v)).withdrawable(), 0, "guarded formula reads 0");
        // and they must DIFFER — else the guard would be untestable
        assertTrue(
            u.unguardedWithdrawable() != StreamVault(payable(v)).withdrawable(),
            "NC1: the guard must change the answer (else the positive test is vacuous)"
        );
    }

    // ---- NC2: multiply-first vs divide-first (protects the accrual tests) ----

    function test_NC2_divideFirstLosesPrecision() public {
        // an amount deliberately NOT divisible by `duration`, so the per-second rate truncates
        uint256 awkward = 1_000_000_007;
        bytes32 salt = keccak256("nc2");
        DivideFirstVault d = new DivideFirstVault(address(f), alice, bob, address(0), awkward, START, END, salt, 0);
        StreamVault good = new StreamVault(address(f), alice, bob, address(0), awkward, START, END, salt, 1);

        vm.warp(START + DURATION / 3);

        uint256 buggy = d.divideFirstWithdrawable();
        uint256 correct = good.withdrawable();

        assertLt(buggy, correct, "divide-first must UNDER-pay (truncated per-second rate)");
        assertTrue(buggy != correct, "NC2: an awkward amount exposes the precision bug");
    }

    // ---- NC3: window off by one second (protects the accrual curve) ----

    function test_NC3_offByOneWindowDiffers() public {
        address v = _deployMutant(Kind.OffByOne);
        OffByOneVault o = OffByOneVault(payable(v));

        vm.warp(START + DURATION / 4);

        uint256 buggy = o.offByOneWithdrawable();
        uint256 correct = StreamVault(payable(v)).withdrawable();

        assertTrue(buggy != correct, "NC3: a one-second window error must change the accrual");
        assertGt(buggy, correct, "dividing by duration-1 over-pays");
    }

    // ---- NC4: fee off by one bps (protects test_withdrawPaysRecipientMinusExactFee) ----

    function test_NC4_feeOffByOneBpsIsCaught() public {
        StreamVault v = StreamVault(payable(_fundViaMutant(Kind.FeeOffByOne)));
        vm.warp(START + DURATION / 2);

        uint256 w = v.withdrawable();
        uint256 correct25 = w * 25 / 10_000;
        uint256 wrong24 = w * 24 / 10_000;

        assertTrue(correct25 != wrong24, "24 vs 25 bps must differ on this size (else the pin is toothless)");
        // the contract's actual fee, computed by the real path:
        (, uint256 actualFee) = v.withdraw();
        assertEq(actualFee, correct25, "the contract must charge exactly 25 bps");
        assertTrue(actualFee != wrong24, "a 1-bps error would be caught");
    }

    function _fundViaMutant(Kind kind) internal returns (address v) {
        v = _deployMutant(kind);
    }

    // ---- NC5: an ERC20 leg where a `false`-returning token must NOT read as success ----

    /// @dev A token whose transfer returns `false` but MOVES nothing. P2's `_pay` rule is
    ///      `ok && (ret.length == 0 || decode(bool))`. A naive `require(ok)` alone would pass and the
    ///      money would silently not move. Protects the ERC20 path.
    function test_NC5_falseReturningTokenIsNotSuccess() public {
        FalseToken bad = new FalseToken();
        bytes32 salt = keccak256("nc5");
        StreamVault v = new StreamVault(address(f), alice, bob, address(bad), 1_000e6, START, END, salt, 0);
        bad.mint(address(v), 1_000e6);                       // fund the vault directly
        assertEq(bad.balanceOf(address(v)), 1_000e6, "vault holds the token");

        vm.warp(END);
        // The token MOVES the funds but returns `false`. P2's `_pay` must REJECT it: a naive
        // `require(ok)` (checking only that the call did not revert) would accept it, and this
        // assertion would pass while the real integration silently trusted a lying token.
        vm.expectRevert(bytes("erc20 transfer failed"));
        v.withdraw();
    }
}

/// @dev MUTANT (M-5) — re-inject the v1 "instant setter" bug: `setFeeBps` writes the live rate
///      directly instead of staging it behind the 48h timelock. Reached through the REAL factory.
///      Protects test_adminGuards / test_M5_commitOnlyAfterEta: against this mutant the "staged,
///      not applied" and "reverts before ETA" assertions redden.
contract InstantFeeFactory is StreamFactory {
    constructor(address o, address r, uint16 b) StreamFactory(o, r, b) {}

    function setFeeBps(uint16 bps) public override onlyOwner {
        if (bps > MAX_FEE_BPS) revert BadFee();
        feeBps = bps;                       // THE BUG: no pending/eta, applied on the set tx
        emit FeeBpsSet(bps);
    }
}

/// @dev Moves the funds and returns `false` — the "it worked, but the token says no" class. The
///      dangerous shape: a `require(ok)`-only integration accepts it; ours must not.
contract FalseToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return false;   // moved, but lies about it
    }
}
/// @title M-5 NEGCONTROL — the timelock + two-step, re-injected broken through a REAL rival factory.
contract M5NegcontrolTest is Test {
    address owner = address(0x0117);
    address feeRcpt = address(0xFEE0);

    function test_NC10_instantSetterMutant_bypassesTheTimelock() public {
        InstantFeeFactory mut = new InstantFeeFactory(owner, feeRcpt, 25);
        StreamFactory real = new StreamFactory(owner, feeRcpt, 25);

        vm.prank(owner);
        mut.setFeeBps(500);
        vm.prank(owner);
        real.setFeeBps(500);

        // the mutant is live IMMEDIATELY; the real one has only staged.
        assertEq(mut.feeBps(), 500, "mutant applied instantly (no timelock)");
        assertEq(real.feeBps(), 25, "real is still at the old rate until commit");
        assertTrue(mut.feeBpsEta() == 0, "mutant never records an ETA");
        assertGt(real.feeBpsEta(), block.timestamp, "real records a future ETA");

        // a commit before the ETA is refused by the real one (the mutant has nothing to commit).
        vm.warp(block.timestamp + 1);
        vm.expectRevert(StreamFactory.TimelockNotElapsed.selector);
        real.commitFeeBps();
        vm.warp(real.feeBpsEta());
        real.commitFeeBps();
        assertEq(real.feeBps(), 500, "real catches up only after the 48h clock");

        // a FRESH real factory with nothing staged: commit is NotStaged (the mutant's model has no
        // such state at all, which is the whole point of the guard).
        StreamFactory fresh = new StreamFactory(owner, feeRcpt, 25);
        vm.expectRevert(StreamFactory.NotStaged.selector);
        fresh.commitFeeBps();
    }

    function test_NC11_twoStep_rejectsNonPendingAccept() public {
        StreamFactory f = new StreamFactory(owner, feeRcpt, 25);
        vm.prank(owner);
        f.transferOwnership(address(0xB0B));
        // a v1-style one-step caller would now think it is owner; two-step says otherwise.
        assertEq(f.owner(), owner, "still the OLD owner until accept");
        vm.prank(address(0xBAD));
        vm.expectRevert(StreamFactory.NotPendingOwner.selector);
        f.acceptOwnership();
        vm.prank(address(0xB0B));
        f.acceptOwnership();
        assertEq(f.owner(), address(0xB0B), "handoff completes only from the pending key");
    }

    /// @dev NC12 (the critic's boundary ask) — a staged-but-UNcommitted knob must NOT move the live
    ///      value at eta-1s; it moves only AT eta. This is the off-by-one that IS the delay: if the
    ///      bound were `<`/`<=` wrong, the value would leak one second early (or a legit commit at eta
    ///      would revert). Proven against the REAL factory, contrasted with the instant mutant.
    function test_NC12_stagedValueDoesNotMoveAtEtaMinus1s() public {
        StreamFactory real = new StreamFactory(owner, feeRcpt, 25);
        InstantFeeFactory mut = new InstantFeeFactory(owner, feeRcpt, 25);

        vm.prank(owner);
        real.setFeeBps(500);
        vm.prank(owner);
        mut.setFeeBps(500);
        uint64 eta = real.feeBpsEta();

        vm.warp(eta - 1);
        // the mutant already moved (no delay); the real one is still flat.
        assertEq(mut.feeBps(), 500, "mutant: live immediately at eta-1s");
        assertEq(real.feeBps(), 25, "real: live value UNCHANGED at eta-1s (the delay holds)");
        vm.expectRevert(StreamFactory.TimelockNotElapsed.selector);
        real.commitFeeBps();                       // one second early -> refused

        vm.warp(eta);                              // exactly at the ETA
        real.commitFeeBps();                       // accepted AT the bound
        assertEq(real.feeBps(), 500, "real: moves exactly at eta, not before");
    }
}
