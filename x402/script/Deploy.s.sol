// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {x402Facilitator} from "../src/x402Facilitator.sol";

/// @title Deploy the SHIPPED x402Facilitator (Base mainnet fire).
/// @dev Mirrors products/fleet-executor/script/Deploy.s.sol. env PRIVATE_KEY is the product's FRESH
///      key (never the shared relay); env OWNER is the orphan treasury. One CREATE, no predicted
///      address in the script — the address is read off the chain after broadcast, not printed here.
///
///      Run (dry run, free):
///        PRIVATE_KEY=0x… OWNER=0xe218…204B forge script script/Deploy.s.sol:Deploy --rpc-url <base>
///      Run (fire):
///        PRIVATE_KEY=0x… OWNER=0xe218…204B forge script script/Deploy.s.sol:Deploy --rpc-url <base> --broadcast
///
///      POST-DEPLOY the owner MUST `setWriter(<seeder>, true)` before any markPaid — the facilitator
///      has its OWN writer allow-list, and verify() reads its OWN _settled map. Until then markPaid
///      reverts NotWriter() and verify() can never flip true. (Readback asserts owner + isWriter.)
contract Deploy is Script {
    function run() external returns (x402Facilitator f) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address me = vm.addr(pk);
        console.log("deployer", me);
        console.log("deployer bal", me.balance);
        console.log("deployer nonce", vm.getNonce(me));
        console.log("owner (orphan)", owner);
        console.log("chainId", block.chainid);

        vm.startBroadcast(pk);
        f = new x402Facilitator(owner);
        vm.stopBroadcast();

        require(address(f).code.length > 0, "no code at facilitator");
        require(f.owner() == owner, "owner mismatch");
        console.log("SHIPPED x402Facilitator", address(f), "code", address(f).code.length);
        console.log("NEXT: owner.setWriter(seeder,true) before any markPaid");
    }
}
