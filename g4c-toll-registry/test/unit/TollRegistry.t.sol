// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TollRegistry} from "../../src/TollRegistry.sol";
import {ITollRegistry} from "../../src/interfaces/ITollRegistry.sol";

/// @title TollRegistry unit tests — scope §6 item 1.
/// @notice The tuple round-trips, and an UNSET product reads `live=false` rather than a silent 0.
///         Fixture addresses are constants (wave rule): the orphan treasury is a literal, product
///         ids are `keccak256("...")`. No live RPC needed.
contract TollRegistryTest is Test {
    address constant ORPHAN = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B;
    address constant OTHER = address(0xBEEF);

    bytes32 constant P_G2B = keccak256("g2b-escrow");
    bytes32 constant P_P2 = keccak256("p2-forwarder");
    bytes32 constant P_ZERO = keccak256("zero-fee-product");

    TollRegistry reg;

    function _prod(bytes32 p, address r, uint16 b)
        internal
        pure
        returns (bytes32[] memory ps, address[] memory rs, uint16[] memory bs)
    {
        ps = new bytes32[](1);
        rs = new address[](1);
        bs = new uint16[](1);
        ps[0] = p;
        rs[0] = r;
        bs[0] = b;
    }

    function setUp() public {
        bytes32[] memory ps = new bytes32[](3);
        address[] memory rs = new address[](3);
        uint16[] memory bs = new uint16[](3);
        ps[0] = P_G2B;
        rs[0] = ORPHAN;
        bs[0] = 100;
        ps[1] = P_P2;
        rs[1] = ORPHAN;
        bs[1] = 100;
        ps[2] = P_ZERO; // registered, fee genuinely 0
        rs[2] = OTHER;
        bs[2] = 0;
        reg = new TollRegistry(ps, rs, bs);
    }

    // ---- happy path: the whole tuple round-trips ----

    function test_toll_returnsTuple() public view {
        (address r, uint16 b, bool live) = reg.toll(P_G2B);
        assertEq(r, ORPHAN, "recipient wrong");
        assertEq(b, 100, "feeBps wrong");
        assertTrue(live, "live should be true for a registered product");
    }

    function test_toll_multipleProducts() public view {
        (address r2,, bool live2) = reg.toll(P_P2);
        assertEq(r2, ORPHAN);
        assertTrue(live2);
    }

    // ---- THE POINT: unset product -> live=false, NOT a silent 0 ----

    function test_toll_unset_isLiveFalse() public view {
        (address r, uint16 b, bool live) = reg.toll(keccak256("never-registered"));
        assertEq(r, address(0), "unset recipient should be 0");
        assertEq(b, 0, "unset feeBps should be 0");
        assertFalse(live, "UNSET product MUST read live=false (not a silent 0)");
    }

    function test_isLive_matchesToll() public view {
        assertTrue(reg.isLive(P_G2B));
        assertFalse(reg.isLive(keccak256("never-registered")));
    }

    /// The critical distinction the `live` flag exists for: a product registered at 0 bps is NOT the
    /// same as an unregistered one. Both read feeBps==0; only `live` tells them apart.
    function test_registeredZeroFee_isDistinguishableFromUnset() public view {
        (, uint16 bZero, bool liveZero) = reg.toll(P_ZERO);
        (, uint16 bUnset, bool liveUnset) = reg.toll(keccak256("never-registered"));
        assertEq(bZero, bUnset, "both feeBps are 0 (the trap)");
        assertTrue(liveZero, "registered-at-0 must be live=true");
        assertFalse(liveUnset, "unset must be live=false");
    }

    // ---- ctor validation ----

    function test_ctor_zeroRecipient_reverts() public {
        (bytes32[] memory ps, address[] memory rs, uint16[] memory bs) = _prod(P_G2B, address(0), 100);
        vm.expectRevert(abi.encodeWithSelector(TollRegistry.ZeroRecipient.selector, P_G2B));
        new TollRegistry(ps, rs, bs);
    }

    function test_ctor_feeBpsTooHigh_reverts() public {
        (bytes32[] memory ps, address[] memory rs, uint16[] memory bs) = _prod(P_G2B, ORPHAN, 10_001);
        vm.expectRevert(abi.encodeWithSelector(TollRegistry.FeeBpsTooHigh.selector, P_G2B, uint16(10_001)));
        new TollRegistry(ps, rs, bs);
    }

    function test_ctor_feeBpsEqualDenominator_ok() public view {
        // 10_000 bps (100%) is allowed — it is not "too high".
        assertEq(reg.BPS_DENOMINATOR(), 10_000);
    }

    function test_ctor_lengthMismatch_reverts() public {
        bytes32[] memory ps = new bytes32[](2);
        address[] memory rs = new address[](1);
        uint16[] memory bs = new uint16[](2);
        ps[0] = P_G2B;
        ps[1] = P_P2;
        rs[0] = ORPHAN;
        bs[0] = 1;
        bs[1] = 2;
        vm.expectRevert(TollRegistry.LengthMismatch.selector);
        new TollRegistry(ps, rs, bs);
    }

    function test_ctor_duplicateProduct_reverts() public {
        bytes32[] memory ps = new bytes32[](2);
        address[] memory rs = new address[](2);
        uint16[] memory bs = new uint16[](2);
        ps[0] = P_G2B;
        ps[1] = P_G2B;
        rs[0] = ORPHAN;
        rs[1] = ORPHAN;
        bs[0] = 1;
        bs[1] = 2;
        vm.expectRevert(abi.encodeWithSelector(TollRegistry.DuplicateProduct.selector, P_G2B));
        new TollRegistry(ps, rs, bs);
    }

    function test_ctor_empty_isLegal() public {
        // an empty registry is legal; every product then reads unset, and its codehash must equal a
        // populated one's (no immutables).
        TollRegistry empty = new TollRegistry(new bytes32[](0), new address[](0), new uint16[](0));
        assertFalse(empty.isLive(keccak256("anything")));
        assertEq(address(empty).codehash, address(reg).codehash, "empty vs populated runtime must match");
    }

    // ---- THE LOAD-BEARING PROPERTY: no immutables => codehash identical across instances ----
    // This is what makes a consumer's codehash pin a CROSS-CHAIN CONSTANT (scope §4). Two registries
    // registering DIFFERENT products must share a runtime codehash.

    function test_codehash_independentOfRegisteredProducts() public {
        (bytes32[] memory ps, address[] memory rs, uint16[] memory bs) = _prod(P_G2B, ORPHAN, 100);
        TollRegistry a = new TollRegistry(ps, rs, bs);

        bytes32[] memory ps2 = new bytes32[](3);
        address[] memory rs2 = new address[](3);
        uint16[] memory bs2 = new uint16[](3);
        ps2[0] = keccak256("x");
        ps2[1] = keccak256("y");
        ps2[2] = keccak256("z");
        rs2[0] = ORPHAN;
        rs2[1] = ORPHAN;
        rs2[2] = OTHER;
        bs2[0] = 1;
        bs2[1] = 2;
        bs2[2] = 3;
        TollRegistry b = new TollRegistry(ps2, rs2, bs2);

        assertEq(address(a).codehash, address(b).codehash, "runtime must not depend on ctor data (NO IMMUTABLES)");
    }
}
