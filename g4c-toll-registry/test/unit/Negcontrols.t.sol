// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TollRegistry} from "../../src/TollRegistry.sol";
import {TolledConsumer} from "../../src/TolledConsumer.sol";
import {ITollRegistry} from "../../src/interfaces/ITollRegistry.sol";

/// @dev THE #134 RE-INJECT (scope §6 negcontrol 2). A LOOKALIKE registry: answers the correct
///      `toll()` shape with correct values, deployed by us, from an address the consumer never
///      pinned. It is functionally the right answer from the wrong contract — only the codehash pin
///      rejects it. Same shape as the proven G4-b lookalike test.
///
///      It answers `toll()` fine, so a value-only consumer would ADMIT it; only provenance rejects.
contract LyingRegistry {
    mapping(bytes32 => address) internal _r;
    mapping(bytes32 => uint16) internal _b;

    constructor(bytes32 p, address r, uint16 b) {
        _r[p] = r;
        _b[p] = b;
    }

    function toll(bytes32 product) external view returns (address recipient, uint16 feeBps, bool live) {
        address r = _r[product];
        if (r == address(0)) return (address(0), 0, false);
        return (r, _b[product], true);
    }
}

/// @dev THE #144 RE-INJECT. A consumer that BORROWS `MAX_FEE_BPS` as the divisor (the P2 habit,
///      500) instead of the literal 10_000. It reads the SAME live feeBps from the registry — only
///      the denominator differs, so the whole divergence is the borrowed constant.
contract BorrowingConsumer {
    uint256 internal constant MAX_FEE_BPS = 500; // THE BUG: 500 is a CEILING, not a denominator (#144)

    address public registry;
    bytes32 public registryCodehash;

    constructor(address registry_, bytes32 registryCodehash_) {
        registry = registry_;
        registryCodehash = registryCodehash_;
    }

    function quotedToll(bytes32 product, uint256 amount) external view returns (uint256 fee) {
        if (registryCodehash != bytes32(0) && registry.codehash != registryCodehash) revert("not ours");
        (, uint16 b, bool live) = ITollRegistry(registry).toll(product);
        require(live, "not live");
        return (amount * b) / MAX_FEE_BPS; // borrowed 500 — WRONG (20x, or 25x under the floor)
    }
}

/// @dev A mutant registry that DOES carry an immutable, to prove the pin's precondition (NO
///      IMMUTABLES) is real: two instances with different ctor args get different codehashes.
///      NOTE: FIXED_FEE_ADDR is actually READ in `toll()` — an immutable that is never used can be
///      dropped by the optimizer and then does NOT perturb the runtime (its own small trap).
contract ImmutableRegistry is ITollRegistry {
    address internal immutable FIXED_FEE_ADDR;
    mapping(bytes32 => address) internal _r;

    constructor(address fixedFeeAddr, bytes32 p, address r) {
        FIXED_FEE_ADDR = fixedFeeAddr;
        _r[p] = r;
    }

    function toll(bytes32 product) external view returns (address recipient, uint16 feeBps, bool live) {
        address r = _r[product];
        if (r == address(0)) return (FIXED_FEE_ADDR, 0, false); // read the immutable so it is emitted
        return (r, 100, true);
    }
}

contract NegcontrolsTest is Test {
    address constant ORPHAN = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B;
    bytes32 constant P_G2B = keccak256("g2b-escrow");

    TollRegistry real;

    function setUp() public {
        bytes32[] memory ps = new bytes32[](1);
        address[] memory rs = new address[](1);
        uint16[] memory bs = new uint16[](1);
        ps[0] = P_G2B;
        rs[0] = ORPHAN;
        bs[0] = 100;
        real = new TollRegistry(ps, rs, bs);
    }

    // ================= NEGCONTROL #134 — provenance via codehash pin =================

    /// POSITIVE first: the real registry, with the real pin, is admitted and prices correctly.
    function test_pin_admitsTheRealRegistry() public {
        TolledConsumer c = new TolledConsumer(address(real), address(real).codehash);
        (address r, uint256 fee) = c.quotedToll(P_G2B, 1_000);
        assertEq(r, ORPHAN);
        assertEq(fee, 10); // 1000 * 100 / 10_000 = 10
    }

    /// THE RE-INJECT: a functioning lookalike (correct values, correct shape) from a never-pinned
    /// address is REJECTED — by provenance, not by value.
    function test_negcontrol_lookalikeRejectedByPin() public {
        LyingRegistry liar = new LyingRegistry(P_G2B, ORPHAN, 100);

        // it is a PERFECT responder: same value a value-only consumer would accept
        (address lr, uint16 lb, bool llive) = liar.toll(P_G2B);
        assertEq(lr, ORPHAN, "liar answers the right recipient");
        assertEq(lb, 100, "liar answers the right fee");
        assertTrue(llive, "liar says live");

        // consumer pinned to the REAL registry, handed the LIAR
        TolledConsumer c = new TolledConsumer(address(liar), address(real).codehash);
        assertTrue(address(liar).codehash != address(real).codehash, "lookalike code differs (the only tell)");

        vm.expectRevert(
            abi.encodeWithSelector(
                TolledConsumer.RegistryNotOurs.selector, address(liar), address(liar).codehash, address(real).codehash
            )
        );
        c.quotedToll(P_G2B, 1_000);
    }

    /// THE LOAD-BEARING HALF (scope §6: "remove the pin and confirm the lookalike is ADMITTED") —
    /// so the assert above can actually FAIL if the pin is dropped. A pin of bytes32(0) is "unpinned".
    function test_negcontrol_removePin_lookalikeAdmitted() public {
        LyingRegistry liar = new LyingRegistry(P_G2B, ORPHAN, 100);
        TolledConsumer unpinned = new TolledConsumer(address(liar), bytes32(0));

        // no pin -> the lookalike passes, proving the pin is what was doing the rejecting
        (address r, uint256 fee) = unpinned.quotedToll(P_G2B, 1_000);
        assertEq(r, ORPHAN);
        assertEq(fee, 10);
    }

    /// A liar that answers a WRONG fee is caught even without a pin — showing the two guards
    /// (provenance vs value) are different and a value-only guard is insufficient for a plausible lie.
    function test_negcontrol_lookalikeWrongValue_caughtOnlyByValue() public {
        LyingRegistry liar = new LyingRegistry(P_G2B, ORPHAN, 25); // plausible-looking wrong rate
        TolledConsumer unpinned = new TolledConsumer(address(liar), bytes32(0));
        (, uint256 fee) = unpinned.quotedToll(P_G2B, 1_000);
        assertEq(fee, 2, "25 bps -> 2 (would read as fine)");
        // and with a pin it is rejected outright, even though 25 is a plausible fleet number
        TolledConsumer pinned = new TolledConsumer(address(liar), address(real).codehash);
        vm.expectRevert();
        pinned.quotedToll(P_G2B, 1_000);
    }

    /// THE PRECONDITION of the pin (scope §4): the pin only works while the registry has NO
    /// immutables. Prove the mutant WITH an immutable breaks codehash stability, so the requirement
    /// is not vacuous.
    function test_precondition_immutableRegistryBreaksCodehashStability() public {
        ImmutableRegistry m1 = new ImmutableRegistry(address(0x1111), P_G2B, ORPHAN);
        ImmutableRegistry m2 = new ImmutableRegistry(address(0x2222), P_G2B, ORPHAN);
        assertTrue(address(m1).codehash != address(m2).codehash, "an immutable must vary the runtime");

        // contrast: our real (immutable-free) registry is stable across instances
        bytes32[] memory ps = new bytes32[](1);
        address[] memory rs = new address[](1);
        uint16[] memory bs = new uint16[](1);
        ps[0] = keccak256("z");
        rs[0] = ORPHAN;
        bs[0] = 3;
        TollRegistry other = new TollRegistry(ps, rs, bs);
        assertEq(address(other).codehash, address(real).codehash, "no-immutable registry stays stable");
    }

    // ================= NEGCONTROL #144 — the 20x denominator trap =================

    /// THE BPS THE ABSOLUTE ASSERTS BELOW ASSUME. The scope's §3 rows used 25 — the fleet rate when
    /// the doc was written — but the fleet re-rated 25 → 100 → 500 across 2026-11-07..09. So the
    /// absolutes are derived from THIS named constant and one workspace-proof row re-derives it live.
    /// A future re-rate therefore reddens ONE named constant, not the whole suite.
    ///
    /// The point of the negcontrol is the DIVERGENCE SHAPE, which is rate-independent: dividing by the
    /// borrowed `MAX_FEE_BPS=500` instead of the literal 10_000 over-charges by exactly 20x wherever
    /// the floor does not bite, and by 25x (not 20x) at tiny amounts — a "20x" assert on small numbers
    /// would itself be subtly wrong. `test_live_assumedBps_matchesFleet` re-derives ASSUMED_BPS live.
    uint16 internal constant ASSUMED_BPS = 500; // CURRENT live fleet rate (2026-11-09)

    /// Assert the trap by ABSOLUTE VALUES on the SAME inputs (scope §6): the borrowed-500 consumer
    /// over-charges the literal-10_000 consumer by exactly 20x on a registry registering ASSUMED_BPS
    /// (at 500 bps the floor does not bite at this amount). If ASSUMED_BPS moves, update the constant;
    /// the SHAPE assertions below still hold.
    function test_negcontrol_144_borrowedCeilingIs20x() public {
        bytes32[] memory ps = new bytes32[](1);
        address[] memory rs = new address[](1);
        uint16[] memory bs = new uint16[](1);
        ps[0] = P_G2B;
        rs[0] = ORPHAN;
        bs[0] = ASSUMED_BPS;
        TollRegistry q = new TollRegistry(ps, rs, bs);

        // right: literal /10_000
        TolledConsumer good = new TolledConsumer(address(q), address(q).codehash);
        (, uint256 goodFee) = good.quotedToll(P_G2B, 1_000);

        // wrong: borrowed /MAX_FEE_BPS (500) — same registry, same feeBps, only the divisor differs
        BorrowingConsumer bad = new BorrowingConsumer(address(q), address(q).codehash);
        uint256 badFee = bad.quotedToll(P_G2B, 1_000);

        // 1000 * 500 / 10_000 = 50 (exact); 1000 * 500 / 500 = 1000 (borrowed)
        assertEq(goodFee, 50, "literal consumer: 1000*500/10_000 = 50");
        assertEq(badFee, 1_000, "borrowed consumer: 1000*500/500 = 1000");
        assertEq(badFee / goodFee, 20, "at 500 bps the floor does not bite -> exactly 20x");
    }

    /// The SHAPE rows, pinned as absolutes on ASSUMED_BPS (the floor caveat is the point: 25x at tiny
    /// amounts, 20x elsewhere). NOTE: Solidity constant-folds `1_000 * 25 / 10_000` as the EXACT
    /// rational 5/2, not the floored 2 — so `a`/`b` are typed to force real integer division.
    function test_negcontrol_144_absoluteRowsFromAssumedBps() public pure {
        uint256 a = 1_000;
        uint256 b = 100_000;
        uint256 k = ASSUMED_BPS;

        // tiny amount: the floor BITES -> ratio 25x, not 20x
        assertEq(a * k / 10_000, 50); // a*k = 500_000; /10_000 = 50 exactly
        assertEq(a * k / 500, 1_000); // a*k/500 = 1000
        assertEq(a * k / 500 / (a * k / 10_000), 20); // at 500 k is exact -> 20x

        // a k where the floor genuinely bites, to show 25x: use the scope's own 25 bps row
        assertEq(a * 25 / 10_000, 2); // 25_000/10_000 = 2 (floors 2.5) -- floor bites
        assertEq(a * 25 / 500, 50);
        assertEq(a * 25 / 500 / (a * 25 / 10_000), 25, "25 bps: floor bites -> 25x, NOT 20x");

        // larger amount at 25 bps: floor no longer bites -> exactly 20x (the scope's second row)
        assertEq(b * 25 / 10_000, 250);
        assertEq(b * 25 / 500, 5_000);
        assertEq(b * 25 / 500 / (b * 25 / 10_000), 20, "100_000 at 25 bps: exactly 20x");
    }

    /// WORKSPACE PROOF that ASSUMED_BPS is the CURRENT live fleet rate — so the named constant is not
    /// just asserting its own arithmetic. Self-forks Base (needs RPC); the OTHER tests here stay
    /// fixture-only. If the fleet re-rates, this reddens naming the new value to put in the constant.
    function test_live_assumedBps_matchesFleet() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://base-rpc.publicnode.com")));
        address p2Base = 0xe9515881fe6976eD9CB55328B8308F6eF7c311a8;
        assertTrue(p2Base.code.length > 0, "p2 Registry must be live on Base");
        (bool ok, bytes memory ret) = p2Base.staticcall(abi.encodeWithSignature("feeBps()"));
        assertTrue(ok, "live p2 Registry must answer feeBps()");
        uint16 live = abi.decode(ret, (uint16));
        assertEq(live, ASSUMED_BPS, "ASSUMED_BPS must equal the live fleet rate (re-derive if the fleet re-rates)");
    }
}
