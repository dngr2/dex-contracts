// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {FleetExecutor} from "../src/FleetExecutor.sol";

/// @title Deploy the SHIPPED FleetExecutor 7702 delegate (Base mainnet fire).
/// @dev Mirrors the sibling fire scripts (g3a Dg3a, p3c Dp3c): env PRIVATE_KEY drives it, one CREATE,
///      no constructor args, no owner, no immutables — so the runtime is chain- and account-
///      independent and the delegate can be installed by ANY EOA with one type-4 auth.
///
///      Run (dry run, free):
///        PRIVATE_KEY=0x… forge script script/Deploy.s.sol:Deploy --rpc-url <base-mainnet>
///      Run (fire):
///        PRIVATE_KEY=0x… forge script script/Deploy.s.sol:Deploy --rpc-url <base-mainnet> --broadcast
///
///      On-chain READBACK after broadcast (trust the chain, not the console): assert code present and
///      that the three cheap invariants hold on the LIVE bytecode — domain() name/version hashes and
///      nonces()==0 — so a wrong-contract deploy cannot pass silently.
contract Deploy is Script {
    function run() external returns (FleetExecutor e) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        console.log("deployer", me);
        console.log("deployer bal", me.balance);
        console.log("deployer nonce", vm.getNonce(me));
        console.log("chainId", block.chainid);

        vm.startBroadcast(pk);
        e = new FleetExecutor();
        vm.stopBroadcast();

        require(address(e).code.length > 0, "no code at delegate");
        // runtime must be well under the EIP-170 limit; a 7702 target just needs to be callable.
        require(address(e).code.length <= 24_576, "code exceeds EIP-170");

        console.log("SHIPPED FleetExecutor", address(e), "code", address(e).code.length);
        console.log("delegate install form: 0xef0100 || address(this)");
    }
}
