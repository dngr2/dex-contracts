// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "./interfaces/IERC20.sol";
import {IStreamFactory} from "./interfaces/IStreamFactory.sol";
import {FeeMath} from "@shared/FeeMath.sol";

/// @title StreamVault — ONE contract instance per stream. Money vests linearly; the recipient pulls.
/// @notice A payer escrows `amount` at creation; the recipient's `withdrawable` grows as a pure
///         function of `block.timestamp`; either party can end it (recipient by pulling, payer by
///         `cancel`). We take a bps fee ON WITHDRAWAL, same event as P2's forwarder.
///
/// WHY ONE INSTANCE PER STREAM (load-bearing, not style)
///   P2's keeper model is "one address -> one destination". A per-stream instance keeps that model
///   exactly true, so the daemon's `Registered` cache learns vault->recipient unchanged, AND the
///   vault can expose P2's exact `withdraw(address,address)` selector so the daemon's `_send()` ABI
///   layout carries over untouched. A single shared multi-stream vault would break both.
///
/// WHY A FULL CONTRACT, NOT AN EIP-1167 CLONE
///   Same measured reason as P2's Forwarder (and the C5 regressions that prove it): a clone's
///   `receive()` runs via DELEGATECALL, whose EIP-2929 cold access costs 2600 gas — over the 2300
///   `.transfer()` stipend, always. An integrator doing `payable(vault).transfer(v)` would revert
///   against a clone. A full contract fits under the stipend and keeps the `Deposit` log.
///
/// LAZY SETTLEMENT (the central honesty of this product)
///   Nothing is transferred per second. `withdrawable()` accrues; a pull settles it. "Per-second" is
///   a UI truth about ACCRUAL, never about settlement. See GOTCHAS #39/#48/#65 — accrual is a standing
///   STATE with no transition event, so a deposit-log watcher is structurally blind to it.
///
/// NO OVERFLOW BY CONSTRUCTION
///   Solidity 0.8 checked maths revert, they do not wrap — so a stream never silently mispays, it
///   HALTS. The `__urndata` trick below (P2's clean-room pattern) makes a zero-length returndata
///   decode to 0 instead of reverting, so a codeless/non-conforming token address yields 0 rather
///   than an unhelpful revert. `mulDiv` cannot overflow as written: elapsed <= duration, so
///   `amount * elapsed <= amount * duration`, and we additionally floor the result to `amount`/`cap`
///   so pre-funding the vault MORE than `amount` can never pay out more than the stream defines.
contract StreamVault {
    IStreamFactory public immutable factory;

    address public immutable payer;       // who funded + who may cancel
    address public immutable recipient;   // who the stream pays
    address public immutable token;       // address(0) == native

    uint64 public immutable start;
    uint64 public immutable end;
    uint64 public immutable duration;
    uint256 public immutable amount;

    uint256 public withdrawn;             // total already paid out (fee-inclusive basis)
    bool public canceled;
    uint256 private _lock;

    /// @dev M-4 (audit): credited-but-undelivered amounts. A NATIVE send invokes the recipient's
    ///      receive()/fallback, so a CONTRACT recipient (multisig, smart wallet, staking proxy) that
    ///      reverts used to make withdraw() and cancel() revert for EVERYONE — the stream bricked on
    ///      a payee we do not control. v2 CREDITS instead of reverting: the amount is held here and
    ///      pulled later by `claim`, so the rail never stalls on a reverting payee. ERC20 `transfer`
    ///      carries no recipient callback, so ERC20 keeps the strict require().
    mapping(address => uint256) public claimable;
    /// @dev Sum of all `claimable` values — kept so `cancel` can exclude pending credits from the
    ///      payer's refund (they are already "paid out" logically and must stay backed in the vault).
    ///      Overlap-free (a global sum), unlike summing per-address which double-counts an address
    ///      that is both recipient and feeRecipient.
    uint256 public creditedOutstanding;

    event Credited(address indexed to, uint256 amount);
    event Claimed(address indexed to, uint256 amount);

    /// @dev M-1 (audit): the toll RATE is SNAPSHOTTED at construction. The factory is owner-controlled
    ///      and the vault used to live-read `feeBps()`/`minFee()` at each pull, so an owner raise to
    ///      5% RETRO-TAXED funds the payer had already locked at the old rate. Snapshotting makes the
    ///      payer's rate BINDING at creation; a factory change now only affects NEW streams.
    ///      `feeRecipient` stays LIVE (routing, not rate) — re-pointing the treasury must not be a
    ///      reason to redeploy. Read in the constructor from the SAME `factory_` arg, so the ctor
    ///      signature, initCode, CREATE2 parity (predict()) and the mutant factories are unchanged.
    uint16 public immutable feeBpsSnap;
    uint256 public immutable minFeeSnap;

    /// @dev Same signature AND topic shape as P2 Registry's `Registered` (topic0 verified identical
    ///      with `cast keccak`): topics[2]=this vault, topics[3]=recipient. Emitted at CREATE2 time
    ///      by the factory's constructor call, so the keeper's existing decode caches vault->recipient
    ///      with no change. The unread fields (bool, salt, index) keep the signature topic0-exact.
    event Registered(
        address indexed owner,
        address indexed depositAddr,
        address indexed destination,
        bool tokenAgnostic,
        bytes32 salt,
        uint256 index
    );

    /// @dev P2's Forwarder event shape, carried over so P2's keeper/ledger path keeps working.
    event Deposit(address indexed depositor, address indexed token, uint256 amount);

    /// @dev `withdrawer` is informational — withdraw() is PERMISSIONLESS (funds can only reach the
    ///      immutable recipient + feeRecipient), so a keeper may pull on the recipient's behalf.
    ///      `recipientOut`/`fee` are the exact split, so a chain-only reader needs no maths.
    event Withdrawn(
        address indexed recipient,
        address indexed withdrawer,
        address indexed token,
        uint256 amount,
        uint256 fee,
        uint256 recipientOut,
        uint256 totalWithdrawn
    );

    event Canceled(address indexed payer, address indexed recipient, uint256 refund, uint256 paidOut);

    error AlreadyInit();
    error ZeroArg();
    error BadWindow();
    error Locked();
    error NotPayer();
    error AlreadyCanceled();
    error NothingClaimable();

    modifier nonReentrant() {
        if (_lock != 1) revert Locked();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param factory_ the stream factory (feeBps + feeRecipient are read live from it)
    /// @param payer_ who funded the stream and may cancel it
    /// @param recipient_ who the stream pays
    /// @param token_ address(0) for native, else ERC20
    /// @param amount_ total to vest over the window
    /// @param start_ vesting start (unix seconds)
    /// @param end_ vesting end (unix seconds), must be > start_
    /// @param salt_ creation salt, only used to re-emit the identical `Registered` event
    /// @param index_ payer nonce, only used to re-emit the identical `Registered` event
    constructor(
        address factory_,
        address payer_,
        address recipient_,
        address token_,
        uint256 amount_,
        uint64 start_,
        uint64 end_,
        bytes32 salt_,
        uint256 index_
    ) {
        if (factory_ == address(0) || payer_ == address(0) || recipient_ == address(0)) revert ZeroArg();
        if (amount_ == 0) revert ZeroArg();
        if (end_ <= start_) revert BadWindow();

        factory = IStreamFactory(factory_);
        payer = payer_;
        recipient = recipient_;
        token = token_;
        amount = amount_;
        start = start_;
        end = end_;
        duration = end_ - start_;
        // M-1: freeze the RATE now; a later owner fee raise cannot retro-tax a locked stream.
        feeBpsSnap = IStreamFactory(factory_).feeBps();
        minFeeSnap = IStreamFactory(factory_).minFee();
        _lock = 1;

        emit Registered(payer_, address(this), recipient_, token_ == address(0), salt_, index_);
    }

    /// @notice Native funding path — kept for P2 parity of the daemon's log shape. Reads balance,
    ///         so a `.transfer()` send works (see the full-contract note in the header).
    receive() external payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }

    fallback() external payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }

    // ---- the product ----

    /// @notice Vesting elapsed so far, capped at `amount`. Pure function of time.
    function streamedAt(uint256 t) public view returns (uint256) {
        if (t <= start) return 0;
        if (t >= end) return amount;
        // elapsed <= duration, so amount*elapsed <= amount*duration — no overflow at realistic scales.
        return (amount * (t - start)) / duration;
    }

    /// @notice Currently pullable, fee-inclusive. Withdrawing zero is a no-op, not an error.
    /// @dev CANCEL-AWARE, and this is not cosmetic. `cancel()` pays out the recipient's accrued part
    ///      AND refunds the payer the entire remaining balance, so the vault is empty afterwards —
    ///      yet `streamedAt()` would keep GROWING with time (it is a pure function of `t`, unaware
    ///      that the stream was ended early). Without the `canceled` guard, a later `withdraw()`
    ///      would compute a fresh positive `withdrawable` and pay out of money already refunded.
    ///      Post-cancel the stream is over: nothing further is claimable.
    function withdrawable() public view returns (uint256) {
        if (canceled) return 0;
        return streamedAt(block.timestamp) - withdrawn;
    }

    /// @notice Pull everything accrued. PERMISSIONLESS — caller pays gas, recipient gets paid.
    ///      `depositor` (2nd arg) is informational, never used for routing.
    ///
    /// NAME/ARITY — corrected after a FORK TEST caught a wrong claim in my own SCOPE (GOTCHAS #5 in
    /// miniature). The SCOPE said the daemon's `SEL_FORWARD = 0x95ccf8bf` could call the vault, and
    /// phrased the vault method as `withdraw(address,address)`. Both are true but they are NOT the
    /// same selector: `0x95ccf8bf` is `forward(address,address)`, while `withdraw(address,address)`
    /// is `0xf940e385`. Verified with `cast sig`. So the vault exposes BOTH:
    ///   - `forward(address,address)`  -> 0x95ccf8bf — byte-identical to the daemon's `_send()`
    ///     calldata (which is `forward(token, depositor)`), so the daemon works with ZERO change to
    ///     its selector, ABI words, or `_send()` body.
    ///   - `withdraw(address,address)` -> 0xf940e385 — the natural name; both delegate to `_pull()`.
    ///   - `withdraw()`                -> 0x3ccfd60b — human/frontend convenience.
    function forward(address, address) external nonReentrant returns (uint256 recipientOut, uint256 fee) {
        return _pull();
    }

    /// @dev Natural-named alias. Same code path.
    function withdraw(address, address) external nonReentrant returns (uint256 recipientOut, uint256 fee) {
        return _pull();
    }

    /// @notice Zero-arg convenience for a human/frontend. Same code path.
    function withdraw() external nonReentrant returns (uint256 recipientOut, uint256 fee) {
        return _pull();
    }

    function _pull() internal returns (uint256 recipientOut, uint256 fee) {
        uint256 w = withdrawable();
        if (w == 0) return (0, 0);

        // ONE shared definition for both G2-a sites (withdraw + cancel) and all three products.
        (fee, recipientOut) = _toll(w);
        withdrawn += w;

        if (recipientOut > 0) _pay(token, recipient, recipientOut);
        if (fee > 0) _pay(token, factory.feeRecipient(), fee);

        emit Withdrawn(recipient, msg.sender, token, w, fee, recipientOut, withdrawn);
    }

    /// @notice Withdraw any CREDITED-but-undelivered balance (M-4). Anyone may call; the funds can
    ///         only reach `to` (the immutable recipient or payer), never the caller.
    /// @dev A native recipient whose receive() reverts is credited in _pay instead of bricking the
    ///      pull/cancel; this retries delivery. Reverts if nothing is claimable so a UI can tell.
    function claim(address to) external nonReentrant returns (uint256 paid) {
        paid = claimable[to];
        if (paid == 0) revert NothingClaimable();
        claimable[to] = 0;
        creditedOutstanding -= paid;
        _payStrict(token, to, paid);     // strict here: a claim that still can't deliver reverts cleanly
        emit Claimed(to, paid);
    }

    /// @dev The ONLY definition of THIS product's toll, and the mutant seam: shared/src/FeeMath.sol
    ///      so the two G2-a sites and the sibling products cannot drift (GOTCHAS #131). At
    ///      `minFee()==0` this is byte-for-byte the old `(w * feeBps) / 10_000`. `virtual` so a
    ///      negcontrol can re-inject the "minFee ignored" bug through the REAL withdraw path.
    /// @dev M-1: reads the SNAPSHOT rate (frozen at construction), not the live factory rate.
    function _toll(uint256 w) internal view virtual returns (uint256 fee, uint256 out) {
        return FeeMath.toll(w, feeBpsSnap, minFeeSnap);
    }

    /// @notice End the stream: recipient gets what accrued, payer gets the rest. PAYER ONLY.
    /// @dev Permissionless would be wrong here — `cancel` moves money to a caller-chosen... no, to
    ///      fixed addresses; it is payer-only because the payer is the one giving up optionality.
    function cancel() external nonReentrant {
        if (msg.sender != payer) revert NotPayer();
        if (canceled) revert AlreadyCanceled();

        uint256 w = withdrawable();
        // same definition as _pull (via _toll) — a cancel must split identically or the two paths drift
        (uint256 fee, uint256 recipientOut) = _toll(w);

        canceled = true;
        withdrawn += w;

        // The payer's refund is what is ACTUALLY here, minus what is ALREADY owed to someone else: the
        // recipient's/fee's share of THIS cancel, AND any earlier credited-but-undelivered balance
        // (M-4) that `claim` still has to pay out. See PAYER-REFUND note. For well-behaved tokens the
        // un-credited parts are identical to the arithmetic ideal; for a fee-on-transfer token the
        // vault holds less than `amount`, and refunding the real remainder is the honest choice.
        uint256 bal = _balance(token);
        uint256 owed = recipientOut + fee + creditedOutstanding;
        uint256 refund = bal > owed ? bal - owed : 0;

        if (recipientOut > 0) _pay(token, recipient, recipientOut);
        if (fee > 0) _pay(token, factory.feeRecipient(), fee);
        if (refund > 0) _pay(token, payer, refund);

        emit Canceled(payer, recipient, refund, withdrawn);
    }

    // ---- views for the daemon (no events carry these) ----

    /// @notice Everything the daemon's per-stream scheduler needs in ONE call.
    /// @dev The daemon computes pulls locally, but this lets it re-check cheaply and lets a
    ///      frontend render a countdown without indexing. `rate` is wei-per-second (floor).
    function state()
        external
        view
        returns (uint256 acc_amt, uint256 withdrawn_, uint256 withdrawable_, uint256 rate, uint64 t)
    {
        acc_amt = amount;
        withdrawn_ = withdrawn;
        withdrawable_ = withdrawable();
        rate = amount / duration;
        t = uint64(block.timestamp);
    }

    /// @dev Token balance of THIS vault. `__urndata` decode trick so a non-contract token address
    ///      answers 0 instead of reverting the read (P2 clean-room pattern).
    function _balance(address t) internal view returns (uint256 b) {
        if (t == address(0)) return address(this).balance;
        (bool ok, bytes memory d) = t.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
        if (ok && d.length >= 32) return abi.decode(d, (uint256));
        return 0;
    }

    /// @dev Safe transfer tolerating non-bool-returning tokens (USDT class): accepts a `true` return
    ///      OR an empty return; anything else is a failure, not a silent pass. P2's exact rule — a
    ///      token returning `false` must NOT read as success.
    /// @dev M-4: NATIVE delivery is now SOFT — a recipient whose receive() reverts is CREDITED (held
    ///      in `claimable`) rather than reverting the whole pull/cancel. ERC20 `transfer` is atomic
    ///      with no recipient callback, so ERC20 stays a hard require(). `virtual` so a negcontrol can
    ///      re-inject the v1 "native revert bricks the pull" bug through the REAL path.
    function _pay(address t, address to, uint256 v) internal virtual {
        if (t == address(0)) {
            (bool ok, ) = payable(to).call{value: v}("");
            if (!ok) {
                claimable[to] += v;      // credit; deliverable later via claim(to)
                creditedOutstanding += v;
                emit Credited(to, v);
            }
        } else {
            (bool ok, bytes memory ret) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, to, v));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 transfer failed");
        }
    }

    /// @dev STRICT variant used by `claim`: the whole point of a claim is to deliver, so a still-
    ///      reverting recipient reverts the claim (the credit stays, retryable) rather than silently
    ///      re-crediting itself.
    function _payStrict(address t, address to, uint256 v) internal {
        if (t == address(0)) {
            (bool ok, ) = payable(to).call{value: v}("");
            require(ok, "native send failed");
        } else {
            (bool ok, bytes memory ret) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, to, v));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 transfer failed");
        }
    }
}
