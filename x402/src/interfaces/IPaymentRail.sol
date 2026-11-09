// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IPaymentRail
/// @notice VENDORED COPY of the frozen common interface published by lane 1 (`products/rails`).
///         The wave brief (products/BUILD-WAVE-1.md) freezes this shape; lane 9 vendors it rather
///         than importing a sibling's `src/` (ground rule: self-contained) so the surface compiles
///         even before `products/rails/` lands. Keep byte-identical to the brief when lane 1 ships.
interface IPaymentRail {
    function feeBps() external view returns (uint16);
    function minFee(address token) external view returns (uint256);
    function quote(address token, uint256 amount) external view returns (uint256 fee, uint256 out);
    function pay(address to, address token, uint256 amount, bytes32 memo, address referrer)
        external payable returns (bytes32 paymentId);
    event Paid(bytes32 indexed paymentId, address indexed payer, address indexed to,
        address token, uint256 amount, uint256 fee, bytes32 memo, address referrer);
}
