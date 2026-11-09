// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {FeeMath} from "@shared/FeeMath.sol";

/// @title Forwarder — one DEPLOYED instance per user deposit address
/// @notice Anything sent here is forwarded to the user's fixed `destination`, minus a fee to the
///         registry's feeRecipient. `forward()` is PERMISSIONLESS: funds can only ever go to the
///         fixed destination + fixed feeRecipient, so any keeper may push without trust.
///
/// WHY A FULL CONTRACT, NOT AN EIP-1167 CLONE (measured, 2026-11-05 — read this before "optimising")
///   A stock 1167 clone CANNOT accept a send from `payable(x).transfer()`. `.transfer()` gives the
///   callee a 2300-gas stipend in its own frame; a clone's `receive()` runs via DELEGATECALL, whose
///   EIP-2929 COLD access to the implementation costs 2600 — over the stipend, always. Measured
///   minimum gas to not-revert: clone 2690, this contract 1620. It is NOT the event (an eventless
///   clone still failed). So integrators doing `addr.transfer(v)` would revert against clones.
///   A full contract fits under 2300 and keeps `Deposit`. Cost: ~156k gas/address vs ~68k cloned.
///
///   `receive()` also emits `Deposit`, so a keeper reading the native leg needs one log, not a
///   balance-diff scan. (ERC20 deposits still don't run our code — see registry PLAN §2.)
contract Forwarder {
    IRegistry public immutable registry;
    address public immutable destination;
    uint256 private _lock;

    /// @dev L-8: a fee the feeRecipient REJECTED (e.g. a contract whose receive/transfer reverts).
    ///      Held here, keyed by token, and re-tried by `releaseFee`. This is money already carved
    ///      out of a past deposit, so `forward()` must EXCLUDE it from the sweepable balance.
    mapping(address => uint256) public feeAccrued;

    /// @param token address(0) == native
    event Deposit(address indexed depositor, address indexed token, uint256 amount);
    event Forwarded(
        address indexed depositor,
        address indexed destination,
        address indexed token,
        uint256 amountIn,
        uint256 fee,
        uint256 amountOut,
        address ref
    );
    /// @dev L-8: the fee recipient refused its fee, so it was parked rather than blocking the forward.
    event FeeAccrued(address indexed token, address indexed feeRecipient, uint256 amount);
    /// @dev A parked fee was successfully delivered on a later attempt.
    event FeeReleased(address indexed token, address indexed feeRecipient, uint256 amount);

    error ZeroArg();
    error Locked();

    modifier nonReentrant() {
        if (_lock != 1) revert Locked();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address registry_, address destination_) {
        if (registry_ == address(0) || destination_ == address(0)) revert ZeroArg();
        registry = IRegistry(registry_);
        destination = destination_;
        _lock = 1;
    }

    /// @notice Native deposit path — the value arrives as a normal send, so this log is complete.
    receive() external payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }

    /// @notice A send with non-empty calldata lands here, not `receive`.
    fallback() external payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }

    /// @notice Push the whole balance to `destination` minus the fee. Permissionless.
    /// @dev L-8: the fee leg is delivered BEST-EFFORT — if the feeRecipient rejects (a contract
    ///      whose receive/transfer reverts), the fee is ACCRUED here instead of reverting the whole
    ///      forward. The destination leg stays a hard requirement (that is the user's money). Accrued
    ///      fee is excluded from the sweepable balance so a later forward does not double-count it;
    ///      `releaseFee` retries delivery.
    /// @param token address(0) for native, else the ERC20 to sweep.
    /// @param depositor informational; the keeper supplies it (see contract header).
    function forward(address token, address depositor) external nonReentrant returns (uint256 amountOut, uint256 fee) {
        uint256 balance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        uint256 held = feeAccrued[token];               // L-8: a previously-parked fee, not sweepable
        if (balance <= held) return (0, 0);
        uint256 amount = balance - held;
        if (amount == 0) return (0, 0);

        (fee, amountOut) = _toll(amount);

        if (amountOut > 0) _pay(token, destination, amountOut);
        if (fee > 0) {
            if (_tryPay(token, registry.feeRecipient(), fee)) {
                // delivered now
            } else {
                feeAccrued[token] = held + fee;
                emit FeeAccrued(token, registry.feeRecipient(), fee);
            }
        }

        emit Forwarded(depositor, destination, token, amount, fee, amountOut, msg.sender);
    }

    /// @notice L-8: re-attempt delivery of a fee a previous forward had to park because the
    ///         feeRecipient rejected it. Permissionless. No-op (returns 0) when nothing is parked.
    function releaseFee(address token) external nonReentrant returns (uint256 released) {
        released = feeAccrued[token];
        if (released == 0) return 0;
        if (_tryPay(token, registry.feeRecipient(), released)) {
            feeAccrued[token] = 0;
            emit FeeReleased(token, registry.feeRecipient(), released);
        } else {
            released = 0;
        }
    }

    /// @dev The ONLY definition of THIS product's toll, and the mutant seam. One shared library
    ///      (shared/src/FeeMath.sol) so p2/g2a/g2b cannot drift into three copies (GOTCHAS #131).
    ///      With `registry.minFee() == 0` this is byte-for-byte the old `(amount * feeBps) / 10_000`;
    ///      with a minFee set, a sub-floor ticket forwards whole and a small ticket pays >= the floor.
    ///      Floor division, as before. `_toll` is virtual so a negcontrol can re-inject the
    ///      "minFee ignored" bug through the REAL `forward()` path.
    function _toll(uint256 amount) internal view virtual returns (uint256 fee, uint256 out) {
        return FeeMath.toll(amount, registry.feeBps(), registry.minFee());
    }

    /// @dev Safe transfer that tolerates non-bool-returning tokens (USDT class): accepts a `true`
    ///      return or an empty return; anything else is a failure, not a silent pass.
    function _pay(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "native send failed");
        } else {
            (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 transfer failed");
        }
    }

    /// @dev L-8 best-effort variant: like `_pay` but returns false instead of reverting on a
    ///      recipient-side failure. Used for the FEE leg only, so a bad feeRecipient cannot block
    ///      settlement. A `false` return from a token (as opposed to a revert) also counts as failed.
    function _tryPay(address token, address to, uint256 amount) internal returns (bool) {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            return ok;
        } else {
            (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            return ok && (ret.length == 0 || abi.decode(ret, (bool)));
        }
    }
}
