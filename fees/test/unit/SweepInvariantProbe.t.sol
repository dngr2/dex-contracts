// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";

contract Rej { receive() external payable { if (reject) revert(); } bool public reject=true; function set(bool r) external { reject=r; } }

/// dex-critic independent probe of the #204 fix: sweep must NEVER strand a pending payee claim.
contract SweepInvariantProbe is Test {
    FeeSplitter s; address treasury=makeAddr("treasury");
    function setUp() public { s=new FeeSplitter(treasury); vm.deal(address(this), 20 ether); }

    // INVARIANT: address(this).balance >= s.nativeOwed at all times => every claim is honorable.
    function _inv() internal view { assertGe(address(s).balance, s.nativeOwed(), "balance must cover owed"); }

    function test_probe_sweepNeverStrandsClaim() public {
        Rej bad = new Rej();
        // referrer = bad (reverting receiver) -> its native cut is booked, not paid
        (uint r,) = s.splitNative{value: 2 ether}("p", makeAddr("payer"), address(bad));
        assertEq(s.claimable(address(bad), address(0)), r, "bad payee owed");
        assertEq(s.nativeOwed(), r, "owed tracked");
        _inv();
        // add 3 ether of pure stray surplus
        (bool ok,) = address(s).call{value: 3 ether}(""); assertTrue(ok);
        _inv();
        // owner sweeps: must take ONLY the 3 ether surplus, leaving r owed
        uint before = treasury.balance;
        vm.prank(address(this)); uint swept = s.sweepNative();
        assertEq(swept, 3 ether, "swept exactly the surplus");
        assertEq(treasury.balance - before, 3 ether, "treasury got surplus");
        assertEq(address(s).balance, r, "owed still present");
        _inv();
        // payee can now accept and claim the full owed
        bad.set(false);
        vm.prank(address(bad)); uint got = s.claim(address(0));
        assertEq(got, r, "payee claims in full after a sweep");
        assertEq(address(s).balance, 0, "contract drained of exactly owed+surplus");
        assertEq(s.nativeOwed(), 0);
        _inv();
    }

    function test_probe_sweepWithNoOwed_takesAll() public {
        (bool ok,) = address(s).call{value: 1 ether}(""); assertTrue(ok);
        vm.prank(address(this)); uint swept = s.sweepNative();
        assertEq(swept, 1 ether, "all of it is recoverable when nothing owed");
        assertEq(address(s).balance, 0);
    }

    function test_probe_secondSweep_revertsNothingToSweep() public {
        (bool ok,) = address(s).call{value: 1 ether}(""); assertTrue(ok);
        vm.prank(address(this)); s.sweepNative();
        vm.prank(address(this)); vm.expectRevert(FeeSplitter.NothingToSweep.selector); s.sweepNative();
    }

    function test_probe_onlyOwnerSweeps() public {
        (bool ok,) = address(s).call{value: 1 ether}(""); assertTrue(ok);
        vm.prank(makeAddr("rando")); vm.expectRevert(); s.sweepNative();
    }

    /// adversarial interleave: claim THEN sweep; sweep then more owed then sweep.
    function test_probe_interleaved_owedAlwaysSecure() public {
        Rej bad = new Rej();
        (uint r,) = s.splitNative{value: 4 ether}("p", makeAddr("payer"), address(bad));
        _inv();
        (bool ok,) = address(s).call{value: 1 ether}(""); assertTrue(ok);
        // half-sweep scenario: owed r, surplus 1 -> sweep 1
        vm.prank(address(this)); uint swept = s.sweepNative(); assertEq(swept, 1 ether); _inv();
        // a SECOND reverting payout adds more owed
        Rej bad2 = new Rej();
        (uint r2,) = s.splitNative{value: 2 ether}("p", makeAddr("payer"), address(bad2));
        assertEq(s.nativeOwed(), r + r2, "both owed tracked"); _inv();
        // now nothing recoverable (all balance is owed)
        assertEq(s.nativeRecoverable(), 0, "no surplus left");
        vm.prank(address(this)); vm.expectRevert(FeeSplitter.NothingToSweep.selector); s.sweepNative();
        // both payees claim fully
        bad.set(false); bad2.set(false);
        vm.prank(address(bad)); assertEq(s.claim(address(0)), r);
        vm.prank(address(bad2)); assertEq(s.claim(address(0)), r2);
        _inv();
    }
}
