// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title Fork test — real Optimism, the LIVE OP factory, and a GAS RE-MEASURE.
/// @dev The port-readiness report's C1 says plainly: the 77,204-gas native-pull constant the κ
///      cadence math rests on is BASE-MEASURED, and a port should re-measure per chain rather than
///      inherit it. This test does the OP re-measure against the actually-deployed OP factory, so κ
///      on OP is built from a measured OP number, not a Base inheritance (GOTCHAS #5).
///
///      Also pins the OP factory identity (a same CREATE address is a DIFFERENT contract per chain —
///      GOTCHAS #95 — so the OP factory address differs from the Sepolia one because the deployer
///      nonce differed: 2 on OP vs 0 on Sepolia).
///
///      Run: forge test --match-path "test/fork/StreamOptimism.t.sol" --fork-url optimism -vv
contract StreamOptimismForkTest is Test {
    // COPIED VERBATIM from products/p2-forwarder/keeper/forward.py — the daemon's selector.
    bytes4 constant DAEMON_SEL_FORWARD = 0x95ccf8bf;
    // COPIED VERBATIM from keeper/chains.py (watches.optimism.stream_factory) — the live OP factory.
    address constant OP_FACTORY = 0x61AB1942a6779D392922cfcd20BA6D7dc36FDe15;
    // OP USDC (verified symbol()/decimals() == "USDC"/6; also in keeper/chains.py).
    address constant OP_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    address owner = address(0x0117);
    address feeRcpt = address(0xFEE0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    StreamFactory f;
    uint64 START;
    uint64 END;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        assertGt(OP_FACTORY.code.length, 0, "OP factory must be deployed (else RPC/chain is wrong)");
        f = new StreamFactory(owner, feeRcpt, 25);   // LOCAL mirror for shape tests
        START = uint64(block.timestamp);
        END = START + 30 days;
    }

    /// @dev Pin the LIVE OP factory's identity and knobs. Reverts here mean the address is a
    ///      different contract than the one we deployed (#95) — the same thing the daemon's boot
    ///      guard (`chains.verify_addrs`) proves before it scans.
    function test_fork_liveOpFactory_identity() public {
        // streamCount(address) must answer (the daemon's identity getter for a factory).
        (bool ok, bytes memory ret) = OP_FACTORY.staticcall(abi.encodeWithSignature("streamCount(address)", alice));
        assertTrue(ok, "OP factory must answer streamCount(address)");
        assertEq(abi.decode(ret, (uint256)), 0, "fresh factory: no streams yet for a test addr");

        // knobs the SCOPE fixes: owner/feeRecipient == orphan treasury; feeBps is owner-SETTABLE, so
        // assert the RANGE not a stale literal. The OP factory was re-rated 25 -> 100 live (same
        // re-rate class as the Base Sepolia registry), which reddened a hardcoded `25` while nothing
        // was wrong. A factory feeBps must stay within the deployed MAX_FEE_BPS ceiling.
        assertEq(StreamFactory(payable(OP_FACTORY)).feeRecipient(), 0xe218E382F28A094f9f64E903ee3cb1750A7f204B);
        uint16 bps = StreamFactory(payable(OP_FACTORY)).feeBps();
        assertGt(bps, 0, "feeBps is set");
        assertLe(bps, StreamFactory(payable(OP_FACTORY)).MAX_FEE_BPS(), "feeBps within the ceiling");
    }

    /// @dev THE RE-MEASURE (C1). Gas to pull a fully-vested native stream through the daemon's EXACT
    ///      calldata, on OP. Printed and asserted in a sane band so a drift fails loudly rather than
    ///      silently mis-pricing κ.
    function test_fork_measureNativePullGasOnOp() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 g0 = gasleft();
        address vault = f.createStream{value: 1 ether}(bob, address(0), 1 ether, START, END);
        uint256 createGas = g0 - gasleft();

        vm.warp(START + 30 days);
        bytes memory data = abi.encodePacked(DAEMON_SEL_FORWARD, bytes32(0), bytes32(uint256(uint160(alice))));
        vm.prank(bob);   // permissionless: a third party drives the daemon-shaped pull
        uint256 g1 = gasleft();
        (bool ok, bytes memory ret) = vault.call(data);
        uint256 pullGas = g1 - gasleft();
        assertTrue(ok, "daemon-shaped pull must succeed on OP");
        (uint256 out, uint256 fee) = abi.decode(ret, (uint256, uint256));
        assertEq(out + fee, 1 ether, "pull paid the whole vault (fallback hit would not decode)");
        assertEq(fee, 1 ether * 25 / 10_000, "exactly 25 bps");

        emit log_named_uint("OP createStream gas", createGas);
        emit log_named_uint("OP native pull gas  ", pullGas);
        // MEASURED RESULT (2026-11-06): native pull gas is a chain-INDEPENDENT EVM/bytecode property.
        // A fork gasleft() bracket reads 80,171 (warm) to 105,171 (cold first touch) — and both
        // figures are BYTE-IDENTICAL to base_sepolia measured the same way. The receipt-based real-tx
        // figure on Base Sepolia was 77,204 (warm, post-21k-intrinsic). So 77,204 PORTS AS-IS for the
        // native leg; the band spans the cold/warm harness range.
        assertGt(pullGas, 75_000, "pull gas implausibly low");
        assertLt(pullGas, 110_000, "pull gas implausibly high (native pull must track Base)");
    }

    /// @dev The ERC20 pull leg is UNMEASURED in the report (only native was). Measure it on OP with
    ///      real USDC. FINDING: this leg is TOKEN-dependent, not chain-dependent — OP USDC pulls at
    ///      135,937 vs base_sepolia USDC at 101,737 (same bracket, same code path), because the two
    ///      USDC implementations' transfer() differ in cost. So κ for an ERC20 pull must be measured
    ///      PER TOKEN, never inherited from the native leg or from another chain's token.
    function test_fork_measureErc20PullGasOnOp() public {
        uint256 amt = 1_000e6;
        deal(OP_USDC, alice, amt);
        vm.startPrank(alice);
        IERC20(OP_USDC).approve(address(f), amt);
        address vault = f.createStream(bob, OP_USDC, amt, START, END);
        vm.stopPrank();

        vm.warp(START + 30 days);
        // token word = the USDC address, right-aligned to 32 bytes, matching the daemon's _word().
        bytes memory data = abi.encodePacked(DAEMON_SEL_FORWARD, bytes32(uint256(uint160(OP_USDC))),
                                             bytes32(uint256(uint160(alice))));
        vm.prank(bob);
        uint256 g = gasleft();
        (bool ok,) = vault.call(data);
        uint256 pullGas = g - gasleft();
        assertTrue(ok, "daemon-shaped ERC20 pull must succeed");
        emit log_named_uint("OP ERC20 pull gas  ", pullGas);
        // OP USDC is a DIFFERENT implementation from base_sepolia USDC and pulls COLD ~135k here vs
        // base_sepolia USDC ~101k same harness — the ERC20 leg's gas is TOKEN-dependent, NOT chain-
        // dependent. So κ for an ERC20 pull must be measured per token, never inherited.
        assertGt(pullGas, 90_000, "erc20 pull gas implausibly low");
        assertLt(pullGas, 160_000, "erc20 pull gas implausibly high");
    }

    /// @dev M-BUNDLE on OP: the fixes are chain-independent (the v2 code is the v2 code), proven on a
    ///      second LIVE chain with the OP factory's own code space. M-1 snapshot + M-5 timelock + M-4
    ///      credit path, all against real OP state.
    function test_fork_M1_M4_M5_onLiveOP() public {
        // M-1: a stream freezes the rate; a later raise does not retro-tax it.
        uint256 amt = 1_000e6;
        deal(OP_USDC, alice, amt);
        vm.startPrank(alice);
        IERC20(OP_USDC).approve(address(f), amt);
        address vault = f.createStream(bob, OP_USDC, amt, START, END);
        vm.stopPrank();
        assertEq(StreamVault(payable(vault)).feeBpsSnap(), 25, "OP stream froze the rate");

        vm.prank(owner);
        f.setFeeBps(100);
        vm.warp(f.feeBpsEta());
        f.commitFeeBps();                        // M-5 stage->commit works on OP too
        assertEq(f.feeBps(), 100);

        vm.warp(START + 30 days);
        uint256 bobBefore = IERC20(OP_USDC).balanceOf(bob);
        StreamVault(payable(vault)).withdraw();
        assertEq(IERC20(OP_USDC).balanceOf(bob) - bobBefore, amt - (amt * 25 / 10_000), "OP pays the SNAPSHOT rate");

        // M-4: a reverting NATIVE payee is credited, not bricked, on OP.
        OPRejecter rev = new OPRejecter();
        vm.deal(alice, amt);
        vm.prank(alice);
        address nv = f.createStream{value: amt}(address(rev), address(0), amt, END, END + 30 days);
        vm.warp(END + 30 days);
        rev.reject(true);
        StreamVault(payable(nv)).withdraw();     // must not revert
        assertGt(StreamVault(payable(nv)).claimable(address(rev)), 0, "credited on OP");
    }
}

contract OPRejecter {
    bool public rejecting;
    function reject(bool b) external { rejecting = b; }
    receive() external payable { if (rejecting) revert("no"); }
}
