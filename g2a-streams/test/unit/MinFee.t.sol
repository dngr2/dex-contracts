// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @title MIN-FEE at the G2-a withdraw toll site, plus a mutation negcontrol via the REAL path.
/// @dev Same shape as p2's MinFee.t.sol: at `minFee()==0` the split is byte-for-byte the old
///      `(w * bps) / 10_000`; above the line a small withdrawal is tolled at the floor; at or below
///      the line the vault SKIPS the toll (recipient gets the whole withdrawal). The negcontrol
///      routes the "minFee ignored" bug through the REAL factory -> vault withdraw path.

/// @dev MUTANT — `_toll` forgets the floor. Protects test_smallWithdraw_nowPaysTheFloor.
contract IgnoringMinFeeVault is StreamVault {
    constructor(
        address f, address p, address r, address t, uint256 a, uint64 s, uint64 e, bytes32 salt, uint256 idx
    ) StreamVault(f, p, r, t, a, s, e, salt, idx) {}

    function _toll(uint256 w) internal view override returns (uint256 fee, uint256 out) {
        uint256 f = (w * factory.feeBps()) / 10_000;   // THE BUG: no floor
        return (f, w - f);
    }
}

/// @dev Factory that spawns the mutant. Same real create path; only the created bytecode differs.
contract MutantStreamFactory is StreamFactory {
    constructor(address o, address r, uint16 b) StreamFactory(o, r, b) {}

    function _initCode(Stream memory s) internal view override returns (bytes memory) {
        return abi.encodePacked(
            type(IgnoringMinFeeVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index)
        );
    }
}

contract MinFeeStreamTest is Test {
    StreamFactory f;
    MutantStreamFactory mut;
    MockERC20 usdc;

    address owner = address(0x0117);
    address feeRcpt = address(0xFEE0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant FEE_BPS = 25;
    uint256 constant MIN_FEE = 1_000;      // 0.001 USDC (6 decimals)
    uint64 START;
    uint64 constant DURATION = 30 days;

    function setUp() public {
        vm.warp(1_000_000);
        START = uint64(block.timestamp);
        f = new StreamFactory(owner, feeRcpt, uint16(FEE_BPS));
        mut = new MutantStreamFactory(owner, feeRcpt, uint16(FEE_BPS));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(alice, 10_000_000e6);
        vm.deal(feeRcpt, 0);
    }

    function _mk(StreamFactory fac, uint256 amt) internal returns (address vault) {
        vm.startPrank(alice);
        usdc.approve(address(fac), amt);
        vault = fac.createStream(bob, address(usdc), amt, START, ENDV());
        vm.stopPrank();
    }

    /// @dev M-5: `setMinFee` now STAGES; land it via commit at the ETA. Warps to the ETA (48h), which
    ///      is still well inside the 30-day window, so the fully-vested withdraw below is unaffected.
    function _floor(StreamFactory fac, uint256 mf) internal {
        vm.prank(owner);
        fac.setMinFee(mf);
        vm.warp(fac.minFeeEta());
        fac.commitMinFee();
    }

    function ENDV() internal view returns (uint64) {
        return START + DURATION;
    }

    function _withdrawAll(address vault) internal returns (uint256 out, uint256 fee) {
        vm.warp(START + DURATION + 1);          // fully vested
        vm.prank(bob);
        return StreamVault(payable(vault)).withdraw();
    }

    // ---------------------------------------------------------------- default 0 = today's behaviour

    /// @dev (1) DEFAULT 0 IS IDENTICAL: a fully vested withdrawal pays exactly the old bps fee.
    function test_defaultZero_isTheOldFormula() public {
        assertEq(f.minFee(), 0, "deploy default is 0");
        uint256 amt = 1_000e6;
        address v = _mk(f, amt);
        (uint256 out, uint256 fee) = _withdrawAll(v);
        assertEq(fee, (amt * FEE_BPS) / 10_000, "fee is the raw bps formula at minFee 0");
        assertEq(out, amt - fee);
        assertEq(usdc.balanceOf(bob), out, "recipient got out");
    }

    // ---------------------------------------------------------------- the loss case, now fixed

    /// @dev (2) THE SMALL-WITHDRAW LOSS CASE: a fully-vested withdrawal whose bps fee is under the
    ///      floor now pays AT the floor.
    function test_smallWithdraw_nowPaysTheFloor() public {
        _floor(f, MIN_FEE);

        uint256 amt = 110_000;                        // $0.11 fully vested
        uint256 bpsOnly = (amt * FEE_BPS) / 10_000;   // 275 — under the floor
        assertLt(bpsOnly, MIN_FEE, "precondition: bps fee is under the floor");

        address v = _mk(f, amt);
        (uint256 out, uint256 fee) = _withdrawAll(v);
        assertEq(fee, MIN_FEE, "small withdraw is tolled AT the floor");
        assertEq(fee + out, amt, "conserves");
        assertEq(usdc.balanceOf(feeRcpt), MIN_FEE, "treasury got the floor");
    }

    /// @dev (3) DUST STAYS SAFE: a withdrawal at or below the floor is untolled — the recipient gets
    ///      the whole withdrawal (a clamp would hand them 0).
    function test_dustBelowFloor_forwardsWhole() public {
        _floor(f, MIN_FEE);

        uint256[3] memory dusts = [uint256(1), 500, 1_000];
        for (uint256 i; i < dusts.length; i++) {
            // same (alice,bob,usdc) + same window -> each pass after the first is a hedge replay
            if (i != 0) {
                vm.prank(alice);
                f.resetHedge(bob, address(usdc));
            }
            address v = _mk(f, dusts[i]);
            (uint256 out, uint256 fee) = _withdrawAll(v);
            assertEq(fee, 0, "at or below the floor: no toll");
            assertEq(out, dusts[i], "recipient gets the whole withdrawal");
        }
    }

    /// @dev (4) `cancel` splits through the SAME definition (via `_toll`) as `withdraw`, so the two
    ///      paths cannot drift. A fully-vested cancel tolls the floor identically.
    function test_cancelUsesSameDefinition() public {
        _floor(f, MIN_FEE);
        uint256 amt = 110_000;
        address v = _mk(f, amt);
        vm.warp(START + DURATION + 1);
        vm.prank(alice);
        StreamVault(payable(v)).cancel();
        assertEq(usdc.balanceOf(feeRcpt), MIN_FEE, "cancel tolled the floor, same as withdraw would");
        assertEq(usdc.balanceOf(bob), amt - MIN_FEE, "recipient got amount - floor");
    }

    // ---------------------------------------------------------------- NEGCONTROL (real path)

    /// @dev (5) NEGCONTROL — the "minFee ignored" mutant reached through the REAL factory/vault path.
    function test_negcontrol_minFeeIgnored_viaRealPath() public {
        _floor(mut, MIN_FEE);
        _floor(f, MIN_FEE);

        uint256 amt = 110_000;
        uint256 bpsOnly = (amt * FEE_BPS) / 10_000;

        address vm_ = _mk(mut, amt);
        (, uint256 mutFee) = _withdrawAll(vm_);
        assertEq(mutFee, bpsOnly, "mutant pays the raw bps fee, ignoring the floor");
        assertTrue(mutFee < MIN_FEE, "and that is BELOW the floor -> the positive test would redden");

        address vr = _mk(f, amt);
        (, uint256 realFee) = _withdrawAll(vr);
        assertEq(realFee, MIN_FEE, "real path keeps the floor");
        assertGt(realFee, mutFee, "mutant and real observably differ");
    }
}
