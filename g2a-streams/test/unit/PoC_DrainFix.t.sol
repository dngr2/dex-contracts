// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";

/// @dev minimal ERC20 (approve/transferFrom), no deps — mirrors the reviewer's PoC token.
contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external returns (bool) { balanceOf[msg.sender] -= v; balanceOf[to] += v; return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v; balanceOf[f] -= v; balanceOf[to] += v; return true;
    }
}

/// @title Fix proof + NEGATIVE CONTROLS for the StreamFactory drain (C-1).
/// @dev Each test either (a) proves the FIX closes the drain, or (b) is a NEGATIVE CONTROL that
///      re-injects the v1 bug through the REAL createStreamFor and asserts the suite would catch it.
contract PoCDrainFix is Test {
    StreamFactory f;
    Tok usdc;
    address owner = address(0xA11CE);
    address feeTo = address(0xFEE);
    address payer = address(0x5B5);        // subscriber / war-chest analogue
    address keeper = address(0x34E9);      // SEPARATE signer, like the live daemon
    address merchant = address(0x2733);
    address attacker = address(0xBAD);
    address attacker2 = address(0xBAD2);

    uint256 constant TICKET = 5_000_000;   // 5 USDC
    uint64 constant PERIOD = 120;
    uint64 T0;

    function setUp() public {
        vm.warp(1_800_000_000);
        T0 = uint64(block.timestamp);
        f = new StreamFactory(owner, feeTo, 500);
        usdc = new Tok();
        usdc.mint(payer, 1_000e6);
        vm.prank(payer);
        usdc.approve(address(f), type(uint256).max);   // the standing mandate (allowance)
    }

    function _window(uint256 lap) internal view returns (uint64 s, uint64 e) {
        s = T0 + uint64(lap) * PERIOD;
        e = s + PERIOD;
    }

    // =============================== FIX PROOF ===============================

    /// F1 — POST-FIX: a STRANGER (not payer, not keeper) fires a lap WITHIN an active mandate and it
    /// PASSES. This is the "must still work" control: the fix is not over-broad.
    function test_F1_strangerFiresWithinMandate_passes() public {
        vm.prank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        (uint64 s, uint64 e) = _window(0);
        vm.prank(attacker);                                  // <-- unrelated caller
        address vault = f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
        assertEq(StreamVault(payable(vault)).recipient(), merchant, "stranger funded the RIGHT reel");
        assertEq(usdc.balanceOf(vault), TICKET, "ticket pulled");
    }

    /// F2 — POST-FIX: the DRAIN is closed. A stranger cannot redirect to a recipient with no mandate
    /// (NotAuthorized), and cannot resize within a mandate (BadMandate — separate test F2b).
    function test_F2_redirectBlocked_noMandateForAttacker() public {
        vm.prank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        (uint64 s, uint64 e) = _window(0);
        // stranger tries recipient=attacker (paying THEMSELVES), amount = whole balance
        vm.prank(attacker);
        vm.expectRevert(StreamFactory.NotAuthorized.selector);
        f.createStreamFor(payer, attacker, address(usdc), 1_000e6, s, e);
    }

    /// F2b — within an active mandate, a wrong ticket or wrong period is rejected (BadMandate). This
    /// is what stops "the keeper fires the right recipient but the wrong SIZE".
    function test_F2b_wrongTicketOrPeriod_reverts() public {
        vm.prank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        (uint64 s, uint64 e) = _window(0);
        vm.prank(attacker);
        vm.expectRevert(StreamFactory.BadMandate.selector);
        f.createStreamFor(payer, merchant, address(usdc), TICKET * 2, s, e);   // wrong amount
        vm.prank(attacker);
        vm.expectRevert(StreamFactory.BadMandate.selector);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e + 1);   // wrong period
    }

    /// F3 — POST-FIX: monotonic laps. Re-firing the SAME window reverts (no double-mint of a past lap).
    function test_F3_monotonicNoRerunOfPastLap() public {
        vm.prank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        (uint64 s, uint64 e) = _window(0);
        vm.prank(attacker);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
        vm.prank(attacker2);
        vm.expectRevert(StreamFactory.BadStart.selector);   // start < lastEnd
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
    }

    /// F4 — POST-FIX: lap budget enforced.
    function test_F4_lapsExhausted() public {
        vm.prank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 2, T0);
        for (uint256 i = 0; i < 2; i++) {
            (uint64 s, uint64 e) = _window(i);
            vm.prank(attacker);
            f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
        }
        (uint64 s2, uint64 e2) = _window(2);
        vm.prank(attacker);
        vm.expectRevert(StreamFactory.MandateExhausted.selector);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s2, e2);
    }

    /// F5 — POST-FIX: hedge path (no mandate) — payer self-create passes; an armed keeper passes; a
    /// stranger reverts. Proves the keeper asymmetry (daemon key != payer) is handled. Laps advance
    /// contiguously because the hedge cursor now gates the un-armed path too (critic ruling #2).
    function test_F5_hedgePath_payerKeeperOnly() public {
        (uint64 s0, uint64 e0) = _window(0);
        // stranger, no mandate -> NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(StreamFactory.NotAuthorized.selector);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s0, e0);
        // payer self -> ok (lap 0, arms the hedge cursor at e0)
        vm.prank(payer);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s0, e0);
        // arm keeper; keeper fires the NEXT contiguous lap (start == hedgeEnd) -> ok
        vm.prank(owner);
        f.setKeeper(keeper, true);
        (uint64 s1, uint64 e1) = _window(1);
        vm.prank(keeper);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s1, e1);
        assertEq(f.hedgeEnd(payer, merchant, address(usdc)), e1, "cursor advanced to lap-1 end");
    }

    /// NC3 — THE HEDGE FOOTGUN, PROVEN. Without the hedge cursor an off-script keeper re-firing the
    /// SAME (start,end) mints a SECOND fully-vested vault and DOUBLE-PULLS the payer. Here the real v2
    /// (cursor ON) reverts BadStart on the re-fire, while a HedgeNoCursor mutant with the cursor line
    /// removed mints twice and pulls twice — so the ruling is proven by state, not argued.
    function test_NC3_hedgeDoubleFire_doublePull_proven() public {
        HedgeNoCursor bad = new HedgeNoCursor(owner, feeTo, 500);
        usdc.mint(payer, 100e6);
        vm.startPrank(payer);
        usdc.approve(address(bad), type(uint256).max);
        vm.stopPrank();
        vm.prank(owner);
        bad.setKeeper(keeper, true);

        (uint64 s, uint64 e) = _window(0);
        vm.prank(keeper);
        bad.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
        uint256 afterFirst = usdc.balanceOf(payer);
        // re-fire the SAME window — no cursor -> mints again, pulls AGAIN
        vm.prank(keeper);
        address v2b = bad.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
        assertLt(usdc.balanceOf(payer), afterFirst, "mutant: payer double-pulled");
        assertEq(afterFirst - usdc.balanceOf(payer), TICKET, "second identical ticket pulled");
        assertTrue(v2b != address(0));

        // and the real v2 rejects the re-fire (cursor ON)
        vm.prank(owner);
        f.setKeeper(keeper, true);
        vm.prank(keeper);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
        vm.prank(keeper);
        vm.expectRevert(StreamFactory.BadStart.selector);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
    }

    /// F6 — the live daemon's REAL shape: index-derived window, fired LATE (start in the past), and it
    /// must NOT be rejected. This is the adversarial counter to the reviewer's `require(start>=now)`.
    function test_F6_lateWindowPastStart_stillWorks() public {
        vm.prank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        vm.warp(block.timestamp + 50_000);          // daemon "late": 50k s past T0
        (uint64 s, uint64 e) = _window(0);
        assertLt(uint256(s), block.timestamp, "window start IS in the past (late fire)");
        vm.prank(attacker);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);   // must succeed
        assertTrue(true, "a past-start late window is accepted (start>=now would have reverted)");
    }

    // =============================== NEGATIVE CONTROL ===============================

    /// NC2 — THE MONOTONIC-GATE PROOF. The reviewer's literal fix text was `require(start >=
    /// block.timestamp)`. The daemon's window is INDEX-derived (t0 + i*period) and fired LATE, so
    /// `start` is normally HOURS in the past — under a `start>=now` gate EVERY real fire reverts.
    /// This arms identical mandates on the real v2 and on a mutant carrying the naive `start>=now`
    /// gate, warps the clock forward (a late fire), and asserts: v2 PASSES, mutant REVERTS. The catch
    /// is thus proven, not asserted.
    function test_NC2_lastEndBeatsNow_provenAgainstNowGateMutant() public {
        V2NowGate bad = new V2NowGate(owner, feeTo, 500);
        vm.startPrank(payer);
        f.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        bad.setMandate(merchant, address(usdc), TICKET, PERIOD, 30, T0);
        usdc.approve(address(bad), type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 50_000);            // daemon fires LATE: window start << now
        (uint64 s, uint64 e) = _window(0);
        assertLt(uint256(s), block.timestamp, "start IS in the past (late daemon fire)");

        // real v2 (lastEnd gate) — accepts the late window, like the live reel
        vm.prank(attacker);
        f.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);

        // naive-now mutant — REVERTS on the exact same daemon fire: the reviewer's text is wrong
        vm.prank(attacker);
        vm.expectRevert(V2NowGate.BadStart.selector);
        bad.createStreamFor(payer, merchant, address(usdc), TICKET, s, e);
    }

    /// NC1 — re-inject the v1 BUG through the REAL path: a "v1-shaped" factory (no auth) lets a
    /// stranger redirect+resize. Simulated here by arming NO mandate and calling as a stranger — with
    /// the fix, this reverts (proving the fix bites); the mutant V1Factory below still drains.
    function test_NC1_v1MutantStillDrains() public {
        V1Factory v1 = new V1Factory(owner, feeTo, 500);
        Tok t = new Tok();
        t.mint(payer, 1_000e6);
        vm.prank(payer);
        t.approve(address(v1), type(uint256).max);
        vm.prank(attacker);
        address vault = v1.createStreamFor(payer, attacker, address(t), 1_000e6, 1, 61);
        vm.prank(attacker);
        StreamVault(payable(vault)).withdraw();
        assertEq(t.balanceOf(payer), 0, "v1 (mutant) drains the whole allowance");
        assertEq(t.balanceOf(attacker), 950e6, "attacker nets 95%");
    }

    // =============================== M-4: pulling on a reverting native recipient ===============

    /// M4-A — POST-FIX: a NATIVE stream whose recipient CONTRACT reverts on receive no longer bricks
    /// the pull. The amount is CREDITED, the pull succeeds, and the payer's cancel still works.
    function test_M4_revertingNativeRecipient_noLongerBricks() public {
        Reverter rv = new Reverter();
        StreamFactory nf = new StreamFactory(owner, feeTo, 500);   // fresh, native
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        address vault = nf.createStream{value: 1 ether}(address(rv), address(0), 1 ether, T0, T0 + 1_000);
        vm.warp(T0 + 1_000);                                       // fully vested
        vm.prank(attacker);                                        // permissionless pull
        (uint256 out, ) = StreamVault(payable(vault)).withdraw();
        assertGt(out, 0, "pull SUCCEEDED despite the reverting recipient");
        assertEq(StreamVault(payable(vault)).claimable(address(rv)), out, "recipient amount CREDITED");
        assertEq(StreamVault(payable(vault)).withdrawn(), 1 ether, "counted as withdrawn");

        // and a cancel afterwards still refunds (does not revert on the same recipient)
        vm.prank(payer);
        StreamVault(payable(vault)).cancel();
        assertEq(address(vault).balance, out, "only the credited amount remains; refund succeeded");
    }

    /// M4-B — POST-FIX: the credited amount is later CLAIMED once the recipient can receive (e.g. the
    /// multisig is fixed). Proves the credit is not stranded.
    function test_M4_claim_deliversOnceRecipientAccepts() public {
        Reverter rv = new Reverter();
        StreamFactory nf = new StreamFactory(owner, feeTo, 500);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        address vault = nf.createStream{value: 1 ether}(address(rv), address(0), 1 ether, T0, T0 + 1_000);
        vm.warp(T0 + 1_000);
        vm.prank(attacker);
        (uint256 out, ) = StreamVault(payable(vault)).withdraw();
        assertEq(StreamVault(payable(vault)).claimable(address(rv)), out);

        rv.accept(true);                                          // recipient now accepts native
        vm.prank(attacker);                                       // claim is permissionless
        StreamVault(payable(vault)).claim(address(rv));
        assertEq(address(rv).balance, out, "credited amount delivered on claim");
        assertEq(StreamVault(payable(vault)).claimable(address(rv)), 0, "credit cleared");
    }

    /// M4-C — a claim with nothing credited reverts (so a UI can distinguish rather than no-op).
    function test_M4_claimNothingReverts() public {
        StreamFactory nf = new StreamFactory(owner, feeTo, 500);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        address vault = nf.createStream{value: 1 ether}(payer, address(0), 1 ether, T0, T0 + 1_000);
        vm.expectRevert(StreamVault.NothingClaimable.selector);
        StreamVault(payable(vault)).claim(payer);
    }

    /// NC4 — THE v1-BUG RE-INJECTION for M-4. A `StrictNativeVault` mutant keeps v1's hard
    /// `require(ok)` on native send, so the SAME reverting recipient BRICKS its withdraw (and thus
    /// the whole stream), while the real v2 accepts. Proven by running the identical call both ways.
    function test_NC4_v1StrictNative_bricks_butV2DoesNot() public {
        Reverter rv = new Reverter();
        StrictNativeFactory bad = new StrictNativeFactory(owner, feeTo, 500);
        StreamFactory nf = new StreamFactory(owner, feeTo, 500);
        vm.deal(payer, 10 ether);
        vm.startPrank(payer);
        address vBad = bad.createStream{value: 1 ether}(address(rv), address(0), 1 ether, T0, T0 + 1_000);
        address vOk = nf.createStream{value: 1 ether}(address(rv), address(0), 1 ether, T0, T0 + 1_000);
        vm.stopPrank();
        vm.warp(T0 + 1_000);

        // mutant (v1 strict native) — the reverting recipient BRICKS the withdraw
        vm.prank(attacker);
        vm.expectRevert(bytes("native send failed"));
        StreamVault(payable(vBad)).withdraw();

        // real v2 — same call, same recipient, SUCCEEDS (credited instead)
        vm.prank(attacker);
        StreamVault(payable(vOk)).withdraw();
        assertGt(StreamVault(payable(vOk)).claimable(address(rv)), 0, "v2 credits what v1 would revert on");
    }
}

/// @dev A CONTRACT recipient that REVERTS on native receive until told otherwise — the multisig/
///      smart-wallet shape that bricks a strict native send.
contract Reverter {
    bool public ok;
    receive() external payable {
        if (!ok) revert("no");
    }
    function accept(bool v) external { ok = v; }
}

/// @dev MUTANT for M-4 — the v1 `_pay`: native send is a hard require, so a reverting recipient
///      bricks the pull. Re-injects the pre-fix bug through the REAL StreamVault code path.
contract StrictNativeVault is StreamVault {
    constructor(
        address f, address p, address r, address t, uint256 a, uint64 s, uint64 e, bytes32 salt, uint256 idx
    ) StreamVault(f, p, r, t, a, s, e, salt, idx) {}

    function _pay(address t, address to, uint256 v) internal override {
        if (t == address(0)) {
            (bool ok, ) = payable(to).call{value: v}("");
            require(ok, "native send failed");        // THE BUG: no credit-on-failure
        } else {
            (bool ok, bytes memory ret) = t.call(abi.encodeWithSelector(bytes4(0xa9059cbb), to, v)); // transfer
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 transfer failed");
        }
    }
}

/// @dev Factory that spawns StrictNativeVault. Real create path; only the vault bytecode differs.
contract StrictNativeFactory is StreamFactory {
    constructor(address o, address r, uint16 b) StreamFactory(o, r, b) {}

    function _initCode(Stream memory s) internal view override returns (bytes memory) {
        return abi.encodePacked(
            type(StrictNativeVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index)
        );
    }
}

/// @dev V1 MUTANT — the exact vulnerable factory (no auth, no monotonic, no ticket binding), so NC1
///      is a real re-injection of the bug, not a hand-asserted claim (GOTCHA #20/#62 discipline).
contract V1Factory {
    address public owner;
    uint16 public feeBps;
    address public feeRecipient;
    bool public paused;
    mapping(address => uint256) public nonce;
    mapping(address => address[]) public streamsOf;
    uint256 public minFee;   // current StreamVault reads factory.minFee(); the mutant supplies it

    struct Stream { address payer; address recipient; address token; uint256 amount; uint64 start; uint64 end; bytes32 salt; uint256 index; }

    constructor(address o, address fr, uint16 fb) { owner = o; feeRecipient = fr; feeBps = fb; }

    function createStreamFor(address payer, address recipient, address token, uint256 amount, uint64 start, uint64 end)
        public payable returns (address vault)
    {
        uint256 idx = nonce[payer]++;
        Stream memory s = Stream(payer, recipient, token, amount, start, end, 0, idx);
        s.salt = keccak256(abi.encodePacked(s.payer, s.index, s.recipient, s.token, s.start, s.end));
        bytes memory ic = abi.encodePacked(type(StreamVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index));
        bytes32 h = keccak256(abi.encodePacked(hex"ff", address(this), s.salt, keccak256(ic)));
        vault = address(uint160(uint256(h)));
        _deploy(s.salt, ic);
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, payer, vault, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pull failed");
        streamsOf[payer].push(vault);
    }

    function _deploy(bytes32 salt_, bytes memory ic_) internal {
        assembly { let inst := create2(0, add(ic_, 0x20), mload(ic_), salt_) if iszero(inst) { revert(0,0) } }
    }

    function streamCount(address p) external view returns (uint256) { return streamsOf[p].length; }
}

/// @dev V2 MUTANT with the REVIEWER'S LITERAL GATE. Everything matching v2's mandate path EXCEPT the
///      start check, which is the naive `start >= block.timestamp` from pagexx's fix text. Used by
///      NC2 to prove the literal wording reverts a real late daemon fire.
contract V2NowGate {
    address public owner;
    uint16 public feeBps;
    address public feeRecipient;
    uint256 public minFee;
    bool public paused;
    mapping(address => uint256) public nonce;
    mapping(address => address[]) public streamsOf;

    struct Mandate { address token; uint256 ticket; uint64 period; uint64 lastEnd; uint32 laps; uint32 fired; bool active; }
    mapping(address => mapping(address => Mandate)) public mandate;

    struct Stream { address payer; address recipient; address token; uint256 amount; uint64 start; uint64 end; bytes32 salt; uint256 index; }

    error BadStart();

    constructor(address o, address fr, uint16 fb) { owner = o; feeRecipient = fr; feeBps = fb; }

    function setMandate(address recipient, address token, uint256 ticket, uint64 period, uint32 laps, uint64 t0) external {
        mandate[msg.sender][recipient] =
            Mandate({token: token, ticket: ticket, period: period, lastEnd: t0, laps: laps, fired: 0, active: true});
    }

    function createStreamFor(address payer, address recipient, address token, uint256 amount, uint64 start, uint64 end)
        public payable returns (address vault)
    {
        Mandate storage m = mandate[payer][recipient];
        if (m.active) {
            if (start < block.timestamp) revert BadStart();   // <-- the NAIVE literal gate
            m.lastEnd = end;
            m.fired += 1;
        }
        uint256 idx = nonce[payer]++;
        Stream memory s = Stream(payer, recipient, token, amount, start, end, 0, idx);
        s.salt = keccak256(abi.encodePacked(s.payer, s.index, s.recipient, s.token, s.start, s.end));
        bytes memory ic = abi.encodePacked(type(StreamVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index));
        bytes32 h = keccak256(abi.encodePacked(hex"ff", address(this), s.salt, keccak256(ic)));
        vault = address(uint160(uint256(h)));
        _deploy(s.salt, ic);
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, payer, vault, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pull failed");
        streamsOf[payer].push(vault);
    }

    function _deploy(bytes32 salt_, bytes memory ic_) internal {
        assembly { let inst := create2(0, add(ic_, 0x20), mload(ic_), salt_) if iszero(inst) { revert(0,0) } }
    }
}

/// @dev HEDGE-NO-CURSOR MUTANT — the pre-ruling hedge path: payer/keeper gated but with NO hedgeEnd
///      cursor, so a repeated (start,end) mints a second vault and double-pulls. Used by NC3 to prove
///      the double-pull footgun the ruling closes.
contract HedgeNoCursor {
    address public owner;
    address public feeRecipient;
    uint16 public feeBps;
    uint256 public minFee;   // StreamVault's ctor snapshots factory.minFee()/feeBps()
    mapping(address => bool) public isKeeper;
    mapping(address => uint256) public nonce;
    mapping(address => address[]) public streamsOf;

    struct Stream { address payer; address recipient; address token; uint256 amount; uint64 start; uint64 end; bytes32 salt; uint256 index; }
    error NotAuthorized();

    constructor(address o, address fr, uint16 fb) { owner = o; feeRecipient = fr; feeBps = fb; }

    function setKeeper(address k, bool a) external { require(msg.sender == owner); isKeeper[k] = a; }

    function createStreamFor(address payer, address recipient, address token, uint256 amount, uint64 start, uint64 end)
        public payable returns (address vault)
    {
        if (msg.sender != payer && !isKeeper[msg.sender]) revert NotAuthorized();
        uint256 idx = nonce[payer]++;
        Stream memory s = Stream(payer, recipient, token, amount, start, end, 0, idx);
        s.salt = keccak256(abi.encodePacked(s.payer, s.index, s.recipient, s.token, s.start, s.end));
        bytes memory ic = abi.encodePacked(type(StreamVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index));
        bytes32 h = keccak256(abi.encodePacked(hex"ff", address(this), s.salt, keccak256(ic)));
        vault = address(uint160(uint256(h)));
        _deployBad(s.salt, ic);
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, payer, vault, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pull failed");
        streamsOf[payer].push(vault);
    }

    function _deployBad(bytes32 salt_, bytes memory ic_) internal {
        assembly { let inst := create2(0, add(ic_, 0x20), mload(ic_), salt_) if iszero(inst) { revert(0,0) } }
    }
}
