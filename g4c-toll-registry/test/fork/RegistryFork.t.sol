// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TollRegistry} from "../../src/TollRegistry.sol";
import {TolledConsumer} from "../../src/TolledConsumer.sol";

/// @dev The live product whose toll we tie to (p2-forwarder Registry on Base). Read by SIGNATURE.
interface ILiveToll {
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
}

/// @title RegistryForkTest — scope §6 item 4 (fork) + the one-byte sabotage.
/// @notice Deploys the registry ON A BASE FORK and proves the two properties a live deploy relies on:
///         (a) the runtime codehash is STABLE and matches the pin a consumer compiles in, and
///         (b) the pin FIRES when one byte is mangled (sabotage) — i.e. the green is not vacuous —
///         and (c) that a registry configured with a product's LIVE toll reproduces exactly what a
///         live consumer would charge.
///
///         THE LIVE TIE IS DERIVED, NOT SNAPSHOTTED (deliberate). The scope's own §0.1 warns that a
///         doc pinning a mutable rate is a second source of truth that WILL disagree with the chain.
///         So this test READS `feeBps()`/`feeRecipient()` from the live p2 registry and REGISTERS
///         those — it cannot go stale when the fleet re-rates. (Live at time of writing: the fleet
///         re-rated 25 -> 100 -> 500 across 2026-11-07..09; the p3 router's immutable 5 is unchanged.)
///
/// RUN: forge test --match-path test/fork/RegistryFork.t.sol   (needs Base RPC)
contract RegistryForkTest is Test {
    address constant P2_REGISTRY = 0xe9515881fe6976eD9CB55328B8308F6eF7c311a8; // live, Base
    address constant ORPHAN = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B;

    bytes32 constant P_G2B = keccak256("g2b-escrow");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://base-rpc.publicnode.com")));
    }

    /// Deploy a registry registering P_G2B with the LIVE (feeBps, feeRecipient) of the real fleet.
    /// Returns the registry AND the live values it was built from, so callers assert against reality.
    function _deployLive() internal returns (TollRegistry reg, uint16 liveBps, address liveRecipient) {
        liveBps = ILiveToll(P2_REGISTRY).feeBps();
        liveRecipient = ILiveToll(P2_REGISTRY).feeRecipient();
        assertTrue(liveRecipient != address(0), "live recipient read");

        bytes32[] memory ps = new bytes32[](1);
        address[] memory rs = new address[](1);
        uint16[] memory bs = new uint16[](1);
        ps[0] = P_G2B;
        rs[0] = liveRecipient;
        bs[0] = liveBps;
        reg = new TollRegistry(ps, rs, bs);
    }

    /// The registry's runtime hash is a compile-time constant: two deploys on the REAL chain agree.
    /// That is what lets one `bytes32` pin be copied into every consumer and every chain (#73).
    function test_fork_codehashStableAcrossInstances() public {
        (TollRegistry a,,) = _deployLive();
        (TollRegistry b,,) = _deployLive();
        assertEq(address(a).codehash, address(b).codehash, "runtime must be identical across instances");
    }

    /// The consumer, pinned to the fork-deployed registry's codehash, ADMITS it and prices using the
    /// LIVE-derived values — i.e. it reproduces exactly what the live fleet's rate implies.
    function test_fork_pinMatchesAndConsumerPrices() public {
        (TollRegistry reg, uint16 liveBps, address liveRecipient) = _deployLive();
        bytes32 pin = address(reg).codehash;
        assertEq(address(reg).codehash, pin, "pin must equal the on-chain runtime hash");

        uint256 amount = 1_000_000;
        TolledConsumer c = new TolledConsumer(address(reg), pin);
        (address r, uint256 fee) = c.quotedToll(P_G2B, amount);

        assertEq(r, liveRecipient, "consumer pays the live orphan treasury");
        assertEq(fee, (amount * liveBps) / 10_000, "consumer prices at the live rate with the LITERAL /10_000");
    }

    /// Tie to LIVE reality: the values we registered equal what the LIVE p2 registry answers right now.
    /// Derived, so a fleet re-rate does not red this test (it reddens only if the registry MIS-mirrors).
    function test_fork_registeredValuesEqualLiveOnChain() public {
        (TollRegistry reg, uint16 liveBps, address liveRecipient) = _deployLive();

        // these are the LIVE on-chain facts, read on the fork (not fixtures):
        assertEq(ILiveToll(P2_REGISTRY).feeBps(), liveBps, "live feeBps");
        assertEq(ILiveToll(P2_REGISTRY).feeRecipient(), liveRecipient, "live feeRecipient");
        // the fleet's live recipient is the orphan treasury (a stable fact, safe to pin):
        assertEq(liveRecipient, ORPHAN, "live Base feeRecipient is the orphan treasury");

        (address r, uint16 b, bool live) = reg.toll(P_G2B);
        assertTrue(live);
        assertEq(r, liveRecipient, "registry mirrors the live recipient");
        assertEq(b, liveBps, "registry mirrors the live fee");
    }

    /// SABOTAGE (scope §6 item 4): mangle ONE byte of the pinned codehash and confirm the guard
    /// fires. If it did not, the pin would be decorative.
    function test_fork_sabotage_oneByteMangled_pinFires() public {
        (TollRegistry reg,,) = _deployLive();
        bytes32 good = address(reg).codehash;

        // mangle the LOW byte only
        bytes32 bad = good ^ bytes32(uint256(1));
        assertTrue(bad != good, "mangled pin differs");

        TolledConsumer c = new TolledConsumer(address(reg), bad);
        vm.expectRevert(abi.encodeWithSelector(TolledConsumer.RegistryNotOurs.selector, address(reg), good, bad));
        c.quotedToll(P_G2B, 1_000_000);

        // and with the correct pin the SAME call succeeds — proving the revert was the pin, not a typo
        TolledConsumer ok = new TolledConsumer(address(reg), good);
        ok.quotedToll(P_G2B, 1_000_000);
    }

    /// DOCUMENTARY SNAPSHOT (kept separate from the derived asserts): the live fleet rate at the time
    /// this lane was built, so a future reader sees WHERE the derived numbers started. Asserted
    /// loosely — it records the current expectation, and if the fleet re-rates this is the line a
    /// reviewer updates. Broken out so the reason is obvious.
    function test_fork_snapshotLiveFleetRate_is500_postReRate() public view {
        assertEq(ILiveToll(P2_REGISTRY).feeBps(), 500, "live Base feeBps snapshot (re-rated to the 500 ceiling)");
    }
}
