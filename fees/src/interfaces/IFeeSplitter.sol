// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice The money-split surface a rail calls when it has collected a fee. The rail approves
/// `fee` of `token` (or sends `fee` as msg.value for the native path) and the splitter fans it out
/// to the referrer and the treasury IN THE SAME CALL.
interface IFeeSplitter {
    /// @notice product = bytes32 product id, payer = who paid, referrer = resolved referrer address.
    event FeeSplit(bytes32 indexed product, address indexed payer, address indexed referrer, uint256 fee, uint256 referrerCut);

    /// @notice Split an ERC-20 fee already approved by msg.sender. referrer == address(0) -> all to treasury.
    function split(address token, uint256 fee, bytes32 product, address payer, address referrer)
        external returns (uint256 referrerCut, uint256 treasuryCut);

    /// @notice Split a native fee (msg.value). referrer the zero address -> all to treasury.
    function splitNative(bytes32 product, address payer, address referrer)
        external payable returns (uint256 referrerCut, uint256 treasuryCut);

    /// @notice claimable[who][token] — balance booked for a payee whose inline transfer failed.
    function claimable(address who, address token) external view returns (uint256);

    /// @notice Pull an accrued balance (reverting-referrer path). token == address(0) is native.
    function claim(address token) external returns (uint256 amount);
}
