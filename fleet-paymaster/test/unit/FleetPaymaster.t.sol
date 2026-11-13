// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FleetPaymaster} from "../../src/FleetPaymaster.sol";
import {Owned} from "../../src/utils/Owned.sol";
import {IPaymaster} from "../../src/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";

/// @dev Unit tests — no live EntryPoint. Uses a MockEntryPoint that drives the
///      paymaster's validate/postOp exactly as the real EP does.
contract FleetPaymasterTest is Test {
    MockEntryPoint internal ep;
    FleetPaymaster internal pm;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal railTarget = makeAddr("rail");
    bytes4 internal constant PAY_SELECTOR = bytes4(keccak256("pay(address,address,uint256,bytes32,address)"));
    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(address,uint256)"));
    bytes4 internal constant ACCT_FN = 0x12345678; // arbitrary account-fn prefix on callData

    function setUp() public {
        ep = new MockEntryPoint();
        pm = new FleetPaymaster(address(ep), owner);
        vm.deal(alice, 100 ether);
    }

    // ---- helpers ----

    /// callData the paymaster understands:
    ///   <4-byte acct fn> ++ abi.encode(address target, uint256 sponsorBase, bytes innerCall)
    function _callData(address target, uint256 sponsorBase, bytes4 innerSel) internal pure returns (bytes memory) {
        bytes memory inner = abi.encodePacked(innerSel);
        return abi.encodePacked(ACCT_FN, abi.encode(target, sponsorBase, inner));
    }

    function _op(address sender, bytes memory callData) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(100e3) << 128 | uint256(50e3)),
            preVerificationGas: 21e3,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(2 gwei)),
            paymasterAndData: abi.encodePacked(address(0)),
            signature: ""
        });
    }

    /// Validate then postOp, as the EP would, and return the accrued surcharge.
    function _runOp(address sender, address target, uint256 base, bytes4 sel)
        internal
        returns (uint256 surcharge)
    {
        PackedUserOperation memory op = _op(sender, _callData(target, base, sel));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(uint256(1)), 0);
        uint256 before = pm.accruedSponsorFee(sender);
        ep.callPostOp(address(pm), IPaymaster.PostOpMode.opSucceeded, ctx, 12345, 1 gwei);
        surcharge = pm.accruedSponsorFee(sender) - before;
    }

    // =====================================================================
    //                            allow-list
    // =====================================================================

    function test_allowList_miss_reverts() public {
        // nothing allowed yet
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR));
        vm.expectRevert(
            abi.encodeWithSelector(FleetPaymaster.NotAllowedCall.selector, railTarget, PAY_SELECTOR)
        );
        ep.callValidate(address(pm), op, bytes32(0), 0);
    }

    function test_allowList_exactSelector_hit() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);

        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR));
        (bytes memory ctx, uint256 vd) = ep.callValidate(address(pm), op, bytes32(0), 0);
        assertGt(ctx.length, 0, "context returned");
        assertEq(vd, 0, "valid now");

        // a DIFFERENT selector on the same target is still a miss
        PackedUserOperation memory op2 = _op(alice, _callData(railTarget, 1e6, SWAP_SELECTOR));
        vm.expectRevert(
            abi.encodeWithSelector(FleetPaymaster.NotAllowedCall.selector, railTarget, SWAP_SELECTOR)
        );
        ep.callValidate(address(pm), op2, bytes32(0), 0);
    }

    function test_allowList_wildcardSelector_hit() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, bytes4(0), true); // whole-target wildcard
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, SWAP_SELECTOR));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(0), 0);
        assertGt(ctx.length, 0, "wildcard sponsors any selector");
    }

    function test_allowList_wholeTarget_hit() public {
        vm.prank(owner);
        pm.setAllowedTarget(railTarget, true);
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, SWAP_SELECTOR));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(0), 0);
        assertGt(ctx.length, 0);
    }

    function test_allowList_isSponsoredView_matches() public {
        assertFalse(pm.isSponsored(_callData(railTarget, 1e6, PAY_SELECTOR)));
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        assertTrue(pm.isSponsored(_callData(railTarget, 1e6, PAY_SELECTOR)));
    }

    function test_senderGate_blocksUnlisted() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setSenderGate(true);
        pm.setAllowedSender(alice, true);
        vm.stopPrank();

        // alice OK
        ep.callValidate(address(pm), _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR)), bytes32(0), 0);

        // bob blocked
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.SenderNotAllowed.selector, bob));
        ep.callValidate(address(pm), _op(bob, _callData(railTarget, 1e6, PAY_SELECTOR)), bytes32(0), 0);
    }

    // =====================================================================
    //                            rate limit
    // =====================================================================

    function test_rateLimit_exceeded_reverts() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setRateLimit(60, 2);
        vm.stopPrank();

        _runOp(alice, railTarget, 1e6, PAY_SELECTOR);
        _runOp(alice, railTarget, 1e6, PAY_SELECTOR);

        // 3rd in same window reverts
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR));
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.RateLimitExceeded.selector, alice, uint32(2), uint32(2)));
        ep.callValidate(address(pm), op, bytes32(0), 0);
    }

    function test_rateLimit_windowRolls() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setRateLimit(60, 1);
        vm.stopPrank();

        _runOp(alice, railTarget, 1e6, PAY_SELECTOR); // window opens, count 1

        // past the window: allowed again
        vm.warp(block.timestamp + 61);
        _runOp(alice, railTarget, 1e6, PAY_SELECTOR);
        assertEq(pm.currentWindowCount(alice), 1, "fresh window");
    }

    function test_rateLimit_isPerSender() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setRateLimit(60, 1);
        vm.stopPrank();

        _runOp(alice, railTarget, 1e6, PAY_SELECTOR);
        _runOp(bob, railTarget, 1e6, PAY_SELECTOR); // bob unaffected by alice's count
        assertEq(pm.opsInWindowOf(bob), 1);
    }

    function test_rateLimit_zeroMeansUnlimited() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setRateLimit(60, 0);
        vm.stopPrank();
        for (uint256 i; i < 10; i++) _runOp(alice, railTarget, 1e6, PAY_SELECTOR);
        assertEq(pm.opsInWindowOf(alice), 10);
    }

    function test_rateLimit_bumpedEvenOnRevertedMode() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setRateLimit(60, 5);
        vm.stopPrank();
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(0), 0);
        // opReverted: the inner call failed but gas is still owed -> slot consumed AND surcharge accrues
        ep.callPostOp(address(pm), IPaymaster.PostOpMode.opReverted, ctx, 999, 1 gwei);
        assertEq(pm.opsInWindowOf(alice), 1, "slot consumed");
        assertEq(pm.accruedSponsorFee(alice), (1e6 * 10) / 10_000, "gas owed even when the op reverted");
    }

    function test_postOpReverted_retryAccrues_finalStateChargedOnce() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(0), 0);

        // First postOp (in the EP) reverts -> EP rolls back its state, then RE-CALLS with postOpReverted.
        ep.callPostOp(address(pm), IPaymaster.PostOpMode.postOpReverted, ctx, 500, 1 gwei);
        // The retry is the ONLY surviving accounting, so it must have charged exactly once.
        assertEq(pm.accruedSponsorFee(alice), (1e6 * 10) / 10_000, "charged once on retry");
        assertEq(pm.totalSponsoredGasCost(), 500);
    }

    // =====================================================================
    //                          sponsorBps accounting
    // =====================================================================

    function test_sponsorBps_default10() public view {
        assertEq(pm.sponsorBps(), 10, "default 10bps per the wave doc");
    }

    function test_sponsorBps_accruesExactFee() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        vm.prank(owner);
        pm.setSponsorBps(50); // 50 bps = 0.5%

        uint256 base = 1_000_000e6; // 1M USDC (6dp)
        uint256 fee = _runOp(alice, railTarget, base, PAY_SELECTOR);
        assertEq(fee, (base * 50) / 10_000, "surcharge == base * bps / 1e4");
        assertEq(pm.totalAccruedSponsorFee(), fee);
    }

    function test_sponsorBps_snapshotted_ownerChangeMidflightDoesNotMoveIt() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        vm.prank(owner);
        pm.setSponsorBps(100);

        // validate at 100 bps
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1_000_000e6, PAY_SELECTOR));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(0), 0);

        // owner changes bps BEFORE postOp (a later op in the same bundle)
        vm.prank(owner);
        pm.setSponsorBps(10);

        ep.callPostOp(address(pm), IPaymaster.PostOpMode.opSucceeded, ctx, 1000, 1 gwei);
        // charged at the SNAPSHOTTED 100 bps, not the new 10
        assertEq(pm.accruedSponsorFee(alice), (1_000_000e6 * 100) / 10_000, "snapshot holds");
    }

    function test_sponsorBps_bound() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.SponsorBpsTooHigh.selector, uint16(1001), uint16(1000)));
        pm.setSponsorBps(1001);
    }

    function test_previewSponsorFee_matchesAccrual() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setSponsorBps(25);
        vm.stopPrank();
        uint256 base = 500_000e6;
        assertEq(pm.previewSponsorFee(base), _runOp(alice, railTarget, base, PAY_SELECTOR));
    }

    function test_clearAccrual() public {
        vm.startPrank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        pm.setSponsorBps(500);
        pm.clearAccrual(alice);
        vm.stopPrank();
        _runOp(alice, railTarget, 1_000_000e6, PAY_SELECTOR);
        assertGt(pm.accruedSponsorFee(alice), 0);
        vm.prank(owner);
        uint256 cleared = pm.clearAccrual(alice);
        assertGt(cleared, 0);
        assertEq(pm.accruedSponsorFee(alice), 0);
        assertEq(pm.totalAccruedSponsorFee(), cleared, "lifetime total unchanged by clear");
    }

    // =====================================================================
    //                            postOp accrual
    // =====================================================================

    function test_postOp_accruesAndEmits() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 2_000_000e6, PAY_SELECTOR));
        (bytes memory ctx,) = ep.callValidate(address(pm), op, bytes32(uint256(7)), 0);

        vm.expectEmit(true, true, true, false);
        emit FleetPaymaster.Sponsored(
            bytes32(uint256(7)), alice, railTarget, PAY_SELECTOR, 2_000_000e6, 10, 88_888, (2_000_000e6 * 10) / 10_000
        );
        ep.callPostOp(address(pm), IPaymaster.PostOpMode.opSucceeded, ctx, 88_888, 1 gwei);

        assertEq(pm.totalSponsoredGasCost(), 88_888);
    }

    function test_postOp_onlyEntryPoint() public {
        vm.expectRevert(FleetPaymaster.NotEntryPoint.selector);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, abi.encode(bytes32(0), alice, uint16(10), 0, railTarget, PAY_SELECTOR), 0, 0);
    }

    // =====================================================================
    //                          EntryPoint deposit
    // =====================================================================

    function test_deposit_and_withdraw() public {
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        pm.deposit{value: 2 ether}();
        assertEq(ep.balanceOf(address(pm)), 2 ether);

        address payable to = payable(makeAddr("treasury"));
        vm.prank(owner);
        pm.withdrawTo(to, 1 ether);
        assertEq(to.balance, 1 ether);
        assertEq(ep.balanceOf(address(pm)), 1 ether);
    }

    function test_withdraw_zeroAddr_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Owned.ZeroAddress.selector);
        pm.withdrawTo(payable(address(0)), 1);
    }

    function test_addStake_forwards() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        pm.addStake{value: 1 ether}(86_400);
        assertEq(ep.unstakeDelay(address(pm)), 86_400);
    }

    // =====================================================================
    //                              admin / guards
    // =====================================================================

    function test_onlyOwner() public {
        vm.expectRevert(Owned.NotOwner.selector);
        pm.setSponsorBps(1);
        vm.expectRevert(Owned.NotOwner.selector);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
    }

    function test_twoStepOwnership() public {
        vm.prank(owner);
        pm.transferOwnership(bob);
        assertEq(pm.pendingOwner(), bob);
        vm.prank(bob);
        pm.acceptOwnership();
        assertEq(pm.owner(), bob);
    }

    function test_validate_onlyEntryPoint() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, PAY_SELECTOR, true);
        PackedUserOperation memory op = _op(alice, _callData(railTarget, 1e6, PAY_SELECTOR));
        vm.expectRevert(FleetPaymaster.NotEntryPoint.selector);
        pm.validatePaymasterUserOp(op, bytes32(0), 0);
    }

    function test_badCallData_reverts() public {
        vm.prank(owner);
        pm.setAllowedCall(railTarget, bytes4(0), true);
        PackedUserOperation memory op = _op(alice, hex"11223344"); // no target/base words
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.BadCallData.selector, 4));
        ep.callValidate(address(pm), op, bytes32(0), 0);
    }

    function test_ctor_zeroEntryPoint_reverts() public {
        vm.expectRevert(Owned.ZeroAddress.selector);
        new FleetPaymaster(address(0), owner);
    }
}
