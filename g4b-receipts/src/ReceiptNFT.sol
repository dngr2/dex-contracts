// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEscrow} from "./interfaces/IEscrow.sol";
import {IEscrowFactory} from "./interfaces/IEscrowFactory.sol";

/// @title ReceiptNFT — a proof-of-payment receipt minted on a COMPLETED g2b escrow.
/// @notice ONE ERC-721 per RELEASED escrow, minted to the PAYER. The receipt carries the escrow's
///         on-chain facts (counterparty, token, amount, releasedAt) and a fully on-chain tokenURI.
///
/// WHY STANDALONE-VERIFY, NOT A HOOK IN g2b
///   g2b's Escrow is already deployed and IMMUTABLE, so it cannot call out to a receipt. Instead the
///   receipt READS the escrow and verifies completion itself. That is also more trustless: the mint
///   is PERMISSIONLESS (payer, counterparty, or any keeper can trigger it) and correctness is checked
///   against chain state, never against a caller's word.
///
/// HONEST SCOPE (read before claiming what a receipt proves)
///   * `escrow.settled()` is ONE bool: it is true after EITHER a release OR a refund, and both drain
///     the escrow to zero. v1 minted on `settled`, so a receipt could stand for a deal the payer got
///     REFUNDED — not a completed payment. v2 (M-3) gates on `escrow.released()` (true ONLY on a
///     release), so a receipt now means "the counterparty was PAID". `releasedAt` records the block
///     time we observed it.
///   * A `mintFeeWei` (default 0; LIVE deployed value 5e13 wei as of 2026-11-07) is charged per MINT —
///     but a receipt only EXISTS per completed payment, so this is "one fee per completed flow", not
///     per arbitrary mint. A 0-value escrow still mints but the fee only earns where a real payment
///     completed. Read `mintFeeWei()` live — it is owner-settable STATE, never a constant.
///
/// TRUST SHAPE — WHY AN ALLOWLIST ALONE IS NOT ENOUGH (and why a blob scan is not either)
///   An escrow is a CREATE2 child of the factory, so its ADDRESS is unforgeable. But every escrow
///   getter (`factory()`, `settled()`, `payer()`, …) is just a value a contract can answer with — so
///   an attacker can deploy their OWN contract (no deposit, no CREATE2) whose runtime immutables make
///   `factory()==realFactory`, `settled()==true`, and payer/token/amount copies. That impostor sails
///   straight through an `escrow.factory() ∈ allowlist` gate.
///   The robust gate is MEMBERSHIP: an escrow is REAL iff it appears in the real factory's own
///   `escrowsOf(payer)` — a list only the factory can append to (it pushes the CREATE2 result). We
///   therefore (a) allowlist the factory AND pin it by EXTCODEHASH, then (b) require the escrow to be
///   a member of `allowlistedFactory.escrowsOf(payer)`. A lookalike can mimic every getter and even
///   embed the arg blob in its own runtime; it CANNOT get itself into the factory's array.
///   Membership is O(n) in that payer's escrow count — stated honestly, and bounded by escrowCount.
///   Negcontrol: test/StubProbe.t.sol proves the lookalike passes the allowlist AND a blob scan yet
///   is REJECTED by membership.
///
/// FEE: `mintFeeWei` (owner-settable) is paid in NATIVE and forwarded to `feeRecipient`. Default 0.
///      ERC-721 is hand-rolled (no OpenZeppelin) to match the lane's no-deps style.
contract ReceiptNFT {
    // ---- ERC-721 (minimal, hand-rolled) ----
    string public constant name = "g2b Receipt";
    string public constant symbol = "G2BRCPT";
    uint256 public totalMinted;

    mapping(uint256 => address) private _owner;
    mapping(address => uint256) private _balance;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ---- receipt facts ----
    struct Facts {
        address escrow;
        address payer;
        address counterparty;
        address token;        // address(0) == native
        uint256 amount;       // credited amount on the escrow (FOT-safe: what ARRIVED)
        bytes32 hash;         // the escrow's hashlock (0 if arbiter-only)
        uint64 releasedAt;    // block time this receipt first verified a RELEASE
    }
    /// @dev tokenId => facts. tokenId starts at 1 (0 is a common "unset" sentinel).
    mapping(uint256 => Facts) public facts;
    /// @dev escrow => tokenId (0 == not minted). The idempotency key.
    mapping(address => uint256) public receiptOf;

    // ---- admin / config ----
    address public owner;
    address public feeRecipient;
    uint256 public mintFeeWei;                 // native fee per mint; default 0
    mapping(address => bool) public factoryAllow;
    /// @dev factory => pinned EXTCODEHASH. 0 == allowlisted but not codehash-pinned.
    mapping(address => bytes32) public factoryCodehashOf;

    /// @dev M-5 (audit) — Ownable2Step + 48h timelock, matching g2a/g2b. `mintFeeWei` and
    ///      `feeRecipient` are the MONEY knobs: a mint reads `mintFeeWei` live, so an instant write
    ///      re-priced every in-flight mint. Both now go stage(eta = now+48h) → commit. `setFactory` /
    ///      `setFactoryCodehash` stay INSTANT: the former is an emergency de-allowlist of a bad
    ///      factory (a 48h-frozen kill-switch is not a kill-switch), the latter is a code pin, not a
    ///      price. Ownership is two-step (OZ shape): `transferOwnership` stages, `acceptOwnership`
    ///      completes. See the field notes in g2a's StreamFactory for the reasoning.
    address public pendingOwner;
    uint64 public mintFeeEta;
    uint64 public feeRecipientEta;
    uint256 public pendingMintFee;
    address public pendingFeeRecipient;
    uint64 public constant TIMELOCK = 48 hours;

    error NotOwner();
    error ZeroArg();
    error NotSettled();
    error NotReleased();
    error UnknownFactory();
    error FactoryCodehashMismatch();
    error NotAFactoryChild();
    error AlreadyMinted();
    error NotMinted();
    error Underpaid();
    error NotAuthorized();
    error BadFrom();
    error NoReceiver();
    error NotPendingOwner();
    error NotStaged();
    error TimelockNotElapsed();

    event Minted(address indexed escrow, address indexed payer, uint256 indexed tokenId, address minter);
    event FactoryAllowed(address factory, bool allowed);
    event FactoryCodehashPinned(address factory, bytes32 codehash);
    event MintFeeSet(uint256 wei_);
    event FeeRecipientSet(address recipient);
    event OwnerSet(address owner);
    event MintFeeStaged(uint256 wei_, uint64 eta);
    event FeeRecipientStaged(address recipient, uint64 eta);
    event MintFeeCanceled();
    event FeeRecipientCanceled();
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address feeRecipient_, address factory_, bytes32 factoryCodehash_) {
        if (owner_ == address(0) || feeRecipient_ == address(0) || factory_ == address(0)) revert ZeroArg();
        owner = owner_;
        feeRecipient = feeRecipient_;
        factoryAllow[factory_] = true;
        if (factoryCodehash_ != bytes32(0)) {
            if (factory_.codehash != factoryCodehash_) revert FactoryCodehashMismatch();
            factoryCodehashOf[factory_] = factoryCodehash_;
            emit FactoryCodehashPinned(factory_, factoryCodehash_);
        }
        emit FactoryAllowed(factory_, true);
    }

    // ---- the product ----

    /// @notice Mint the receipt for a SETTLED escrow. PERMISSIONLESS. Idempotent.
    /// @param escrow a RELEASED g2b escrow that is a real CREATE2 child of an allowlisted factory.
    /// @return tokenId the receipt id (minted to the escrow's payer).
    function mintForEscrow(address escrow) external payable returns (uint256 tokenId) {
        if (receiptOf[escrow] != 0) revert AlreadyMinted();
        if (msg.value < mintFeeWei) revert Underpaid();

        IEscrow e = IEscrow(escrow);
        address f = e.factory();
        if (!factoryAllow[f]) revert UnknownFactory();
        bytes32 pin = factoryCodehashOf[f];
        if (pin != bytes32(0) && f.codehash != pin) revert FactoryCodehashMismatch();

        address payer = e.payer();
        if (payer == address(0)) revert ZeroArg();

        // PROVENANCE: the escrow must be one the REAL factory itself deployed for this payer. A
        // lookalike can copy getters and embed the arg blob, but cannot join the factory's array.
        if (!_isFactoryChild(f, payer, escrow)) revert NotAFactoryChild();

        _requireReleased(e);

        tokenId = ++totalMinted;                 // 1-based
        receiptOf[escrow] = tokenId;
        facts[tokenId] = Facts({
            escrow: escrow,
            payer: payer,
            counterparty: e.counterparty(),
            token: e.token(),
            amount: e.amount(),
            hash: e.hash(),
            releasedAt: uint64(block.timestamp)
        });

        _mint(payer, tokenId);

        // L-6: only the fee is taken; any overpayment (msg.value above the fee) is returned to the
        // CALLER, not silently kept. mintFeeWei is read live at mint, so the split is exact.
        if (mintFeeWei != 0) _payNative(feeRecipient, mintFeeWei);
        uint256 excess = msg.value - mintFeeWei;
        if (excess != 0) _payNative(msg.sender, excess);
        emit Minted(escrow, payer, tokenId, msg.sender);
    }

    /// @dev True iff `escrow` appears in factory.escrowsOf(payer). The factory pushes every CREATE2
    ///      child it deploys, so membership is first-party provenance. Bounded by escrowCount.
    function _isFactoryChild(address f, address payer, address escrow) internal view returns (bool) {
        uint256 n = IEscrowFactory(f).escrowCount(payer);
        for (uint256 i = 0; i < n; i++) {
            if (IEscrowFactory(f).escrowsOf(payer, i) == escrow) return true;
        }
        return false;
    }

    /// @dev M-3 gate, and the mutant seam (virtual). v2 requires `released` (true only on a release),
    ///      so a REFUNDED escrow mints no receipt.
    ///      MIGRATION: escrows are IMMUTABLE and already deployed — every LIVE escrow is v1 and has
    ///      no `released()` getter. So we PROBE for it: if the selector answers, this is a v2 escrow
    ///      and `released` is the authority; if it is absent (v1), `settled` is all the chain offers
    ///      and we say so (a v1 refund is indistinguishable on-chain). `virtual` so a negcontrol can
    ///      re-inject the v1 "settled is enough" bug through the REAL mint path.
    function _requireReleased(IEscrow e) internal view virtual {
        (bool ok, bytes memory ret) = address(e).staticcall(abi.encodeWithSelector(IEscrow.released.selector));
        if (ok && ret.length >= 32) {
            if (!abi.decode(ret, (bool))) revert NotReleased();
        } else {
            if (!e.settled()) revert NotSettled();
        }
    }

    /// @notice The escrow's full record, joined for a reader. Convenience over `facts`.
    function receiptOf_(address escrow) external view returns (Facts memory) {
        uint256 id = receiptOf[escrow];
        if (id == 0) revert NotMinted();  // L-6: was AlreadyMinted, which reads backwards when unminted
        return facts[id];
    }

    // ---- tokenURI: fully on-chain, base64 JSON (no server) ----

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owner[tokenId] == address(0)) revert ZeroArg();
        Facts memory f = facts[tokenId];
        return string(abi.encodePacked("data:application/json;base64,", _b64(bytes(_json(tokenId, f)))));
    }

    /// @dev Split from tokenURI: the packed JSON has too many locals for one frame (stack-too-deep
    ///      without viaIR — same posture as the rest of the fleet, which does not enable viaIR).
    function _json(uint256 tokenId, Facts memory f) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                _head(tokenId, f),
                _attrs(f),
                "]}"
            )
        );
    }

    function _head(uint256 tokenId, Facts memory f) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"name":"g2b Receipt #', _u2s(tokenId),
                '","description":"Proof of a COMPLETED g2b escrow (released on-chain). Escrow ',
                _hex(f.escrow), ' released to the counterparty; payer ', _hex(f.payer),
                '. NOTE: released is true only on a release; a refunded escrow mints no receipt.",',
                '"attributes":['
            )
        );
    }

    function _attrs(Facts memory f) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type":"escrow","value":"', _hex(f.escrow), '"},',
                '{"trait_type":"payer","value":"', _hex(f.payer), '"},',
                '{"trait_type":"counterparty","value":"', _hex(f.counterparty), '"},',
                '{"trait_type":"token","value":"', _hex(f.token), '"},',
                '{"trait_type":"amount","value":"', _u2s(f.amount), '"},',
                '{"trait_type":"releasedAt","value":', _u2s(uint256(f.releasedAt)), '}'
            )
        );
    }

    // ---- ERC-721 core ----

    function balanceOf(address a) external view returns (uint256) { return _balance[a]; }
    function ownerOf(uint256 id) external view returns (address) {
        address o = _owner[id];
        if (o == address(0)) revert ZeroArg();
        return o;
    }
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7            // ERC165
            || id == 0x80ac58cd            // ERC721
            || id == 0x5b5e139f;           // ERC721Metadata (L-6: name/symbol/tokenURI all exist)
    }

    function approve(address to, uint256 id) external {
        address o = _owner[id];
        if (msg.sender != o && !isApprovedForAll[o][msg.sender]) revert NotAuthorized();
        getApproved[id] = to;
        emit Approval(o, to, id);
    }
    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
        emit ApprovalForAll(msg.sender, op, ok);
    }
    function transferFrom(address from, address to, uint256 id) public {
        address o = _owner[id];
        if (o != from) revert BadFrom();
        if (to == address(0)) revert ZeroArg();
        if (msg.sender != from && msg.sender != getApproved[id] && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();
        delete getApproved[id];
        _balance[from] -= 1;
        _balance[to] += 1;
        _owner[id] = to;
        emit Transfer(from, to, id);
    }
    function safeTransferFrom(address from, address to, uint256 id) external { safeTransferFrom(from, to, id, ""); }
    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeWithSelector(0x150b7a02, msg.sender, from, id, data)  // onERC721Received
            );
            require(ok && (ret.length == 0 || abi.decode(ret, (bytes4)) == 0x150b7a02), "bad receiver");
        }
    }

    // ---- admin ----

    function setFactory(address f, bool allowed) external onlyOwner {
        if (f == address(0)) revert ZeroArg();
        factoryAllow[f] = allowed;
        emit FactoryAllowed(f, allowed);
    }
    /// @notice Pin a factory's EXTCODEHASH. `pin == 0` clears the pin (allowlist-only for that f).
    ///         Called by the owner with the artefact's runtime keccak, so a later swap of the same
    ///         ADDRESS to different code is caught. The factory's vars are STORAGE (not immutables),
    ///         so its runtime hash is STABLE across instances — unlike an Escrow, whose immutables are
    ///         patched into runtime at deploy and therefore differ per instance.
    function setFactoryCodehash(address f, bytes32 codehash_) external onlyOwner {
        if (f == address(0)) revert ZeroArg();
        if (!factoryAllow[f]) revert UnknownFactory();
        if (codehash_ != bytes32(0) && f.codehash != codehash_) revert FactoryCodehashMismatch();
        factoryCodehashOf[f] = codehash_;
        emit FactoryCodehashPinned(f, codehash_);
    }
    function setMintFee(uint256 wei_) public virtual onlyOwner {
        pendingMintFee = wei_;
        mintFeeEta = uint64(block.timestamp) + TIMELOCK;
        emit MintFeeStaged(wei_, mintFeeEta);
    }
    function commitMintFee() public {
        if (mintFeeEta == 0) revert NotStaged();
        if (block.timestamp < mintFeeEta) revert TimelockNotElapsed();
        mintFeeWei = pendingMintFee;
        mintFeeEta = 0;
        emit MintFeeSet(mintFeeWei);
    }
    function cancelMintFee() external onlyOwner {
        if (mintFeeEta == 0) revert NotStaged();
        mintFeeEta = 0;
        emit MintFeeCanceled();
    }

    function setFeeRecipient(address r) public virtual onlyOwner {
        if (r == address(0)) revert ZeroArg();
        pendingFeeRecipient = r;
        feeRecipientEta = uint64(block.timestamp) + TIMELOCK;
        emit FeeRecipientStaged(r, feeRecipientEta);
    }
    function commitFeeRecipient() public {
        if (feeRecipientEta == 0) revert NotStaged();
        if (block.timestamp < feeRecipientEta) revert TimelockNotElapsed();
        feeRecipient = pendingFeeRecipient;
        feeRecipientEta = 0;
        emit FeeRecipientSet(feeRecipient);
    }
    function cancelFeeRecipient() external onlyOwner {
        if (feeRecipientEta == 0) revert NotStaged();
        feeRecipientEta = 0;
        emit FeeRecipientCanceled();
    }

    /// @notice Ownable2Step handoff (OZ shape): stages `o`; `o` must `acceptOwnership`.
    function setOwner(address o) public onlyOwner {
        if (o == address(0)) revert ZeroArg();
        pendingOwner = o;
        emit OwnershipTransferStarted(owner, o);
    }
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
        emit OwnerSet(owner);   // legacy event kept for pre-M-5 tooling
    }
    /// @notice Alias so an OZ-shaped integrator can use the standard name too.
    function transferOwnership(address o) external onlyOwner {
        setOwner(o);
    }

    // ---- internals ----

    function _mint(address to, uint256 id) internal {
        if (to == address(0)) revert ZeroArg();
        _balance[to] += 1;
        _owner[id] = to;
        emit Transfer(address(0), to, id);
    }

    function _payNative(address to, uint256 v) internal {
        (bool ok, ) = payable(to).call{value: v}("");
        require(ok, "native send failed");
    }

    function _u2s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n = v; uint256 len;
        while (n != 0) { n /= 10; len++; }
        bytes memory b = new bytes(len);
        while (v != 0) { b[--len] = bytes1(uint8(48 + (v % 10))); v /= 10; }
        return string(b);
    }

    function _hex(address a) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0"; out[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 byteVal = uint8(uint160(a) >> (8 * (19 - i)));
            out[2 + i * 2] = h[byteVal >> 4];
            out[3 + i * 2] = h[byteVal & 0x0f];
        }
        return string(out);
    }

    /// @dev base64 (RFC 4648, no padding stripped) over the bytes — standard alphabet, `=` pad.
    function _b64(bytes memory data) internal pure returns (string memory) {
        bytes memory T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 n = data.length;
        if (n == 0) return "";
        uint256 outLen = 4 * ((n + 2) / 3);
        bytes memory out = new bytes(outLen);
        uint256 oi;
        for (uint256 i = 0; i < n; i += 3) {
            uint256 b0 = uint8(data[i]);
            uint256 b1 = i + 1 < n ? uint8(data[i + 1]) : 0;
            uint256 b2 = i + 2 < n ? uint8(data[i + 2]) : 0;
            out[oi++] = T[b0 >> 2];
            out[oi++] = T[((b0 & 0x03) << 4) | (b1 >> 4)];
            out[oi++] = i + 1 < n ? T[((b1 & 0x0f) << 2) | (b2 >> 6)] : bytes1("=");
            out[oi++] = i + 2 < n ? T[b2 & 0x3f] : bytes1("=");
        }
        return string(out);
    }
}
