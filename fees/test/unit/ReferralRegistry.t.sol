// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ReferralRegistry} from "../../src/ReferralRegistry.sol";

contract ReferralRegistryTest is Test {
    ReferralRegistry internal reg;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bytes32 internal constant CODE_A = keccak256("alice");
    bytes32 internal constant CODE_B = keccak256("bob");
    bytes32 internal constant CODE_C = keccak256("carol");

    function setUp() public {
        reg = new ReferralRegistry();
    }

    function test_register_firstCome() public {
        vm.prank(alice);
        reg.register(CODE_A);
        assertEq(reg.resolve(CODE_A), alice, "code bound to alice");
        assertEq(reg.codeOf(alice), CODE_A, "alice owns CODE_A");
    }

    function test_register_secondTakerReverts() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.CodeTaken.selector, CODE_A));
        reg.register(CODE_A);
    }

    function test_register_sameOwnerIdempotent() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(alice);
        reg.register(CODE_A); // same owner re-register is fine
        assertEq(reg.resolve(CODE_A), alice);
    }

    function test_register_emptyCodeReverts() public {
        vm.prank(alice);
        vm.expectRevert(ReferralRegistry.EmptyCode.selector);
        reg.register(bytes32(0));
    }

    function test_register_releasePriorCode() public {
        vm.prank(alice);
        reg.register(CODE_A);
        // alice rebinds to CODE_B -> CODE_A becomes free
        vm.prank(alice);
        reg.register(CODE_B);
        assertEq(reg.resolve(CODE_A), address(0), "prior code freed");
        assertEq(reg.resolve(CODE_B), alice, "new code bound");

        // bob can now take CODE_A
        vm.prank(bob);
        reg.register(CODE_A);
        assertEq(reg.resolve(CODE_A), bob);
    }

    function test_transferCode_byOwner() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(alice);
        reg.transferCode(bob);
        assertEq(reg.resolve(CODE_A), bob, "code moved to bob");
        assertEq(reg.codeOf(alice), bytes32(0), "alice no longer owns");
        assertEq(reg.codeOf(bob), CODE_A);
    }

    function test_transferCode_notOwnerReverts() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(bob); // bob owns nothing
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.NotCodeOwner.selector, bytes32(0)));
        reg.transferCode(carol);
    }

    function test_transferCode_toZeroReverts() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(alice);
        vm.expectRevert(ReferralRegistry.ZeroAddress.selector);
        reg.transferCode(address(0));
    }

    function test_transferCode_receiverPriorCodeReleased() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(bob);
        reg.register(CODE_B);
        vm.prank(alice);
        reg.transferCode(bob); // bob already had CODE_B -> released
        assertEq(reg.resolve(CODE_B), address(0), "bob's prior code freed");
        assertEq(reg.resolve(CODE_A), bob, "bob now owns CODE_A");
    }

    function test_burn_freesCode() public {
        vm.prank(alice);
        reg.register(CODE_A);
        vm.prank(alice);
        reg.burn();
        assertEq(reg.resolve(CODE_A), address(0), "code freed");
        assertEq(reg.codeOf(alice), bytes32(0));
        // bob can claim it
        vm.prank(bob);
        reg.register(CODE_A);
        assertEq(reg.resolve(CODE_A), bob);
    }

    function test_burn_noCodeReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.NotCodeOwner.selector, bytes32(0)));
        reg.burn();
    }

    function test_resolve_freeCode_isZero() public view {
        assertEq(reg.resolve(CODE_C), address(0));
    }
}
