// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";
import { BPS } from "@1inch/swap-vm/src/instructions/Fee.sol";

import { IParamOracle } from "../interfaces/IParamOracle.sol";

library ToxicFlowTollArgsBuilder {
    using Calldata for bytes;

    error ToxicFlowTollMissingArgs();
    error ToxicFlowTollMaxTollTooHigh(uint32 maxTollBps);

    /// @dev layout: oracle(20) | maxAgeSeconds(uint32,4) | maxTollBps(uint32,4)
    function build(address oracle, uint32 maxAgeSeconds, uint32 maxTollBps) internal pure returns (bytes memory) {
        require(maxTollBps < BPS, ToxicFlowTollMaxTollTooHigh(maxTollBps));
        return abi.encodePacked(oracle, maxAgeSeconds, maxTollBps);
    }

    function parse(bytes calldata args) internal pure returns (address oracle, uint32 maxAgeSeconds, uint32 maxTollBps) {
        oracle = address(uint160(bytes20(args.slice(0, 20, ToxicFlowTollMissingArgs.selector))));
        maxAgeSeconds = uint32(bytes4(args.slice(20, 24, ToxicFlowTollMissingArgs.selector)));
        maxTollBps = uint32(bytes4(args.slice(24, 28, ToxicFlowTollMissingArgs.selector)));
    }
}

/// @title ToxicFlowToll
/// @notice Custom SwapVM opcode `_toxicFlowToll`: a PER-TAKER surcharge fed by the cross-protocol adverse-selection
///         markout signal. The off-chain agent flags takers with systematically positive post-trade
///         markout and posts a `tollBps` for them; this opcode reads it and widens their price.
/// @dev The surcharge is retained in the pool exactly like `_flatFeeAmountInXD` (ceilDiv, rounding
///      favors the maker). READ-ONLY single staticcall + no persisted state, so quote() == swap() FOR
///      THE SAME taker. It is taker-dependent BY DESIGN (that is the whole point) — different takers
///      get different prices; equality only holds when the quoting and swapping address match.
///      Fails OPEN (toll = 0) on missing/stale data: the global `_loadParamsXD` spread and the
///      `_depegCircuitBreaker` cover systemic risk, so a dead agent must not over-toll honest flow.
contract ToxicFlowToll {
    using ContextLib for Context;

    error ToxicFlowTollMustPrecedeSwap();
    error ToxicFlowTollOutOfRange(uint256 tollBps);

    /// @dev args: oracle(20) | maxAgeSeconds(4) | maxTollBps(4). Wraps the rest via ctx.runLoop().
    function _toxicFlowToll(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ToxicFlowTollMustPrecedeSwap());
        (address oracle, uint32 maxAgeSeconds, uint32 maxTollBps) = ToxicFlowTollArgsBuilder.parse(args);

        uint256 tollBps = 0; // fail-open
        if (oracle != address(0)) {
            (bool ok, bytes memory res) = oracle.staticcall(
                abi.encodeCall(IParamOracle.getToll, (ctx.query.orderHash, ctx.query.taker))
            );
            if (ok && res.length == 64) {
                (uint32 t, uint40 updatedAt) = abi.decode(res, (uint32, uint40));
                bool fresh = updatedAt != 0 && block.timestamp <= uint256(updatedAt) + maxAgeSeconds;
                if (fresh && t <= maxTollBps) {
                    tollBps = t;
                }
            }
        }
        require(tollBps <= BPS, ToxicFlowTollOutOfRange(tollBps));

        if (ctx.query.isExactIn) {
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            ctx.swap.amountIn -= Math.ceilDiv(ctx.swap.amountIn * tollBps, BPS);
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            ctx.runLoop();
            ctx.swap.amountIn += Math.ceilDiv(ctx.swap.amountIn * tollBps, BPS - tollBps);
        }
    }
}
