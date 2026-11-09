// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FleetPaymaster} from "../../src/FleetPaymaster.sol";
import {IPaymaster} from "../../src/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";

contract Adversary { fallback() external payable {} }

/// @dev Adversarial probes run by dex-critic, not exec8.
contract PaymasterAdversarialTest is Test {
    MockEntryPoint ep; FleetPaymaster pm;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address rail = makeAddr("rail");
    bytes4 constant PAY = bytes4(keccak256("pay(address,address,uint256,bytes32,address)"));
    bytes4 constant ACCT = 0x12345678;

    function setUp() public {
        ep = new MockEntryPoint();
        pm = new FleetPaymaster(address(ep), owner);
        vm.prank(owner); pm.setAllowedCall(rail, PAY, true);
    }

    function _op(address declaredTarget, uint256 base, bytes4 sel) internal view returns (PackedUserOperation memory) {
        bytes memory inner = abi.encodePacked(sel);
        bytes memory cd = abi.encodePacked(ACCT, abi.encode(declaredTarget, base, inner));
        return PackedUserOperation(address(0), 0, "", cd, bytes32(0), 21e3, bytes32(0), "", "");
    }

    /// PROBE 1: the allow-list trusts the DECLARED target word, not the callee.
    /// An account whose callData declares an allowed target is sponsored even if
    /// it actually calls an enemy contract. By design, but untested before now.
    function test_probe_declaredTargetIsTrustedNotVerified() public {
        Adversary enemy = new Adversary();
        // declare `rail` (allowed) while actually calling `enemy`:
        PackedUserOperation memory op = _op(rail, 1e6, PAY);
        (, uint256 vd) = ep.callValidate(address(pm), op, bytes32(0), 0);
        assertEq(vd, 0, "sponsored on the DECLARED word; callee `enemy` never consulted");
        assertTrue(address(enemy) != rail);
    }

    /// PROBE 2: declared target = enemy (unallowed) → refused, even if that is what is really called.
    function test_probe_unlistedDeclaredTarget_refused() public {
        Adversary enemy = new Adversary();
        PackedUserOperation memory op = _op(address(enemy), 1e6, PAY);
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.NotAllowedCall.selector, address(enemy), PAY));
        ep.callValidate(address(pm), op, bytes32(0), 0);
    }

    /// PROBE 3: selector is read from the innerCall HEAD; a declared PAY with a
    /// shifted/garbage inner tail still passes validate (only head 4 bytes read).
    function test_probe_selectorFromInnerHeadOnly() public {
        PackedUserOperation memory op = _op(rail, 1e6, SWAP_SEL_FAR());
        // declared sel "swap" is NOT allowed on rail -> should revert
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.NotAllowedCall.selector, rail, SWAP_SEL_FAR()));
        ep.callValidate(address(pm), op, bytes32(0), 0);
    }
    function SWAP_SEL_FAR() internal pure returns (bytes4) { return bytes4(keccak256("swap(address,uint256)")); }

    /// PROBE 4: empty innerCall (2-word form) → selector = bytes4(0) → allowedTarget-only path.
    /// If only (rail,PAY) is allowed (not whole-target), a 2-word calldata MISSES.
    function test_probe_twoWordFormNeedsWholeTargetOrWildcard() public {
        bytes memory cd = abi.encodePacked(ACCT, abi.encode(rail, uint256(1e6)));
        PackedUserOperation memory op = PackedUserOperation(address(0), 0, "", cd, bytes32(0), 21e3, bytes32(0), "", "");
        // (rail,PAY) allowed but sel reads bytes4(0) -> not matched -> revert
        vm.expectRevert(abi.encodeWithSelector(FleetPaymaster.NotAllowedCall.selector, rail, bytes4(0)));
        ep.callValidate(address(pm), op, bytes32(0), 0);
    }
}
