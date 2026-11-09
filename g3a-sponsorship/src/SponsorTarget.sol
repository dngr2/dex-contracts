// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title SponsorTarget — the 7702 delegate target (the code a delegated EOA runs).
/// @dev Kept tiny on purpose: the G3-a fork test delegates a user EOA to this, then relays a call
///      so the RELAY key pays gas while the USER's address executes this code. It emits
///      `Sponsored(authority, target, value)` so the test can prove (b) the target executed and that
///      msg.sender inside the call was the DELEGATED EOA (the user), not the relay — the whole point
///      of 7702 sponsorship: the user stays the acting identity and simply pays no gas.
///
/// VULN (audit #2) + FIX
///   As written, `sponsoredCall` had NO auth: ANYONE could call the delegated EOA and make it run
///   arbitrary code in the user's frame (e.g. `transferFrom(user, attacker, all)`), because inside
///   the delegate `msg.sender` is the CALLER (the relay), never the user. The reviewer suggested
///   "verify an EIP-712 signature from the delegating account, with a nonce. Alternatively, allow
///   only self-calls." — but "self-calls only" (`require(msg.sender == address(this))`) BREAKS the
///   relay, because the sponsor's whole shape is `from=relay, to=user` (msg.sender != address(this)).
///   So the FIX is the EIP-712 intent: the user signs `(authority, target, dataHash, value, nonce,
///   deadline)` ONCE, off-chain; any relayer may carry it; the delegate verifies against
///   `address(this)` (== the user) with a monotonic nonce. `sponsoredCall` (2-arg) is kept for
///   back-compat and is the STILL-DRAINABLE legacy path; `sponsoredCallSigned` is the guarded one.
///
/// NONCE STORAGE NOTE (a real 7702 hazard): a delegate's non-constant/non-immutable state vars read
///   the AUTHORITY's slots, which are EMPTY for a plain EOA — so the replay nonce lives in a
///   NAMESPACED slot (`keccak256("SponsorTarget.intent.nonce")`), not a compiler slot, so it cannot
///   collide with a different delegate the same EOA may later install.
contract SponsorTarget {
    event Sponsored(address indexed authority, address indexed caller, address target, uint256 value);

    error BadSignature();
    error BadNonce();
    error Expired();

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("SponsorTarget");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent(address authority,address target,bytes32 dataHash,uint256 value,uint256 nonce,uint256 deadline)"
    );
    /// @dev secp256k1n/2 — reject the high-s twin so one signature is never two valid sigs.
    uint256 internal constant MALLEABILITY_THRESHOLD =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 internal constant NONCE_SLOT = keccak256("SponsorTarget.intent.nonce");

    /// @dev LEGACY (unauthenticated). Kept so existing relay callers do not break — but callers
    ///      should migrate to `sponsoredCallSigned`, because as long as the legacy path is used, the
    ///      audit-#2 drain stays open.
    function sponsoredCall(address target, bytes calldata data) external payable returns (bytes memory) {
        return _forward(target, data);
    }

    /// @notice AUTHORIZED path. The user signs an EIP-712 Intent OFF-CHAIN (no tx, no gas); any
    ///         relayer carries it. Runs in the user's frame, so `address(this) == user` and the
    ///         recovered signer must equal the user, binding the call to the delegating account.
    /// @param nonce    strictly-increasing per-authority intent counter (replay guard)
    /// @param deadline unix seconds after which the intent is void
    /// @param sig      65-byte (r,s,v) EIP-712 signature over the Intent typed-data
    function sponsoredCallSigned(
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external payable returns (bytes memory) {
        if (block.timestamp > deadline) revert Expired();
        if (_recover(_digest(target, data, nonce, deadline), sig) != address(this)) revert BadSignature();
        if (nonce <= nonces()) revert BadNonce();
        _setNonce(nonce);
        return _forward(target, data);
    }

    /// @notice Current replay counter for THIS authority (call it ON the delegated EOA).
    function nonces() public view returns (uint256 n) {
        bytes32 s = NONCE_SLOT;
        assembly {
            n := sload(s)
        }
    }

    /// @notice The exact digest a signer must sign for `sponsoredCallSigned`. Exposed so the relay
    ///         and wallet never re-derive it by hand (a silent domain/hash drift is GOTCHAS #5 class).
    function digest(address target, bytes calldata data, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _digest(target, data, nonce, deadline);
    }

    function _digest(address target, bytes calldata data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(INTENT_TYPEHASH, address(this), target, keccak256(data), msg.value, nonce, deadline)
        );
        return keccak256(abi.encodePacked(hex"1901", _domain(), structHash));
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev The forwarded call. Reverts propagate so a failed inner call is not silently swallowed.
    function _forward(address target, bytes calldata data) internal returns (bytes memory) {
        emit Sponsored(address(this), msg.sender, target, msg.value);
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        require(ok, "sponsoredCall: inner call failed");
        return ret;
    }

    /// @dev minimal low-s ECDSA (no OZ dep, matching this file's "tiny" rule).
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "BADSIGLEN");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        require(uint256(s) <= MALLEABILITY_THRESHOLD, "HIGHS");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "ECDSA_ZERO");
        return signer;
    }

    function _setNonce(uint256 n) internal {
        bytes32 s = NONCE_SLOT;
        assembly {
            sstore(s, n)
        }
    }
}
