// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {ReferralRegistry} from "../../src/ReferralRegistry.sol";

contract BadToken {
    mapping(address=>uint) public balanceOf; mapping(address=>mapping(address=>uint)) public allowance;
    bool public tFalse; bool public tRevert;
    function mint(address t,uint a) external { balanceOf[t]+=a; }
    function approve(address s,uint a) external returns(bool){ allowance[msg.sender][s]=a; return true; }
    function setTransfer(bool _f,bool _r) external { tFalse=_f; tRevert=_r; }
    function transferFrom(address f,address t,uint a) external returns(bool){ allowance[f][msg.sender]-=a; balanceOf[f]-=a; balanceOf[t]+=a; return true; }
    function transfer(address t,uint a) external returns(bool){ if(tRevert) revert("x"); if(tFalse) return false; balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
}
contract Rejector { receive() external payable { revert(); } }

contract FeesAdversarialTest is Test {
    FeeSplitter s; BadToken tok; address treasury=makeAddr("treasury"); address ref=makeAddr("ref");
    function setUp() public { s=new FeeSplitter(treasury); tok=new BadToken(); tok.mint(address(this),1e24); tok.approve(address(s),type(uint256).max); }

    /// split is EXACT: referrerCut + treasuryCut == fee, no dust leak.
    function test_probe_splitIsExact_noDust() public {
        (uint r,uint t)=s.split(address(tok), 999, "p", makeAddr("payer"), ref);
        assertEq(r+t, 999, "exact, no rounding leak");
        assertEq(r, uint256(999)*2500/10000, "referrer cut");
    }
    /// referrer==0 -> ALL to treasury.
    function test_probe_zeroReferrer_allTreasury() public {
        (uint r,uint t)=s.split(address(tok), 1000, "p", makeAddr("payer"), address(0));
        assertEq(r,0); assertEq(t,1000);
    }
    /// reverting/return-false TReasury transfer accrues to claimable, doesn't brick the split.
    function test_probe_falseTransfer_accrues_doesNotBrick() public {
        tok.setTransfer(true,false); // payout transfer returns false; pull stays ok
        s.split(address(tok), 1000, "p", makeAddr("payer"), ref);
        assertEq(s.claimable(ref, address(tok)), 250, "referrer owed booked on false-transfer");
        assertEq(s.claimable(treasury, address(tok)), 750, "treasury owed booked");
    }
    /// native: a reverting-receive referrer does not brick splitNative.
    function test_probe_nativeRevertingReceiver_bookedNotBricked() public {
        Rejector bad = new Rejector();
        vm.deal(address(this), 1 ether);
        (uint r,) = s.splitNative{value: 1 ether}("p", makeAddr("payer"), address(bad));
        assertEq(s.claimable(address(bad), address(0)), r, "native owed booked, split not bricked");
    }
    /// claim zero-amount is a no-op (returns 0, no revert).
    function test_probe_claimZero_noop() public {
        assertEq(s.claim(address(tok)), 0);
    }
    /// double-claim: second claim returns 0 (effects-before-interaction).
    function test_probe_doubleClaim_secondIsZero() public {
        tok.setTransfer(true,false); s.split(address(tok),1000,"p",makeAddr("payer"),ref);
        tok.setTransfer(false,false); // now claim can pay out
        vm.prank(ref); uint a=s.claim(address(tok)); assertEq(a,250);
        vm.prank(ref); uint b=s.claim(address(tok)); assertEq(b,0,"second claim empty");
    }
}

/// @dev dex-critic probe: a BARE native send (no calldata) to FeeSplitter is accepted by
///      `receive()` but NOTHING ever spends the contract's native balance — `split` pulls tokens,
///      `splitNative` distributes only `msg.value`, and there is no sweep. Stray ETH is a dead drop.
contract StrayNativeProbe is Test {
    FeeSplitter s; address treasury=makeAddr("treasury");
    function setUp() public { s=new FeeSplitter(treasury); }
    function test_probe_bareSendIsStranded() public {
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(s).call{value: 1 ether}("");   // bare send, no calldata
        assertTrue(ok, "receive() accepted it");
        assertEq(address(s).balance, 1 ether, "1 ETH now sits in the splitter");
        // a subsequent splitNative distributes ONLY its own msg.value; prior balance untouched
        s.splitNative{value: 1 ether}("p", makeAddr("payer"), address(0));
        assertEq(address(s).balance, 1 ether, "stray 1 ETH still there after a splitNative");
        assertEq(treasury.balance, 1 ether, "treasury got the NEW split's cut, not the stray");
        // and there is no sweep()/withdraw() to recover it
        assertEq(address(s).balance, 1 ether, "no sweep => stranded");
    }
}
