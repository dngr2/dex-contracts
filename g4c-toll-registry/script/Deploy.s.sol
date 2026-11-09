// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TollRegistry} from "../src/TollRegistry.sol";

/// @title Deploy the SHIPPED TollRegistry (Base mainnet fire) with the fleet seed.
/// @dev Mirrors products/fleet-executor/script/Deploy.s.sol. env PRIVATE_KEY is the product's FRESH
///      key. The seed is HARD-CODED here (not env) so the exact arrays are auditable in the source:
///      four fleet products -> the orphan treasury. NO owner, NO setter: a bad seed = redeploy.
///
///      Recipients are all the orphan 0xe218E382F28A094f9f64E903ee3cb1750A7f204B.
///      feeBps per product is the product's LIVE rate: p2/g2a/g2b = 500 (post re-rate), p3 = 5 (its
///      compiled-in IMMUTABLE). Read live 2026-11-09.
///
///      Run (dry run):  PRIVATE_KEY=0x… forge script script/Deploy.s.sol:Deploy --rpc-url <base>
///      Run (fire):     PRIVATE_KEY=0x… forge script script/Deploy.s.sol:Deploy --rpc-url <base> --broadcast
contract Deploy is Script {
    address constant ORPHAN = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B;

    function run() external returns (TollRegistry r) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        console.log("deployer", me);
        console.log("deployer bal", me.balance);
        console.log("deployer nonce", vm.getNonce(me));
        console.log("chainId", block.chainid);

        bytes32[] memory products = new bytes32[](4);
        address[] memory recipients = new address[](4);
        uint16[] memory feeBps = new uint16[](4);

        products[0] = keccak256("p2-forwarder");
        products[1] = keccak256("g2a-streams");
        products[2] = keccak256("g2b-escrow");
        products[3] = keccak256("p3-router");

        recipients[0] = ORPHAN;
        recipients[1] = ORPHAN;
        recipients[2] = ORPHAN;
        recipients[3] = ORPHAN;

        feeBps[0] = 500; // p2-forwarder  live
        feeBps[1] = 500; // g2a-streams   live
        feeBps[2] = 500; // g2b-escrow    live
        feeBps[3] = 5;   // p3-router     live (IMMUTABLE, compiled in)

        vm.startBroadcast(pk);
        r = new TollRegistry(products, recipients, feeBps);
        vm.stopBroadcast();

        require(address(r).code.length > 0, "no code at registry");
        // the pin a consumer compiles in, printed so it can be copied into KEY-RECORDs (#73):
        console.log("SHIPPED TollRegistry", address(r), "code", address(r).code.length);
        console.logBytes32(address(r).codehash);
        for (uint256 i; i < 4; ++i) {
            (address rec, uint16 bps, bool live) = r.toll(products[i]);
            console.log("seed idx", i);
            console.log("  recipient", rec);
            console.log("  feeBps", bps);
            console.log("  live", live);
        }
    }
}
