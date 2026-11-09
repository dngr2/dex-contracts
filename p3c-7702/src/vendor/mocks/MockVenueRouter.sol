// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "../interfaces/IERC20.sol";
import {IUniswapV3Router} from "../interfaces/IUniswapV3Router.sol";
import {IAerodromeRouter} from "../interfaces/IAerodrome.sol";

/// @dev Stand-in venue that swaps at a fixed, settable rate. Used to make the unit tests
///      deterministic and — importantly — to let each venue's OWN path be driven separately,
///      so a bug in the UniV3 branch cannot be masked by the Aerodrome one.
contract MockVenueRouter is IUniswapV3Router, IAerodromeRouter {
    uint256 public rateNum = 1; // out = in * rateNum / rateDen
    uint256 public rateDen = 1;
    bool public pullInput = true;

    function setRate(uint256 n, uint256 d) external {
        rateNum = n;
        rateDen = d;
    }

    function setPullInput(bool v) external {
        pullInput = v;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        uint256 out = (p.amountIn * rateNum) / rateDen;
        if (pullInput) IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenOut).transfer(p.recipient, out);
        return out;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        uint256 out = (amountIn * rateNum) / rateDen;
        if (pullInput) IERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        IERC20(routes[0].to).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function getAmountsOut(uint256 amountIn, Route[] calldata) external view returns (uint256[] memory) {
        uint256[] memory a = new uint256[](2);
        a[0] = amountIn;
        a[1] = (amountIn * rateNum) / rateDen;
        return a;
    }
}
