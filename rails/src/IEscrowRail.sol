// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IEscrowRail — escrow rail shape with a referrer and a terminal `outcome()`
/// @notice The integrator-facing shape for the fleet's escrow factory. A caller creates a deal for a
///         counterparty (optionally attributing a referrer, or supplying a payer signature) and reads
///         the terminal outcome off the escrow rather than inferring it from the `settled` bool.
///
/// @dev SOURCE: roadmap p.4 (EscrowFactory + Escrow table) + p.7. FROZEN for BUILD WAVE 1.
///
///      `outcome()` RETURNS uint8 {0 open, 1 released, 2 refunded}. This exists because the live v1
///      `settled` bool is TRUE after EITHER release OR refund (audit M-3), so a downstream reader that
///      treats "settled" as "the counterparty was PAID" is wrong on a refund. `outcome()` is the one
///      honest discriminator; a consumer that needs "was the counterparty paid" MUST check `== 1`.
interface IEscrowRail {
    /// @notice A deal's terms. `hook` is optional (address(0) => none); when set, the escrow calls
    ///         `IEscrowHook.onEscrowSettled` on release/refund inside a try/catch with a 100k gas cap.
    /// @param counterparty the party who receives on release (and reveals the preimage, if hashlocked)
    /// @param arbiter      the third party who may release/refund; address(0) => hashlock-only
    /// @param token        ERC20 address; address(0) => native ETH (payable create path)
    /// @param amount       escrowed amount, in `token` units
    /// @param hash         keccak256(preimage); bytes32(0) => arbiter-only (no hashlock)
    /// @param timeout      unix seconds; refund opens here
    /// @param releaseGrace seconds after `timeout` during which release still wins; then refund-only
    /// @param hook         optional post-settlement notifier (IEscrowHook); address(0) => none
    struct Deal {
        address counterparty;
        address arbiter;
        address token;
        uint256 amount;
        bytes32 hash;
        uint64 timeout;
        uint64 releaseGrace;
        address hook;
    }

    /// @notice Create an escrow for `d`, crediting `referrer` on the referral ledger. Pays from
    ///         msg.sender. `payable` so a native-ETH deal (`d.token == address(0)`) can fund it.
    /// @return escrow The deployed escrow address (the deal's on-chain handle).
    function createFor(Deal calldata d, address referrer) external payable returns (address escrow);

    /// @notice Create an escrow on behalf of `payer`, authorised by `sig` (an EIP-712/ERC-2612-style
    ///         approval from `payer`), so an integrator can escrow for a user who is not the tx sender.
    /// @return escrow The deployed escrow address.
    function createForPayer(Deal calldata d, address payer, bytes calldata sig)
        external
        payable
        returns (address escrow);

    /// @notice The terminal state of this escrow: 0 = open, 1 = released (counterparty paid),
    ///         2 = refunded (payer made whole). Read THIS, not a `settled` bool, to discriminate.
    function outcome() external view returns (uint8);

    /// @notice After settlement, return post-construction deposits (overpayments, stray native ETH)
    ///         to the payer. No-op-safe to call when there is nothing to sweep.
    /// @return amount The amount returned to the payer.
    function sweepExcess() external returns (uint256 amount);

    /// @notice Emitted on the release leg. `preimage` proves the hashlock on a hashlocked deal.
    event Released(
        bytes32 indexed preimage,
        address indexed to,
        uint256 amountIn,
        uint256 fee,
        uint256 out,
        address by
    );

    /// @notice Emitted on the refund leg.
    event Refunded(address indexed to, uint256 amount, address by);
}
