// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "./interfaces/IERC20.sol";
import {IEscrowFactory} from "./interfaces/IEscrowFactory.sol";

/// @title Escrow — one instance per deal, deployed by EscrowFactory (CREATE2)
/// @notice Holds a payer's ERC-20 until ONE of four terminal paths fires: the counterparty's
///         preimage releases it, the payer's timeout refunds it, or the nominated arbiter releases
///         or refunds it. Funds only ever go to `counterparty` or `payer` (+ a fee to the factory's
///         feeRecipient on a RELEASE), so every path is trust-minimised and permissionless.
///
/// TRUST MODEL (stated, not implied)
///   - HASH path is fully trustless: whoever presents `keccak(preimage)==hash` releases. Anyone may
///     call it; the preimage is the authority.
///   - TIMEOUT path is fully trustless: after `timeout`, anyone may refund to the payer. This is the
///     payer's protection against a quiet counterparty.
///   - ARBITER path is a NOMINATED TRUST: `arbiter` may release or refund at any time. It is the
///     "counterparty went quiet before timeout, and the preimage can't be proven on-chain" case.
///     v1 is a single arbiter; 2-of-3 is v2.
///
/// FOT-SAFE AND WHY THERE ARE TWO AMOUNTS: `declaredAmount` is what the payer SAID they sent (a
///   constructor arg); `amount` is what actually ARRIVED (`balanceOf` measured at construction).
///   A fee-on-transfer or rebasing token delivers less than declared, so crediting the MEASURED
///   amount is the only correct credit — crediting `declaredAmount` under-collateralises the escrow
///   and makes the release revert. `declaredAmount` is kept public for accounting/inspection.
///
/// NO CLONE: like P2's Forwarder, a full contract (a stock 1167 clone cannot survive a 2300-gas
///   `.transfer()` stipend — P2 GOTCHAS, measured). Escrow is funded by `transferFrom`, not a native
///   send, but the full-contract choice is kept for uniformity with the P2 family.
///
/// MUTANT HOOKS: `release`, `refund`, `_release`, `_refund` are `virtual` so a test can deploy a
///   genuine rival contract that IS a bug (see test/unit/EscrowNegcontrol.t.sol). GOTCHAS #20: a
///   negcontrol must route the injection through the REAL mechanism, not hand-asserted math.
contract Escrow {
    IEscrowFactory public immutable factory;
    address public immutable payer;
    address public immutable counterparty;   // receives on release
    address public immutable arbiter;        // address(0) => hashlock-only escrow
    address public immutable token;
    bytes32 public immutable hash;           // keccak256(preimage); 0 => no hashlock
    uint64 public immutable timeout;         // REFUND WINDOW: seconds from creation
    uint64 public immutable deadline;        // absolute unix second = creation + timeout; refund opens here
    uint256 public immutable declaredAmount; // what the payer asserted they sent
    uint256 public immutable amount;         // credited = what actually ARRIVED (FOT-safe)

    uint256 private _lock;
    bool public settled;

    /// @param preimage the revealed preimage (0 on arbiter/refund paths)
    /// @param to the recipient (counterparty on release, payer on refund)
    /// @param by msg.sender of the settling call, for the record
    event Released(bytes32 preimage, address indexed to, uint256 amountIn, uint256 fee, uint256 amountOut, address by);
    event Refunded(address indexed to, uint256 amount, address by);

    error ZeroArg();
    error Locked();
    error AlreadySettled();
    error NotArbiter();
    error BadPreimage();
    error TooEarly();
    error NoHashlock();

    modifier nonReentrant() {
        if (_lock != 1) revert Locked();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address factory_,
        address payer_,
        address counterparty_,
        address arbiter_,
        address token_,
        bytes32 hash_,
        uint64 timeout_,
        uint256 declaredAmount_
    ) {
        if (factory_ == address(0) || payer_ == address(0) || counterparty_ == address(0) || token_ == address(0))
            revert ZeroArg();
        factory = IEscrowFactory(factory_);
        payer = payer_;
        counterparty = counterparty_;
        arbiter = arbiter_;
        token = token_;
        hash = hash_;
        timeout = timeout_;
        declaredAmount = declaredAmount_;
        // `timeout` is a DURATION; the refund deadline is an absolute second derived here, so the
        // caller passes "1 days" not a wall-clock timestamp. Bounds in the factory are then
        // meaningful (10 min .. 365 days) instead of silently comparing a duration to a timestamp.
        deadline = uint64(block.timestamp) + timeout_;
        // The factory transfers funds to this address BEFORE deploying, so the balance is already
        // here. MEASURING (not asserting) is the FOT-safe credit — see header.
        amount = IERC20(token_).balanceOf(address(this));
        if (amount == 0) revert ZeroArg();
        _lock = 1;
    }

    // ---- the four terminal paths ----

    /// @notice Release to the counterparty by revealing the preimage. Permissionless.
    function release(bytes32 preimage) external virtual nonReentrant {
        if (settled) revert AlreadySettled();
        if (hash == bytes32(0)) revert NoHashlock();
        if (keccak256(abi.encodePacked(preimage)) != hash) revert BadPreimage();
        _release(preimage);
    }

    /// @notice Refund the payer after the deadline. Permissionless. No fee on a refund.
    function refund() external virtual nonReentrant {
        if (settled) revert AlreadySettled();
        if (block.timestamp < deadline) revert TooEarly();
        _refund();
    }

    /// @notice Arbiter releases to the counterparty (fee applies). Only the nominated arbiter.
    function arbiterRelease() external nonReentrant {
        if (settled) revert AlreadySettled();
        if (msg.sender != arbiter) revert NotArbiter();
        _release(bytes32(0));
    }

    /// @notice Arbiter refunds the payer (no fee). Only the nominated arbiter.
    function arbiterRefund() external nonReentrant {
        if (settled) revert AlreadySettled();
        if (msg.sender != arbiter) revert NotArbiter();
        _refund();
    }

    // ---- internals (virtual: the mutant hooks) ----

    function _release(bytes32 preimage) internal virtual {
        settled = true;
        uint256 cred = _credited();
        uint256 fee = (cred * factory.feeBps()) / 10_000;     // floor; dust-safe (fee==0 when tiny)
        uint256 out = cred - fee;
        if (out > 0) _pay(counterparty, out);
        if (fee > 0) _pay(factory.feeRecipient(), fee);
        emit Released(preimage, counterparty, cred, fee, out, msg.sender);
    }

    function _refund() internal virtual {
        settled = true;
        uint256 cred = _credited();
        _pay(payer, cred);
        emit Refunded(payer, cred, msg.sender);
    }

    /// @dev What the escrow pays out: the MEASURED arrival (`amount`). A mutant that credits the
    ///      asserted figure instead is the FOT bug — see EscrowNegcontrol.
    function _credited() internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Safe transfer tolerating non-bool tokens (USDT class): accepts `true` or empty return;
    ///      anything else is a failure, not a silent pass. Same rule as P2's Forwarder._pay.
    function _pay(address to, uint256 v) internal virtual {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, v));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 transfer failed");
    }

    // ---- views for the page (chain-only readable, no server) ----

    function status() external view returns (string memory state, bool canRelease, bool canRefund, uint64 t) {
        t = deadline;
        if (settled) return ("settled", false, false, t);
        bool pastTimeout = block.timestamp >= deadline;
        return (pastTimeout ? "refundable" : "locked", hash != bytes32(0), pastTimeout, t);
    }
}
