// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FleetExecutor} from "../../src/FleetExecutor.sol";
import {Counter} from "../../src/interfaces/Counter.sol";

/// @dev Adversarial probes run by dex-critic, not exec5.
contract ExecutorAdversarialTest is Test {
    FleetExecutor exec; Counter counter;
    uint256 USER_PK = 0xA11CE; uint256 ATTACKER_PK = 0xBAD;
    address USER; address ATTACKER;

    function setUp() public {
        USER = vm.addr(USER_PK); ATTACKER = vm.addr(ATTACKER_PK);
        exec = new FleetExecutor(); counter = new Counter();
        vm.etch(USER, abi.encodePacked(hex"ef0100", address(exec)));
        vm.deal(USER, 100 ether); vm.deal(ATTACKER, 100 ether);
    }

    /// PROBE A: ERC-7821 path needs NO signature and NO self-check. An ARBITRARY third
    /// party drives the delegated EOA's frame with a batch of their choosing.
    function test_probe_7821_isPermissionless() public {
        FleetExecutor.Call[] memory calls = new FleetExecutor.Call[](1);
        calls[0] = FleetExecutor.Call(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        bytes memory data = abi.encode(calls);
        vm.prank(ATTACKER);   // ATTACKER, never the user, never signed anything
        FleetExecutor(USER).executeBare(bytes32(uint256(0x01) << 248), data);
        assertEq(counter.count(), 1, "attacker drove the user's frame with zero signature");
    }

    /// PROBE B: the caller (not the EOA) funds value — 7821 requires msg.value >= total, so the
    /// EOA's OWN native is NOT spendable via 7821. The batch pays a FRESH sink; the EOA balance
    /// is unchanged while the sink is paid out of the caller's pocket.
    function test_probe_7821_valueFundedByCallerNotEoa() public {
        address sink = makeAddr("sink");
        assertEq(USER.balance, 100 ether, "EOA holds 100");
        FleetExecutor.Call[] memory calls = new FleetExecutor.Call[](1);
        calls[0] = FleetExecutor.Call(sink, 5 ether, "");
        bytes memory data = abi.encode(calls);
        // (a) attacker sends 0 -> ValueMismatch (declared 5 > msg.value 0)
        vm.prank(ATTACKER);
        vm.expectRevert(FleetExecutor.ValueMismatch.selector);
        FleetExecutor(USER).executeBare(bytes32(uint256(0x01) << 248), data);
        // (b) attacker attaches 5 -> runs; sink paid, EOA untouched
        vm.prank(ATTACKER);
        FleetExecutor(USER).executeBare{value: 5 ether}(bytes32(uint256(0x01) << 248), data);
        assertEq(sink.balance, 5 ether, "sink paid from the caller's msg.value");
        assertEq(USER.balance, 100 ether, "EOA native untouched by 7821");
        assertEq(ATTACKER.balance, 95 ether, "attacker's own 100 funded it (minus 5)");
    }

    /// PROBE B2: executeSelf (msg.sender == EOA) DOES spend the EOA's own balance.
    function test_probe_executeSelf_spendsEoaNative() public {
        address sink = makeAddr("sink2");
        FleetExecutor.Call[] memory calls = new FleetExecutor.Call[](1);
        calls[0] = FleetExecutor.Call(sink, 3 ether, "");
        vm.prank(USER);   // the EOA calls itself
        FleetExecutor(USER).executeSelf{value: 3 ether}(calls);
        assertEq(sink.balance, 3 ether, "self path spent the EOA's native");
        assertEq(USER.balance, 97 ether, "EOA down 3");
    }

    /// PROBE C: 7821 mode SINGLE accepts a junk extra tail on executionData silently (abi.decode
    /// ignores trailing bytes) — confirm no revert, and the intended call still runs.
    function test_probe_7821_singleIgnoresTrailingBytes() public {
        bytes memory single = abi.encode(address(counter), uint256(0), abi.encodeCall(Counter.inc, ()));
        bytes memory tampered = abi.encodePacked(single, hex"deadbeef");
        vm.prank(ATTACKER);
        FleetExecutor(USER).executeBare(bytes32(0x00), tampered);
        assertEq(counter.count(), 1, "trailing junk tolerated");
    }

    /// PROBE D: MALLEABILITY — a high-s variant of the SAME signature is rejected.
    function test_probe_highs_rejected() public {
        FleetExecutor.Call[] memory calls = new FleetExecutor.Call[](1);
        calls[0] = FleetExecutor.Call(address(counter), 0, abi.encodeCall(Counter.inc, ()));
        bytes32 d = FleetExecutor(USER).digest(calls, 0, block.timestamp + 1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, d);
        // flip to high-s: s' = secp256k1n - s, v' = flipped
        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory sig = abi.encodePacked(r, sHigh, vFlip);
        // signature with high-s should REVERT (require uint256(s) <= threshold)
        vm.prank(USER);
        (bool ok,) = USER.call(abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)", calls, uint256(0), block.timestamp + 1000, sig));
        assertFalse(ok, "high-s variant rejected (canonical), by design");
    }
}
