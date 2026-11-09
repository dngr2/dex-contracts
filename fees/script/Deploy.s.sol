// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";

/// @title Deploy the fees lane (FeeSplitter + ReferralRegistry) to Base mainnet.
/// @dev Mirrors products/fleet-executor/script/Deploy.s.sol: env PRIVATE_KEY drives it, ONE CREATE per
///      contract, no owner/immutable beyond the ctor arg. The deployments are NONCE-CHAINED off one
///      fresh key (nonce 0 = FeeSplitter, nonce 1 = ReferralRegistry) so a single funded EOA lands both
///      with no gaps.
///
///      The FeeSplitter ctor takes the treasury (the orphan 0xe218E382…204B). We pass it as an env var
///      (TREASURY) so the SAME script serves mainnet and any dry chain without an edit; default to the
///      canonical orphan so a bare run is correct.
///
///      Run (dry run, free):
///        PRIVATE_KEY=0x… forge script script/Deploy.s.sol:Deploy --rpc-url base
///      Run (fire):
///        PRIVATE_KEY=0x… forge script script/Deploy.s.sol:Deploy --rpc-url base --broadcast
///
///      On-chain READBACK after broadcast (trust the chain, not the console): assert code is present
///      at BOTH addresses AND that a real getter answers — FeeSplitter.treasury() == the orphan and
///      ReferralRegistry.ownerOf(bytes32(0)) == 0 — so a wrong-contract or mis-wired deploy cannot
///      pass silently. The post-fire readback lives in the sibling key-receipt; this script asserts the
///      cheap invariants it CAN see from its own broadcast.
contract Deploy is Script {
    // the canonical orphan fee sink (also the ops signer) — the FeeSplitter treasury.
    address constant ORPHAN = 0xe218E382F28A094f9f64E903ee3cb1750A7f204B;

    function run() external returns (FeeSplitter fs, ReferralRegistry rr) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", ORPHAN);

        console.log("deployer", me);
        console.log("deployer bal", me.balance);
        console.log("deployer nonce", vm.getNonce(me));
        console.log("chainId", block.chainid);
        console.log("treasury (FeeSplitter ctor)", treasury);
        require(treasury != address(0), "treasury is zero");
        require(vm.getNonce(me) == 0, "fresh key must start at nonce 0");

        vm.startBroadcast(pk);
        fs = new FeeSplitter(treasury);      // nonce 0
        rr = new ReferralRegistry();         // nonce 1
        vm.stopBroadcast();

        // trust the chain: code present at BOTH, under EIP-170, and a real getter answers.
        require(address(fs).code.length > 0, "no code at FeeSplitter");
        require(address(rr).code.length > 0, "no code at ReferralRegistry");
        require(address(fs).code.length <= 24_576, "FeeSplitter code exceeds EIP-170");
        require(address(rr).code.length <= 24_576, "ReferralRegistry code exceeds EIP-170");
        require(fs.treasury() == treasury, "FeeSplitter.treasury() != ctor arg");
        require(fs.owner() == me, "FeeSplitter.owner() != deployer");
        require(rr.ownerOf(bytes32(0)) == address(0), "ReferralRegistry.ownerOf(0) != 0");

        console.log("FeeSplitter", address(fs), "code", address(fs).code.length);
        console.log("ReferralRegistry", address(rr), "code", address(rr).code.length);
    }
}
