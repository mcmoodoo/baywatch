// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Uniswap's official pattern for hooks to recover the original swapper: v4 periphery routers
///         (Universal Router, V4Router) implement this so a hook can call IMsgSender(sender).msgSender()
///         during beforeSwap. Vendored from Uniswap v4-periphery, src/interfaces/IMsgSender.sol.
/// @dev UNAUTHENTICATED by design — any contract can claim any address. Callers MUST gate this lookup on
///      a trusted-router allowlist (see the official docs guide "Access msg.sender Inside a Hook").
interface IMsgSender {
    function msgSender() external view returns (address);
}
