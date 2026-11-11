// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title Fork test — real Base Sepolia, real USDC (no key, no money)
/// @dev Two jobs:
///      1. The ERC20 leg meets a REAL token's transfer() instead of a mock's.
///      2. THE DAEMON-REUSE PIN: assert on-chain that `StreamVault`'s `Registered` log is
///         byte-identical to P2's keeper `TOPIC_REGISTERED` constant with the same topic layout
///         (topics[2]=vault, topics[3]=recipient). If this drifts, the daemon's discovery cache
///         silently stops learning vault->recipient and streams go unsettled — the exact failure
///         the SCOPE §2 catch is about. Asserting it in a test is what keeps the claim honest.
///      Run: forge test --match-path "test/fork/*" --fork-url base_sepolia
contract StreamBaseSepoliaForkTest is Test {
    // canonical Base Sepolia USDC (verified live: decimals 6, symbol "USDC")
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // COPIED VERBATIM from products/p2-forwarder/keeper/forward.py — if the daemon constant moves
    // and this does not, the parity test must go red. Do not recompute it here; the point is to pin
    // the LITERAL the daemon uses.
    bytes32 constant DAEMON_TOPIC_REGISTERED =
        0xe87c38afe1530714b547d22c5653192a993f1f3c037bd7947063558cb86e0bd2;
    // NOTE the name: the daemon's selector is `forward(address,address)`, NOT `withdraw(...)`.
    // `cast sig` proves it: forward->0x95ccf8bf, withdraw(address,address)->0xf940e385.
    bytes4 constant DAEMON_SEL_FORWARD = 0x95ccf8bf;

    // COPIED VERBATIM from products/g2a-streams/keeper/stream_poller.py (TOPIC_STREAM_CREATED) and
    // from the daemon. The factory's StreamCreated is the address-filterable DISCOVERY feed the
    // poller rides — the vault's own Registered log is emitted by the VAULT, so a `--registry`
    // style address filter pointed at the factory finds nothing there. Pin the literal the daemon
    // actually uses so an event-signature drift is caught on-chain, not in a comment.
    bytes32 constant DAEMON_TOPIC_STREAM_CREATED =
        0xa844bb0b1151841641a3ce5a94169e016356d1b1be5d6cace67723c5b9eeb173;

    // LIVE StreamFactory on Base Sepolia (F1-a's sibling product; deployed + recorded in SCOPE §6)
    address constant LIVE_FACTORY = 0x83303e59d4F9798C3B49f9D4C6E522FfeC05f2A5;

    address owner = address(0x0117);
    address feeRcpt = address(0xFEE0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    StreamFactory f;
    uint64 START;
    uint64 END;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC", string("https://sepolia.base.org")));
        assertGt(USDC.code.length, 0, "USDC must exist on this fork (else RPC/chain is wrong)");
        f = new StreamFactory(owner, feeRcpt, 25);
        START = uint64(block.timestamp);
        END = START + 30 days;
    }

    /// @dev THE PIN. A real factory-created vault's constructor emits `Registered`; the log's
    ///      topic0 must equal the daemon's constant byte-for-byte, and topics[2]/topics[3] must be
    ///      vault/recipient in the positions the daemon reads (`topics[2]`, `topics[3]`). If the
    ///      event signature or its indexed-ness ever changes, this test fails and the "no daemon
    ///      decode change" claim is falsified on-chain rather than in a comment.
    function test_fork_registeredLogMatchesKeeperTopicLayout() public {
        vm.recordLogs();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        address vault = f.createStream{value: 1 ether}(bob, address(0), 1 ether, START, END);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != DAEMON_TOPIC_REGISTERED) continue;
            found = true;
            assertEq(logs[i].topics.length, 4, "must be 4 topics (sig + 3 indexed) like P2's event");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), vault, "topics[2] must be the VAULT addr");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), bob, "topics[3] must be the RECIPIENT");
            assertEq(logs[i].emitter, vault, "emitted by the vault (the daemon caches this address)");
            // The daemon decodes exactly this way in forward.py:
            //   dep = addr_from_topic(lg["topics"][2]); dst = addr_from_topic(lg["topics"][3])
            assertEq(_bare(logs[i].topics[2]), _bare(bytes32(uint256(uint160(vault)))), "topics[2] hex == vault");
            assertEq(_bare(logs[i].topics[3]), _bare(bytes32(uint256(uint160(bob)))), "topics[3] hex == recipient");
        }
        assertTrue(found, "the vault's Registered log MUST be found under the daemon's topic filter");
    }

    /// @dev THE LIVE-FACTORY PIN. Against the actually-deployed StreamFactory: (a) the discovery
    ///      feed the daemon filters on (`StreamCreated`, at the FACTORY address) matches the
    ///      daemon's literal topic0 and decodes to the same field positions the poller reads; and
    ///      (b) the vault's OWN `Registered` log is emitted at the VAULT address — the subtlety that
    ///      makes a factory-address filter on `Registered` return nothing. Both are asserted on live
    ///      deployed code, so the discovery path can't silently rot.
    function test_fork_liveFactory_streamCreatedIsTheDiscoveryFeed() public {
        assertGt(LIVE_FACTORY.code.length, 0, "live StreamFactory must be deployed");

        vm.recordLogs();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        address vault = StreamFactory(payable(LIVE_FACTORY)).createStream{value: 1 ether}(bob, address(0), 1 ether, START, END);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundCreated;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != DAEMON_TOPIC_STREAM_CREATED) continue;
            foundCreated = true;
            // The factory emits it — this is WHY it is address-filterable (unlike Registered).
            assertEq(logs[i].emitter, LIVE_FACTORY, "StreamCreated must be emitted by the FACTORY");
            assertEq(logs[i].topics.length, 4, "sig + 3 indexed, matching discover_stream()'s layout");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), bob, "topics[2] == recipient");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), vault, "topics[3] == vault (discover_stream reads topics[3])");
            // data words the poller reads as token/amount/start/end:
            (address tok, uint256 amt, uint64 s, uint64 e) =
                abi.decode(logs[i].data, (address, uint256, uint64, uint64));
            assertEq(tok, address(0), "native stream token word");
            assertEq(amt, 1 ether, "amount word");
            assertEq(s, START, "start word");
            assertEq(e, END, "end word");
        }
        assertTrue(foundCreated, "the factory's StreamCreated MUST carry the daemon's exact topic0");
    }

    /// @dev The selector the daemon sends must exist on the vault, so `_send()` works unchanged.
    function test_fork_daemonForwardSelectorExists() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        address vault = f.createStream{value: 1 ether}(bob, address(0), 1 ether, START, END);
        vm.warp(START + 30 days);

        // literally the daemon's `SEL_FORWARD + token_word + depositor_word` calldata shape
        bytes memory data = abi.encodePacked(DAEMON_SEL_FORWARD, bytes32(0), bytes32(uint256(uint160(alice))));
        (bool ok, bytes memory ret) = vault.call(data);
        assertTrue(ok, "vault must accept the daemon's EXACT calldata, selector and all");
        (uint256 out, uint256 fee) = abi.decode(ret, (uint256, uint256));
        assertGt(out, 0, "daemon-shaped call must actually pay the recipient");
        assertEq(fee, 1 ether * 25 / 10_000, "and take exactly 25 bps");

        // The fallback() would ALSO swallow bad calldata and return empty, so `ok` alone is not a
        // tooth — assert the return decoded to a real split (which fallback cannot produce).
        assertEq(out + fee, 1 ether, "a fallback() hit would not have returned a decoded split");
    }

    /// @dev Real USDC through a real token implementation, with DELTA assertions (test addresses are
    ///      not clean on a fork).
    function test_fork_realUsdcStreamAndCancel() public {
        uint256 amt = 1_000e6;
        deal(USDC, alice, amt);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(f), amt);
        address vault = f.createStream(bob, USDC, amt, START, END);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(vault), amt, "vault holds real USDC");

        vm.warp(START + (30 days) / 2);
        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        uint256 feeBefore = IERC20(USDC).balanceOf(feeRcpt);

        StreamVault(payable(vault)).withdraw();               // permissionless pull

        uint256 pulled = amt / 2;
        uint256 fee = pulled * 25 / 10_000;
        assertEq(IERC20(USDC).balanceOf(bob) - bobBefore, pulled - fee, "recipient got real USDC minus fee");
        assertEq(IERC20(USDC).balanceOf(feeRcpt) - feeBefore, fee, "feeRecipient got exactly the fee");

        // cancel the rest: unvested back to the payer, no fee on the refund
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        StreamVault(payable(vault)).cancel();
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, amt - pulled, "unvested returned to payer in full");
        assertEq(IERC20(USDC).balanceOf(vault), 0, "vault drained");
    }

    /// @dev The 40 lowercase hex chars of an address word — byte-identical to the daemon's
    ///      `addr_from_topic`, which does `"0x" + t[-40:]`. Comparing BARE (no 0x) keeps it a
    ///      string-to-string compare without needing a concat helper.
    function _bare(bytes32 t) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory out = new bytes(40);
        for (uint256 i; i < 20; i++) {
            uint8 b = uint8(t[i + 12]);
            out[i * 2] = alphabet[b >> 4];
            out[i * 2 + 1] = alphabet[b & 0x0f];
        }
        return string(out);
    }

    // ---- M-BUNDLE fork-live: the audit fixes proven against a REAL token + REAL clock ----

    /// @dev M-1 fork-live: the rate is a ctor SNAPSHOT. A factory raise after a stream is locked does
    ///      NOT retro-tax it; a new stream takes the new rate — on real USDC + real chain clock.
    function test_fork_M1_snapshotRateOnLiveToken() public {
        uint256 amt = 1_000e6;
        deal(USDC, alice, amt);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(f), amt);
        address vault = f.createStream(bob, USDC, amt, START, END);
        vm.stopPrank();
        assertEq(StreamVault(payable(vault)).feeBpsSnap(), 25, "stream froze the old rate");

        vm.prank(owner);
        f.setFeeBps(100);                       // M-5 stage...
        vm.warp(f.feeBpsEta());
        f.commitFeeBps();                       // ...commit
        assertEq(f.feeBps(), 100, "factory rate moved");

        vm.warp(START + 30 days);
        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        StreamVault(payable(vault)).withdraw();
        uint256 pulled = amt;                   // fully vested
        assertEq(IERC20(USDC).balanceOf(bob) - bobBefore, pulled - (pulled * 25 / 10_000), "pays the SNAPSHOT rate");

        // a NEW stream snapshots the raised rate. Its window must be MONOTONIC vs the hedge cursor
        // (same payer/recipient/token), so start it at the first window's END.
        deal(USDC, alice, amt);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(f), amt);
        address v2 = f.createStream(bob, USDC, amt, END, END + 30 days);
        vm.stopPrank();
        assertEq(StreamVault(payable(v2)).feeBpsSnap(), 100, "new stream takes the new rate");
    }

    /// @dev M-4 fork-live: a CONTRACT recipient whose receive() reverts is CREDITED, not bricked,
    ///      and `claim` delivers later — on real code, with a real reverting payee. Proves the pull
    ///      rail never stalls on a payee we do not control.
    function test_fork_M4_revertingRecipientCredited_notBricked() public {
        RevertingPayee rev = new RevertingPayee();
        uint256 amt = 1_000e6;
        deal(USDC, alice, amt);                  // ERC20: no callback, unaffected -- use NATIVE instead
        vm.deal(alice, amt);
        vm.prank(alice);
        address vault = f.createStream{value: amt}(address(rev), address(0), amt, START, END);

        vm.warp(START + 30 days);
        rev.reject(true);                        // payee will revert on receive
        uint256 feeBefore = feeRcpt.balance;
        StreamVault(payable(vault)).withdraw();  // must NOT revert
        uint256 fee = amt * 25 / 10_000;
        assertEq(feeRcpt.balance - feeBefore, fee, "fee still paid while the payee reverts");
        assertEq(address(rev).balance, 0, "payee got nothing on the pull");
        assertEq(StreamVault(payable(vault)).claimable(address(rev)), amt - fee, "payee amount CREDITED, not lost");

        rev.reject(false);                       // payee now accepts
        StreamVault(payable(vault)).claim(address(rev));
        assertEq(address(rev).balance, amt - fee, "claim delivers the credited amount");
    }

    /// @dev M-5 fork-live: the 48h stage->commit + two-step ownership, on a real chain clock.
    function test_fork_M5_timelockAndTwoStepOnLiveChain() public {
        vm.prank(owner);
        f.setMinFee(1_000);
        assertEq(f.minFee(), 0, "unchanged until commit");
        uint64 eta = f.minFeeEta();
        vm.warp(eta - 1);
        vm.expectRevert(StreamFactory.TimelockNotElapsed.selector);
        f.commitMinFee();
        vm.warp(eta);
        f.commitMinFee();
        assertEq(f.minFee(), 1_000, "committed at the ETA");

        vm.prank(owner);
        f.transferOwnership(address(0xC0FFEE));
        assertEq(f.owner(), owner, "owner holds until accept");
        vm.prank(address(0xC0FFEE));
        f.acceptOwnership();
        assertEq(f.owner(), address(0xC0FFEE), "two-step handoff completes");
    }
}

/// @dev A payee CONTRACT that can be told to revert on native receive — the M-4 shape (a multisig /
///      smart wallet we do not control). `reject` toggles it.
contract RevertingPayee {
    bool public rejecting;
    function reject(bool b) external { rejecting = b; }
    receive() external payable {
        if (rejecting) revert("nope");
    }
}
