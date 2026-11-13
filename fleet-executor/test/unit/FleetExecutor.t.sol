// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FleetExecutor} from "../../src/FleetExecutor.sol";
import {Counter} from "../../src/interfaces/Counter.sol";

/// @title FleetExecutor — signed-intent batch via an EIP-7702 delegate: the C-2/C-3 fix, generalised.
/// @dev THE MODEL: `USER` is a plain EOA. One `vm.etch` installs the 7702 marker
///      (`0xef0100 || executor`), so a call to USER runs the executor code IN THE USER's FRAME:
///      `address(this) == USER`, the EIP-712 domain binds to USER, and `ecrecover == address(this)`
///      is the user's own signature. A relayer (a different `msg.sender`) carries the tx — the whole
///      point: the USER acts, the RELAY pays.
///
///      Every helper computes the digest ON the delegated EOA (`FleetExecutor(USER).digest(...)`),
///      because the domain's `verifyingContract` is `address(this)` — computing it on the bare
///      executor address would bind the wrong contract (a real drift; pinned in `test_domainBindsUser`).
contract FleetExecutorTest is Test {
    uint256 constant USER_PK = 0xA11CE;
    uint256 constant ATTACKER_PK = 0xBADBAD;
    address USER;
    address ATTACKER;
    address RELAY = address(0x5EA1);

    FleetExecutor exec;              // the delegate implementation (deployed once)
    Counter counter;

    /// @dev `execute` is overloaded (signed 4-arg vs ERC-7821 2-arg), so `abi.encodeCall(FleetExecutor.execute,..)`
    ///      is ambiguous — pin the signed overload's selector literally.
    bytes4 constant EXEC_SEL = bytes4(keccak256("execute((address,uint256,bytes)[],uint256,uint256,bytes)"));
    bytes4 constant EXECSELF_SEL = bytes4(keccak256("executeSelf((address,uint256,bytes)[])"));

    function setUp() public {
        USER = vm.addr(USER_PK);
        ATTACKER = vm.addr(ATTACKER_PK);
        exec = new FleetExecutor();
        counter = new Counter();
        vm.deal(RELAY, 100 ether);           // the relayer funds any value the batch forwards
        vm.deal(USER, 100 ether);            // the EOA funds its own executeSelf value
        // install the 7702 delegation on the USER's EOA (marker = 0xef0100 || impl)
        vm.etch(USER, abi.encodePacked(hex"ef0100", address(exec)));
        assertEq(USER.code.length, 23, "precondition: delegated EOA code is 23 bytes");
    }

    // ---------------------------------------------------------------- helpers

    function _calls1(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (FleetExecutor.Call[] memory calls)
    {
        calls = new FleetExecutor.Call[](1);
        calls[0] = FleetExecutor.Call({target: target, value: value, data: data});
    }

    function _digest(FleetExecutor.Call[] memory calls, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        // compute IN THE USER's FRAME (verifyingContract == USER)
        return FleetExecutor(USER).digest(calls, nonce, deadline);
    }

    function _sign(bytes32 d, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Submit `execute` the way a RELAY would: prank the relay, send exactly the batch's value
    ///      total, and call the USER's EOA.
    function _relayExecute(FleetExecutor.Call[] memory calls, uint256 nonce, uint256 deadline, bytes memory sig)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 total;
        for (uint256 i; i < calls.length; ++i) total += calls[i].value;
        vm.prank(RELAY);
        (ok, ret) = USER.call{value: total}(abi.encodeWithSelector(EXEC_SEL, calls, nonce, deadline, sig));
    }

    // =====================================================================================
    // HAPPY PATH — a relayed, user-signed batch runs in the user's frame and lands value.
    // =====================================================================================
    function test_signedHappyPath_relayCarriesUserIntent() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 1 ether, abi.encodeCall(Counter.inc, ()));
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, nonce, deadline), USER_PK);

        (bool ok,) = _relayExecute(calls, nonce, deadline, sig);
        assertTrue(ok, "relayed signed batch must succeed");

        // the call RAN, in the USER's frame: msg.sender seen by the target is USER, not the relay.
        assertEq(counter.count(), 1, "inner call executed");
        assertEq(counter.lastCaller(), USER, "actor == USER (delegate frame), NOT the relay");
        assertEq(counter.received(), 1 ether, "value forwarded into the call");
        // replay guard advanced, and the EOA's own tx-nonce was NOT used (the relay sent).
        assertEq(FleetExecutor(USER).nonces(), nonce, "intent nonce consumed");
    }

    /// @dev The signed batch is multi-call and ORDERED: two calls, both land, in order.
    function test_signedBatch_multipleCalls() public {
        FleetExecutor.Call[] memory calls = new FleetExecutor.Call[](2);
        calls[0] = FleetExecutor.Call(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        calls[1] = FleetExecutor.Call(address(counter), 0, abi.encodeWithSignature("record(bytes32)", bytes32(uint256(0xC0FFEE))));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        (bool ok,) = _relayExecute(calls, 1, deadline, sig);
        assertTrue(ok, "batch must succeed");
        assertEq(counter.count(), 1, "call 0 ran");
        assertEq(counter.lastData(), bytes32(uint256(0xC0FFEE)), "call 1 ran");
    }

    // =====================================================================================
    // NEGATIVES — each attacker/caller degree of freedom is rejected.
    // =====================================================================================

    /// @dev REPLAY: the same signed intent twice -> BadNonce on the second.
    function test_replayRejected() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);

        (bool ok1,) = _relayExecute(calls, 1, deadline, sig);
        assertTrue(ok1, "first use ok");

        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.BadNonce.selector);
        FleetExecutor(USER).execute(calls, 1, deadline, sig);   // same nonce again
    }

    /// @dev EXPIRED: deadline in the past -> Expired.
    function test_expiredRejected() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.Expired.selector);
        FleetExecutor(USER).execute(calls, 1, deadline, sig);
    }

    /// @dev WRONG SIGNER: an attacker signs the same intent -> BadSignature (only the user may).
    function test_wrongSignerRejected() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), ATTACKER_PK);   // attacker, not user
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.BadSignature.selector);
        FleetExecutor(USER).execute(calls, 1, deadline, sig);
    }

    /// @dev TAMPERED CALLS: sign for `inc`, submit a batch that names a different target -> BadSignature
    ///      (the whole calls[] array is bound, so a relayer cannot swap the action).
    function test_tamperedCallsRejected() public {
        FleetExecutor.Call[] memory signedCalls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(signedCalls, 1, deadline), USER_PK);

        FleetExecutor.Call[] memory tampered = _calls1(address(counter), 5 ether, abi.encodeCall(Counter.inc, ()));
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.BadSignature.selector);
        FleetExecutor(USER).execute(tampered, 1, deadline, sig);
    }

    /// @dev TAMPERED VALUE inside a call (same target+data, different value) -> BadSignature: value is
    ///      covered by the per-call struct hash, not a loose msg.value.
    function test_tamperedValueRejected() public {
        FleetExecutor.Call[] memory c1 = _calls1(address(counter), 1 ether, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(c1, 1, deadline), USER_PK);

        FleetExecutor.Call[] memory c2 = _calls1(address(counter), 2 ether, abi.encodeCall(Counter.inc, ()));
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.BadSignature.selector);
        FleetExecutor(USER).execute(c2, 1, deadline, sig);
    }

    /// @dev UNDERFUNDED: batch needs more value than msg.value -> ValueMismatch.
    function test_underfundedValueRejected() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 1 ether, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.ValueMismatch.selector);
        FleetExecutor(USER).execute{value: 0.5 ether}(calls, 1, deadline, sig);
    }

    /// @dev INNER FAILURE propagates (not swallowed) with the failing target named.
    function test_innerCallFailurePropagates() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.boom, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        vm.prank(RELAY);
        vm.expectRevert(abi.encodeWithSelector(FleetExecutor.CallFailed.selector, address(counter)));
        FleetExecutor(USER).execute(calls, 1, deadline, sig);
    }

    // =====================================================================================
    // SELF PATH — msg.sender == address(this) needs no signature.
    // =====================================================================================
    function test_executeSelf_path() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 1 ether, abi.encodeCall(Counter.inc, ()));

        // the USER is the caller AND the delegate frame -> msg.sender == address(this) == USER.
        vm.prank(USER);
        (bool ok,) = USER.call{value: 1 ether}(abi.encodeCall(FleetExecutor.executeSelf, (calls)));
        assertTrue(ok, "executeSelf must succeed with no signature");
        assertEq(counter.count(), 1, "self batch ran");
        assertEq(counter.lastCaller(), USER, "actor == USER");

        // a NON-self caller on the self path -> NotSelf.
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.NotSelf.selector);
        FleetExecutor(USER).executeSelf(calls);
    }

    // =====================================================================================
    // ERC-7821 compat + domain binding + namespaced nonce isolation.
    // =====================================================================================

    /// @dev ERC-7821 mode 0x00 (single) and 0x01 (batch) both execute; unknown mode reverts.
    ///      Since #203 the 2-arg door is GATED (self OR intent), so the mode coverage uses the
    ///      explicit opt-in door (`executeBare`) to isolate mode decoding from auth.
    function test_erc7821_modes() public {
        // single
        bytes memory single = abi.encode(address(counter), uint256(0), abi.encodeCall(Counter.inc, ()));
        vm.prank(RELAY);
        (bool okS,) = USER.call(abi.encodeWithSignature("executeBare(bytes32,bytes)", bytes32(0x00), single));
        assertTrue(okS, "single mode call ok");
        assertEq(counter.count(), 1, "single mode ran");

        // batch (mode 0x01)
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        bytes memory batch = abi.encode(calls);
        vm.prank(RELAY);
        (bool okB,) = USER.call(abi.encodeWithSignature("executeBare(bytes32,bytes)", bytes32(uint256(0x01) << 248), batch));
        assertTrue(okB, "batch mode call ok");
        assertEq(counter.count(), 2, "batch mode ran");

        // unknown mode (through the gated default, from the EOA itself)
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(FleetExecutor.UnsupportedMode.selector, bytes32(uint256(0x09))));
        FleetExecutor(USER).execute(bytes32(uint256(0x09)), "");
    }

    /// @dev The domain binds verifyingContract = address(this) = the DELEGATED EOA, NOT the bare
    ///      implementation address. A signature over the bare-impl digest must NOT verify on the EOA.
    function test_domainBindsUser_notImpl() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 userDigest = _digest(calls, 1, deadline);
        bytes32 implDigest = exec.digest(calls, 1, deadline);
        assertTrue(userDigest != implDigest, "domain must differ between EOA and impl");

        // signed over the WRONG (impl) digest -> BadSignature on the EOA
        bytes memory badSig = _sign(implDigest, USER_PK);
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.BadSignature.selector);
        FleetExecutor(USER).execute(calls, 1, deadline, badSig);

        // signed over the RIGHT (EOA) digest -> passes
        bytes memory goodSig = _sign(userDigest, USER_PK);
        (bool ok,) = _relayExecute(calls, 1, deadline, goodSig);
        assertTrue(ok, "correct-digest signature passes");
    }

    /// @dev The nonce lives in a NAMESPACED slot (not slot 0/1), so a DIFFERENT delegate installed on
    ///      the same EOA cannot alias it. Pinned by reading the slot key directly.
    function test_nonceIsNamespacedSlot() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 7, deadline), USER_PK);
        (bool ok,) = _relayExecute(calls, 7, deadline, sig);
        assertTrue(ok, "nonce 7 accepted");

        // the nonce is NOT in slot 0 (a compiler slot would be) — it is in the namespaced slot.
        bytes32 slot = keccak256(abi.encodePacked(keccak256("FleetExecutor.nonce"), USER));
        assertEq(uint256(vm.load(USER, slot)), 7, "nonce stored at the namespaced slot");
        assertEq(uint256(vm.load(USER, bytes32(uint256(0)))), 0, "slot 0 untouched");
    }

    // =====================================================================================
    // GOTCHA #203 — the 7821 door is now GATED. Default requires self OR a valid EIP-712 intent;
    // `executeBare` is the explicit opt-in to the old always-permissionless behaviour.
    // =====================================================================================

    /// @dev GATED default: a stranger with NO signature and NOT the EOA is REJECTED on the 2-arg door.
    function test_7821_gated_strangerNoSig_reverts() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        bytes memory data = abi.encodeWithSignature("execute(bytes32,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls));
        vm.prank(RELAY);                                   // a total stranger, no sig
        (bool ok, bytes memory ret) = USER.call(data);
        assertFalse(ok, "gated 7821 rejects an unsigned stranger");
        assertEq(bytes4(ret), FleetExecutor.NotSelfOrIntent.selector, "reverts NotSelfOrIntent");
        assertEq(counter.count(), 0, "nothing ran");
    }

    /// @dev SELF is still allowed on the 2-arg door (the EOA calls itself).
    function test_7821_gated_self_passes() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        vm.prank(USER);                                    // the EOA itself
        (bool ok,) = USER.call(abi.encodeWithSignature("execute(bytes32,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls)));
        assertTrue(ok, "self path passes the gate");
        assertEq(counter.count(), 1, "self batch ran");
    }

    /// @dev A STRANGER with a valid EIP-712 intent passes the 5-arg door (and consumes the nonce).
    function test_7821_gated_strangerWithIntent_passes() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        bytes memory data =
            abi.encodeWithSignature("execute(bytes32,bytes,uint256,uint256,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls), 1, deadline, sig);
        vm.prank(RELAY);                                   // stranger, but carries the user's sig
        (bool ok,) = USER.call(data);
        assertTrue(ok, "signed 7821 intent passes");
        assertEq(counter.count(), 1, "intent batch ran");
        assertEq(FleetExecutor(USER).nonces(), 1, "intent nonce consumed (no replay)");
    }

    /// @dev THE CRITIC'S NEGCONTROL (#203): the SAME batch that was ACCEPTED unsigned now REVERTS, and
    ///      the SAME op with a valid intent still PASSES. One batch, two doors, opposite outcomes.
    function test_7821_negcontrol_wasAccepted_nowReverts_intentStillPasses() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;

        // (a) the OLD bare call, now GATED -> reverts.
        vm.prank(RELAY);
        (bool bareOk,) = USER.call(abi.encodeWithSignature("execute(bytes32,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls)));
        assertFalse(bareOk, "unsigned 7821 that WAS accepted is now REJECTED by the gate");

        // (b) the SAME batch WITH a valid intent -> still passes.
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        vm.prank(RELAY);
        (bool intentOk,) = USER.call(abi.encodeWithSignature(
            "execute(bytes32,bytes,uint256,uint256,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls), 1, deadline, sig));
        assertTrue(intentOk, "same batch with an intent still passes");
        assertEq(counter.count(), 1, "ran exactly once (gate held, then intent)");
    }

    /// @dev EXPLICIT OPT-IN: `executeBare` is STILL fully permissionless (proves the #203 door remains,
    ///      just opt-in) — a stranger runs a caller-chosen batch, twice (replayable, no nonce).
    function test_7821_optin_executeBare_stillPermissionlessAndReplayable() public {
        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        bytes memory data = abi.encodeWithSignature("executeBare(bytes32,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls));
        vm.prank(RELAY);
        (bool ok1,) = USER.call(data);
        assertTrue(ok1, "executeBare is permissionless (stranger, no sig)");
        vm.prank(RELAY);
        (bool ok2,) = USER.call(data);                     // identical data again
        assertTrue(ok2, "executeBare is replayable (no nonce)");
        assertEq(counter.count(), 2, "ran twice via the opt-in door");
        assertEq(counter.lastCaller(), USER, "still the EOA's frame");
    }

    /// @dev Every 7821 door is CALLER-funded: the EOA's own native is NOT spendable through them
    ///      (only executeSelf or the signed path-with-value spends frame native).
    function test_7821choice_isCallerFunded_notEoaNative() public {
        address sink = makeAddr("sink203");
        FleetExecutor.Call[] memory calls = _calls1(sink, 5 ether, "");
        bytes memory data = abi.encodeWithSignature("executeBare(bytes32,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls));

        // caller attaches 0 -> ValueMismatch (declared 5 > msg.value 0)
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.ValueMismatch.selector);
        FleetExecutor(USER).executeBare(bytes32(uint256(0x01) << 248), abi.encode(calls));

        uint256 eoaBefore = USER.balance;
        vm.prank(RELAY);
        USER.call{value: 5 ether}(data);
        assertEq(sink.balance, 5 ether, "sink paid from the CALLER's value");
        assertEq(USER.balance, eoaBefore, "EOA native untouched by 7821");
    }

    /// @dev THE FUND-PATH TEETH: the token drain the reviewer proved on the bare door is CLOSED on the
    ///      gated default — an unsigned stranger can no longer drive approve(stranger,MAX). It reopens
    ///      only with the user's intent.
    function test_7821_gate_closesTheDrain_onDefaultDoor() public {
        Tok t = new Tok();
        t.mint(USER, 1000e18);
        assertEq(t.allowance(USER, ATTACKER), 0, "starts with no allowance");

        // attacker drives the GATED default unsigned -> approve(stranger,MAX) did NOT land
        FleetExecutor.Call[] memory calls = _calls1(address(t), 0, abi.encodeCall(Tok.approve, (ATTACKER, type(uint256).max)));
        bytes memory gated = abi.encodeWithSignature("execute(bytes32,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls));
        vm.prank(ATTACKER);
        (bool ok,) = USER.call(gated);
        assertFalse(ok, "gated default rejects the unsigned attacker");
        assertEq(t.allowance(USER, ATTACKER), 0, "no allowance yet -> drain blocked");
        vm.prank(ATTACKER);
        vm.expectRevert();                                  // transferFrom needs the allowance
        t.transferFrom(USER, ATTACKER, 1000e18);

        // now WITH the user's intent -> approve lands, attacker can pull
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(_digest(calls, 1, deadline), USER_PK);
        vm.prank(ATTACKER);
        USER.call(abi.encodeWithSignature(
            "execute(bytes32,bytes,uint256,uint256,bytes)", bytes32(uint256(0x01) << 248), abi.encode(calls), 1, deadline, sig));
        assertEq(t.allowance(USER, ATTACKER), type(uint256).max, "intent let the approve land");
        vm.prank(ATTACKER);
        t.transferFrom(USER, ATTACKER, 1000e18);
        assertEq(t.balanceOf(ATTACKER), 1000e18, "drain proceeds ONLY with the intent");
    }

    // =====================================================================================
    // NEGCONTROL — drop the ecrecover check -> an attacker-signed call passes (proves teeth).
    // =====================================================================================
    function test_negcontrol_dropEcrecover_attackerPasses() public {
        NoAuthExecutor na = new NoAuthExecutor();
        address u2 = vm.addr(0xC0FFEE);
        vm.etch(u2, abi.encodePacked(hex"ef0100", address(na)));
        vm.deal(address(this), 100 ether);

        FleetExecutor.Call[] memory calls = _calls1(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        uint256 deadline = block.timestamp + 1 hours;

        // digest computed in u2's frame; signed by the ATTACKER (not u2)
        bytes32 d = FleetExecutor(u2).digest(calls, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTACKER_PK, d);
        bytes memory badSig = abi.encodePacked(r, s, v);

        // THE MUTANT accepts it (no ecrecover) -> the attacker drove u2's frame.
        vm.prank(RELAY);
        (bool okM,) = u2.call(abi.encodeWithSelector(EXEC_SEL, calls, 1, deadline, badSig));
        assertTrue(okM, "mutant (no auth) accepts an attacker signature");
        assertEq(counter.count(), 1, "mutant let the attacker run the batch");

        // CONTROL: the real executor rejects the same attacker signature.
        vm.prank(RELAY);
        vm.expectRevert(FleetExecutor.BadSignature.selector);
        FleetExecutor(USER).execute(calls, 1, deadline, badSig);

        // and the real executor accepts the USER's own signature (isolates signer, not formatting).
        bytes memory goodSig = _sign(_digest(calls, 1, deadline), USER_PK);
        (bool okR,) = _relayExecute(calls, 1, deadline, goodSig);
        assertTrue(okR, "real executor accepts the user's signature");
    }
}

/// @dev Minimal ERC20 for the drain-path proof (approve + transferFrom, the #203 shape).
contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address t, uint256 a) external {
        balanceOf[t] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "ALLOW");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev MUTANT — `execute` forgets the ecrecover check. Same storage shape, so `vm.etch` works.
contract NoAuthExecutor is FleetExecutor {
    function execute(FleetExecutor.Call[] calldata calls, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        payable
        override
    {
        // THE BUG: the `_recover(...) != address(this)` check is DROPPED; sig is ignored entirely.
        if (block.timestamp > deadline) revert Expired();
        if (nonce <= _nonce()) revert BadNonce();
        _setNonce(nonce);
        _run(calls, nonce);
        sig; // silence the unused-param warning
    }
}
