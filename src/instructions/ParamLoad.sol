// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";
import { BPS } from "@1inch/swap-vm/src/instructions/Fee.sol";

import { IParamOracle } from "../interfaces/IParamOracle.sol";

library ParamLoadArgsBuilder {
    using Calldata for bytes;

    error ParamLoadMissingArgs();
    error ParamLoadMaxSpreadTooHigh(uint32 maxSpreadBps);

    /// @dev layout: oracle(20) | maxAgeSeconds(uint32,4) | maxSpreadBps(uint32,4)
    function build(address oracle, uint32 maxAgeSeconds, uint32 maxSpreadBps) internal pure returns (bytes memory) {
        require(maxSpreadBps < BPS, ParamLoadMaxSpreadTooHigh(maxSpreadBps));
        return abi.encodePacked(oracle, maxAgeSeconds, maxSpreadBps);
    }

    function parse(bytes calldata args) internal pure returns (address oracle, uint32 maxAgeSeconds, uint32 maxSpreadBps) {
        oracle = address(uint160(bytes20(args.slice(0, 20, ParamLoadMissingArgs.selector))));
        maxAgeSeconds = uint32(bytes4(args.slice(20, 24, ParamLoadMissingArgs.selector)));
        maxSpreadBps = uint32(bytes4(args.slice(24, 28, ParamLoadMissingArgs.selector)));
    }
}

/// @title ParamLoad
/// @notice Custom SwapVM opcode `_loadParamsXD`: read an agent-posted spread from the ParamOracle and
///         apply it to the swap, failing safe to the maker's max spread when data is missing or stale.
/// @dev READ-ONLY against the oracle (a single staticcall) and never persists state, so quote() and
///      swap() compute identically — the documented quote==swap discipline. The spread is retained in
///      the pool exactly like `_flatFeeAmountInXD` (ceilDiv, rounding favors the maker).
contract ParamLoad {
    using ContextLib for Context;

    error ParamLoadMustPrecedeSwap();
    error ParamLoadSpreadOutOfRange(uint256 spreadBps);

    /// @dev Place FIRST in the program: it wraps the rest of the program via ctx.runLoop().
    ///      args: oracle(20) | maxAgeSeconds(4) | maxSpreadBps(4)
    function _loadParamsXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ParamLoadMustPrecedeSwap());
        (address oracle, uint32 maxAgeSeconds, uint32 maxSpreadBps) = ParamLoadArgsBuilder.parse(args);

        // Fail-safe default: maximum defensive spread (used if oracle missing, stale, or out-of-range).
        uint256 spreadBps = maxSpreadBps;
        if (oracle != address(0)) {
            (bool ok, bytes memory res) = oracle.staticcall(
                abi.encodeCall(IParamOracle.getParams, (ctx.query.orderHash))
            );
            if (ok && res.length == 64) {
                (uint32 sBps, uint40 updatedAt) = abi.decode(res, (uint32, uint40));
                bool fresh = updatedAt != 0 && block.timestamp <= uint256(updatedAt) + maxAgeSeconds;
                if (fresh && sBps <= maxSpreadBps) {
                    spreadBps = sBps;
                }
            }
        }
        require(spreadBps <= BPS, ParamLoadSpreadOutOfRange(spreadBps));

        // Apply spread like _flatFeeAmountInXD: retained in the pool, rounding favors the maker.
        if (ctx.query.isExactIn) {
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            ctx.swap.amountIn -= Math.ceilDiv(ctx.swap.amountIn * spreadBps, BPS);
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            ctx.runLoop();
            ctx.swap.amountIn += Math.ceilDiv(ctx.swap.amountIn * spreadBps, BPS - spreadBps);
        }
    }
}
