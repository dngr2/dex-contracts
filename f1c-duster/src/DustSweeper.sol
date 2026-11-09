// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// ---------------------------------------------------------------------------------------------
// F1-c dust-sweep fork proof — the A/B decider.
//
// QUESTION THE FORK ANSWERS: to sweep a user's dust into USDC in ONE signature and ONE tx, which
// frame wins?
//
//   Option A — user signs a Permit2 `permit()` (or does a one-time approve), then the whole batch
//              is submitted through Multicall3.aggregate3, which calls Permit2.transferFrom +
//              Router.swapExactTokensForTokens for each token.
//   Option B — the user does a ONE-TIME approve to a thin stateless Sweeper, then calls
//              Sweeper.sweep(tokens[], hops[][], minOut[]) directly. msg.sender == user.
//
// THE SPECIFIC HAZARD TO MEASURE (critic GO 2026-11-05): under Option A `msg.sender == Multicall3`
// inside the batch. Router._pull() pulls from `msg.sender` — so tokens must be routed
// user -> Permit2 -> MC3, and MC3 must hold an allowance to the Router, which must be re-approved
// INSIDE THE BATCH on every sweep (an SSTORE/token). Option B has msg.sender == user, so the MC3
// hop and the per-sweep approve vanish.
//
// DECISION RULE (pre-agreed, no re-litigating after the measurement):
//   switch to B if the fork confirms BOTH (a) a per-sweep approve is required inside the A batch,
//   AND (b) a standing MC3->Router allowance exists. If either fails to appear, A stands.
// ---------------------------------------------------------------------------------------------

import {IERC20} from "./interfaces/IERC20.sol";
import {IUniswapV3Router} from "./interfaces/IUniswapV3Router.sol";

/// @title DustSweeper — Option B. Stateless, no storage, no owner, no fee.
/// @notice For each token: pull the user's full balance via Permit2, approve the venue router,
///         one-hop swap to USDC, deliver USDC straight to the user.
/// @dev The user approves THIS contract once per token (max), forever. No MC3, so
///      `msg.sender == user` throughout and no third party ever holds an allowance.
contract DustSweeper {
    IPermit2Like public constant PERMIT2 = IPermit2Like(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    struct HopInput {
        uint8 venue; // 0 = UniV3
        address tokenIn;
        address tokenOut;
        uint24 feeTier;
        address venueRouter;
    }

    error Empty();
    error Swept();

    /// @param tokens   the dust tokens to sweep (each must be approved to Permit2 by the user)
    /// @param hops     parallel array: the single hop that turns tokens[i] into USDC
    /// @param minOut   parallel array: minimum USDC out per token (slippage guard)
    function sweep(address[] calldata tokens, HopInput[] calldata hops, uint256[] calldata minOut)
        external
        returns (uint256 totalOut)
    {
        uint256 n = tokens.length;
        if (n == 0 || n != hops.length || n != minOut.length) revert Empty();

        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(msg.sender);
            if (bal == 0) continue;

            // user -> this. Permit2 must be approved by the user for `tokens[i]`.
            PERMIT2.transferFrom(msg.sender, address(this), _u160(bal), tokens[i]);

            HopInput calldata h = hops[i];
            _approve(tokens[i], h.venueRouter, bal);
            uint256 out = IUniswapV3Router(h.venueRouter).exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: h.tokenIn,
                    tokenOut: h.tokenOut,
                    fee: h.feeTier,
                    recipient: msg.sender, // straight to the user, no intermediate custody
                    amountIn: bal,
                    amountOutMinimum: minOut[i],
                    sqrtPriceLimitX96: 0
                })
            );
            totalOut += out;
        }
    }

    function _approve(address token, address spender, uint256 amount) internal {
        uint256 a = IERC20(token).allowance(address(this), spender);
        if (a < amount) {
            if (a != 0) IERC20(token).approve(spender, 0); // USDT-style
            IERC20(token).approve(spender, type(uint256).max);
        }
    }

    function _u160(uint256 x) internal pure returns (uint160) {
        return uint160(x);
    }
}

interface IPermit2Like {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}
