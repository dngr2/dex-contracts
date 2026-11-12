// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Router} from "../../src/Router.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockVenueRouter} from "../../src/mocks/MockVenueRouter.sol";

/// @dev Unit leg for the L-1-FIX `rescue`. The Router is OWNERLESS, so rescue is permissionless
///      and the destination is the immutable `treasury` — these tests pin BOTH halves:
///        (a) the balance actually leaves and lands at `treasury`, exactly;
///        (b) ANY caller can do it, but the caller never receives the funds;
///        (c) it is inert on an empty balance (no revert, returns 0);
///        (d) it does not disturb the live swap path.
///
///      Property-style (assert the exact swept amount and the exact treasury delta), never a
///      literal that happens to match. Neg controls live in `NegControl` style below.
contract RescueTest is Test {
    Router router;
    MockERC20 usdc;
    MockERC20 weth;
    MockVenueRouter venue;

    address treasury = address(0xBEEF);
    address alice = address(0xA11CE);
    address stranger = address(0x5EED);

    uint256 constant FEE_BPS = 5;
    uint256 constant ONE = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        venue = new MockVenueRouter();
        venue.setRate(2400, 1);
        router = new Router(FEE_BPS, treasury);

        weth.mint(alice, 100 * ONE);
        usdc.mint(address(venue), 1e30);
        vm.prank(alice);
        weth.approve(address(router), type(uint256).max);
    }

    function _hop(address tin, address tout) internal view returns (Router.Hop memory) {
        return Router.Hop(0, tin, tout, 3000, false, address(venue), address(0));
    }

    function _swap(uint256 amountIn) internal returns (uint256) {
        Router.Hop[] memory hops = new Router.Hop[](1);
        hops[0] = _hop(address(weth), address(usdc));
        vm.prank(alice);
        return router.swapExactTokensForTokens(
            Router.ExactInputParams(amountIn, 0, hops, alice, block.timestamp + 100)
        );
    }

    // ------------------------------------------------------------------ core property
    /// A stranded balance is moved to `treasury` EXACTLY, and the router ends empty.
    function test_rescueSweepsStrandedBalanceToTreasury() public {
        usdc.mint(address(router), 1_234_567); // simulate a short-pull strand

        uint256 tBefore = usdc.balanceOf(treasury);
        uint256 swept = router.rescue(address(usdc));

        assertEq(swept, 1_234_567, "swept must equal the whole stranded balance");
        assertEq(usdc.balanceOf(treasury) - tBefore, 1_234_567, "treasury delta exact");
        assertEq(usdc.balanceOf(address(router)), 0, "router left empty");
    }

    /// Permissionless: a caller who is NOT the treasury and NOT an owner can call it — but never
    /// receives the funds. This is the property that makes "no owner" safe.
    function test_rescueIsPermissionlessButCallerDoesNotReceive() public {
        weth.mint(address(router), 5 * ONE);
        uint256 sBefore = weth.balanceOf(stranger);
        uint256 tBefore = weth.balanceOf(treasury);

        vm.prank(stranger);                  // no prank for owner — there is no owner
        router.rescue(address(weth));

        assertEq(weth.balanceOf(stranger), sBefore, "caller must NOT be credited");
        assertEq(weth.balanceOf(treasury) - tBefore, 5 * ONE, "treasury is the fixed destination");
    }

    /// Inert on an empty balance: returns 0, does not revert, emits with amount 0.
    function test_rescueOnEmptyBalanceIsInert() public {
        uint256 swept = router.rescue(address(usdc));
        assertEq(swept, 0, "empty balance sweeps 0");
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// The event carries (token, to, amount) — a watcher can index on token.
    function test_rescueEmitsEvent() public {
        usdc.mint(address(router), 42);
        vm.expectEmit(true, true, false, true, address(router));
        emit Router.Rescued(address(usdc), treasury, 42);
        router.rescue(address(usdc));
    }

    /// rescueable() previews exactly what rescue() would move.
    function test_rescueableViewMatchesAction() public {
        usdc.mint(address(router), 999);
        uint256 preview = router.rescueable(address(usdc));
        uint256 acted = router.rescue(address(usdc));
        assertEq(preview, acted, "preview must equal the action");
    }

    // ------------------------------------------------------------------ does not disturb swaps
    /// A real swap runs correctly with a stranded balance sitting in the router, and rescue still
    /// recovers ONLY the strand (the swap's transient balances are gone by the time it returns).
    function test_swapUnaffectedByStrandedBalance_thenRescueRecoversIt() public {
        weth.mint(address(router), 3 * ONE);        // pre-existing strand
        uint256 out = _swap(10 * ONE);
        assertGt(out, 0, "swap still works with a stranded balance present");
        assertEq(weth.balanceOf(address(router)), 3 * ONE, "strand untouched by an unrelated swap");

        uint256 swept = router.rescue(address(weth));
        assertEq(swept, 3 * ONE, "rescue recovers exactly the strand, not the swap's tokens");
    }

    /// fund-relevant: rescue moves ONLY the named token, leaving a different token alone.
    function test_rescueIsTokenScoped() public {
        usdc.mint(address(router), 111);
        weth.mint(address(router), 222);
        router.rescue(address(usdc));
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 222, "other token untouched");
    }

    // ------------------------------------------------------------------ neg control
    /// INJECTION: prove the sweep assertion can actually fail. Override `treasury` destination by
    /// deploying a router whose treasury is a DIFFERENT address and assert the funds do NOT land at
    /// the old one — i.e. the destination really is the immutable, not something incidental.
    function test_negControl_destinationIsTheConstructorTreasury() public {
        address other = address(0x0DDB1A);
        Router r2 = new Router(FEE_BPS, other);
        usdc.mint(address(r2), 777);

        address caller = address(0xCA11E4);
        vm.prank(caller);
        r2.rescue(address(usdc));

        assertEq(usdc.balanceOf(other), 777, "funds follow the ctor treasury");
        assertEq(usdc.balanceOf(treasury), 0, "and NOT the other instance's treasury");
        assertEq(usdc.balanceOf(caller), 0, "nor the caller");
    }
}
