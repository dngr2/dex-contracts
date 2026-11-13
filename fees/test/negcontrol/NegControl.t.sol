// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {PickyToken} from "../unit/mocks/RevertingReceiver.sol";

/// @notice A deliberately-BROKEN splitter: on a reverting payout it does NOT accrue the payable,
/// it just DROPS it (the classic "lost fee" bug). Everything else matches FeeSplitter. The
/// negcontrol proves the unit suite's accrual assertions actually have teeth: run the SAME
/// scenario against this broken twin and the accrual check MUST fail.
contract BrokenFeeSplitter {
    uint16 public constant BPS = 10_000;
    uint16 public referralBps = 2500;
    address public treasury;
    mapping(address => mapping(address => uint256)) public claimable;

    constructor(address t) {
        treasury = t;
    }

    function split(address token, uint256 fee, address referrer) external returns (uint256 rc, uint256 tc) {
        rc = (fee * referralBps) / BPS;
        tc = fee - rc;
        // pull
        (bool ok, bytes memory r) =
            token.call(abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), fee));
        require(ok && (r.length == 0 || abi.decode(r, (bool))), "pull");
        // pay referrer (DROP on failure — the bug)
        _payDropping(token, referrer, rc);
        _payDropping(token, treasury, tc);
    }

    function _payDropping(address token, address to, uint256 amt) internal {
        (bool ok,) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amt));
        // NOTE: on !ok we do nothing -> the amount is LOST (never accrued)
        ok;
    }
}

contract NegControlTest is Test {
    address internal referrer = makeAddr("referrer");
    address internal treasury = makeAddr("treasury");

    function _setup() internal returns (PickyToken picky, FeeSplitter good, BrokenFeeSplitter bad) {
        picky = new PickyToken();
        picky.mint(address(this), 100_000);
        good = new FeeSplitter(treasury);
        bad = new BrokenFeeSplitter(treasury);
        picky.approve(address(good), type(uint256).max);
        picky.approve(address(bad), type(uint256).max);
        picky.setReject(referrer, true); // referrer rejects the token -> payout reverts
    }

    /// @dev The GOOD splitter accrues the referrer cut on revert -> claimable == rc.
    function test_good_accrues() public {
        (PickyToken picky, FeeSplitter good,) = _setup();
        (uint256 rc,) = good.split(address(picky), 1000, "p", address(this), referrer);
        assertEq(rc, 250);
        assertEq(good.claimable(referrer, address(picky)), 250, "good accrues");
        assertEq(good.claimable(treasury, address(picky)), 0, "treasury paid inline");
        assertEq(picky.balanceOf(treasury), 750, "treasury got its cut");
    }

    /// @dev NEGCONTROL: the SAME scenario against the broken twin. The accrual is ZERO (the bug) —
    /// so a test asserting `claimable == rc` would FAIL. This proves the assertion is meaningful.
    function test_negcontrol_broken_losesFee() public {
        (PickyToken picky,, BrokenFeeSplitter bad) = _setup();
        (uint256 rc,) = bad.split(address(picky), 1000, referrer);
        assertEq(rc, 250);
        // THE BUG: referrer cut vanished instead of accruing.
        assertEq(bad.claimable(referrer, address(picky)), 0, "broken twin does NOT accrue");
        assertTrue(bad.claimable(referrer, address(picky)) != rc, "so good's ==rc assertion has teeth");
        // and the 250 is stuck in the broken splitter, unreachable (proof of loss)
        assertEq(picky.balanceOf(address(bad)), 250, "250 stranded in broken twin");
    }
}
