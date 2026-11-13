// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {ReferralRegistry} from "../../src/ReferralRegistry.sol";

contract RegistryAdversarialTest is Test {
    ReferralRegistry r;
    address alice=makeAddr("alice"); address bob=makeAddr("bob");
    bytes32 C=keccak256("ALICE"); bytes32 D=keccak256("BOB");
    function setUp() public { r=new ReferralRegistry(); }

    function test_probe_firstCome_wins() public {
        vm.prank(alice); r.register(C);
        assertEq(r.resolve(C), alice);
        vm.prank(bob); vm.expectRevert(abi.encodeWithSelector(ReferralRegistry.CodeTaken.selector, C)); r.register(C);
    }
    function test_probe_idempotentReregisterByOwner() public {
        vm.prank(alice); r.register(C);
        vm.prank(alice); r.register(C); // same owner re-register ok
        assertEq(r.resolve(C), alice);
    }
    function test_probe_oneCodePerAddress_priorReleased() public {
        vm.prank(alice); r.register(C);
        vm.prank(alice); r.register(D); // alice moves to D; C freed
        assertEq(r.resolve(C), address(0), "prior code freed");
        assertEq(r.resolve(D), alice);
        vm.prank(bob); r.register(C); assertEq(r.resolve(C), bob, "freed code re-claimable");
    }
    function test_probe_burn_frees() public {
        vm.prank(alice); r.register(C);
        vm.prank(alice); r.burn();
        assertEq(r.resolve(C), address(0));
        vm.prank(bob); r.register(C); assertEq(r.resolve(C), bob);
    }
    function test_probe_emptyCode_rejected() public {
        vm.expectRevert(ReferralRegistry.EmptyCode.selector); r.register(bytes32(0));
    }
    function test_probe_nonOwnerBurn_reverts() public {
        vm.prank(bob); vm.expectRevert(); r.burn();
    }
    function test_probe_transferCode_movesOwnership() public {
        vm.prank(alice); r.register(C);
        vm.prank(alice); r.transferCode(bob);
        assertEq(r.resolve(C), bob);
        assertEq(r.codeOf(bob), C);
    }
}
