// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SettlementRegistry} from "../../src/SettlementRegistry.sol";
import {ISettlementRegistry} from "../../src/interfaces/ISettlementRegistry.sol";

/// @notice Unit tests for the settlement read-side. Each named case maps 1:1 to the lane brief:
/// writer-only guard, idempotent re-mark, mismatch revert, unknown id -> (0,0); plus a NEGATIVE
/// CONTROL that a non-writer mark reverts (so the guard is proven to bite, not merely present).
contract SettlementRegistryTest is Test {
    SettlementRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal railA = makeAddr("railA");
    address internal railB = makeAddr("railB");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant PID = keccak256("payment-1");

    event Settled(bytes32 indexed paymentId, uint256 amount, uint64 at);
    event WriterSet(address indexed writer, bool allowed);

    function setUp() public {
        reg = new SettlementRegistry(owner);
        vm.prank(owner);
        reg.setWriter(railA, true);
    }

    // ---- happy path: a writer marks, and `paid` reflects it ----

    function test_markPaid_recordsAmountAndTime() public {
        uint256 amount = 5_000_000;
        vm.warp(1_700_000_123);
        vm.expectEmit(true, false, false, true, address(reg));
        emit Settled(PID, amount, uint64(1_700_000_123));

        vm.prank(railA);
        reg.markPaid(PID, amount);

        (uint256 got, uint64 at) = reg.paid(PID);
        assertEq(got, amount, "amount not recorded");
        assertEq(at, uint64(1_700_000_123), "timestamp not recorded");
        assertTrue(reg.isPaid(PID), "isPaid false after mark");
    }

    // ---- unknown id returns (0, 0) ----

    function test_paid_unknownId_returnsZeroZero() public view {
        (uint256 amount, uint64 at) = reg.paid(keccak256("never-seen"));
        assertEq(amount, 0, "unknown amount != 0");
        assertEq(at, 0, "unknown at != 0");
    }

    function test_isPaid_unknownId_false() public view {
        assertFalse(reg.isPaid(keccak256("never-seen")), "unknown id reads paid");
    }

    // ---- idempotent re-mark: same id + same amount is a no-op (no second event) ----

    function test_markPaid_sameIdSameAmount_isNoop() public {
        vm.prank(railA);
        reg.markPaid(PID, 1_000);

        // Second identical mark: expect NO Settled event (record the topic once, assert once).
        vm.recordLogs();
        vm.prank(railA);
        reg.markPaid(PID, 1_000);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no-op re-mark emitted a log");

        (uint256 amount, uint64 at) = reg.paid(PID);
        assertEq(amount, 1_000, "amount drifted on idempotent re-mark");
        assertEq(at, uint64(block.timestamp), "timestamp drifted on idempotent re-mark");
    }

    /// A different WRITER re-marking the SAME id + amount is also a no-op — idempotency is keyed on
    /// the record, not the caller, so two rails racing to report one settlement do not double-record.
    function test_markPaid_secondWriterSameAmount_alsoNoop() public {
        vm.prank(owner);
        reg.setWriter(railB, true);

        vm.prank(railA);
        reg.markPaid(PID, 42);

        vm.prank(railB);
        reg.markPaid(PID, 42); // must not revert, must not rewrite

        (uint256 amount,) = reg.paid(PID);
        assertEq(amount, 42, "cross-writer no-op changed the record");
    }

    // ---- mismatch revert: same id, different amount is loud ----

    function test_markPaid_sameIdDifferentAmount_reverts() public {
        vm.prank(railA);
        reg.markPaid(PID, 1_000);

        vm.expectRevert(
            abi.encodeWithSelector(SettlementRegistry.AmountMismatch.selector, PID, uint256(1_000), uint256(2_000))
        );
        vm.prank(railA);
        reg.markPaid(PID, 2_000);

        // and the FIRST amount survives the failed second call
        (uint256 amount,) = reg.paid(PID);
        assertEq(amount, 1_000, "first amount not preserved after mismatch revert");
    }

    // ---- writer-only guard ----

    function test_markPaid_nonWriter_reverts() public {
        // NEGATIVE CONTROL: `stranger` was never allow-listed.
        vm.expectRevert(SettlementRegistry.NotWriter.selector);
        vm.prank(stranger);
        reg.markPaid(PID, 7);
    }

    function test_markPaid_ownerIsNotImplicitlyWriter() public {
        // The owner adds writers; being the owner is NOT itself write permission.
        vm.expectRevert(SettlementRegistry.NotWriter.selector);
        vm.prank(owner);
        reg.markPaid(PID, 7);
    }

    function test_markPaid_revokedWriter_reverts() public {
        vm.prank(owner);
        reg.setWriter(railA, false);
        assertFalse(reg.isWriter(railA), "writer not revoked");

        vm.expectRevert(SettlementRegistry.NotWriter.selector);
        vm.prank(railA);
        reg.markPaid(PID, 7);
    }

    // ---- writer/owner admin gating ----

    function test_setWriter_onlyOwner() public {
        vm.expectRevert(SettlementRegistry.NotOwner.selector);
        vm.prank(stranger);
        reg.setWriter(stranger, true);
    }

    function test_setWriter_batch() public {
        address[] memory ws = new address[](2);
        ws[0] = railB;
        ws[1] = stranger;
        vm.prank(owner);
        reg.setWriters(ws, true);
        assertTrue(reg.isWriter(railB), "batch writer not added");
        assertTrue(reg.isWriter(stranger), "batch writer not added");
    }

    function test_transferOwnership() public {
        vm.prank(owner);
        reg.transferOwnership(stranger);
        assertEq(reg.owner(), stranger, "ownership not transferred");

        // old owner is now powerless, new owner can add writers
        vm.expectRevert(SettlementRegistry.NotOwner.selector);
        vm.prank(owner);
        reg.setWriter(railB, true);

        vm.prank(stranger);
        reg.setWriter(railB, true);
        assertTrue(reg.isWriter(railB), "new owner could not set writer");
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(SettlementRegistry.ZeroArg.selector);
        new SettlementRegistry(address(0));
    }

    // ---- edge: a legitimate ZERO-amount settlement is distinguishable from unknown ----

    /// A writer may settle an id for amount 0 (e.g. a zero-value invoice). `at != 0` is the settled
    /// predicate, so this must read as PAID, not as unknown.
    function test_markPaid_zeroAmount_isStillPaid() public {
        vm.warp(1_000);
        vm.prank(railA);
        reg.markPaid(PID, 0);

        (uint256 amount, uint64 at) = reg.paid(PID);
        assertEq(amount, 0, "amount should be 0");
        assertEq(at, 1_000, "zero-amount mark must still stamp `at`");
        assertTrue(reg.isPaid(PID), "zero-amount settlement read as unknown");
    }

    // ---- fuzz: idempotency holds for arbitrary ids/amounts ----

    function testFuzz_markPaid_idempotent(bytes32 id, uint256 amount) public {
        vm.prank(railA);
        reg.markPaid(id, amount);
        vm.prank(railA);
        reg.markPaid(id, amount); // must not revert

        (uint256 got, uint64 at) = reg.paid(id);
        assertEq(got, amount, "fuzz: amount drifted");
        assertEq(at, uint64(block.timestamp), "fuzz: at drifted");
    }

    function testFuzz_markPaid_mismatchAlwaysReverts(bytes32 id, uint256 a, uint256 b) public {
        vm.assume(a != b);
        vm.prank(railA);
        reg.markPaid(id, a);

        vm.expectRevert(abi.encodeWithSelector(SettlementRegistry.AmountMismatch.selector, id, a, b));
        vm.prank(railA);
        reg.markPaid(id, b);
    }
}
