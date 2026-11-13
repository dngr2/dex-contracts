// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IStreamRail — recurring-mandate rail (payer-signed), permissionless lap execution
/// @notice The integrator shape for setting and driving subscriptions as ON-CHAIN MANDATES. A payer
///         signs a mandate (so a wallet or subscription app can set it with the payer's signature);
///         once set, `executeLap` is PERMISSIONLESS — anyone (a keeper, the recipient, a bot) may fire
///         the next lap, because the authorization already lives in the mandate, not in the caller.
///
/// @dev SOURCE: roadmap p.5 (StreamFactory + StreamVault mandates table) + p.7. FROZEN for BUILD WAVE 1.
///
///      `setMandateFor(payer, …, sig)` is the SIGNED portal (an app sets a mandate on the user's
///      behalf from an EIP-712 approval). A mandate is addressable by its `mandateId` (bytes32).
///      `mandatesOf(payer)` and `dueLaps(fromMandateId, count)` are the ONE view path for keepers and
///      dashboards, so nobody has to reconstruct due-ness off-chain.
///
///      Each lap ENFORCES, in the mandate's own frame: allowance >= ticket, block.timestamp >=
///      nextLapAt, lapsLeft > 0; it sets start = nextLapAt, end = start + period, and decrements.
///      There is no caller check on the lap — that is the point.
interface IStreamRail {
    /// @notice A signed recurring mandate. Immutable terms (recipient/token/ticket/period/laps/
    ///         referrer) plus the live cursors the executor advances (nextLapAt, lapsLeft).
    /// @param payer    the account whose allowance funds every lap
    /// @param recipient who each lap's vault pays
    /// @param token    the ERC20 pulled per lap
    /// @param ticket   amount of `token` per lap
    /// @param period   seconds between laps
    /// @param laps     total laps authorised
    /// @param referrer attributed on the referral ledger (may be address(0))
    /// @param nextLapAt unix seconds at/after which the next lap may fire
    /// @param lapsLeft laps still unfired
    struct Mandate {
        address payer;
        address recipient;
        address token;
        uint256 ticket;
        uint64 period;
        uint32 laps;
        address referrer;
        uint64 nextLapAt;
        uint32 lapsLeft;
    }

    /// @notice Set a mandate for `payer`, authorised by `sig`. The deployer/app is the tx sender; the
    ///         mandate binds the PAYER's allowance, so no separate `approve` call from the payer is
    ///         needed at set time beyond what `sig` authorises.
    /// @return mandateId The id the mandate is addressable by.
    function setMandateFor(
        address payer,
        address recipient,
        address token,
        uint256 ticket,
        uint64 period,
        uint32 laps,
        address referrer,
        bytes calldata sig
    ) external returns (bytes32 mandateId);

    /// @notice Fire the next due lap of `mandateId`. PERMISSIONLESS — no caller check. Reverts if the
    ///         lap is not yet due, the mandate is exhausted, or the payer's allowance is short.
    /// @return vault The vault created (or reused) for this lap.
    function executeLap(bytes32 mandateId) external returns (address vault);

    /// @notice The ids of the mandates that are DUE now, starting at `fromMandateId` (exclusive) and
    ///         returning at most `count`. One read path for keepers: ask what to fire, then fire it.
    function dueLaps(bytes32 fromMandateId, uint256 count) external view returns (bytes32[] memory);

    /// @notice Every mandate id for `payer`, so a dashboard can render a payer's full book.
    function mandatesOf(address payer) external view returns (bytes32[] memory);

    /// @notice The full mandate record for `mandateId`.
    function getMandate(bytes32 mandateId) external view returns (Mandate memory);

    /// @notice Revoke a not-yet-exhausted mandate (payer-only). The `MandateRevoked` event is the
    ///         terminal marker; `executeLap` on a revoked mandate reverts.
    function revokeMandate(bytes32 mandateId) external;

    /// @notice Emitted when a mandate is set. All terms ride the event so a chain-only reader can
    ///         reconstruct the mandate without a storage read (mirrors P2's Registered event role).
    event MandateSet(
        bytes32 indexed mandateId,
        address indexed payer,
        address recipient,
        address token,
        uint256 ticket,
        uint64 period,
        uint32 laps,
        address referrer
    );

    /// @notice Emitted on each executed lap.
    event LapExecuted(
        bytes32 indexed mandateId,
        address indexed vault,
        uint32 lapIndex,
        uint64 start,
        uint64 end
    );

    /// @notice Emitted when a mandate is revoked.
    event MandateRevoked(bytes32 indexed mandateId);
}
