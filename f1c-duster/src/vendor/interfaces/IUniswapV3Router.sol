// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal shape of Uniswap V3 SwapRouter02 as needed by the router.
///      `exactInputSingle` on SwapRouter02 takes a struct WITHOUT the `deadline`
///      field (the "02" routers dropped it), which is why the deadline is passed
///      in the struct here and the router enforces its own deadline check.
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev `payable` to match the real SwapRouter02 (ETH-in support), even though the MVP
    ///      routes ERC20-in only and never sends value.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}
