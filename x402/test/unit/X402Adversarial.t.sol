// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
import {Test} from "forge-std/Test.sol";
import {x402Facilitator} from "../../src/x402Facilitator.sol";

contract X402AdversarialTest is Test {
    x402Facilitator f;
    address owner = makeAddr("owner"); address writer = makeAddr("writer");
    address merchant = makeAddr("merchant"); address tok = makeAddr("usdc");
    bytes32 id = keccak256("pay1");
    function setUp() public { f = new x402Facilitator(owner); vm.prank(owner); f.setWriter(writer, true); }
    function _mark(address to,address t,uint a) internal { vm.prank(writer); f.markPaid(id,to,t,a); }

    function test_probe_verifyExactMatch_only() public {
        _mark(merchant, tok, 1000);
        assertTrue(f.verify(id, merchant, tok, 1000), "exact");
        assertTrue(f.verify(id, merchant, tok, 999), "min<=settled");
        assertFalse(f.verify(id, merchant, tok, 1001), "min>settled");
        assertFalse(f.verify(id, makeAddr("wrongTo"), tok, 1000), "wrong recipient");
        assertFalse(f.verify(id, merchant, makeAddr("wrongTok"), 1000), "wrong token");
        assertFalse(f.verify(keccak256("nope"), merchant, tok, 1000), "unknown id");
    }
    function test_probe_nonWriter_cannotMark() public {
        vm.prank(makeAddr("rando")); vm.expectRevert(x402Facilitator.NotWriter.selector); f.markPaid(id,merchant,tok,1);
    }
    function test_probe_conflictingRemark_reverts() public {
        _mark(merchant, tok, 1000);
        vm.prank(writer); vm.expectRevert(x402Facilitator.ConflictingMark.selector); f.markPaid(id,merchant,tok,2000);
        vm.prank(writer); f.markPaid(id,merchant,tok,1000); // identical -> no-op, no revert
        assertTrue(f.verify(id,merchant,tok,1000));
    }
    function test_probe_zeroAmountSettled_isDistinctFromUnknown() public {
        _mark(merchant, tok, 0);
        assertTrue(f.verify(id, merchant, tok, 0), "zero-amount settlement is a real settle");
        (uint256 amt, uint64 at) = f.paid(id);
        assertEq(amt, 0); assertTrue(at != 0, "at set -> distinct from unknown (0,0)");
    }
}
