// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import { IParamOracle } from "../interfaces/IParamOracle.sol";
import { IMsgSender } from "./IMsgSender.sol";

/// @title BaywatchV4Hook
/// @notice The SAME Baywatch defense that powers our 1inch Aqua pool, expressed as a Uniswap v4 hook — one
///         Graph-fetched toxicity signal, one ParamOracle, two defended venues. The oracle is keyed by
///         bytes32, so the v4 PoolId slots in exactly where the SwapVM orderHash does; the off-chain agent
///         posts the identical three signals and this hook maps them onto v4 primitives:
///           market toxicity index  -> dynamic LP fee override        (global spread)
///           cross-venue reputation -> per-swapper fee surcharge      (the toll)
///           depeg regime           -> revert / one-directional pool  (the circuit breaker)
/// @dev Deploy at an address whose low 14 bits are exactly BEFORE_SWAP_FLAG (1 << 7) — the pool must be
///      initialized with LPFeeLibrary.DYNAMIC_FEE_FLAG for the fee override to be honored.
///
///      Swapper identity: `sender` is the router that called PoolManager.swap. For allowlisted routers we
///      recover the real swapper via Uniswap's official IMsgSender pattern; for unknown callers the caller
///      IS the identity (it accumulates its own reputation — rotating contracts is the provenance layer's
///      problem, same as rotating wallets). The allowlist is mandatory: msgSender() is unauthenticated and
///      an arbitrary contract could return any address (spoof/griefing).
///
///      Fail semantics mirror the SwapVM opcodes: spread fails SAFE to `maxFeePips` (missing/stale oracle
///      => maximum defensive fee), the per-swapper toll fails OPEN to 0 (a dead agent must not over-toll
///      honest flow), and the regime falls back to `staleTier`.
contract BaywatchV4Hook {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant TIER_NORMAL = 0;
    uint8 internal constant TIER_DEFENSIVE = 1;
    uint8 internal constant TIER_HALT = 2;

    /// @dev Oracle stores 1e9-scale bps (1e9 = 100%); v4 LP fees are pips (1e6 = 100%).
    uint256 internal constant BPS_PER_PIP = 1000;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable ORACLE;
    uint32 public immutable MAX_AGE_SECONDS;
    uint24 public immutable MAX_FEE_PIPS;   // spread cap AND its fail-safe default
    uint24 public immutable MAX_TOLL_PIPS;  // per-swapper toll cap (fail-open beyond it)
    uint8 public immutable STALE_TIER;      // regime fallback when oracle data is stale

    address public owner;
    mapping(address router => bool trusted) public trustedRouters;

    event TrustedRouterSet(address indexed router, bool trusted);
    event BaywatchDefense(bytes32 indexed poolId, address indexed taker, uint24 spreadPips, uint24 tollPips, uint8 tier);

    error NotPoolManager();
    error NotOwner();
    error FeeCapTooHigh();
    error BaywatchHalted(bytes32 poolId);
    error BaywatchDefensiveRejected(bytes32 poolId, address riskToken);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPoolManager poolManager,
        address oracle,
        uint32 maxAgeSeconds,
        uint24 maxFeePips,
        uint24 maxTollPips,
        uint8 staleTier,
        address owner_
    ) {
        if (maxFeePips > LPFeeLibrary.MAX_LP_FEE || maxTollPips > LPFeeLibrary.MAX_LP_FEE) revert FeeCapTooHigh();
        POOL_MANAGER = poolManager;
        ORACLE = oracle;
        MAX_AGE_SECONDS = maxAgeSeconds;
        MAX_FEE_PIPS = maxFeePips;
        MAX_TOLL_PIPS = maxTollPips;
        STALE_TIER = staleTier;
        owner = owner_;
    }

    function setOwner(address owner_) external onlyOwner {
        owner = owner_;
    }

    /// @notice Allowlist a router that implements Uniswap's IMsgSender (e.g. the Universal Router).
    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        trustedRouters[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    /// @notice The only hook v4 calls on us (address carries only BEFORE_SWAP_FLAG).
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        bytes32 poolId = PoolId.unwrap(key.toId());

        // 1. Regime guard (mirrors _depegCircuitBreaker): HALT reverts; DEFENSIVE rejects swaps where the
        //    pool RECEIVES the at-risk token (grows the LPs' exposure) and only lets takers buy it out.
        (uint8 tier, address riskToken) = _regime(poolId);
        if (tier == TIER_HALT) revert BaywatchHalted(poolId);
        if (tier == TIER_DEFENSIVE) {
            address tokenIn = params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
            if (tokenIn == riskToken) revert BaywatchDefensiveRejected(poolId, riskToken);
        }

        // 2. Resolve the real swapper (official allowlist + IMsgSender pattern; unknown caller = identity).
        address taker = _resolveTaker(sender);

        // 3. Market toxicity index -> global spread (fail-SAFE to the max defensive fee).
        uint24 spreadPips = _spreadPips(poolId);

        // 4. Cross-venue reputation -> per-swapper toll (fail-OPEN to 0).
        uint24 tollPips = _tollPips(poolId, taker);

        uint256 fee = uint256(spreadPips) + uint256(tollPips);
        if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;

        emit BaywatchDefense(poolId, taker, spreadPips, tollPips, tier);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uint24(fee) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ----- internal reads (raw staticcalls, malformed responses fall through to the fail defaults) -----

    function _resolveTaker(address sender) internal view returns (address) {
        if (trustedRouters[sender]) {
            (bool ok, bytes memory res) = sender.staticcall(abi.encodeCall(IMsgSender.msgSender, ()));
            if (ok && res.length == 32) {
                address swapper = abi.decode(res, (address));
                if (swapper != address(0)) return swapper;
            }
        }
        return sender;
    }

    function _regime(bytes32 poolId) internal view returns (uint8 tier, address riskToken) {
        tier = STALE_TIER;
        (bool ok, bytes memory res) = ORACLE.staticcall(abi.encodeCall(IParamOracle.getRisk, (poolId)));
        if (ok && res.length == 96) {
            (uint8 depegTier, address rt, uint40 updatedAt) = abi.decode(res, (uint8, address, uint40));
            bool fresh = updatedAt != 0 && block.timestamp <= uint256(updatedAt) + MAX_AGE_SECONDS;
            tier = fresh ? depegTier : STALE_TIER;
            riskToken = rt;
        }
    }

    function _spreadPips(bytes32 poolId) internal view returns (uint24) {
        uint256 pips = MAX_FEE_PIPS; // fail-safe: maximum defensive fee
        (bool ok, bytes memory res) = ORACLE.staticcall(abi.encodeCall(IParamOracle.getParams, (poolId)));
        if (ok && res.length == 64) {
            (uint32 sBps, uint40 updatedAt) = abi.decode(res, (uint32, uint40));
            bool fresh = updatedAt != 0 && block.timestamp <= uint256(updatedAt) + MAX_AGE_SECONDS;
            uint256 p = uint256(sBps) / BPS_PER_PIP;
            if (fresh && p <= MAX_FEE_PIPS) pips = p;
        }
        return uint24(pips);
    }

    function _tollPips(bytes32 poolId, address taker) internal view returns (uint24) {
        uint256 pips = 0; // fail-open
        (bool ok, bytes memory res) = ORACLE.staticcall(abi.encodeCall(IParamOracle.getToll, (poolId, taker)));
        if (ok && res.length == 64) {
            (uint32 tBps, uint40 updatedAt) = abi.decode(res, (uint32, uint40));
            bool fresh = updatedAt != 0 && block.timestamp <= uint256(updatedAt) + MAX_AGE_SECONDS;
            uint256 p = uint256(tBps) / BPS_PER_PIP;
            if (fresh && p <= MAX_TOLL_PIPS) pips = p;
        }
        return uint24(pips);
    }
}
