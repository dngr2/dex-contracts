// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IERC20Min {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title P3cDelegate — the EIP-7702 delegate that turns the user's EOA into a 1-tx swapper.
/// @notice A user's EOA sets its code to `0xef0100 || address(this)` via ONE type-4 authorization.
///         From then on a call to the user's address runs THIS code in the user's own context:
///         `address(this) == user`, so every `msg.sender` downstream is the user — the user stays
///         the acting identity while our relay (or the user) pays gas.
///
/// WHY THIS EXISTS (the P3c value): plain P3 needs a per-user Router deploy AND an approve tx
/// before the swap. The delegate removes both seams from the user's path — the approve is folded
/// into the same call, and the swap itself is delegated to the ALREADY-DEPLOYED P3 Router (no new
/// router, no per-user bytecode). This delegate holds NO storage and NO tokens, so it is a safe
/// 7702 target: a delegate that read constructor-set storage would read the USER's (empty) slots.
///
/// WHERE THE 5 bps RIDES: not here. The delegate only ensures the allowance and forwards the call;
/// the fee is P3 Router's own fee-on-input (`feeBps` -> `treasury`), so there is exactly ONE fee
/// and no double-charge. This delegate is fee-agnostic by construction.
contract P3cDelegate {
    /// @dev `authority` == address(this) == the user's EOA (proves the code ran in the USER's frame);
    ///      `caller` == whoever sent the tx (the relay in the sponsored shape, the user when
    ///      self-funding). That split is the sponsorship signature, mirrored from g3a's SponsorTarget.
    event Routed(address indexed authority, address indexed caller, address target, uint256 value);

    error InnerCallFailed();

    /// @notice Ensure `spender` may pull `amount` of `token` from the user's EOA, then call `target`
    ///         with `data`. Runs in the USER's frame, so the approve sets the USER's allowance and
    ///         the forwarded call arrives at `target` with `msg.sender == user`.
    /// @param token   input token to approve (address(0) = skip the approve leg entirely)
    /// @param spender who must be allowed to pull (the P3 Router)
    /// @param amount  allowance the swap needs (the router's amountIn)
    /// @param target  the call target (the P3 Router)
    /// @param data    the pre-encoded swap calldata
    function batch(
        address token,
        address spender,
        uint256 amount,
        address target,
        bytes calldata data
    ) external payable returns (bytes memory) {
        if (token != address(0)) {
            // Approve only when SHORT. The P3 Router pulls with `transferFrom`, which CONSUMES the
            // allowance to 0 each swap — so on every swap this guard fires and re-approves INLINE
            // (that is how the tier removes the separate approve TX, not the approve call).
            uint256 a = IERC20Min(token).allowance(address(this), spender);
            if (a < amount) {
                // USDT-class tokens reject non-zero -> non-zero; reset first when one is present.
                if (a != 0) _approve(token, spender, 0);
                _approve(token, spender, amount);
            }
        }

        emit Routed(address(this), msg.sender, target, msg.value);

        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) revert InnerCallFailed();
        return ret;
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20Min.approve.selector, spender, amount));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "APPROVE_FAILED");
    }
}
