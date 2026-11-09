// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IP2Registry} from "./interfaces/IP2Registry.sol";

/// @title RequestRegistry — F1-a payment links. A thin layer ON TOP OF the untouched P2 Registry.
/// @notice A merchant calls `request(...)` ONCE and gets back an id + a deposit address. The id
///         fully describes the ask (destination, token, amount, memo) and is the whole URL payload:
///         a payer's frontend renders "pay 10 USDC, order #123" from the id alone, with no server.
///         Anything sent to the deposit address auto-forwards via P2 exactly as before.
///
/// SHAPE B — LINK, DO NOT INHERIT (dex-critic ruling 2026-11-05).
///   Registry.sol and Forwarder.sol are BYTE-FOR-BYTE UNCHANGED, so P2's 25 tests stay valid and the
///   forwarder/keeper path is untouched. Deposit addresses minted here are STOCK P2 Forwarders, so
///   the keeper's `Registered` cache picks them up with ZERO daemon change — that is the point.
///
/// SETTLEMENT IS A STATUS BIT, NOT AN AMOUNT (v1, ruled).
///   The Forwarder forwards whatever arrives; we do NOT enforce "exactly `amount`" on-chain (that
///   would mean touching Forwarder — the EIP-1167 lesson). `amount` is the ASK, soft. Overpayment is
///   the merchant's gain; underpayment is theirs to reconcile — both acceptable at the P2 rate
///   (comments elsewhere say 25 bps; the LIVE Base feeBps is 500 — read it live, never assume 25).
///   `settle()` is PERMISSIONLESS (matches P2's trustless forward): anyone may flip it once goods/
///   funds have moved. Low-stakes bit; a keeper, the payer, or the merchant can all set it.
///
/// PAYER SEAM (executor4 streams ask, relayed by dex-critic 2026-11-05).
///   `payer` is an EXPLICIT argument from day one, even though v1 always passes msg.sender. It is free
///   now and a breaking change later: a future StreamFactory can mint a request/stream on behalf of a
///   payer through this entry point without a signature change. Stored + emitted so a chain-only
///   reader sees who is meant to pay. No other coupling; the stream<->request link stays a bytes32 ref.
///
/// SCOPE (v1): no expiry, no refund, reusable deposit address (consistent with P2). memo is bytes32 so
///   it stays short/opaque (an order ref) and encodes URL-safely as hex.
contract RequestRegistry {
    /// @notice The P2 Registry this layer mints deposit addresses from. Immutable, set once.
    IP2Registry public immutable p2Registry;
    address public owner;

    /// @dev v2 TODO (deferred, ruled): accumulate `amountReceived` per request from the Forwarder's
    ///      `Forwarded` log so a chain-only reader sees HOW MUCH settled, not just THAT it did.
    ///      v1 keeps a boolean + settledAt block; enough to distinguish settled from unsettled.
    struct Request {
        address merchant;      // who asked
        address payer;         // WHO PAYS — explicit seam (see header); v1 default = msg.sender
        address destination;   // where funds land (the merchant's receive address)
        address token;         // address(0) == native
        uint256 amount;        // the ASK (soft, not enforced — see header)
        bytes32 memo;          // short opaque order ref (URL-safe as hex)
        address depositAddr;   // stock P2 Forwarder minted for this request
        uint64 createdAt;
        bool settled;          // THE status bit — the product difference vs "a bare deposit address"
        uint64 settledAt;      // block the status flipped; 0 while unsettled
    }

    uint256 public nextId;                       // global monotonic id (same shape as Registry's nonce)
    mapping(uint256 => Request) internal _requests;

    /// @dev Carries the full ask + the deposit address, so a chain-only reader reconstructs a request
    ///      from its own log with no server. Indexed merchant/payer/id for filtering.
    event RequestCreated(
        uint256 indexed id,
        address indexed merchant,
        address indexed payer,
        address depositAddr,
        address destination,
        address token,
        uint256 amount,
        bytes32 memo,
        uint64 createdAt
    );
    /// @dev THE settled record. A reader that has this log for an id KNOWS it settled — distinct
    ///      from an id that only has RequestCreated. `settler` is informational (permissionless).
    event Settled(uint256 indexed id, address indexed depositAddr, address indexed settler, uint64 settledAt);

    event OwnerSet(address owner);

    error ZeroDest();
    error NoSuchRequest();
    error AlreadySettled();
    error NotSettler();
    error NotPayer();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address p2Registry_, address owner_) {
        require(p2Registry_ != address(0) && owner_ != address(0), "zero");
        p2Registry = IP2Registry(p2Registry_);
        owner = owner_;
    }

    // ---- the product ----

    /// @notice Create a payment request where the CALLER is the payer (the common case). Thin wrapper
    ///         over the explicit-payer form below.
    function request(address destination, address token, uint256 amount, bytes32 memo)
        external
        returns (uint256 id, address depositAddr)
    {
        return request(destination, token, amount, memo, msg.sender);
    }

    /// @notice Create a payment request with an EXPLICIT payer. Mints a fresh deposit address via the
    ///         P2 Registry and stores the ask against a new id. Returns everything a frontend needs to
    ///         build the URL. `payer` is the seam (see header): v1 callers pass msg.sender, a future
    ///         StreamFactory can pass someone else.
    /// @param destination merchant receive address (funds forward here)
    /// @param token address(0) for native, else ERC20
    /// @param amount the soft ask, in the token's smallest unit (not enforced on-chain)
    /// @param memo short opaque order ref; bytes32, URL-safe as hex
    /// @param payer who is meant to pay; recorded + indexed for a chain-only reader. v1 REQUIRES
    ///        `payer == msg.sender` (L-9): with no signature mechanism, letting a third party name an
    ///        arbitrary payer let anyone pollute a payer's indexed queries. A future v2 that mints on
    ///        a payer's behalf (StreamFactory) relaxes this with a signed intent, not by opening it.
    function request(address destination, address token, uint256 amount, bytes32 memo, address payer)
        public
        returns (uint256 id, address depositAddr)
    {
        if (destination == address(0)) revert ZeroDest();
        if (payer != msg.sender) revert NotPayer();

        // Mints a stock P2 Forwarder owned by THIS contract; it emits Registry's `Registered`, so the
        // keeper learns depositAddr->destination with no change.
        depositAddr = p2Registry.register(destination);

        id = nextId++;
        uint64 nowTs = uint64(block.timestamp);
        _requests[id] = Request({
            merchant: msg.sender,
            payer: payer,
            destination: destination,
            token: token,
            amount: amount,
            memo: memo,
            depositAddr: depositAddr,
            createdAt: nowTs,
            settled: false,
            settledAt: 0
        });

        emit RequestCreated(id, msg.sender, payer, depositAddr, destination, token, amount, memo, nowTs);
    }

    /// @notice Flip a request to settled. GATED (M-2): only the merchant, the named payer, or the
    ///         owner may call — so an arbitrary third party can no longer mark an unpaid request paid
    ///         while the UI renders `settled` as PAID. (v1 keeps a status bit; a fully trustless
    ///         "the forwarder really moved funds" check needs an amount counter, deferred to v2.)
    function settle(uint256 id) external {
        Request storage r = _requests[id];
        if (r.depositAddr == address(0)) revert NoSuchRequest();
        if (r.settled) revert AlreadySettled();
        if (msg.sender != r.merchant && msg.sender != r.payer && msg.sender != owner) revert NotSettler();        r.settled = true;
        r.settledAt = uint64(block.timestamp);
        emit Settled(id, r.depositAddr, msg.sender, r.settledAt);
    }

    /// @notice Full request, so a chain-only reader (and the frontend) needs no server.
    function request_(uint256 id) external view returns (Request memory) {
        Request memory r = _requests[id];
        if (r.depositAddr == address(0)) revert NoSuchRequest();
        return r;
    }

    /// @notice Client-side parity: the deposit address `request(destination, ...)` WOULD mint on the
    ///         NEXT call. Lets a frontend show the address before the tx (mirrors Registry.predict).
    ///         The id is NOT part of the salt — only (RequestRegistry, its nonce, destination) is —
    ///         so this needs the destination and nothing else.
    function predictDepositFor(address destination) external view returns (address) {
        return p2Registry.predict(address(this), destination);
    }

    // ---- admin ----

    function transferOwnership(address o) external onlyOwner {
        require(o != address(0), "zero");
        owner = o;
        emit OwnerSet(o);
    }
}
