// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {FleetPaymaster} from "../src/FleetPaymaster.sol";

/// @title Deploy the SHIPPED FleetPaymaster (Base mainnet fire).
/// @dev Mirrors products/fleet-executor/script/Deploy.s.sol. env PRIVATE_KEY is the product's FRESH
///      key; env ENTRY_POINT is the ERC-4337 v0.7 EntryPoint (0x0000000071727De22E5E9d8BAf0edAc6f37da032,
///      LIVE on Base — verified 16035 B); env OWNER is the orphan treasury. One CREATE.
///
///      Run (dry run):  PRIVATE_KEY=0x… OWNER=0xe218…204B ENTRY_POINT=0x00…da032 forge script script/Deploy.s.sol:Deploy --rpc-url <base>
///      Run (fire):     … same … --broadcast
contract Deploy is Script {
    function run() external returns (FleetPaymaster p) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address ep = vm.envAddress("ENTRY_POINT");
        address me = vm.addr(pk);
        console.log("deployer", me);
        console.log("deployer bal", me.balance);
        console.log("deployer nonce", vm.getNonce(me));
        console.log("owner (orphan)", owner);
        console.log("entryPoint", ep);
        console.log("chainId", block.chainid);

        // the EntryPoint must be the real, LIVE v0.7 one — a wrong EP address is a silent policy lie
        require(ep.code.length > 0, "EntryPoint has no code");
        console.log("entryPoint code", ep.code.length);

        vm.startBroadcast(pk);
        p = new FleetPaymaster(ep, owner);
        vm.stopBroadcast();

        require(address(p).code.length > 0, "no code at paymaster");
        require(address(p.entryPoint()) == ep, "entryPoint mismatch");
        require(p.owner() == owner, "owner mismatch");
        console.log("SHIPPED FleetPaymaster", address(p), "code", address(p).code.length);
    }
}
