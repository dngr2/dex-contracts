// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev The ONLY slice of the P2 Registry that RequestRegistry uses. Kept as its own interface
///      (mirroring IRegistry.sol) so the F1-a dependency is explicit and narrow: it can mint a
///      deposit address and predict one — nothing else. Signature is byte-identical to
///      Registry.register/predict, so a real Registry satisfies it with no adapter.
interface IP2Registry {
    function register(address destination) external returns (address depositAddr);
    function predict(address owner_, address destination) external view returns (address);
}
