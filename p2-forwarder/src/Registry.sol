// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Forwarder} from "./Forwarder.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

/// @title Registry — the only contract an integrator calls
/// @notice `register(destination)` mints the caller a personal deposit address (a CREATE2-deployed
///         Forwarder) that auto-forwards to that destination. This is the product:
///         "register(destination) -> deposit address, done."
///
/// CLEAN-ROOM: a fresh contract at fresh addresses. It does not read, call, or coordinate with any
/// existing forwarder channels — "honest racer" means a race our contract wins on its own terms.
///
/// WHY CREATE2: addresses are salt-derived, so an integrator can show the deposit address BEFORE the
/// tx via `predict()` and it is reproducible client-side. Salt binds (owner, nonce, destination) so
/// distinct callers/salts cannot collide.
///
/// DEPLOYED FULL CONTRACTS, NOT CLONES — see Forwarder header: a clone cannot survive the 2300-gas
/// `.transfer()` stipend. `predict()` therefore hashes the real creation code, incl. constructor args.
contract Registry is IRegistry {
    address public owner;

    uint16 public feeBps;
    address public feeRecipient;
    bool public paused;

    uint16 public constant MAX_FEE_BPS = 500;   // 5% ceiling

    /// @dev per-owner nonce, so the same (owner, destination) can be registered twice if wanted.
    mapping(address => uint256) public nonce;
    /// @dev owner -> list of deposit addresses they created (integrators index their own users).
    mapping(address => address[]) public depositsOf;

    /// @dev The daemon CACHES this: at registration it learns every deposit address and its
    ///      destination, so per-deposit forwarding never re-reads the registry.
    ///      `tokenAgnostic` is informational (we forward whatever arrives).
    event Registered(
        address indexed owner,
        address indexed depositAddr,
        address indexed destination,
        bool tokenAgnostic,
        bytes32 salt,
        uint256 index
    );
    event FeeBpsSet(uint16 bps);
    event FeeRecipientSet(address recipient);
    event PausedSet(bool paused);
    event OwnerSet(address owner);

    error NotOwner();
    error BadFee();
    error ZeroDest();
    error Paused();
    error CloneFailed();

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

    /// @notice Mint the caller a personal deposit address forwarding to `destination`.
    function register(address destination) external returns (address depositAddr) {
        return register(destination, true);
    }

    /// @param tokenAgnostic informational; forwarded to the event for integrators.
    function register(address destination, bool tokenAgnostic) public returns (address depositAddr) {
        if (paused) revert Paused();
        if (destination == address(0)) revert ZeroDest();

        uint256 idx = nonce[msg.sender]++;
        bytes32 salt = _salt(msg.sender, idx, destination);
        bytes memory initCode = _initCode(destination);
        depositAddr = _predictAddr(salt, initCode);

        address created = _deploy(salt, initCode);
        if (created != depositAddr) revert CloneFailed();   // parity pin: derivation must match CREATE2

        depositsOf[msg.sender].push(depositAddr);
        emit Registered(msg.sender, depositAddr, destination, tokenAgnostic, salt, idx);
    }

    /// @notice Address `register` WOULD produce for (owner, currentNonce, destination). Lets an
    ///         integrator display the deposit address with no tx.
    function predict(address owner_, address destination) external view returns (address) {
        return _predictAddr(_salt(owner_, nonce[owner_], destination), _initCode(destination));
    }

    /// @dev salt binds owner+nonce+destination — distinct callers can't collide.
    function _salt(address owner_, uint256 idx, address destination) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner_, idx, destination));
    }

    /// @dev creation code = Forwarder bytecode ++ abi-encoded constructor args. `virtual` so a
    ///      negcontrol factory can spawn a mutant Forwarder through the REAL register path.
    function _initCode(address destination) internal view virtual returns (bytes memory) {
        return abi.encodePacked(type(Forwarder).creationCode, abi.encode(address(this), destination));
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
        if (inst == address(0)) revert CloneFailed();
    }

    // ---- admin ----

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert BadFee();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

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

    function depositCount(address owner_) external view returns (uint256) {
        return depositsOf[owner_].length;
    }
}
