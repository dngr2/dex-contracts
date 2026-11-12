// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PickyToken, RevertingReceiver} from "./mocks/RevertingReceiver.sol";

contract FeeSplitterTest is Test {
    FeeSplitter internal splitter;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal referrer = makeAddr("referrer");
    address internal payer = makeAddr("payer");
    address internal rail = address(this);

    function setUp() public {
        vm.prank(owner);
        splitter = new FeeSplitter(treasury, owner);
        token = new MockERC20();
        token.mint(rail, 1_000_000e18);
        token.approve(address(splitter), type(uint256).max);
    }

    // ---------------------------------------------------------------- conservation

    /// @dev THE invariant: fee == referrerCut + treasuryCut EXACTLY, across many odd amounts.
    function testFuzz_conservation_exact(uint256 fee) public {
        fee = bound(fee, 0, 500_000e18);
        (uint256 rc, uint256 tc) = splitter.split(address(token), fee, "prod", payer, referrer);
        assertEq(rc + tc, fee, "split must equal fee exactly");
        assertEq(rc, (fee * 2500) / 10_000, "referrer gets referralBps");
        assertEq(tc, fee - rc, "treasury gets remainder");
        assertEq(token.balanceOf(referrer), rc, "referrer paid inline");
        assertEq(token.balanceOf(treasury), tc, "treasury paid inline");
    }

    function test_split_default25pct_1000wei() public {
        (uint256 rc, uint256 tc) = splitter.split(address(token), 1000, "prod", payer, referrer);
        assertEq(rc, 250, "25% of 1000");
        assertEq(tc, 750, "remainder");
        assertEq(rc + tc, 1000, "exact");
    }

    /// @dev rounding: an odd fee that does not divide evenly must NOT leak a wei.
    function test_split_oddAmount_noLeak() public {
        uint256 fee = 333;
        (uint256 rc, uint256 tc) = splitter.split(address(token), fee, "prod", payer, referrer);
        assertEq(rc, (fee * 2500) / 10_000); // 83 (floored)
        assertEq(tc, fee - 83);              // 250 — remainder keeps the dust
        assertEq(rc + tc, fee, "no wei leak");
    }

    function test_zeroReferrer_allToTreasury() public {
        (uint256 rc, uint256 tc) = splitter.split(address(token), 500, "prod", payer, address(0));
        assertEq(rc, 0, "no referrer cut");
        assertEq(tc, 500, "all to treasury");
        assertEq(token.balanceOf(treasury), 500);
    }

    function test_zeroFee_noop() public {
        (uint256 rc, uint256 tc) = splitter.split(address(token), 0, "prod", payer, referrer);
        assertEq(rc + tc, 0);
    }

    /// @dev boundary: a tiny fee where referrerCut floors to 0 -> all to treasury, no zero-transfer,
    /// conservation holds. (3 * 2500 / 10000 = 0.)
    function test_tinyFee_referrerCutFloorsToZero() public {
        (uint256 rc, uint256 tc) = splitter.split(address(token), 3, "prod", payer, referrer);
        assertEq(rc, 0, "rounds to zero");
        assertEq(tc, 3, "all to treasury");
        assertEq(token.balanceOf(treasury), 3, "treasury got it, no revert");
    }

    function test_nativeSplit_conservation() public {
        vm.deal(rail, 10 ether);
        (uint256 rc, uint256 tc) = splitter.splitNative{value: 1 ether}("prod", payer, referrer);
        assertEq(rc + tc, 1 ether, "native exact");
        assertEq(rc, 0.25 ether);
        assertEq(referrer.balance, 0.25 ether);
        assertEq(treasury.balance, 0.75 ether);
    }

    // ---------------------------------------------------------------- reverting referrer

    /// @dev NEGCONTROL: referrer's token transfer reverts -> split must NOT brick, must accrue
    /// referrerCut to claimable, must still pay treasury inline, and conservation still holds.
    function test_revertingReferrer_accruesNotBrick() public {
        PickyToken picky = new PickyToken();
        picky.mint(rail, 10_000);
        picky.approve(address(splitter), type(uint256).max);
        picky.setReject(referrer, true); // referrer rejects this token

        (uint256 rc, uint256 tc) = splitter.split(address(picky), 1000, "prod", payer, referrer);
        assertEq(rc + tc, 1000, "conservation holds even on revert path");
        assertEq(rc, 250);
        assertEq(tc, 750);
        assertEq(picky.balanceOf(treasury), 750, "treasury still paid inline");
        assertEq(picky.balanceOf(referrer), 0, "referrer got nothing inline");
        assertEq(splitter.claimable(referrer, address(picky)), 250, "referrer cut ACCRUED, not lost");

        // referrer stops rejecting, then claims
        picky.setReject(referrer, false);
        vm.prank(referrer);
        uint256 got = splitter.claim(address(picky));
        assertEq(got, 250, "claims the accrued amount");
        assertEq(picky.balanceOf(referrer), 250);
        assertEq(splitter.claimable(referrer, address(picky)), 0, "claimable cleared");
    }

    /// @dev NEGCONTROL native: referrer rejects native -> accrues native claimable.
    function test_revertingReferrerNative_accrues() public {
        RevertingReceiver bad = new RevertingReceiver(true, true);
        vm.deal(rail, 1 ether);
        (uint256 rc, uint256 tc) = splitter.splitNative{value: 1 ether}("prod", payer, address(bad));
        assertEq(rc + tc, 1 ether, "conservation holds");
        assertEq(address(bad).balance, 0, "native refused");
        assertEq(treasury.balance, 0.75 ether, "treasury still paid");
        assertEq(splitter.claimable(address(bad), address(0)), 0.25 ether, "accrued native");
    }

    /// @dev The task's exact case: BOTH payees revert -> BOTH cuts accrue, nothing lost, and the
    /// conservation identity still holds. Then both claim once they stop rejecting.
    function test_bothRevert_bothAccrue() public {
        PickyToken picky = new PickyToken();
        picky.mint(rail, 10_000);
        picky.approve(address(splitter), type(uint256).max);
        picky.setReject(referrer, true);
        picky.setReject(treasury, true);

        (uint256 rc, uint256 tc) = splitter.split(address(picky), 1000, "prod", payer, referrer);
        assertEq(rc + tc, 1000, "conservation holds when both reject");
        assertEq(splitter.claimable(referrer, address(picky)), rc, "referrer accrued");
        assertEq(splitter.claimable(treasury, address(picky)), tc, "treasury accrued");
        assertEq(picky.balanceOf(address(splitter)), 1000, "whole fee parked, not lost");

        picky.setReject(referrer, false);
        picky.setReject(treasury, false);
        vm.prank(referrer);
        assertEq(splitter.claim(address(picky)), rc);
        vm.prank(treasury);
        assertEq(splitter.claim(address(picky)), tc);
        assertEq(picky.balanceOf(address(splitter)), 0, "splitter drained exactly");
    }

    /// @dev A token that returns false on `transfer` (a lying token, no revert) must be treated as
    /// a FAILED payout -> accrued to claimable, not silently recorded as paid. Here the pull also
    /// lies, so the split reverts at the pull (TransferFromFailed) — a separate case from a live
    /// pull. We assert BOTH phases.
    function test_falseReturningToken_behaviour() public {
        MockERC20 liar = new MockERC20();
        liar.mint(rail, 10_000);
        liar.approve(address(splitter), type(uint256).max);

        // phase 1: honest pull + honest payouts -> fine
        (uint256 rc, uint256 tc) = splitter.split(address(liar), 1000, "prod", payer, referrer);
        assertEq(rc + tc, 1000);

        // phase 2: token now lies on transfer -> the PULL lies first, so revert at pull
        liar.setReturnFalse(true);
        vm.expectRevert(FeeSplitter.TransferFromFailed.selector);
        splitter.split(address(liar), 1000, "prod", payer, referrer);
    }

    /// @dev Only the PAYOUT lies (transferFrom stays honest) -> both cuts ACCRUE, no brick, and
    /// conservation still holds. Models a token that accepts the pull but returns false on
    /// transfer-to-a-holder.
    function test_falseReturningPayout_accrues() public {
        MockERC20 liar = new MockERC20();
        liar.mint(rail, 10_000);
        liar.approve(address(splitter), type(uint256).max);
        liar.setLieTransfersOnly(true); // transferFrom honest, transfer lies

        (uint256 rc, uint256 tc) = splitter.split(address(liar), 1000, "prod", payer, referrer);
        assertEq(rc + tc, 1000, "conservation holds on false-return path");
        assertEq(liar.balanceOf(referrer), 0, "referrer not paid (transfer lied)");
        assertEq(liar.balanceOf(treasury), 0, "treasury not paid (transfer lied)");
        assertEq(splitter.claimable(referrer, address(liar)), rc, "referrer cut ACCRUED");
        assertEq(splitter.claimable(treasury, address(liar)), tc, "treasury cut ACCRUED");

        // stop lying -> both can claim
        liar.setLieTransfersOnly(false);
        vm.prank(referrer);
        assertEq(splitter.claim(address(liar)), rc);
        vm.prank(treasury);
        assertEq(splitter.claim(address(liar)), tc);
    }

    // ---------------------------------------------------------------- native strand / sweep (GOTCHA #204)

    /// @dev NEGCONTROL for #204: a BARE send() to the splitter lands in receive() and is NOT split.
    /// Without a sweep it would be stranded forever. Assert it is recoverable, not lost.
    function test_bareSend_isStrandedButRecoverable() public {
        vm.deal(rail, 10 ether);
        (bool ok,) = address(splitter).call{value: 1 ether}(""); // bare send -> receive()
        assertTrue(ok, "receive accepts");
        assertEq(address(splitter).balance, 1 ether, "stranded in contract");
        assertEq(splitter.nativeRecoverable(), 1 ether, "fully recoverable");

        vm.prank(owner);
        uint256 swept = splitter.sweepNative();
        assertEq(swept, 1 ether, "swept the strand");
        assertEq(treasury.balance, 1 ether, "treasury recovered it");
        assertEq(address(splitter).balance, 0, "contract drained");
        assertEq(splitter.nativeRecoverable(), 0, "nothing left");
    }

    /// @dev The cap that matters: sweep MUST NOT drain native owed to a reverting payee. A bare send
    /// plus a pending native claim -> sweep recovers ONLY the excess, the payee still claims in full.
    function test_sweep_doesNotDrainClaimable() public {
        RevertingReceiver bad = new RevertingReceiver(true, true);
        vm.deal(rail, 10 ether);
        // a real split where the referrer rejects native -> 0.25 ether accrues to claimable
        splitter.splitNative{value: 1 ether}("prod", payer, address(bad));
        assertEq(splitter.claimable(address(bad), address(0)), 0.25 ether, "native accrued");
        assertEq(splitter.nativeOwed(), 0.25 ether, "owed tracked");

        // an unrelated bare send lands on top
        (bool ok,) = address(splitter).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(splitter.nativeRecoverable(), 2 ether, "only the excess is recoverable");

        vm.prank(owner);
        uint256 swept = splitter.sweepNative();
        assertEq(swept, 2 ether, "swept only the strand, kept the owed");
        assertEq(address(splitter).balance, 0.25 ether, "owed native STILL parked");

        // the payee still claims in full — sweep did not steal it
        bad.setRejectNative(false); // payee stops rejecting so it can receive
        vm.prank(address(bad));
        assertEq(splitter.claim(address(0)), 0.25 ether, "payee claims full owed amount");
        assertEq(splitter.nativeOwed(), 0, "owed cleared");
        assertEq(address(splitter).balance, 0, "contract empty at rest");
    }

    function test_sweep_onlyOwner() public {
        vm.deal(rail, 1 ether);
        address(splitter).call{value: 1 ether}("");
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        splitter.sweepNative();
    }

    function test_sweep_nothingToSweep_reverts() public {
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NothingToSweep.selector);
        splitter.sweepNative();
    }

    /// @dev At rest after an all-inline split there is nothing recoverable (pure pass-through).
    function test_atRest_noRecoverable() public {
        splitter.split(address(token), 1000, "prod", payer, referrer);
        assertEq(splitter.nativeRecoverable(), 0, "no stranding on the happy path");
        assertEq(address(splitter).balance, 0);
    }

    // ---------------------------------------------------------------- owner/bps

    function test_setReferralBps_andBound() public {
        vm.prank(owner);
        splitter.setReferralBps(5000);
        (uint256 rc,) = splitter.split(address(token), 1000, "prod", payer, referrer);
        assertEq(rc, 500, "50%");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.BadBps.selector, uint16(10_001)));
        splitter.setReferralBps(10_001);
    }

    function test_setReferralBps_zero_allTreasury() public {
        vm.prank(owner);
        splitter.setReferralBps(0);
        (uint256 rc, uint256 tc) = splitter.split(address(token), 1000, "prod", payer, referrer);
        assertEq(rc, 0);
        assertEq(tc, 1000);
    }

    function test_setReferralBps_10k_allReferrer() public {
        vm.prank(owner);
        splitter.setReferralBps(10_000);
        (uint256 rc, uint256 tc) = splitter.split(address(token), 1000, "prod", payer, referrer);
        assertEq(rc, 1000, "all to referrer");
        assertEq(tc, 0, "nothing to treasury");
    }

    function test_onlyOwner_bps() public {
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        splitter.setReferralBps(1000);
    }

    function test_defaultReferralBps_is2500() public view {
        assertEq(splitter.referralBps(), 2500);
    }

    function test_event_emitted() public {
        vm.recordLogs();
        splitter.split(address(token), 1000, "prod", payer, referrer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 want = keccak256("FeeSplit(bytes32,address,address,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == want && logs[i].emitter == address(splitter)) {
                found = true;
                assertEq(logs[i].topics[1], bytes32("prod"), "product topic");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(payer))), "payer topic");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(referrer))), "referrer topic");
                (uint256 fee, uint256 cut) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(fee, 1000);
                assertEq(cut, 250);
            }
        }
        assertTrue(found, "FeeSplit emitted");
    }
}
