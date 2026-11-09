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

    uint16 public feeBps;               // default 25 (P2 parity)
    address public feeRecipient;
    bool public paused;

    uint16 public constant MAX_FEE_BPS = 500;   // 5% ceiling
    uint256 public constant MIN_DURATION = 60;  // 1 min: below this, per-second is meaningless

    mapping(address => uint256) public nonce;
    mapping(address => address[]) public streamsOf;

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
    event PausedSet(bool paused);
    event OwnerSet(address owner);

    error NotOwner();
    error BadFee();
    error ZeroArg();
    error Paused();
    error BadWindow();
    error FundingFailed();
    error DeployFailed();

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

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert BadFee();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    /// @dev Live-read by vaults at withdrawal, so a change applies to EXISTING streams from the next
    ///      pull. The escrowed principal is untouched either way — only the split moves.
    function setFeeRecipient(address r) external onlyOwner {
        require(r != address(0), "zero");
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function transferOwnership(address o) external onlyOwner {
        require(o != address(0), "zero");
        owner = o;
        emit OwnerSet(o);
    }

    function streamCount(address payer) external view returns (uint256) {
        return streamsOf[payer].length;
    }
}
