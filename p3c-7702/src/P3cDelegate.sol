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
///
/// VULN (audit #3) + FIX
///   `batch` had NO auth: inside the delegate `msg.sender` is the CALLER (the relay), never the
///   user, so ANYONE could call the delegated EOA with a caller-chosen `spender` and `amount` and
///   have the user's frame grant THEMSELVES a max allowance (then `transferFrom` the user dry).
///   Reviewer's suggested fix: "EIP-712 from the delegating account, with a nonce. Alternatively,
///   self-calls only." — self-calls only BREAKS the relay (the sponsored shape is `from=relay,
///   to=user`, so msg.sender != address(this)). So the FIX is an EIP-712 signed intent binding
///   (token, spender, amount, target, dataHash, value, nonce, deadline) to `address(this)` (== user).
///   ANY caller may carry it; the fields the attacker could previously choose freely are now SIGNED.
///   Legacy `batch` is kept for back-compat and stays drainable until callers migrate.
///
/// NONCE STORAGE NOTE (a real 7702 hazard): non-constant/non-immutable state reads the AUTHORITY's
///   slots, EMPTY for a plain EOA — so the replay nonce lives in a NAMESPACED slot
///   (`keccak256("P3cDelegate.intent.nonce")`), not a compiler slot, so it cannot collide with a
///   different delegate the same EOA may later install.
contract P3cDelegate {
    /// @dev `authority` == address(this) == the user's EOA (proves the code ran in the USER's frame);
    ///      `caller` == whoever sent the tx (the relay in the sponsored shape, the user when
    ///      self-funding). That split is the sponsorship signature, mirrored from g3a's SponsorTarget.
    event Routed(address indexed authority, address indexed caller, address target, uint256 value);

    error InnerCallFailed();
    error BadSignature();
    error BadNonce();
    error Expired();

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("P3cDelegate");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent(address authority,address token,address spender,uint256 amount,address target,bytes32 dataHash,uint256 value,uint256 nonce,uint256 deadline)"
    );
    uint256 internal constant MALLEABILITY_THRESHOLD =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 internal constant NONCE_SLOT = keccak256("P3cDelegate.intent.nonce");

    /// @notice LEGACY (unauthenticated) — approve-if-short then forward. Kept for back-compat;
    ///         migrate to `batchSigned`, because while this path is used the audit-#3 drain is open.
    function batch(
        address token,
        address spender,
        uint256 amount,
        address target,
        bytes calldata data
    ) external payable returns (bytes memory) {
        return _run(token, spender, amount, target, data);
    }

    /// @notice AUTHORIZED path. The user signs an EIP-712 Intent OFF-CHAIN; any relayer carries it.
    ///         Runs in the user's frame, so recovery must equal `address(this)` (== the user), which
    ///         binds the previously-attacker-chosen `spender`/`amount` to the user's own signature.
    /// @param nonce    strictly-increasing per-authority intent counter (replay guard)
    /// @param deadline unix seconds after which the intent is void
    /// @param sig      65-byte (r,s,v) EIP-712 signature over the Intent typed-data
    function batchSigned(
        address token,
        address spender,
        uint256 amount,
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external payable returns (bytes memory) {
        if (block.timestamp > deadline) revert Expired();
        bytes32 d = _digest(token, spender, amount, target, data, nonce, deadline);
        if (_recover(d, sig) != address(this)) revert BadSignature();
        if (nonce <= nonces()) revert BadNonce();
        _setNonce(nonce);
        return _run(token, spender, amount, target, data);
    }

    function nonces() public view returns (uint256 n) {
        bytes32 s = NONCE_SLOT;
        assembly {
            n := sload(s)
        }
    }

    /// @notice The exact digest a signer must sign for `batchSigned` (so no hand re-derivation drifts).
    function digest(
        address token,
        address spender,
        uint256 amount,
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _digest(token, spender, amount, target, data, nonce, deadline);
    }

    function _digest(
        address token,
        address spender,
        uint256 amount,
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                address(this),
                token,
                spender,
                amount,
                target,
                keccak256(data),
                msg.value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", _domain(), structHash));
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev approve-if-short then forward. Unchanged behaviour from v1; the auth layer wraps it.
    function _run(address token, address spender, uint256 amount, address target, bytes calldata data)
        internal
        returns (bytes memory)
    {
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

    function _recover(bytes32 digest_, bytes calldata sig) internal pure returns (address) {
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
        address signer = ecrecover(digest_, v, r, s);
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
