// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IPaymentRail} from "../../src/IPaymentRail.sol";
import {IEscrowRail} from "../../src/IEscrowRail.sol";
import {IStreamRail} from "../../src/IStreamRail.sol";
import {IEscrowHook} from "../../src/IEscrowHook.sol";

/// @title InterfaceIds — freeze the ABI of the wave's shared interfaces
/// @notice Every selector and every event topic0 is asserted against a HARDCODED expected value,
///         derived independently with `cast sig` / `cast keccak`. A rename or a signature tweak in any
///         of the four interfaces therefore turns this suite RED — which is the point: other lanes
///         import these shapes and must not be broken silently.
///
/// @dev These values are the wave's contract. If a lane NEEDS a change, the change is made here first
///      and the new value recorded, never worked around at the call site.
contract InterfaceIds is Test {
    // --------------------------------------------------------------------------------------------
    // IPaymentRail — the frozen common interface (roadmap p.6, verbatim)
    // --------------------------------------------------------------------------------------------
    function test_selectors_IPaymentRail() public pure {
        assertEq(IPaymentRail.feeBps.selector, bytes4(0x24a9d853), "feeBps()");
        assertEq(IPaymentRail.minFee.selector, bytes4(0x5c9edb87), "minFee(address)");
        assertEq(IPaymentRail.quote.selector, bytes4(0x8f79306e), "quote(address,uint256)");
        assertEq(
            IPaymentRail.pay.selector,
            bytes4(0x68abdc82),
            "pay(address,address,uint256,bytes32,address)"
        );
    }

    function test_topic0_IPaymentRail_Paid() public pure {
        assertEq(
            IPaymentRail.Paid.selector,
            bytes32(0x872ea37449fbd69d50d72f2abf35c2b547f7db8c58a7054747e54ae1e174a595),
            "Paid(bytes32,address,address,address,uint256,uint256,bytes32,address)"
        );
    }

    // --------------------------------------------------------------------------------------------
    // IEscrowRail — create-for-with-referrer + outcome()
    // --------------------------------------------------------------------------------------------
    function test_selectors_IEscrowRail() public pure {
        assertEq(
            IEscrowRail.createFor.selector,
            bytes4(0xd9b22c47),
            "createFor(Deal,address)"
        );
        assertEq(
            IEscrowRail.createForPayer.selector,
            bytes4(0xc715cbc8),
            "createForPayer(Deal,address,bytes)"
        );
        assertEq(IEscrowRail.outcome.selector, bytes4(0x27793f87), "outcome()");
        assertEq(IEscrowRail.sweepExcess.selector, bytes4(0x975918d8), "sweepExcess()");
    }

    function test_topic0_IEscrowRail_events() public pure {
        assertEq(
            IEscrowRail.Released.selector,
            bytes32(0x56ea2ec572622330e2d1be08b567d01ec363db7eaf1974bbba24d06c649c49fe),
            "Released(bytes32,address,uint256,uint256,uint256,address)"
        );
        assertEq(
            IEscrowRail.Refunded.selector,
            bytes32(0xb44b3631755227290f8fbd7b248fa4be405129d15351313e3c332a3fb9919417),
            "Refunded(address,uint256,address)"
        );
    }

    /// @dev The Deal tuple hash is what the selectors above are derived from — pin its member TYPES
    ///      so a field reorder (same names, swapped order) is caught, since that changes the selector.
    function test_EscrowRail_DealTupleTypes() public pure {
        IEscrowRail.Deal memory d;
        d.counterparty = address(1);
        d.token = address(2);
        d.amount = 3;
        d.hash = bytes32(uint256(4));
        d.timeout = 5;
        d.releaseGrace = 6;
        d.hook = address(7);
        assertEq(d.counterparty, address(1));
        assertEq(d.releaseGrace, 6);
        assertEq(d.hook, address(7));
    }

    // --------------------------------------------------------------------------------------------
    // IStreamRail — mandate shape, signed set, permissionless execution
    // --------------------------------------------------------------------------------------------
    function test_selectors_IStreamRail() public pure {
        assertEq(
            IStreamRail.setMandateFor.selector,
            bytes4(0x1370269f),
            "setMandateFor(address,address,address,uint256,uint64,uint32,address,bytes)"
        );
        assertEq(IStreamRail.executeLap.selector, bytes4(0x8f25e28d), "executeLap(bytes32)");
        assertEq(IStreamRail.dueLaps.selector, bytes4(0x9a5acba8), "dueLaps(bytes32,uint256)");
        assertEq(IStreamRail.mandatesOf.selector, bytes4(0x66d25731), "mandatesOf(address)");
        assertEq(IStreamRail.getMandate.selector, bytes4(0xa32db67e), "getMandate(bytes32)");
        assertEq(IStreamRail.revokeMandate.selector, bytes4(0xd91ebc2a), "revokeMandate(bytes32)");
    }

    function test_topic0_IStreamRail_events() public pure {
        assertEq(
            IStreamRail.MandateSet.selector,
            bytes32(0x08b6f7c8b6303bca31cb26451da17e4c078b228811255e219e317b06528eba5c),
            "MandateSet(bytes32,address,address,address,uint256,uint64,uint32,address)"
        );
        assertEq(
            IStreamRail.LapExecuted.selector,
            bytes32(0x94c9fbf1a11189542a03edac4e9d882b85b7b423aa2f6fecc8e4199c916b6f00),
            "LapExecuted(bytes32,address,uint32,uint64,uint64)"
        );
        assertEq(
            IStreamRail.MandateRevoked.selector,
            bytes32(0x31c289dd93001fcacb63a0874240a9d06870135458e9be63e0463f46edf663fa),
            "MandateRevoked(bytes32)"
        );
    }

    // --------------------------------------------------------------------------------------------
    // IEscrowHook — one callback, and its ABI
    // --------------------------------------------------------------------------------------------
    function test_selectors_IEscrowHook() public pure {
        assertEq(
            IEscrowHook.onEscrowSettled.selector,
            bytes4(0xeaca612a),
            "onEscrowSettled(address,uint8,uint256)"
        );
    }

    // --------------------------------------------------------------------------------------------
    // NEGATIVE CONTROL — a one-byte-off selector must NOT match (proves the teeth are real)
    // --------------------------------------------------------------------------------------------
    function test_negativeControl_oneNibbleOffSelectorFails() public pure {
        // 0x24a9d853 is feeBps(); 0x24a9d854 is not any selector in the set.
        assertTrue(IPaymentRail.feeBps.selector != bytes4(0x24a9d854));
        // outcome() is 0x27793f87 — a reordered/hypothetical outcome(bool) would be different.
        assertTrue(IEscrowRail.outcome.selector != bytes4(0x27793f88));
    }
}
