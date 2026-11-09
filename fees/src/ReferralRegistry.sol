// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title ReferralRegistry
/// @notice First-come binding of a 32-byte referral code to an address. A code is free until the
/// first `register`; after that it belongs to the first registrant and can only be moved by that
/// owner via `transferCode` (or released with `burn`, which frees it for the next taker).
/// Non-custodial: the registry never holds value; it is pure mapping.
///
/// Codes are `bytes32` on purpose: the rail passes a bytes32 referral code and the registry
/// resolves it to a payout address. A code can be a hashed handle, a short string, or an ENS-ish
/// tag — the registry does not interpret it.
contract ReferralRegistry {
    /// @notice code -> owner address. address(0) means the code is free.
    mapping(bytes32 => address) public ownerOf;

    /// @notice address -> the code it currently owns (one code per address; register again = rebind).
    mapping(address => bytes32) public codeOf;

    event Registered(bytes32 indexed code, address indexed owner);
    event Transferred(bytes32 indexed code, address indexed from, address indexed to);
    event Burned(bytes32 indexed code, address indexed owner);

    error CodeTaken(bytes32 code);
    error NotCodeOwner(bytes32 code);
    error ZeroAddress();
    error EmptyCode();

    /// @notice Bind `code` to msg.sender if it is free. If msg.sender already owns a code, that
    /// code is released first (so an address holds at most one code at a time).
    function register(bytes32 code) external {
        if (code == bytes32(0)) revert EmptyCode();
        address existing = ownerOf[code];
        if (existing != address(0) && existing != msg.sender) revert CodeTaken(code);

        bytes32 prior = codeOf[msg.sender];
        if (prior != bytes32(0) && prior != code) {
            // release the prior code so it becomes free again
            delete ownerOf[prior];
            emit Burned(prior, msg.sender);
        }

        ownerOf[code] = msg.sender;
        codeOf[msg.sender] = code;
        emit Registered(code, msg.sender);
    }

    /// @notice Move the caller's own code to `to`. Non-transferable except by the owner-of-code.
    function transferCode(address to) external {
        if (to == address(0)) revert ZeroAddress();
        bytes32 code = codeOf[msg.sender];
        if (code == bytes32(0)) revert NotCodeOwner(code);

        if (codeOf[to] != bytes32(0)) {
            // the receiver already holds a code -> release theirs first
            delete ownerOf[codeOf[to]];
            emit Burned(codeOf[to], to);
        }

        ownerOf[code] = to;
        delete codeOf[msg.sender];
        codeOf[to] = code;
        emit Transferred(code, msg.sender, to);
    }

    /// @notice Release the caller's own code (frees it for anyone to claim).
    function burn() external {
        bytes32 code = codeOf[msg.sender];
        if (code == bytes32(0)) revert NotCodeOwner(code);
        delete ownerOf[code];
        delete codeOf[msg.sender];
        emit Burned(code, msg.sender);
    }

    /// @notice Resolve a code to its owner (address(0) if free).
    function resolve(bytes32 code) external view returns (address) {
        return ownerOf[code];
    }
}
