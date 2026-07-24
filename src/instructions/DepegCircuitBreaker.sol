// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";

import { IParamOracle } from "../interfaces/IParamOracle.sol";

library DepegCircuitBreakerArgsBuilder {
    using Calldata for bytes;

    error DepegMissingArgs();

    /// @dev layout: oracle(20) | maxAgeSeconds(uint32,4) | staleTier(uint8,1)
    function build(address oracle, uint32 maxAgeSeconds, uint8 staleTier) internal pure returns (bytes memory) {
        return abi.encodePacked(oracle, maxAgeSeconds, staleTier);
    }

    function parse(bytes calldata args) internal pure returns (address oracle, uint32 maxAgeSeconds, uint8 staleTier) {
        oracle = address(uint160(bytes20(args.slice(0, 20, DepegMissingArgs.selector))));
        maxAgeSeconds = uint32(bytes4(args.slice(20, 24, DepegMissingArgs.selector)));
        staleTier = uint8(bytes1(args.slice(24, 25, DepegMissingArgs.selector)));
    }
}

/// @title DepegCircuitBreaker
/// @notice Custom SwapVM opcode `_depegCircuitBreaker`: a pre-swap guard driven by the agent's depeg
///         regime. NORMAL passes; DEFENSIVE makes the pool one-directional (rejects swaps that GROW
///         the maker's exposure to the at-risk leg); HALT reverts all swaps. On stale data it falls
///         back to `staleTier` (the strategy author's chosen safe default).
/// @dev Pure guard: reads the oracle once (view) and either reverts or returns — it does NOT wrap the
///      program via runLoop and never touches swap amounts, so quote() == swap() trivially. Depends
///      only on (orderHash, tokenIn), not on the taker.
contract DepegCircuitBreaker {
    uint8 internal constant TIER_NORMAL = 0;
    uint8 internal constant TIER_DEFENSIVE = 1;
    uint8 internal constant TIER_HALT = 2;

    error DepegHalted(bytes32 orderHash);
    error DepegDefensiveRejected(bytes32 orderHash, address riskToken);

    /// @dev Place FIRST in the program. args: oracle(20) | maxAgeSeconds(4) | staleTier(1).
    function _depegCircuitBreaker(Context memory ctx, bytes calldata args) internal view {
        (address oracle, uint32 maxAgeSeconds, uint8 staleTier) = DepegCircuitBreakerArgsBuilder.parse(args);

        uint8 tier = staleTier;
        address riskToken;
        if (oracle != address(0)) {
            (bool ok, bytes memory res) = oracle.staticcall(
                abi.encodeCall(IParamOracle.getRisk, (ctx.query.orderHash))
            );
            if (ok && res.length == 96) {
                (uint8 depegTier, address rt, uint40 updatedAt) = abi.decode(res, (uint8, address, uint40));
                bool fresh = updatedAt != 0 && block.timestamp <= uint256(updatedAt) + maxAgeSeconds;
                tier = fresh ? depegTier : staleTier;
                riskToken = rt;
            }
        }

        if (tier == TIER_HALT) revert DepegHalted(ctx.query.orderHash);
        if (tier == TIER_DEFENSIVE) {
            // Maker's exposure to riskToken grows when the pool RECEIVES it (tokenIn == riskToken).
            // Reject those; only let takers BUY the at-risk leg off the pool (de-risking the maker).
            if (ctx.query.tokenIn == riskToken) revert DepegDefensiveRejected(ctx.query.orderHash, riskToken);
        }
    }
}
