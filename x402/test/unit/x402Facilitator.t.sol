// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {x402Facilitator} from "../../src/x402Facilitator.sol";

/// @dev Lane 9 unit tests. The brief requires: verify TRUE on a matching settled payment; FALSE on
///      under-amount / wrong-recipient / unknown-id. Plus the write-side honesty (idempotent,
///      conflict-reverts, writer-gated) and re-entrancy-free reads.
contract x402FacilitatorTest is Test {
    x402Facilitator f;

    address owner;
    address writer;
    address payTo;
    address token;
    address stranger;

    bytes32 constant PID = keccak256("pay-order-1");
    uint256 constant AMOUNT = 5_000_000; // 5 USDC (6dp)

    function setUp() public {
        owner = makeAddr("owner");
        writer = makeAddr("writer");
        payTo = makeAddr("payTo");
        token = makeAddr("token");
        stranger = makeAddr("stranger");
        f = new x402Facilitator(owner);
        vm.prank(owner);
        f.setWriter(writer, true);
    }

    // --- helpers ---------------------------------------------------------

    function _mark(bytes32 id, address to, address tok, uint256 amt) internal {
        vm.prank(writer);
        f.markPaid(id, to, tok, amt);
    }

    // --- the four required cases ----------------------------------------

    function test_verify_true_on_exact_match() public {
        _mark(PID, payTo, token, AMOUNT);
        assertTrue(f.verify(PID, payTo, token, AMOUNT), "exact match must verify");
    }

    function test_verify_true_when_settled_above_min() public {
        _mark(PID, payTo, token, AMOUNT);
        assertTrue(f.verify(PID, payTo, token, AMOUNT - 1), "over-amount must verify (>= min)");
    }

    function test_verify_false_on_under_amount() public {
        _mark(PID, payTo, token, AMOUNT - 1);
        assertFalse(f.verify(PID, payTo, token, AMOUNT), "under-amount must NOT verify");
    }

    function test_verify_false_on_wrong_recipient() public {
        _mark(PID, payTo, token, AMOUNT);
        assertFalse(f.verify(PID, stranger, token, AMOUNT), "wrong recipient must NOT verify");
    }

    function test_verify_false_on_wrong_token() public {
        _mark(PID, payTo, token, AMOUNT);
        assertFalse(f.verify(PID, payTo, stranger, AMOUNT), "wrong token must NOT verify");
    }

    function test_verify_false_on_unknown_id() public {
        _mark(PID, payTo, token, AMOUNT);
        assertFalse(f.verify(keccak256("never-seen"), payTo, token, AMOUNT), "unknown id must NOT verify");
    }

    // --- write-side honesty ---------------------------------------------

    function test_mark_is_idempotent_on_identical_remark() public {
        _mark(PID, payTo, token, AMOUNT);
        _mark(PID, payTo, token, AMOUNT); // identical -> no revert
        assertTrue(f.verify(PID, payTo, token, AMOUNT));
        (, , uint256 amt, ) = f.settlement(PID);
        assertEq(amt, AMOUNT, "amount unchanged");
    }

    function test_mark_reverts_on_conflicting_remark() public {
        _mark(PID, payTo, token, AMOUNT);
        vm.prank(writer);
        vm.expectRevert(x402Facilitator.ConflictingMark.selector);
        f.markPaid(PID, payTo, token, AMOUNT + 1);
    }

    function test_mark_reverts_on_zero_id() public {
        vm.prank(writer);
        vm.expectRevert(x402Facilitator.ZeroPaymentId.selector);
        f.markPaid(bytes32(0), payTo, token, AMOUNT);
    }

    function test_mark_reverts_for_non_writer() public {
        vm.prank(stranger);
        vm.expectRevert(x402Facilitator.NotWriter.selector);
        f.markPaid(PID, payTo, token, AMOUNT);
    }

    function test_writer_gating_toggles() public {
        vm.prank(owner);
        f.setWriter(writer, false);
        vm.prank(writer);
        vm.expectRevert(x402Facilitator.NotWriter.selector);
        f.markPaid(PID, payTo, token, AMOUNT);
    }

    // --- read-side extras -------------------------------------------------

    function test_paid_adapter_matches_lane10_shape() public {
        _mark(PID, payTo, token, AMOUNT);
        (uint256 amt, uint64 at) = f.paid(PID);
        assertEq(amt, AMOUNT);
        assertEq(at, uint64(block.timestamp));

        (uint256 z, uint64 zat) = f.paid(keccak256("nope"));
        assertEq(z, 0);
        assertEq(zat, 0);
    }

    function test_settlement_zeroed_for_unknown() public view {
        (address to, address tok, uint256 amt, uint64 at) = f.settlement(PID);
        assertEq(to, address(0));
        assertEq(tok, address(0));
        assertEq(amt, 0);
        assertEq(at, 0);
    }

    // --- admin ------------------------------------------------------------

    function test_constructor_rejects_zero_owner() public {
        vm.expectRevert(x402Facilitator.ZeroAddress.selector);
        new x402Facilitator(address(0));
    }

    function test_transfer_ownership() public {
        vm.prank(owner);
        f.transferOwnership(stranger);
        assertEq(f.owner(), stranger);
    }

    function test_only_owner_sets_writer() public {
        vm.prank(stranger);
        vm.expectRevert(x402Facilitator.NotOwner.selector);
        f.setWriter(stranger, true);
    }

    // --- fuzz: verify is exactly [hasSettled && to==p && tok==t && amt>=min] ---

    function testFuzz_verify_is_strict(
        bytes32 id, address to, address tok, uint256 amt, address qto, address qtok, uint256 minAmt
    ) public {
        vm.assume(id != bytes32(0) && to != address(0));
        _mark(id, to, tok, amt);

        bool expected = (qto == to) && (qtok == tok) && (amt >= minAmt);
        assertEq(f.verify(id, qto, qtok, minAmt), expected, "verify must equal the strict predicate");
    }
}
