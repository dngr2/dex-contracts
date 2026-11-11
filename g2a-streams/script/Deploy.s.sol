// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {StreamFactory} from "../src/StreamFactory.sol";

/// @title Deploy — ONE StreamFactory per chain (vaults are CREATE2-deployed on demand per stream)
/// @dev NOTHING fires a chain unless --broadcast is passed. Chain-agnostic: addresses from env.
///      Mirrors P2's Deploy.s.sol shape so the fleet has ONE deploy idiom.
///
///      CREATE2 NOTE (differs from P2): P2's Registry used plain `new` so its address was identical
///      on every chain (deployer+nonce only). Here the FACTORY itself is still plain `new`, so the
///      FACTORY address is likewise chain-independent — but each VAULT's address depends on the
///      factory's address, so a same-key+same-nonce factory deploy per chain yields a consistent
///      vault-address space per chain too. `predict()` is always authoritative for a live factory.
///
/// USAGE (dry run):      forge script script/Deploy.s.sol --rpc-url base_sepolia
/// USAGE (testnet):      PRIVATE_KEY=0x.. OWNER=0x.. FEE_RECIPIENT=0x.. FEE_BPS=25 \
///                       forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast
contract Deploy is Script {
    function run() external {
        address owner_ = vm.envAddress("OWNER");
        address feeRcpt = vm.envAddress("FEE_RECIPIENT");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(25)));
        uint256 pk = vm.envUint("PRIVATE_KEY");   // test-only key; never a real-funds key

        vm.startBroadcast(pk);
        StreamFactory f = new StreamFactory(owner_, feeRcpt, feeBps);
        vm.stopBroadcast();

        console2.log("StreamFactory", address(f));
        console2.log("owner        ", owner_);
        console2.log("feeRcpt      ", feeRcpt);
        console2.log("feeBps       ", feeBps);
        console2.log("deployer     ", vm.addr(pk));
        console2.log("chainId      ", block.chainid);
    }
}
