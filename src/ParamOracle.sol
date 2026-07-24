// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IParamOracle } from "./interfaces/IParamOracle.sol";

/// @title ParamOracle
/// @notice Agent-writable, per-strategy parameter store read by the Baywatch opcodes every swap.
///         The off-chain agent computes risk from The Graph (market toxicity index, per-taker markout, depeg regime)
///         and posts it here; the *next* swap reprices with NO re-ship (fast path).
/// @dev Superset store serving all Baywatch opcodes without forking the base:
///        - global  {spreadBps, depegTier, riskToken, updatedAt}  keyed by orderHash
///        - per-taker {tollBps, updatedAt}                          keyed by (orderHash, taker)
contract ParamOracle is IParamOracle {
    uint8 internal constant TIER_NORMAL = 0;
    uint8 internal constant TIER_DEFENSIVE = 1;
    uint8 internal constant TIER_HALT = 2;

    struct Global {
        uint32 spreadBps;  // swap spread in 1e9 bps
        uint8 depegTier;   // 0 NORMAL / 1 DEFENSIVE / 2 HALT
        address riskToken; // at-risk leg (DEFENSIVE direction guard)
        uint40 updatedAt;  // last global post
    }

    struct Toll {
        uint32 tollBps;   // per-taker surcharge in 1e9 bps
        uint40 updatedAt; // last toll post
    }

    address public poster;

    mapping(bytes32 => Global) internal _globalOf;
    mapping(bytes32 => mapping(address => Toll)) internal _tollOf;

    event PosterUpdated(address indexed poster);
    event ParamsPosted(bytes32 indexed key, uint32 spreadBps, uint40 updatedAt);
    event RiskPosted(bytes32 indexed key, uint8 depegTier, address riskToken, uint40 updatedAt);
    event TollPosted(bytes32 indexed key, address indexed taker, uint32 tollBps, uint40 updatedAt);

    error NotPoster();

    modifier onlyPoster() {
        if (msg.sender != poster) revert NotPoster();
        _;
    }

    constructor(address poster_) {
        poster = poster_;
        emit PosterUpdated(poster_);
    }

    function setPoster(address poster_) external onlyPoster {
        poster = poster_;
        emit PosterUpdated(poster_);
    }

    // ----- agent fast-path writes (next swap reprices; no re-ship) -----

    /// @notice Post the global spread (read-modify-write; leaves depegTier/riskToken).
    function setParams(bytes32 key, uint32 spreadBps) external onlyPoster {
        Global storage g = _globalOf[key];
        g.spreadBps = spreadBps;
        g.updatedAt = uint40(block.timestamp);
        emit ParamsPosted(key, spreadBps, uint40(block.timestamp));
    }

    /// @notice Post the depeg/risk regime (read-modify-write; leaves spreadBps).
    function setRisk(bytes32 key, uint8 depegTier, address riskToken) external onlyPoster {
        Global storage g = _globalOf[key];
        g.depegTier = depegTier;
        g.riskToken = riskToken;
        g.updatedAt = uint40(block.timestamp);
        emit RiskPosted(key, depegTier, riskToken, uint40(block.timestamp));
    }

    /// @notice Post a per-taker toxic-flow toll.
    function setToll(bytes32 key, address taker, uint32 tollBps) external onlyPoster {
        Toll storage t = _tollOf[key][taker];
        t.tollBps = tollBps;
        t.updatedAt = uint40(block.timestamp);
        emit TollPosted(key, taker, tollBps, uint40(block.timestamp));
    }

    // ----- reads (staticcall-friendly; consumed by the opcodes) -----

    /// @inheritdoc IParamOracle
    function getParams(bytes32 key) external view returns (uint32 spreadBps, uint40 updatedAt) {
        Global memory g = _globalOf[key];
        return (g.spreadBps, g.updatedAt);
    }

    /// @inheritdoc IParamOracle
    function getRisk(bytes32 key) external view returns (uint8 depegTier, address riskToken, uint40 updatedAt) {
        Global memory g = _globalOf[key];
        return (g.depegTier, g.riskToken, g.updatedAt);
    }

    /// @inheritdoc IParamOracle
    function getToll(bytes32 key, address taker) external view returns (uint32 tollBps, uint40 updatedAt) {
        Toll memory t = _tollOf[key][taker];
        return (t.tollBps, t.updatedAt);
    }
}
