// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal Permit2 (canonical 0x000000000022D473030F116dDEE9F6B43aC78BA3, present on Base
///      mainnet, codelen 9152 verified 2026-11-05). Only the allowance path is needed for the
///      proof; the signature `permit()` path is the v2 one-signature UX and is NOT exercised here.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
