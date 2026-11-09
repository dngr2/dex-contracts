// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {StreamVault} from "./StreamVault.sol";
import {IStreamFactory} from "./interfaces/IStreamFactory.sol";

/// @title StreamFactory — the only contract a payer calls
/// @notice `createStream(recipient, token, amount, start, end)` funds a per-stream StreamVault that
///         pays the recipient linearly and refunds the payer on cancel. Fee = bps on withdrawal.
///         This is FEE-IDEAS G2-a: P2's forwarder extended along the time axis.
///
/// SALT / CREATE2: salt binds (payer, nonce, recipient, token, start, end) so `predict()` shows the
/// vault address BEFORE the tx and it is reproducible client-side — the exact P2 Registry pattern.
/// Note the salt bakes in `start`/`end`, so a hardcoded `start=0` salt to `predict()` would be
/// WRONG; either query `nonce(payer)` and pass the real window, or use the `now`-resolved overload.
/// (This is GOTCHAS #5 class: a derivation that "looks right" but disagrees with the chain.)
///
/// WHY `payer` IS AN EXPLICIT ARG (not always msg.sender)
///   So a contract — e.g. F1-a's RequestRegistry — can mint a stream on a user's behalf later. Costs
///   nothing today, closes a seam that would otherwise need a factory redeploy.
///
/// FUNDING: `createStream` is payable (native) and pulls `amount` for ERC20 via `transferFrom`. The
/// caller must have approved this factory for ERC20. Amount is transferred INTO the vault, never held
/// by the factory — the factory is stateless apart from the nonce and its three knobs.
contract StreamFactory is IStreamFactory {
    address public owner;

    uint16 public feeBps;               // deploy default 25 (P2 parity); LIVE Base/OP = 500 (read it)
    address public feeRecipient;
    /// @dev Per-withdraw minimum toll, in TOKEN BASE UNITS (see FeeMath). 0 = legacy: plain bps fee
    ///      and a sub-floor withdrawal pays no toll. Owner-settable.
    uint256 public minFee;
    bool public paused;

    /// @dev M-5 (audit) — Ownable2Step + 48h timelock. WHY, exactly: `feeBps`/`minFee`/`feeRecipient`
    ///      are LIVE-read by every vault the instant they change, so a one-tx owner write RE-PRICED
    ///      live streams with zero warning (and, pre-M-1-snapshot, could retro-tax locked ones). Two
    ///      hazards, two guards, both here:
    ///        * CONFIRMATION — transferOwnership only STAGES; the incoming owner must `acceptOwnership`
    ///          from the new key, so a typo'd address cannot orphan the contract.
    ///        * NOTICE — the money knobs go through stage(eta = now+48h) → commit. A watcher sees the
    ///          intent 48h early. (M-1 already makes a vault's RATE binding at creation; the timelock
    ///          is the operational-warning half for the FACTORY's live readers.)
    ///      `paused` + `setKeeper` stay INSTANT — `paused` is an emergency brake and a 48h-frozen brake
    ///      is not a brake; `setKeeper` is a role grant, not a price. Only the three money knobs are
    ///      timelocked.
    address public pendingOwner;
    uint64 public feeBpsEta;            // 0 = nothing staged; else earliest commit time
    uint64 public minFeeEta;
    uint64 public feeRecipientEta;
    uint16 public pendingFeeBps;
    uint256 public pendingMinFee;
    address public pendingFeeRecipient;

    uint16 public constant MAX_FEE_BPS = 500;   // 5% ceiling
    uint256 public constant MIN_DURATION = 60;  // 1 min: below this, per-second is meaningless
    uint64 public constant TIMELOCK = 48 hours; // M-5: every fee/recipient change waits this long

    mapping(address => uint256) public nonce;
    mapping(address => address[]) public streamsOf;

    /// @dev MANDATE (the v2 drain fix). `payer` is an explicit arg, so in v1 ANY caller could mint a
    ///      stream that pulls the payer's standing allowance to a recipient of the caller's choosing,
    ///      for any amount, over any (possibly fully-past) window. v2 makes the payer PUBLISH what
    ///      that allowance is FOR: a mandate binds (recipient, token, ticket=amount/lap, period, laps).
    ///      While a mandate is active, createStreamFor may be called by ANYONE, but only within the
    ///      mandate's bounds (amount==ticket, end-start==period, laps not exhausted, monotonic laps).
    ///      So the maximum a stranger can ever extract == the payer's authorized total, to the
    ///      authorized recipient — the drain is closed even if a stranger fires every lap.
    ///      KEYED [payer][recipient][token] so one payer may run several independent reels, including
    ///      two different tokens to the SAME recipient (each with its OWN lastLapEnd cursor).
    mapping(address => mapping(address => mapping(address => Mandate))) public mandate;

    /// @dev Auth fallback when a (payer,recipient) has NO active mandate: only the payer itself or a
    ///      keeper the operator armed. Needed because the fleet's sub_daemon signs with a SEPARATE
    ///      keeper key (`0x34E911fb…`), never the payer — so a bare `msg.sender == payer` would break
    ///      the recurring reel. With a mandate armed this map is redundant (anyone may call); it
    ///      covers the un-armed hedge path.
    mapping(address => bool) public isKeeper;

    /// @dev HEDGE-PATH monotonic cursor, keyed (payer,recipient,token) like the mandate. The hedge
    ///      path is payer/keeper-gated, so a STRANGER cannot over-reach — but a KEEPER that is
    ///      off-script (retries, a restart with lost state, a double-send) could fire the SAME
    ///      (start,end) twice, minting a SECOND fully-vested vault and DOUBLE-PULLING the payer.
    ///      No mandate is armed on the live rail today, so this is the path the daemon actually runs;
    ///      the cursor makes "no re-minting a past lap" a hard reel invariant on BOTH paths.
    ///      `0` = no hedge lap fired yet. Clear it with `resetHedge` for a fresh non-contiguous reel.
    mapping(address => mapping(address => mapping(address => uint64))) public hedgeEnd;

    /// @dev A payer's published authorization for one (payer,recipient) reel. `lastEnd` is the
    ///      anti-refill cursor: each lap's start must be >= the previous lap's end, so a stranger
    ///      cannot re-mint an already-vested past window. `fired` counts laps against `laps`.
    struct Mandate {
        address token;    // the ONE token this mandate funds with
        uint256 ticket;   // amount per lap; create's `amount` must equal this
        uint64 period;    // seconds per lap; create's (end-start) must equal this
        uint64 lastEnd;   // monotonic cursor (0 = no lap fired yet)
        uint32 laps;      // total laps authorized
        uint32 fired;     // laps fired so far
        bool active;
    }

    /// @dev The full stream identity in one memory struct. Grouping into a struct is not cosmetic:
    ///      the non-IR compiler hit `Stack too deep` with 8 loose params threaded through
    ///      `_salt`/`_initCode`/`_predictAddr` at once, and `--via-ir` would fork the build settings
    ///      away from P2's. The struct keeps the non-IR pipeline (matching the rest of the fleet).
    struct Stream {
        address payer;
        address recipient;
        address token;
        uint256 amount;
        uint64 start;
        uint64 end;
        bytes32 salt;
        uint256 index;
    }

    event StreamCreated(
        address indexed payer,
        address indexed recipient,
        address indexed vault,
        address token,
        uint256 amount,
        uint64 start,
        uint64 end,
        bytes32 salt,
        uint256 index
    );
    event FeeBpsSet(uint16 bps);
    event FeeRecipientSet(address recipient);
    event MinFeeSet(uint256 minFee);
    event PausedSet(bool paused);
    event OwnerSet(address owner);
    /// @dev M-5 (audit) — the timelock's own log. A `*Staged` fires when the owner REQUESTS a change
    ///      (with its ETA); the matching `*Set` above fires 48h later when it is COMMITTED. So "Set"
    ///      still means "the value changed, now", exactly as before — the delay is visible as the gap.
    event FeeBpsStaged(uint16 bps, uint64 eta);
    event MinFeeStaged(uint256 minFee, uint64 eta);
    event FeeRecipientStaged(address recipient, uint64 eta);
    event FeeBpsCanceled();
    event MinFeeCanceled();
    event FeeRecipientCanceled();
    /// @dev M-5 — Ownable2Step. OZ's exact event names so external tooling recognizes the handoff.
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event KeeperSet(address keeper, bool allowed);
    event MandateSet(address indexed payer, address indexed recipient, address token, uint256 ticket, uint64 period, uint32 laps);
    event MandateCleared(address indexed payer, address indexed recipient);
    event HedgeReset(address indexed payer, address indexed recipient, address token);

    error NotOwner();
    error BadFee();
    error ZeroArg();
    error Paused();
    error BadWindow();
    error FundingFailed();
    error DeployFailed();
    error NotAuthorized();
    error BadStart();
    error BadMandate();
    error MandateExhausted();
    error NoMandate();
    error NotPendingOwner();
    error NotStaged();
    error TimelockNotElapsed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address feeRecipient_, uint16 feeBps_) {
        require(owner_ != address(0) && feeRecipient_ != address(0), "zero");
        if (feeBps_ > MAX_FEE_BPS) revert BadFee();
        owner = owner_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    // ---- the product ----

    /// @notice Create + fund a stream. For ERC20, approve this factory for `amount` FIRST.
    /// @param recipient who the stream pays
    /// @param token address(0) for native, else ERC20
    /// @param amount total to vest over the window (== msg.value for native)
    /// @param start vesting start (unix seconds); pass `block.timestamp` for "now"
    /// @param end vesting end; must be > start
    function createStream(address recipient, address token, uint256 amount, uint64 start, uint64 end)
        external
        payable
        returns (address vault)
    {
        return createStreamFor(msg.sender, recipient, token, amount, start, end);
    }

    /// @notice Same, but the stream is PAID FOR by `payer` (the explicit-arg seam above). For native,
    ///         msg.value is still what funds it; for ERC20, `payer` must have approved this factory.
    /// @dev AUTHORIZATION — the v2 drain fix, in two layers:
    ///   1. If (payer,recipient,token) has an ACTIVE MANDATE, ANYONE may call, but only within the
    ///      mandate's bounds (token, ticket, period, monotonic laps, laps remaining). A stranger can
    ///      therefore never redirect the funds, change the size, or over-mint — the worst they can do
    ///      is fire a lap the payer already authorized, which is the intended keeper behaviour.
    ///   2. Without a mandate, only the payer or an armed keeper may call (the hedge path) — AND the
    ///      hedge cursor (`hedgeEnd`) enforces the SAME monotonic rule, so a keeper cannot double-mint
    ///      a fully-vested window and double-pull the payer.
    /// @dev NOTE on `start`: the daemon's window is INDEX-derived (t0 + i*period) and fired LATE, so
    ///      `start` is normally ~hours in the PAST — a `start >= block.timestamp` check would break
    ///      the live reel (proven against live logs). The correct gate is MONOTONIC (`start >=
    ///      lastEnd`/`hedgeEnd`), which stops re-minting an already-vested window without demanding a
    ///      forward clock. (GOTCHA #190's t0-clock rate-limit is the stricter cousin; see the spec.)
    function createStreamFor(
        address payer,
        address recipient,
        address token,
        uint256 amount,
        uint64 start,
        uint64 end
    ) public payable returns (address vault) {
        if (paused) revert Paused();
        if (payer == address(0) || recipient == address(0)) revert ZeroArg();
        if (amount == 0) revert ZeroArg();
        if (end <= start) revert BadWindow();
        if (end - start < MIN_DURATION) revert BadWindow();

        Mandate storage m = mandate[payer][recipient][token];
        if (m.active) {
            // MANDATE path — bounded, permissionless-by-anyone. A stranger may fire a lap, but ONLY
            // strictly within the mandate's bounds, so the worst case == the payer's authorization.
            if (token != m.token) revert BadMandate();
            if (amount != m.ticket) revert BadMandate();
            if (end - start != m.period) revert BadMandate();
            if (start < m.lastEnd) revert BadStart();     // monotonic: no re-minting a past lap
            if (m.fired >= m.laps) revert MandateExhausted();
            m.lastEnd = end;
            m.fired += 1;
        } else {
            // HEDGE path — no mandate armed: caller must be the payer or an authorized keeper...
            if (msg.sender != payer && !isKeeper[msg.sender]) revert NotAuthorized();
            // ...AND the same monotonic rule applies, so an off-script keeper cannot double-mint.
            uint64 le = hedgeEnd[payer][recipient][token];
            if (le != 0 && start < le) revert BadStart();
            hedgeEnd[payer][recipient][token] = end;
        }

        if (token == address(0)) {
            if (msg.value != amount) revert FundingFailed();   // exact, so no stranded dust
        } else if (msg.value != 0) {
            revert FundingFailed();
        }

        uint256 idx = nonce[payer]++;
        Stream memory s = Stream(payer, recipient, token, amount, start, end, 0, idx);
        s.salt = _salt(s);
        bytes memory initCode = _initCode(s);
        vault = _predictAddr(s.salt, initCode);

        address created = _deploy(s.salt, initCode);
        if (created != vault) revert DeployFailed();   // parity pin: derivation must match CREATE2

        // Fund the vault — the factory holds nothing.
        if (token == address(0)) {
            (bool ok, ) = payable(vault).call{value: amount}("");
            if (!ok) revert FundingFailed();
        } else {
            _pullFunds(token, payer, vault, amount);
        }

        streamsOf[payer].push(vault);
        emit StreamCreated(payer, recipient, vault, token, amount, start, end, s.salt, idx);
    }

    /// @notice Vault address `createStreamFor(...)` WOULD produce for (payer, current nonce, ...).
    ///         A frontend shows this before the tx.
    /// @dev `amount` IS REQUIRED — my first draft asserted in a comment that it "only gets stored" and
    ///      passed 0; the unit test caught it (GOTCHAS #5 in miniature). The constructor's `amount`
    ///      is an IMMUTABLE, so it is a constructor ARG, so it is part of `creationCode ++ args`, so it
    ///      is hashed into the CREATE2 address. `salt`/`index` likewise ride in the args. Only `salt`
    ///      and `index` are additionally in the salt itself; `amount` is in the initcode. Pass the
    ///      REAL amount or the UI shows an address where no vault will ever be.
    ///      (Ordering here is the same `Stream` field order as `createStreamFor` — keep it in sync.)
    function predict(address payer, address recipient, address token, uint256 amount, uint64 start, uint64 end)
        external
        view
        returns (address)
    {
        uint256 idx = nonce[payer];
        Stream memory s = Stream(payer, recipient, token, amount, start, end, 0, idx);
        s.salt = _salt(s);
        return _predictAddr(s.salt, _initCode(s));
    }

    /// @dev salt binds the full stream identity so distinct streams cannot collide.
    function _salt(Stream memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(s.payer, s.index, s.recipient, s.token, s.start, s.end));
    }

    function _initCode(Stream memory s) internal view virtual returns (bytes memory) {
        return abi.encodePacked(
            type(StreamVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index)
        );
    }

    function _predictAddr(bytes32 salt, bytes memory initCode) internal view returns (address) {
        bytes32 h = keccak256(abi.encodePacked(hex"ff", address(this), salt, keccak256(initCode)));
        return address(uint160(uint256(h)));
    }

    function _deploy(bytes32 salt, bytes memory initCode) internal returns (address inst) {
        assembly {
            inst := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (inst == address(0)) revert DeployFailed();
    }

    /// @dev transferFrom with the USDT-class tolerance (empty return == ok, `false` == failure).
    function _pullFunds(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));   // transferFrom
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pull failed");
    }

    // ---- admin ----
    //
    // M-5 SHAPE (read before changing a name): the three MONEY knobs are STAGE -> WAIT 48h -> COMMIT.
    //   * `setFeeBps` / `setMinFee` / `setFeeRecipient` STAGE (they no longer take effect instantly) —
    //     they record the pending value + the earliest commit time (`*Eta`) and emit `*Staged`.
    //   * `commitFeeBps` / `commitMinFee` / `commitFeeRecipient` apply it, only at/after the ETA, and
    //     emit the SAME `*Set` event the instant path always did (so a log watcher sees one clear
    //     "value changed" line, exactly 48h after the "intent" line).
    //   * `cancel*` clears a stage before it lands.
    //   Calling a stager again simply REPLACES the pending value and RESTARTS the 48h clock (explicit:
    //   no partial state where an old ETA applies to a new value).
    // `paused` and `setKeeper` stay INSTANT (brake + role grant, not price).

    /// @notice STAGE a new feeBps. Takes effect only via `commitFeeBps`, at/after `feeBpsEta`.
    /// @dev Validates the ceiling at STAGE time so a bad value fails immediately, not 48h later.
    function setFeeBps(uint16 bps) public virtual onlyOwner {
        if (bps > MAX_FEE_BPS) revert BadFee();
        pendingFeeBps = bps;
        feeBpsEta = uint64(block.timestamp) + TIMELOCK;
        emit FeeBpsStaged(bps, feeBpsEta);
    }

    /// @notice Apply a staged feeBps once the 48h clock has run. Permissionless to nudge (anyone may
    ///         pay the gas), but it can only apply what the owner staged at the time the owner chose.
    function commitFeeBps() public {
        if (feeBpsEta == 0) revert NotStaged();
        if (block.timestamp < feeBpsEta) revert TimelockNotElapsed();
        feeBps = pendingFeeBps;
        feeBpsEta = 0;
        emit FeeBpsSet(feeBps);
    }

    function cancelFeeBps() external onlyOwner {
        if (feeBpsEta == 0) revert NotStaged();
        feeBpsEta = 0;
        emit FeeBpsCanceled();
    }

    /// @notice STAGE the per-withdraw minimum toll (token base units). 0 = legacy. Commit after 48h.
    ///         No ceiling: a minFee above the withdrawable amount just skips the toll.
    function setMinFee(uint256 minFee_) public virtual onlyOwner {
        pendingMinFee = minFee_;
        minFeeEta = uint64(block.timestamp) + TIMELOCK;
        emit MinFeeStaged(minFee_, minFeeEta);
    }

    function commitMinFee() public {
        if (minFeeEta == 0) revert NotStaged();
        if (block.timestamp < minFeeEta) revert TimelockNotElapsed();
        minFee = pendingMinFee;
        minFeeEta = 0;
        emit MinFeeSet(minFee);
    }

    function cancelMinFee() external onlyOwner {
        if (minFeeEta == 0) revert NotStaged();
        minFeeEta = 0;
        emit MinFeeCanceled();
    }

    /// @notice STAGE a new treasury address. Commit after 48h. Non-zero enforced at stage time.
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

    // ---- ownership: Ownable2Step (OZ shape, hand-rolled) ----
    //
    // A one-step `transferOwnership(typo)` orphans the contract FOREVER — the typo'd key owns it and
    // nobody else can move fees again. Ownable2Step makes the incoming key PROVE it can sign: the call
    // only STAGES, and the new owner must `acceptOwnership` from its own address. Ownership is NOT
    // 48h-gated (OZ's Ownable2Step has no delay); the 48h clock guards the MONEY knobs above, which
    // is where a live re-pricing lands. The old owner keeps full authority until accept, so a handoff
    // to a dead key leaves the contract GOVERNED, never frozen — and `transferOwnership` can be
    // re-issued to a corrected address at any time before accept.

    /// @notice Begin a handoff: `o` becomes pendingOwner and must `acceptOwnership` to take over.
    function transferOwnership(address o) external onlyOwner {
        if (o == address(0)) revert ZeroArg();
        pendingOwner = o;
        emit OwnershipTransferStarted(owner, o);
    }

    /// @notice Complete a handoff — MUST be called by the pending owner (its key proves liveness).
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
        emit OwnerSet(owner);   // legacy event kept so pre-M-5 tooling still sees a handoff line
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    /// @notice Arm/disarm a keeper that may create streams against ANY payer's allowance.
    ///         Owner-only, because the owner is the fleet operator and there is one keeper key
    ///         (`0x34E911fb…`). A per-payer allowlist (payer arms their own keeper) is the v3
    ///         hardening; the global map is the minimal change that keeps the recurring rail alive.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroArg();
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Publish a mandate: "my standing allowance to this factory, for `recipient`, is for
    ///         `laps` laps of `ticket` `token` every `period` seconds, starting at `t0`." While
    ///         active, ANYONE may call createStreamFor within these bounds. Signed by the payer.
    /// @dev The payer arms one mandate per recipient. Re-arming (same recipient) RESETS the laps
    ///      budget and the monotonic cursor — used to top up a reel without a redeploy. `t0` is the
    ///      first lap's start; laps advance contiguously (start must be >= lastEnd), and the caller
    ///      supplies the concrete window each time (so a late keeper is not punished, per the
    ///      index-derived window rule).
    function setMandate(address recipient, address token, uint256 ticket, uint64 period, uint32 laps, uint64 t0)
        external
    {
        if (recipient == address(0)) revert ZeroArg();
        if (ticket == 0) revert ZeroArg();
        if (laps == 0) revert ZeroArg();
        if (period < MIN_DURATION) revert BadWindow();
        mandate[msg.sender][recipient][token] =
            Mandate({token: token, ticket: ticket, period: period, lastEnd: t0, laps: laps, fired: 0, active: true});
        emit MandateSet(msg.sender, recipient, token, ticket, period, laps);
    }

    /// @notice Clear a mandate — the contract half of revoke (the allowance half is approve(factory,0)).
    function disarmMandate(address recipient, address token) external {
        delete mandate[msg.sender][recipient][token];
        emit MandateCleared(msg.sender, recipient);
    }

    /// @notice Reset the HEDGE cursor for (msg.sender, recipient, token) — the escape hatch when a new
    ///         non-contiguous reel is wanted on the un-armed path (e.g. a different t0 after a long
    ///         gap). Payer-only (the cursor is keyed by the payer's own reel identity).
    function resetHedge(address recipient, address token) external {
        delete hedgeEnd[msg.sender][recipient][token];
        emit HedgeReset(msg.sender, recipient, token);
    }

    function streamCount(address payer) external view returns (uint256) {
        return streamsOf[payer].length;
    }
}
