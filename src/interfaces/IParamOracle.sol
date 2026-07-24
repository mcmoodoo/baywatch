// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IParamOracle
/// @notice Read interface the Baywatch opcodes staticcall each swap, keyed by strategy orderHash.
/// @dev depegTier: 0 = NORMAL, 1 = DEFENSIVE (one-directional), 2 = HALT (revert all).
interface IParamOracle {
    /// @notice Global spread for a strategy (read by `_loadParamsXD`).
    /// @return spreadBps active swap spread in 1e9 bps (1e9 = 100%)
    /// @return updatedAt block.timestamp of the last global post (0 = never)
    function getParams(bytes32 key) external view returns (uint32 spreadBps, uint40 updatedAt);

    /// @notice Depeg/risk regime for a strategy (read by `_depegCircuitBreaker`).
    /// @return depegTier 0 NORMAL / 1 DEFENSIVE / 2 HALT
    /// @return riskToken the at-risk leg; in DEFENSIVE mode swaps that grow maker exposure to it revert
    /// @return updatedAt block.timestamp of the last global post (0 = never)
    function getRisk(bytes32 key) external view returns (uint8 depegTier, address riskToken, uint40 updatedAt);

    /// @notice Per-taker toxic-flow toll for a strategy (read by `_toxicFlowToll`).
    /// @return tollBps surcharge in 1e9 bps applied to this taker (0 = none)
    /// @return updatedAt block.timestamp of the last toll post for this taker (0 = never)
    function getToll(bytes32 key, address taker) external view returns (uint32 tollBps, uint40 updatedAt);
}
