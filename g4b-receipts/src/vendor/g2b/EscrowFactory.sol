// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Escrow} from "./Escrow.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title EscrowFactory — the only contract a user calls
/// @notice `create(counterparty, token, amount, hash, timeout) -> escrow address, done.` Deploys a
///         fresh CREATE2 Escrow and funds it in the same tx. This is the product:
///         "lock a trade safe, share the address, counterparty releases or it times out."
///
/// SHAPE REUSE (deliberate, so the fee-ledger tooling reads it unchanged — critic's build rule)
///   - owner / feeBps / feeRecipient / paused / MAX_FEE_BPS / onlyOwner — copied from P2 Registry.
///   - setFeeBps / setFeeRecipient / setPaused / transferOwnership — same names + events.
///   - predict() before deploy, CREATE2 salary binding (owner, nonce, params) — same discipline.
///   - Escrow reads `IEscrowFactory.feeBps()/feeRecipient()` exactly like Forwarder reads IRegistry.
///
/// FUNDS NEVER TOUCH THE FACTORY: `create` predicts the escrow address, pulls the payer's tokens
/// DIRECTLY to that address (transferFrom payer -> escrow), THEN deploys. The Escrow's constructor
/// measures its own balance. So there is no factory-held-funds moment and no "sweep the factory"
/// step. The payer must first `approve(factory, amount)` on the token.
///
/// DEFAULT FEE: bps on RELEASE only, nothing on refund (critic ruling). Default 25 bps to match the
/// P2 precedent; owner-settable below a 5% ceiling.
contract EscrowFactory {
    address public owner;

    uint16 public feeBps;
    address public feeRecipient;
    /// @dev Per-release minimum toll, in TOKEN BASE UNITS (see FeeMath). 0 = legacy: plain bps fee,
    ///      and a sub-floor release forwards whole. Owner-settable.
    uint256 public minFee;
    bool public paused;

    uint16 public constant MAX_FEE_BPS = 500;   // 5% ceiling
    uint64 public constant MIN_TIMEOUT = 10 minutes;   // refund window floor (a DURATION)
    uint64 public constant MAX_TIMEOUT = 365 days;     // refund window ceiling (a DURATION)

    /// @dev Deal params as a struct: keeps `createFor` off the stack-too-deep edge, and gives the page
    ///      one static tuple to encode (all fields static => flat head, no inner offsets).
    struct Deal {
        address counterparty;
        address arbiter;     // address(0) => hashlock-only
        address token;
        uint256 amount;
        bytes32 hash;        // keccak256(preimage); bytes32(0) => arbiter-only
        uint64 timeout;      // unix seconds; refund opens here
    }

    /// @dev per-owner nonce, so the same params can be escrowed twice.
    mapping(address => uint256) public nonce;
    /// @dev owner -> list of escrows they created.
    mapping(address => address[]) public escrowsOf;

    /// @dev The page reads this to render a shared link without storage reads: params + amount on the
    ///      event, so a chain-only reader resolves escrow -> deal. Mirrors P2's Registered event role.
    event Created(
        address indexed payer,
        address indexed escrow,
        address indexed counterparty,
        address token,
        uint256 amount,
        bytes32 hash,
        address arbiter,
        uint64 timeout,
        bytes32 salt,
        uint256 index
    );
    event FeeBpsSet(uint16 bps);
    event FeeRecipientSet(address recipient);
    event MinFeeSet(uint256 minFee);
    event PausedSet(bool paused);
    event OwnerSet(address owner);

    error NotOwner();
    error BadFee();
    error ZeroArg();
    error Paused();
    error BadTimeout();
    error DeployFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param feeBps_ in bps (25 = 0.25%). Default set by the deployer.
    constructor(address owner_, address feeRecipient_, uint16 feeBps_) {
        if (owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroArg();
        if (feeBps_ > MAX_FEE_BPS) revert BadFee();
        owner = owner_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    // ---- the product ----

    /// @notice Create a hashlock+timeout escrow (no arbiter). See createFor.
    function create(address counterparty, address token, uint256 amount, bytes32 hash, uint64 timeout)
        external
        returns (address escrow)
    {
        Deal memory d =
            Deal(counterparty, address(0), token, amount, hash, timeout);
        return createFor(d);
    }

    /// @notice Create an escrow and pull `d.amount` of `d.token` from the caller into it.
    function createFor(Deal memory d) public virtual returns (address escrow) {
        if (paused) revert Paused();
        if (d.counterparty == address(0) || d.token == address(0) || d.amount == 0) revert ZeroArg();
        if (d.hash == bytes32(0) && d.arbiter == address(0)) revert ZeroArg(); // need SOME release path
        if (d.timeout < MIN_TIMEOUT || d.timeout > MAX_TIMEOUT) revert BadTimeout();

        uint256 idx = nonce[msg.sender]++;
        bytes32 salt = _salt(msg.sender, idx, d);
        bytes memory initCode = _initCode(msg.sender, d);
        escrow = _predictAddr(salt, initCode);

        // fund FIRST (predictable address), then deploy — funds go payer -> escrow, never via here.
        _pullFrom(msg.sender, escrow, d.token, d.amount);
        address created = _deploy(salt, initCode);
        if (created != escrow) revert DeployFailed();   // parity pin: derivation must match CREATE2

        escrowsOf[msg.sender].push(escrow);
        emit Created(
            msg.sender, escrow, d.counterparty, d.token, d.amount, d.hash, d.arbiter, d.timeout, salt, idx
        );
    }

    /// @notice Address `createFor` WOULD produce for (payer, currentNonce, params). Lets a share
    ///         link be built with no tx.
    function predict(address payer, Deal memory d) external view returns (address) {
        bytes32 salt = _salt(payer, nonce[payer], d);
        return _predictAddr(salt, _initCode(payer, d));
    }

    /// @dev salt binds payer+nonce+all params — distinct callers/args can't collide.
    function _salt(address payer, uint256 idx, Deal memory d) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(payer, idx, d.counterparty, d.arbiter, d.token, d.amount, d.hash, d.timeout)
        );
    }

    /// @dev creation code = Escrow bytecode ++ abi-encoded constructor args.
    function _initCode(address payer, Deal memory d) internal view virtual returns (bytes memory) {
        return abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(
                address(this), payer, d.counterparty, d.arbiter, d.token, d.hash, d.timeout, d.amount
            )
        );
    }

    /// @dev CREATE2 address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:].
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

    /// @dev pull `amount` token from payer directly to the (predicted, not-yet-deployed) escrow.
    function _pullFrom(address from, address to, address token, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transferFrom failed");
    }

    // ---- admin (same names/events as P2 Registry) ----

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert BadFee();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    /// @notice Set the per-release minimum toll (token base units). 0 = legacy. No ceiling needed:
    ///         a minFee above the ticket just skips the toll (FeeMath), never strands funds.
    function setMinFee(uint256 minFee_) external onlyOwner {
        minFee = minFee_;
        emit MinFeeSet(minFee_);
    }

    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0)) revert ZeroArg();
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function transferOwnership(address o) external onlyOwner {
        if (o == address(0)) revert ZeroArg();
        owner = o;
        emit OwnerSet(o);
    }

    function escrowCount(address payer) external view returns (uint256) {
        return escrowsOf[payer].length;
    }
}
