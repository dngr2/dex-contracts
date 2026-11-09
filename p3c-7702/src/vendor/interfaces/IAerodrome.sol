// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal shape of the Aerodrome (Solidly-fork) Router and Factory as needed.
///      IMPORTANT, verified live 2026-11-05: `getAmountsOut` takes `Route[]`
///      = (from, to, stable, factory) — NOT `address[]`. The address[] form reverts.
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external
        view
        returns (uint256[] memory amounts);
}

interface IAerodromeFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}
