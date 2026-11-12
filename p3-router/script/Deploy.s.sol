// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {Router} from "../src/Router.sol";

/// @dev Deploy script. Reads feeBps and treasury from env so the same script serves Sepolia and,
///      later, mainnet — with the values the USER decides (see PLAN.md §7), never hardcoded here.
///
///      No mainnet fire: `forge script ... --broadcast` only when told.
///
///      DEPLOYER KEY: mirror P2's Deploy.s.sol and broadcast EXPLICITLY from PRIVATE_KEY. A bare
///      `vm.startBroadcast()` falls back to Foundry's default sender, which makes the dry-run's
///      predicted address WRONG and the first --broadcast a no-op (GOTCHA #107, cost one wasted
///      broadcast on the Linea Wave-2 fire). If PRIVATE_KEY is unset, callers must still pass
///      `--private-key <pk> --sender <addr>` on the CLI.
contract Deploy is Script {
    function run() external returns (Router) {
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(5));
        address treasury = vm.envAddress("TREASURY");
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));

        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }
        Router r = new Router(feeBps, treasury);
        vm.stopBroadcast();

        return r;
    }
}
