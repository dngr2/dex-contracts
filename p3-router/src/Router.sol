// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "./interfaces/IERC20.sol";
import {IUniswapV3Router} from "./interfaces/IUniswapV3Router.sol";
import {IAerodromeRouter} from "./interfaces/IAerodrome.sol";

/// @title P3 — MEV-protected swap router (Base)
/// @notice Aggregates EXISTING pools. Holds no liquidity, keeps no state between swaps.
///         The route (which venue, which hops) is chosen OFF-CHAIN by the quote engine and
///         handed in; the contract just executes it and takes a flat fee on the input.
///
/// @dev DESIGN NOTES THAT MATTER
///
///  1. FEE-ON-INPUT. `fee = received * feeBps / 10_000` is moved to `treasury` BEFORE routing;
///     only the remainder is routed. No router balance, no `collect()`, no SSTORE. The user's
///     `amountOutMin` therefore applies to the routed portion and is checked on the FINAL hop.
///
///  2. THE `private` FLAG IS OFF-CHAIN. The contract cannot know how its tx was submitted
///     (sequencer RPC vs public mempool). That decision lives in the submitter/keeper, not here.
///     See PLAN.md §2 — "add a private relay" is not Solidity work.
///
///  3. AERODROME TAKES A STRUCT ROUTE. `Route[] = (from,to,stable,factory)`, NOT `address[]`.
///     Verified live 2026-11-05: the address[] form reverts.
///
///  4. `venueRouter` IS PASSED PER HOP, not hardcoded, so one bytecode serves Base mainnet and
///     Base Sepolia (whose Uniswap V3 deployment lives at different addresses). The quote engine
///     supplies it. A malicious router is therefore a caller-trusted input — see PLAN.md.
///
///  L-1 (caller-trusted venue; stranded balances are sweepable by anyone). Because `venueRouter` is
///     arbitrary, a hop can approve a router that never pulls, or pulls less than `amountIn`. The
///     Router keeps NO per-user accounting, so anything left here between calls belongs to nobody in
///     particular. FIXED (v2): there is now a `rescue(token)` that sweeps a stranded balance to
///     `treasury` — see L-1-FIX below. The remaining mitigation is still procedural: the quote engine
///     must re-derive the route fresh each swap (venue swaps are on-chain, not here), and a per-hop
///     balance-delta measurement (rather than trusting `returned`) would make a short-pulling router
///     fail loud instead of stranding.
///
///  L-1-FIX: `rescue(address token)` is PERMISSIONLESS but the destination is the immutable
///     `treasury`, so a caller cannot route a stranded balance to themselves. Permissionless is safe
///     precisely BECAUSE the Router holds nothing between swaps (no per-user accounting): every
///     balance present when no swap is mid-flight IS stranded, so there is nothing to pick out.
///     A malicious token's `transfer` cannot reenter into a bad state (rescue reads the balance
///     first and has no other invariants); the contract keeps no balance that rescue must preserve.
///
///  5. OWNERSHIP: immutable (proposal, not decided). `feeBps` and `treasury` are fixed at deploy,
///     removing the admin-key attack surface entirely. P3b/P3c redeploy anyway. Flipping to
///     Ownable is a small, contained change — see `FEE_BPS`/`TREASURY` below.
contract Router {
    // ---------------------------------------------------------------- venues
    uint8 internal constant VENUE_UNIV3 = 0;
    uint8 internal constant VENUE_AERODROME = 1;

    // ---------------------------------------------------------------- config
    /// @dev #144: this is the 10_000 DENOMINATOR, NOT a 500-bps cap (as it is on the factories).
    ///      Kept `internal` so the back-compat `MAX_FEE_BPS()` getter below can carry the name.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev ABI BACK-COMPAT (I-3): the live router answers `MAX_FEE_BPS()` (selector 0xd55be8c6 →
    ///      10000) and off-chain readers key on that selector (dex-site/PRODUCTS.json sig entries,
    ///      merchant page SEL.maxFeeBps). A bare rename to BPS_DENOMINATOR would revert them, so the
    ///      getter name is preserved and just returns the denominator.
    function MAX_FEE_BPS() external pure returns (uint256) {
        return BPS_DENOMINATOR;
    }

    uint256 public immutable feeBps;
    address public immutable treasury;

    // ---------------------------------------------------------------- types
    /// @dev One hop. `feeTier` is UniV3-only; `stable`/`factory` are Aerodrome-only. The unused
    ///      fields are ignored by the venue branch. A union was avoided to keep the ABI flat and
    ///      the off-chain encoder trivial.
    struct Hop {
        uint8 venue;
        address tokenIn;
        address tokenOut;
        uint24 feeTier;
        bool stable;
        address venueRouter;
        address factory;
    }

    struct ExactInputParams {
        uint256 amountIn;
        uint256 amountOutMin;
        Hop[] hops;
        address recipient;
        uint256 deadline;
    }

    event Swap(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 fee,
        uint256 amountOut
    );

    /// @dev L-1-FIX: emitted by `rescue`. `token` indexed for the quote engine's watcher.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error Expired();
    error EmptyRoute();
    error ZeroAmount();
    error UnknownVenue(uint8 venue);
    error InsufficientOutput(uint256 got, uint256 want);
    error FeeTooHigh(uint256 bps);

    constructor(uint256 feeBps_, address treasury_) {
        if (feeBps_ > BPS_DENOMINATOR) revert FeeTooHigh(feeBps_);
        if (treasury_ == address(0)) revert ZeroAmount();
        feeBps = feeBps_;
        treasury = treasury_;
    }

    // ---------------------------------------------------------------- main
    /// @notice Swap `amountIn` of `hops[0].tokenIn` for at least `amountOutMin` of the final
    ///         hop's output token, delivering to `recipient`. A flat `feeBps` is taken off the
    ///         input to `treasury` first.
    function swapExactTokensForTokens(ExactInputParams calldata p)
        external
        returns (uint256 amountOut)
    {
        _checkDeadline(p.deadline);
        if (p.hops.length == 0) revert EmptyRoute();
        if (p.amountIn == 0) revert ZeroAmount();
        // L-2: a zero recipient is accepted by both venues as a literal sink — the output lands at
        // address(0), recoverable by nobody (fork-proved on Uniswap SwapRouter02 + Aerodrome). Only
        // the LAST hop can be hit, since intermediate hops force address(this).
        if (p.recipient == address(0)) revert ZeroAmount();

        Hop calldata first = p.hops[0];

        // Pull the input, measuring what ACTUALLY arrived so a fee-on-transfer input token
        // cannot make the fee overshoot the real balance.
        uint256 balBefore = IERC20(first.tokenIn).balanceOf(address(this));
        _pull(first.tokenIn, msg.sender, p.amountIn);
        uint256 received = IERC20(first.tokenIn).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();

        uint256 fee = _feeFor(received);
        uint256 amount = _postFee(received, fee);
        if (fee != 0) _push(first.tokenIn, treasury, fee);

        uint256 last = p.hops.length - 1;
        for (uint256 i = 0; i <= last; ++i) {
            Hop calldata h = p.hops[i];
            _checkVenue(h.venue);
            bool isLast = i == last;
            address to = isLast ? p.recipient : address(this);

            uint256 got = _hop(h, amount, to);

            // Only the final hop's shortfall is the user's problem; intermediate hops are
            // bounded by the route the quote engine chose.
            if (isLast) _checkMinOut(got, p.amountOutMin);

            amount = got;
        }

        amountOut = amount;
        emit Swap(msg.sender, p.recipient, first.tokenIn, p.hops[last].tokenOut, p.amountIn, fee, amountOut);
    }

    /// @notice The fee a given input would incur. Convenience for the quote engine / UI.
    function previewFee(uint256 amountIn) external view returns (uint256) {
        return _feeFor(amountIn);
    }

    /// @notice Sweep a stranded balance of `token` to `treasury`. PERMISSIONLESS — the Router holds
    ///         nothing between swaps (there is no per-user accounting), so any balance present when
    ///         no swap is mid-flight is stranded and the fixed destination means a caller cannot
    ///         divert it. Closes L-1: a short-pulling venue router used to strand tokens with no
    ///         recovery path at all (the Router is ownerless, so there was no other exit).
    /// @dev    Native (address(0)) is NOT handled: the Router never holds native — every swap path
    ///         pulls/returns ERC-20 only, and no `msg.value` is accepted. Kept explicit so the
    ///         address(0) sentinel cannot be mistaken for the zero address as a real token.
    /// @return amount the balance that was swept (0 if already empty).
    function rescue(address token) external returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) _push(token, treasury, amount);
        emit Rescued(token, treasury, amount);
    }

    /// @notice View form of `rescue` for a quote engine / UI that wants to preview the sweep.
    function rescueable(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ---------------------------------------------------------------- seams
    // These exist so the negative controls can re-inject a bug INTO THE LIVE PATH.
    // A control that recomputes the "buggy" value by hand proves nothing (GOTCHAS #20);
    // overriding these makes `swapExactTokensForTokens` itself run the bad arithmetic.

    /// @dev floor(received * feeBps / BPS_DENOMINATOR). Rounding DOWN is the deliberate choice:
    ///      rounding up would make the fee exceed the user's `amountIn * bps / 10_000` intuition.
    function _feeFor(uint256 received) internal view virtual returns (uint256) {
        return (received * feeBps) / BPS_DENOMINATOR;
    }

    /// @dev What is actually routed. Splitting it out makes the "forgot to subtract the fee"
    ///      class injectable independently of `_feeFor`.
    function _postFee(uint256 received, uint256 fee) internal pure virtual returns (uint256) {
        return received - fee;
    }

    function _checkDeadline(uint256 deadline) internal view virtual {
        if (block.timestamp > deadline) revert Expired();
    }

    function _checkMinOut(uint256 got, uint256 minOut) internal pure virtual {
        if (got < minOut) revert InsufficientOutput(got, minOut);
    }

    function _checkVenue(uint8 venue) internal pure virtual {
        if (venue != VENUE_UNIV3 && venue != VENUE_AERODROME) revert UnknownVenue(venue);
    }

    // ---------------------------------------------------------------- internals
    function _hop(Hop calldata h, uint256 amountIn, address to) internal returns (uint256 out) {
        if (h.venue == VENUE_UNIV3) {
            _forceApprove(h.tokenIn, h.venueRouter, amountIn);
            out = IUniswapV3Router(h.venueRouter).exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: h.tokenIn,
                    tokenOut: h.tokenOut,
                    fee: h.feeTier,
                    recipient: to,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        } else if (h.venue == VENUE_AERODROME) {
            _forceApprove(h.tokenIn, h.venueRouter, amountIn);
            IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
            routes[0] = IAerodromeRouter.Route({
                from: h.tokenIn,
                to: h.tokenOut,
                stable: h.stable,
                factory: h.factory
            });
            uint256[] memory amounts =
                IAerodromeRouter(h.venueRouter).swapExactTokensForTokens(amountIn, 0, routes, to, block.timestamp);
            out = amounts[amounts.length - 1];
        } else {
            revert UnknownVenue(h.venue);
        }
    }

    function _pull(address token, address from, uint256 amount) internal {
        _safeTransferFrom(token, from, address(this), amount);
    }

    function _push(address token, address to, uint256 amount) internal {
        _safeTransfer(token, to, amount);
    }

    /// @dev Tolerates tokens (USDT-style) that require a zero allowance before a new one.
    function _forceApprove(address token, address spender, uint256 amount) internal {
        uint256 a = IERC20(token).allowance(address(this), spender);
        if (a != amount) {
            if (a != 0) _safeApprove(token, spender, 0);
            _safeApprove(token, spender, amount);
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}
