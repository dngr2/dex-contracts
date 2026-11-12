// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFeeSplitter} from "./interfaces/IFeeSplitter.sol";

/// @title FeeSplitter
/// @notice Splits ONE fee into a referral cut and a treasury cut, forwarding both IN THE SAME CALL.
/// It is a pure pass-through: it holds no fee longer than the transaction, EXCEPT when a payee's
/// inline transfer fails — then the owed amount is booked in `claimable[who][token]` for a later
/// `claim(token)`. Nothing is ever lost, and the split is exact:
///
///     fee == referrerCut + treasuryCut          (treasuryCut is the remainder, no rounding leak)
///
/// THE ONE HONEST CAVEAT: `referralBps` is a cut OF THE FEE ALREADY CHARGED (the rail sets the fee
/// level; this contract only divides whatever fee arrives). It does NOT set the fee. Default
/// referralBps = 2500 = 25% of the fee to the referrer; the remainder (~75%) to treasury.
///
/// Non-custodial: no owner funds, no upgrade, no selfdestruct. Only the failed-payout accrual is
/// held, and `claim` returns it.
contract FeeSplitter is IFeeSplitter {
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_REFERRAL_BPS = 10_000;

    address public owner;
    address public treasury;

    /// @notice Referrer share of the fee, in bps. 2500 = 25% of the fee. Settable by owner, <=10000.
    uint16 public referralBps = 2500;

    /// @notice Balances owed to a payee whose inline transfer failed. token == address(0) is native.
    mapping(address => mapping(address => uint256)) public claimable;

    /// @notice Running total of native owed to payees via `claimable[who][address(0)]`. `sweepNative`
    /// subtracts this so it NEVER drains a payee's pending native — it recovers only the stray excess
    /// (e.g. a bare `send` to `receive()`).
    uint256 public nativeOwed;

    uint256 private _locked = 1;

    event ReferralBpsSet(uint16 oldBps, uint16 newBps);
    event TreasurySet(address oldTreasury, address newTreasury);
    event Claimed(address indexed who, address token, uint256 amount);
    event NativeSwept(address to, uint256 amount);

    error NotOwner();
    error BadBps(uint16 bps);
    error ZeroTreasury();
    error ZeroOwner();
    error TransferFromFailed();
    error NativeClaimFailed();
    error TokenClaimFailed();
    error NothingToSweep();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address _treasury, address _owner) {
        if (_treasury == address(0)) revert ZeroTreasury();
        if (_owner == address(0)) revert ZeroOwner();
        // NOTE: NOT msg.sender — under CREATE2 msg.sender is the deterministic-deployment proxy
        // (0x4e59b448…), a keyless contract. Pass the intended EOA explicitly.
        owner = _owner;
        treasury = _treasury;
    }

    // ------------------------------------------------------------------ owner

    function setReferralBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_REFERRAL_BPS) revert BadBps(newBps);
        uint16 old = referralBps;
        referralBps = newBps;
        emit ReferralBpsSet(old, newBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroTreasury();
        address old = treasury;
        treasury = newTreasury;
        emit TreasurySet(old, newTreasury);
    }

    // ------------------------------------------------------------------ split

    /// @inheritdoc IFeeSplitter
    function split(address token, uint256 fee, bytes32 product, address payer, address referrer)
        external
        nonReentrant
        returns (uint256 referrerCut, uint256 treasuryCut)
    {
        (referrerCut, treasuryCut) = _compute(fee, referrer);

        // pull the whole fee FIRST so the split is funded atomically, then fan out.
        if (fee > 0) _pullExact(msg.sender, token, fee);

        emit FeeSplit(product, payer, referrer, fee, referrerCut);

        _payout(referrer, token, referrerCut); // no-op when referrerCut == 0 (covers referrer == 0)
        _payout(treasury, token, treasuryCut);
    }

    /// @inheritdoc IFeeSplitter
    function splitNative(bytes32 product, address payer, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 referrerCut, uint256 treasuryCut)
    {
        uint256 fee = msg.value;
        (referrerCut, treasuryCut) = _compute(fee, referrer);

        emit FeeSplit(product, payer, referrer, fee, referrerCut);

        _payout(referrer, address(0), referrerCut);
        _payout(treasury, address(0), treasuryCut);
    }

    // ------------------------------------------------------------------ claim

    /// @inheritdoc IFeeSplitter
    function claim(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][token];
        if (amount == 0) return 0;
        claimable[msg.sender][token] = 0; // effects before interaction
        if (token == address(0)) nativeOwed -= amount;
        emit Claimed(msg.sender, token, amount);

        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert NativeClaimFailed();
        } else {
            if (!_tryTransfer(token, msg.sender, amount)) revert TokenClaimFailed();
        }
    }

    // ------------------------------------------------------------------ sweep

    /// @notice Native held by this contract that is NOT owed to any payee via `claimable` — i.e. the
    /// stray balance from a bare `receive()`. At rest this is 0 (pure pass-through); it only exists
    /// if someone `send`s native directly instead of calling `splitNative`.
    function nativeRecoverable() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > nativeOwed ? bal - nativeOwed : 0;
    }

    /// @notice Forward the stray native (a bare-`send` strand) to treasury. Gated to owner. NEVER
    /// touches native owed to payees (`nativeOwed`): those are only payable via `claim(address(0))`.
    /// Reverts if there is nothing recoverable, so it is not a no-op footgun.
    function sweepNative() external nonReentrant onlyOwner returns (uint256 amount) {
        amount = nativeRecoverable();
        if (amount == 0) revert NothingToSweep();
        emit NativeSwept(treasury, amount);
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert NativeClaimFailed();
    }

    // ------------------------------------------------------------------ internal

    /// @dev referrerCut + treasuryCut == fee EXACTLY. zero referrer -> all to treasury.
    function _compute(uint256 fee, address referrer) internal view returns (uint256 referrerCut, uint256 treasuryCut) {
        if (referrer == address(0)) return (0, fee);
        referrerCut = (fee * referralBps) / BPS;
        treasuryCut = fee - referrerCut; // remainder: no rounding leak
    }

    /// @dev Best-effort payout: a revert OR a `false` return both accrue to `claimable` instead of
    /// bricking the split. This is the reverting-referrer safety net.
    function _payout(address who, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = who.call{value: amount}("");
            if (!ok) {
                claimable[who][address(0)] += amount;
                nativeOwed += amount;
            }
        } else {
            if (!_tryTransfer(token, who, amount)) claimable[who][token] += amount;
        }
    }

    /// @dev Pull exactly `amount` from `from`; revert if the token returns false or reverts.
    function _pullExact(address from, address token, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || !(ret.length == 0 || abi.decode(ret, (bool)))) revert TransferFromFailed();
    }

    /// @dev Non-reverting transfer; false/revert -> false (caller decides to accrue or revert).
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @notice Allow native receipts (e.g. from a rail forwarding value via a bare `send`). Value
    /// that arrives this way is NOT split; it sits until `sweepNative()` forwards it to treasury.
    /// Prefer `splitNative{value: ...}` so the fee is divided on receipt.
    receive() external payable {}
}
