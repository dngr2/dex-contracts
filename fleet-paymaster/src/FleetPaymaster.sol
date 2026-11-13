// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation, UserOperationLib} from "./interfaces/PackedUserOperation.sol";
import {Owned} from "./utils/Owned.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title FleetPaymaster — ERC-4337 v0.7 verifying paymaster for the DEX fleet
/// @notice Sponsors UserOps that call a FLEET contract, and charges the
///         sponsorship back as a SMALL ADDITION TO THE RAIL FEE (a `sponsorBps`
///         surcharge riding the rail's fee) rather than pulling ETH from the
///         sender. The bps is SNAPSHOTTED into the postOp context in validation,
///         so an owner change mid-flight cannot move the price of an in-flight op.
///
/// Design constraints (BUILD-WAVE-1 ground rules):
///   - self-contained: EntryPoint / IPaymaster / PackedUserOperation are vendored
///     under src/interfaces; no lib import beyond forge-std in tests.
///   - non-custodial, non-upgradeable, no selfdestruct.
///   - `nonReentrant` on the value paths (deposit / withdraw).
///
/// What "sponsor" means here: the paymaster's EntryPoint deposit pays the op's
/// gas. It then accrues `sponsorBase * sponsorBps / 10_000` against the sender.
/// `sponsorBase` is the amount word the op carries (see `_parseOp`); for a rail
/// pay that is the payment amount, so the charge is, exactly, an addition to the
/// rail fee. Accruals are an internal ledger the rail/settlement side reads; the
/// paymaster holds no user funds.
contract FleetPaymaster is IPaymaster, Owned, ReentrancyGuard {
    using UserOperationLib for PackedUserOperation;

    // ---- frozen constants ----
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_SPONSOR_BPS = 1_000; // 10% ceiling on the surcharge

    IEntryPoint public immutable entryPoint;

    // ---- sponsorship policy ----
    /// @notice Allowed (target, selector) pairs. Empty selector (bytes4(0)) is a
    ///         whole-target wildcard.
    mapping(address target => mapping(bytes4 selector => bool allowed)) public allowedCall;
    /// @notice Allowed call targets, whole-contract (any selector).
    mapping(address target => bool allowed) public allowedTarget;
    /// @notice Allowed senders, used only when `senderGateOn` is set.
    mapping(address sender => bool allowed) public allowedSender;
    bool public senderGateOn;

    /// @notice Surcharge added to the rail fee, in bps. Snapshotted per op.
    uint16 public sponsorBps = 10; // default 10 bps per the wave doc

    /// @notice Per-sender rate limit: at most `maxOpsPerWindow` ops per
    ///         `rateWindowSeconds`. `maxOpsPerWindow == 0` ⇒ unlimited.
    uint32 public rateWindowSeconds = 60;
    uint32 public maxOpsPerWindow;

    // ---- rate-limit state ----
    mapping(address sender => uint64 windowStart) public windowStartOf;
    mapping(address sender => uint32 opsInWindow) public opsInWindowOf;

    // ---- accounting ----
    /// @notice Accrued sponsorship surcharge per sender (in base-token units).
    mapping(address sender => uint256 accrued) public accruedSponsorFee;
    /// @notice Lifetime sum of the surcharge accrued (observability).
    uint256 public totalAccruedSponsorFee;
    /// @notice Lifetime ETH gas the paymaster actually prefunded via the EntryPoint.
    uint256 public totalSponsoredGasCost;

    // ---- events ----
    event Sponsored(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed target,
        bytes4 selector,
        uint256 sponsorBase,
        uint16 sponsorBps,
        uint256 actualGasCost,
        uint256 surcharge
    );
    event SponsorBpsChanged(uint16 oldBps, uint16 newBps);
    event CallAllowed(address indexed target, bytes4 indexed selector, bool allowed);
    event TargetAllowed(address indexed target, bool allowed);
    event SenderAllowed(address indexed sender, bool allowed);
    event SenderGateChanged(bool on);
    event RateLimitChanged(uint32 windowSeconds, uint32 maxOpsPerWindow);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event AccrualCleared(address indexed sender, uint256 amount);
    event PostOpModeSeen(PostOpMode mode);

    // ---- errors ----
    error NotEntryPoint();
    error NotAllowedCall(address target, bytes4 selector);
    error SenderNotAllowed(address sender);
    error RateLimitExceeded(address sender, uint32 opsInWindow, uint32 max);
    error SponsorBpsTooHigh(uint16 bps, uint16 max);
    error BadCallData(uint256 length);
    error PostOpCalledOutOfBand();
    error NilAmount();

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    constructor(address _entryPoint, address _owner) Owned(_owner) {
        if (_entryPoint == address(0)) revert ZeroAddress();
        entryPoint = IEntryPoint(_entryPoint);
    }

    // =====================================================================
    //                          ERC-4337 v0.7
    // =====================================================================

    /// @inheritdoc IPaymaster
    /// @dev Runs in validation. Reverts (⇒ op rejected) on policy miss, sender
    ///      miss, or rate-limit breach. On success returns a context blob that
    ///      postOp hands back verbatim — carrying the sender, the SNAPSHOTTED
    ///      bps, the parsed sponsor base and target.
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256)
        external
        view
        override
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        (address target, bytes4 selector, uint256 sponsorBase) = _parseOp(userOp.callData);

        // policy: whole-target allow, exact (target,selector), or a bytes4(0)
        // wildcard entry meaning "any selector on this target".
        if (!(allowedTarget[target] || allowedCall[target][selector] || allowedCall[target][bytes4(0)])) {
            revert NotAllowedCall(target, selector);
        }

        // optional sender gate
        if (senderGateOn && !allowedSender[userOp.sender]) revert SenderNotAllowed(userOp.sender);

        // per-sender rate limit (checked here; the counter is bumped in postOp
        // because validate is a view of storage that only postOp may mutate in
        // the same op and we want the bump durable even if the op reverts later)
        uint32 max = maxOpsPerWindow;
        if (max != 0 && _withinWindowCount(userOp.sender) >= max) {
            revert RateLimitExceeded(userOp.sender, opsInWindowOf[userOp.sender], max);
        }

        context = abi.encode(userOpHash, userOp.sender, sponsorBps, sponsorBase, target, selector);
        // validationData = 0 ⇒ valid now, no aggregator, no time bounds.
        return (context, 0);
    }

    /// @inheritdoc IPaymaster
    /// @dev Charges/accrues the surcharge on EVERY mode. `opSucceeded`/`opReverted`
    ///      are the op's own outcome (gas is owed either way); `postOpReverted` is
    ///      the EntryPoint's retry after a first postOp reverted — that attempt's
    ///      state rolled back, so charging again here is correct, not a double.
    ///      The rate window is bumped once per call for the same reason.
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256)
        external
        override
        onlyEntryPoint
    {
        (bytes32 userOpHash, address sender, uint16 bpsSnap, uint256 sponsorBase, address target, bytes4 selector) =
            abi.decode(context, (bytes32, address, uint16, uint256, address, bytes4));

        _bumpWindow(sender);

        uint256 surcharge = (sponsorBase * bpsSnap) / BPS;
        if (surcharge != 0) {
            accruedSponsorFee[sender] += surcharge;
            totalAccruedSponsorFee += surcharge;
        }
        totalSponsoredGasCost += actualGasCost;

        emit Sponsored(userOpHash, sender, target, selector, sponsorBase, bpsSnap, actualGasCost, surcharge);
        emit PostOpModeSeen(mode);
    }

    // =====================================================================
    //                            ADMIN
    // =====================================================================

    function setSponsorBps(uint16 bps) external onlyOwner {
        if (bps > MAX_SPONSOR_BPS) revert SponsorBpsTooHigh(bps, MAX_SPONSOR_BPS);
        emit SponsorBpsChanged(sponsorBps, bps);
        sponsorBps = bps;
    }

    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedCall[target][selector] = allowed;
        emit CallAllowed(target, selector, allowed);
    }

    /// @notice Allow / disallow a whole target (any selector), e.g. to sponsor
    ///         every entry on a rail once its surface is stable.
    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTarget[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function setAllowedSender(address sender, bool allowed) external onlyOwner {
        allowedSender[sender] = allowed;
        emit SenderAllowed(sender, allowed);
    }

    function setSenderGate(bool on) external onlyOwner {
        senderGateOn = on;
        emit SenderGateChanged(on);
    }

    function setRateLimit(uint32 windowSeconds, uint32 maxPerWindow) external onlyOwner {
        rateWindowSeconds = windowSeconds;
        maxOpsPerWindow = maxPerWindow;
        emit RateLimitChanged(windowSeconds, maxPerWindow);
    }

    /// @notice Zero a sender's accrual after it has been settled off-chain.
    function clearAccrual(address sender) external onlyOwner returns (uint256 cleared) {
        cleared = accruedSponsorFee[sender];
        accruedSponsorFee[sender] = 0;
        emit AccrualCleared(sender, cleared);
    }

    // =====================================================================
    //                          ENTRYPOINT DEPOSIT
    // =====================================================================

    /// @notice Fund the paymaster's EntryPoint deposit (the gas prefund source).
    function deposit() external payable nonReentrant {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Owner withdraws the EntryPoint deposit to `to`.
    function withdrawTo(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        entryPoint.withdrawTo(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Post stake so relays treat the paymaster as not-paymaster.
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice This paymaster's live EntryPoint deposit.
    function depositBalance() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // =====================================================================
    //                            VIEWS
    // =====================================================================

    /// @notice Pure preview of the surcharge for a given base amount at the
    ///         current bps (the on-chain charge snapshots bps, see validate).
    function previewSponsorFee(uint256 sponsorBase) external view returns (uint256) {
        return (sponsorBase * sponsorBps) / BPS;
    }

    /// @notice Whether an op with this callData would be sponsored right now.
    function isSponsored(bytes calldata callData) external view returns (bool) {
        (address target, bytes4 selector,) = _parseOp(callData);
        return allowedTarget[target] || allowedCall[target][selector] || allowedCall[target][bytes4(0)];
    }

    /// @notice Current rate-limit count for a sender in the live window.
    function currentWindowCount(address sender) external view returns (uint32) {
        return _withinWindowCount(sender);
    }

    // =====================================================================
    //                            INTERNALS
    // =====================================================================

    /// @dev Parse an op's callData. Convention understood by this paymaster:
    ///        callData = <4-byte account fn selector> ++ abi.encode(address target, uint256 sponsorBase, bytes innerCall)
    ///      where `sponsorBase` is the rail/payment amount the surcharge rides
    ///      and `bytes4(innerCall)` is the selector matched on the allow-list.
    ///      A callData shorter than the head (no innerCall) is treated as a
    ///      target-only call: selector = bytes4(0), sponsorBase = the 2nd word.
    function _parseOp(bytes calldata callData)
        internal
        pure
        returns (address target, bytes4 selector, uint256 sponsorBase)
    {
        uint256 n = callData.length;
        if (n < 4 + 64) revert BadCallData(n); // need fnSel + target + sponsorBase

        // word 0 after the fn selector = target
        target = address(uint160(uint256(bytes32(callData[4:36]))));
        // word 1 = sponsorBase
        sponsorBase = uint256(bytes32(callData[36:68]));

        // optional innerCall selector: head word 2 is the dynamic offset
        if (n >= 4 + 96) {
            uint256 off = uint256(bytes32(callData[68:100]));
            uint256 abs = 4 + off; // start of the bytes' length word
            if (abs + 32 <= n) {
                uint256 len = uint256(bytes32(callData[abs:abs + 32]));
                if (len >= 4 && abs + 32 + 4 <= n) {
                    selector = bytes4(callData[abs + 32:abs + 36]);
                }
            }
        }
    }

    /// @dev Ops counted in the sender's live window (before this op's bump).
    function _withinWindowCount(address sender) internal view returns (uint32) {
        uint64 start = windowStartOf[sender];
        if (start == 0 || block.timestamp >= uint256(start) + rateWindowSeconds) return 0;
        return opsInWindowOf[sender];
    }

    /// @dev Roll the window if stale, then count this op.
    function _bumpWindow(address sender) internal {
        uint64 start = windowStartOf[sender];
        if (start == 0 || block.timestamp >= uint256(start) + rateWindowSeconds) {
            windowStartOf[sender] = uint64(block.timestamp);
            opsInWindowOf[sender] = 1;
        } else {
            opsInWindowOf[sender] += 1;
        }
    }
}
