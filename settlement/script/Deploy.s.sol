// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {SettlementRegistry} from "../src/SettlementRegistry.sol";

/// @title Deploy the SHIPPED SettlementRegistry (Base mainnet fire).
/// @dev Mirrors products/fleet-executor/script/Deploy.s.sol. env PRIVATE_KEY is the product's FRESH
///      key; env OWNER is the orphan treasury. One CREATE, no ctor-listed predicted address.
///
///      Run (dry run):  PRIVATE_KEY=0x… OWNER=0xe218…204B forge script script/Deploy.s.sol:Deploy --rpc-url <base>
///      Run (fire):     … same … --broadcast
contract Deploy is Script {
    function run() external returns (SettlementRegistry r) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address me = vm.addr(pk);
        console.log("deployer", me);
        console.log("deployer bal", me.balance);
        console.log("deployer nonce", vm.getNonce(me));
        console.log("owner (orphan)", owner);
        console.log("chainId", block.chainid);

        vm.startBroadcast(pk);
        r = new SettlementRegistry(owner);
        vm.stopBroadcast();

        require(address(r).code.length > 0, "no code at registry");
        require(r.owner() == owner, "owner mismatch");
        console.log("SHIPPED SettlementRegistry", address(r), "code", address(r).code.length);
    }
}
