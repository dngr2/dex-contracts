// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title SponsorTarget — the 7702 delegate target (the code a delegated EOA runs).
/// @dev Kept tiny on purpose: the G3-a fork test delegates a user EOA to this, then relays a call
///      so the RELAY key pays gas while the USER's address executes this code. It emits
///      `Sponsored(authority, target, value)` so the test can prove (b) the target executed and that
///      msg.sender inside the call was the DELEGATED EOA (the user), not the relay — the whole point
///      of 7702 sponsorship: the user stays the acting identity and simply pays no gas.
contract SponsorTarget {
    event Sponsored(address indexed authority, address indexed caller, address target, uint256 value);

    /// @dev Called by the delegated EOA (as itself). Forwards a call to `target` and records the
    ///      ACTING IDENTITY: `authority` is `address(this)` — the user's EOA, proving the code ran in
    ///      the user's context — while `caller` is whoever paid gas (the relay). That split IS 7702
    ///      sponsorship: the user is the actor, the relay is the payer. Reverts propagate so a failed
    ///      inner call is not silently swallowed.
    function sponsoredCall(address target, bytes calldata data) external payable returns (bytes memory) {
        emit Sponsored(address(this), msg.sender, target, msg.value);
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        require(ok, "sponsoredCall: inner call failed");
        return ret;
    }
}
