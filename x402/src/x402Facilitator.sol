// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title x402Facilitator
/// @notice On-chain settlement check for an x402-style 402 flow.
///
/// The x402 flow: a server returns `402 Payment Required` naming `{rail, to, token, amount, memo}`.
/// The client pays through the rail (`IPaymentRail.pay`), which settles on-chain and yields a
/// `paymentId`. The client retries with that id; the server calls THIS contract's `verify()` — a
/// pure VIEW — and only serves the resource if it returns true.
///
/// Design notes (per wave brief, LANE 9):
///  - `verify()` is a view and emits nothing: the reference server is the only actor. There is no
///    "consume", so one settled payment can unlock a resource more than once (the server, or an
///    optional per-request nonce in the memo, decides replay policy). Kept deliberately tiny.
///  - The facilitator is the on-chain source of truth for *what settled*. A gated WRITER (the rail
///    itself, or a relayer that watches `IPaymentRail.Paid`) records each settlement with `markPaid`.
///    This mirrors lane 10's `SettlementRegistry` shape; `ISettlementRegistry` below is the frozen
///    adapter so a deployment can point at lane 10 instead.
///  - Non-custodial, non-upgradeable, no `selfdestruct`. No value path (all state writes are plain
///    storage, all reads are views) so no `nonReentrant` is required — noted, not forgotten.
///  - Owner is an address (2-of-3-agnostic): the caller (Safe/timelock) is out of scope here.
contract x402Facilitator {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Settlement {
        address to;      // recipient the rail settled to
        address token;   // ERC-20 the rail settled (address(0) == native)
        uint256 amount;  // gross amount settled, in token units
        uint64 at;       // block time of the mark
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public owner;

    /// @notice Accounts allowed to record settlements (the rail / a relayer). Owner-managed.
    mapping(address => bool) public isWriter;

    /// @dev paymentId => settlement record. Presence flag is a separate map so a zero-value record
    ///      is still distinguishable from "unknown id" without a sentinel.
    mapping(bytes32 => Settlement) private _settled;
    mapping(bytes32 => bool) public hasSettled;

    // ---------------------------------------------------------------------
    // Events (verify() itself is a view and emits nothing)
    // ---------------------------------------------------------------------

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);
    event WriterSet(address indexed writer, bool allowed);
    event Marked(bytes32 indexed paymentId, address indexed to, address indexed token, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotWriter();
    error ZeroAddress();
    error ZeroPaymentId();
    error ConflictingMark();

    // ---------------------------------------------------------------------
    // Construction / admin
    // ---------------------------------------------------------------------

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerChanged(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyWriter() {
        if (!isWriter[msg.sender]) revert NotWriter();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        // WriterSet IS emitted just below; the linter doesn't follow the assignment→event pairing.
        // forge-lint: disable-next-line(missing-events-access-control)
        isWriter[writer] = allowed;
        emit WriterSet(writer, allowed);
    }

    // ---------------------------------------------------------------------
    // Write side — the rail / relayer records what its `Paid` event announced
    // ---------------------------------------------------------------------

    /// @notice Record that `paymentId` settled `amount` of `token` to `to`.
    /// @dev Idempotent: re-marking with IDENTICAL fields is a no-op; a conflicting re-mark reverts,
    ///      so a paymentId can never silently change meaning.
    function markPaid(bytes32 paymentId, address to, address token, uint256 amount) external onlyWriter {
        if (paymentId == bytes32(0)) revert ZeroPaymentId();
        if (to == address(0)) revert ZeroAddress();

        if (hasSettled[paymentId]) {
            Settlement storage s = _settled[paymentId];
            if (s.to != to || s.token != token || s.amount != amount) revert ConflictingMark();
            return; // identical re-mark: no-op
        }

        // uint64(block.timestamp): safe until year ~584 billion; explicit and cheaper than u256.
        // forge-lint: disable-next-line(unsafe-typecast)
        _settled[paymentId] = Settlement({to: to, token: token, amount: amount, at: uint64(block.timestamp)});
        hasSettled[paymentId] = true;
        emit Marked(paymentId, to, token, amount);
    }

    // ---------------------------------------------------------------------
    // Read side — what the reference server calls
    // ---------------------------------------------------------------------

    /// @notice True iff `paymentId` settled at least `minAmount` of `token` to exactly `to`.
    /// @dev The server passes the SAME `{to, token, amount}` it advertised in the 402, with
    ///      `minAmount == amount`. Any mismatch (wrong id / recipient / token / under-amount) -> false.
    function verify(bytes32 paymentId, address to, address token, uint256 minAmount)
        external
        view
        returns (bool)
    {
        if (!hasSettled[paymentId]) return false;
        Settlement storage s = _settled[paymentId];
        return s.to == to && s.token == token && s.amount >= minAmount;
    }

    /// @notice Raw record read (zeroed if unknown).
    function settlement(bytes32 paymentId)
        external
        view
        returns (address to, address token, uint256 amount, uint64 at)
    {
        Settlement storage s = _settled[paymentId];
        return (s.to, s.token, s.amount, s.at);
    }

    /// @notice Adapter matching lane 10's `SettlementRegistry.paid` read shape, so a deployment may
    ///         use that contract instead. `amount` is the settled amount; `at` the mark time.
    function paid(bytes32 paymentId) external view returns (uint256 amount, uint64 at) {
        Settlement storage s = _settled[paymentId];
        if (!hasSettled[paymentId]) return (0, 0);
        return (s.amount, s.at);
    }
}
