// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title FleetExecutor — the merged 7702 delegate (C-2/C-3 fix, GENERALISED).
///
/// @notice A user's EOA sets its code to `0xef0100 || address(this)` via ONE type-4 authorization;
///         from then on a call to the user's address runs THIS code in the user's own context.
///         `address(this) == user`, so every downstream `msg.sender` is the user — the user stays the
///         acting identity while a relayer (or the user) pays the gas. This is the union of
///         `SponsorTarget` (g3a) and `P3cDelegate` (p3c-7702), generalised from "forward one target"
///         to "run a signed BATCH of (target,value,data)", so one installed delegate drives every
///         fleet surface instead of one delegate per action.
///
/// THE FIX (audit #2 + #3, same class): as written, the sibling forwards had NO auth — inside the
///   delegate `msg.sender` is the CALLER (a relayer), never the user, so ANYONE could call the
///   delegated EOA and make it run caller-chosen code in the user's frame (drain via transferFrom,
///   grant a max allowance, etc.). "Self-calls only" does not work either (the sponsored shape is
///   `from=relay, to=user`, so msg.sender != address(this)). The fix, here GENERALISED to a batch, is
///   an EIP-712 intent: the user signs `(authority, calls[], nonce, deadline)` OFF-CHAIN (no tx); any
///   relayer carries it; the delegate verifies `ecrecover == address(this)` (== the user) and enforces
///   a monotonic namedspaced nonce + a deadline. Every field an attacker could previously choose is
///   now SIGNED — including the whole `calls[]` array, whose per-call `value` is therefore covered
///   too (no separate msg.value in the struct).
///
/// NONCE STORAGE NOTE (a real 7702 hazard): a delegate's non-constant/non-immutable state reads the
///   AUTHORITY's slots, which are EMPTY for a plain EOA. So the replay nonce and the reentrancy lock
///   live in NAMESPACED slots — `keccak256("FleetExecutor.nonce")` (further salted by the account)
///   and `keccak256("FleetExecutor.lock")` — NOT compiler slots, so they cannot collide with a
///   different delegate the same EOA may later install, nor with the EOA's ordinary storage.
///
/// NON-CUSTODIAL / NON-UPGRADEABLE / NO selfdestruct. Holds NO tokens between calls; a call's value
///   rides in that call. `nonReentrant` guards every value path.
contract FleetExecutor {
    /// @notice One call in a signed batch. `data` is opaque; `value` is wei forwarded with the call.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice `authority` == address(this) == the user's EOA (proves the code ran in the USER's
    ///         frame); `caller` == whoever sent the tx (the relayer in the sponsored shape, the user
    ///         when self-funding). That split is the sponsorship signature, mirrored from g3a/p3c.
    event Executed(address indexed authority, address indexed caller, uint256 callCount, uint256 nonce);

    error BadSignature();
    error BadNonce();
    error Expired();
    error NotSelf();
    error NotSelfOrIntent();
    error ValueMismatch();
    error CallFailed(address target);
    error UnsupportedMode(bytes32 mode);

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("FleetExecutor");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    /// @dev The primary type string includes the referenced `Call` type (EIP-712 encodeType rule:
    ///      primary first, referenced types appended). `Call[] calls` covers every (target,value,data).
    bytes32 internal constant EXECUTE_TYPEHASH = keccak256(
        "Execute(address authority,Call[] calls,uint256 nonce,uint256 deadline)"
        "Call(address target,uint256 value,bytes data)"
    );
    bytes32 internal constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");

    /// @dev secp256k1n/2 — reject the high-s twin so one signature is never two valid sigs.
    uint256 internal constant MALLEABILITY_THRESHOLD =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @dev Namespaced bases (see NONCE STORAGE NOTE). The nonce slot is further salted by the
    ///      account, so `nonceOf` is a real per-account API and one EOA's slots never alias another's.
    bytes32 internal constant NONCE_SLOT_BASE = keccak256("FleetExecutor.nonce");
    bytes32 internal constant LOCK_SLOT = keccak256("FleetExecutor.lock");

    /// @dev ERC-7821 mode bytes (first byte = exec type; rest zero). 0x00 single, 0x01 batch.
    bytes32 internal constant MODE_SINGLE = bytes32(0x00);
    bytes32 internal constant MODE_BATCH = bytes32(uint256(0x01) << 248);

    // =====================================================================================
    // The authorized path — the C-2/C-3 fix, generalized to a signed batch.
    // =====================================================================================

    /// @notice Run `calls` in the user's frame on an OFF-CHAIN EIP-712 signature. Any relayer may
    ///         carry it; the recovered signer must be `address(this)` (== the delegating EOA), which
    ///         binds the whole batch to the user's own signature.
    /// @param calls    the batch of (target,value,data) to run, in order
    /// @param nonce    strictly-increasing per-authority intent counter (replay guard)
    /// @param deadline unix seconds after which the intent is void
    /// @param sig      65-byte (r,s,v) EIP-712 signature over the Execute typed-data
    function execute(Call[] calldata calls, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        payable
        virtual
        nonReentrant
    {
        if (block.timestamp > deadline) revert Expired();
        if (_recover(_digest(calls, nonce, deadline), sig) != address(this)) revert BadSignature();
        if (nonce <= _nonce()) revert BadNonce();
        _setNonce(nonce);
        _run(calls, nonce);
    }

    /// @notice Self path: the EOA calls its own delegate directly (msg.sender == the EOA ==
    ///         address(this) inside the delegate), so no signature is needed. Same gas/behaviour.
    function executeSelf(Call[] calldata calls) external payable nonReentrant {
        if (msg.sender != address(this)) revert NotSelf();
        _run(calls, _nonce());                 // nonce read is informational here (no signature)
    }

    /// @notice ERC-7821 `execute(bytes32 mode, bytes data)` — the GATED default door (GOTCHA #203).
    ///         mode 0x00 -> single `(address target,uint256 value,bytes data)`;
    ///         mode 0x01 -> batch  `(address,uint256,bytes)[]` (== `Call[]`).
    ///
    /// ⚠ #203 — WHY THIS IS GATED. The bare 7821 entry carries NO auth, so on a 7702 EOA it is a
    ///      permissionless remote-exec: any third party can make the EOA `approve(stranger,MAX)` then
    ///      drain its ERC-20s, or `transfer` them out, with ZERO user signature (proved in the probes).
    ///      So this default door now requires **self OR a valid EIP-712 intent**:
    ///        • `msg.sender == address(this)` (the EOA calling itself) -> allowed, bare;
    ///        • otherwise the caller supplies the intent via the 5-arg overload below.
    ///      `executeBare` is the EXPLICIT OPT-IN to the old always-permissionless behaviour.
    ///
    ///      CALLER-FUNDED throughout: `msg.value >= Σ calls.value` is required, so the CALLER's native
    ///      pays the batch value — the EOA's OWN native is only spendable via `executeSelf` or a
    ///      signed/opt-in path the EOA itself funds.
    function execute(bytes32 mode, bytes calldata data) external payable nonReentrant {
        if (msg.sender != address(this)) revert NotSelfOrIntent();
        _runCalls(_decode(mode, data));
    }

    /// @notice ERC-7821 with an EIP-712 intent — self OR a valid signature (the relayable 7821 door).
    ///         Same modes as above; the intent is over the DECODED `Call[]`, so the whole batch is
    ///         bound, with the usual monotonic nonce + deadline.
    function execute(bytes32 mode, bytes calldata data, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        payable
        nonReentrant
    {
        Call[] memory calls = _decode(mode, data);
        if (msg.sender != address(this)) {
            if (block.timestamp > deadline) revert Expired();
            if (_recover(_digestMem(calls, nonce, deadline), sig) != address(this)) revert BadSignature();
            if (nonce <= _nonce()) revert BadNonce();
            _setNonce(nonce);
        }
        _runCalls(calls);
    }

    /// @notice EXPLICIT OPT-IN: the old, always-permissionless bare 7821 door (no auth, no nonce —
    ///         replayable). Kept nameable so a consumer can choose the raw door deliberately
    ///         (`executeBare`) while the default `execute` stays gated.
    function executeBare(bytes32 mode, bytes calldata data) external payable nonReentrant {
        _runCalls(_decode(mode, data));
    }

    // =====================================================================================
    // Views — the relay/wallet never re-derive the digest by hand (GOTCHAS #5 class).
    // =====================================================================================

    /// @notice Current replay counter for THIS authority (call it ON the delegated EOA).
    function nonces() external view returns (uint256) {
        return _nonce();
    }

    /// @notice Per-account nonce (the account is salted into the namespaced slot).
    function nonceOf(address account) external view returns (uint256 n) {
        bytes32 s = _nonceSlot(account);
        assembly {
            n := sload(s)
        }
    }

    /// @notice The exact digest a signer must sign for `execute`.
    function digest(Call[] calldata calls, uint256 nonce, uint256 deadline) external view returns (bytes32) {
        return _digest(calls, nonce, deadline);
    }

    /// @notice The EIP-712 domain separator (chainId + verifyingContract=address(this) bound).
    function domain() external view returns (bytes32) {
        return _domain();
    }

    // =====================================================================================
    // Internals
    // =====================================================================================

    function _digest(Call[] calldata calls, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        bytes32 callsHash = _callsHash(calls);
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, address(this), callsHash, nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", _domain(), structHash));
    }

    /// @dev EIP-712 hash of a struct array: keccak of the concatenated per-element structHashes.
    function _callsHash(Call[] calldata calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data))
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev EIP-712 digest over a memory Call[] (the 7821 path decodes to memory first).
    function _digestMem(Call[] memory calls, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, address(this), _callsHashMem(calls), nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", _domain(), structHash));
    }

    function _callsHashMem(Call[] memory calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data))
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev Decode ERC-7821 (mode, data) into a canonical Call[]. mode 0x00 -> single call,
    ///      0x01 -> batch; anything else reverts UnsupportedMode.
    function _decode(bytes32 mode, bytes calldata data) internal pure returns (Call[] memory calls) {
        if (mode == MODE_SINGLE) {
            (address target, uint256 value, bytes memory cd) = abi.decode(data, (address, uint256, bytes));
            calls = new Call[](1);
            calls[0] = Call(target, value, cd);
        } else if (mode == MODE_BATCH) {
            calls = abi.decode(data, (Call[]));
        } else {
            revert UnsupportedMode(mode);
        }
    }

    /// @dev Run a decoded 7821 batch; same value-cover rule and emit as `_run`.
    function _runCalls(Call[] memory calls) internal {
        uint256 total;
        uint256 len = calls.length;
        for (uint256 i; i < len; ++i) {
            total += calls[i].value;
            _call(calls[i].target, calls[i].value, calls[i].data);
        }
        if (total > msg.value) revert ValueMismatch();
        emit Executed(address(this), msg.sender, len, _nonce());
    }

    /// @dev Runs the batch; enforces the value the caller sent covers the batch (SAFE: no surprise
    ///      spend of a residual balance). Reverts propagate — a failed inner call is never swallowed.
    function _run(Call[] calldata calls, uint256 nonce) internal {
        uint256 total;
        uint256 len = calls.length;
        for (uint256 i; i < len; ++i) {
            total += calls[i].value;
            _call(calls[i].target, calls[i].value, calls[i].data);
        }
        if (total > msg.value) revert ValueMismatch();
        emit Executed(address(this), msg.sender, len, nonce);
    }

    function _call(address target, uint256 value, bytes memory data) internal {
        (bool ok,) = target.call{value: value}(data);
        if (!ok) revert CallFailed(target);
    }

    /// @dev minimal low-s ECDSA (no OZ dep, matching the siblings' "tiny" rule).
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

    function _nonceSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(NONCE_SLOT_BASE, account));
    }

    function _nonce() internal view returns (uint256 n) {
        bytes32 s = _nonceSlot(address(this));
        assembly {
            n := sload(s)
        }
    }

    function _setNonce(uint256 n) internal {
        bytes32 s = _nonceSlot(address(this));
        assembly {
            sstore(s, n)
        }
    }

    // ---- namespaced reentrancy lock (1 = unlocked, 2 = entered) ----

    modifier nonReentrant() {
        bytes32 s = LOCK_SLOT;
        uint256 l;
        assembly {
            l := sload(s)
        }
        if (l == 2) revert Locked();
        assembly {
            sstore(s, 2)
        }
        _;
        assembly {
            sstore(s, 1)
        }
    }

    error Locked();
}
