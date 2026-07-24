// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";

import { SharedOpcodes } from "./opcodes/SharedOpcodes.sol";
import { ParamLoad, ParamLoadArgsBuilder } from "./instructions/ParamLoad.sol";
import { ToxicFlowToll, ToxicFlowTollArgsBuilder } from "./instructions/ToxicFlowToll.sol";
import { DepegCircuitBreaker, DepegCircuitBreakerArgsBuilder } from "./instructions/DepegCircuitBreaker.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/// @title LpStrategy
/// @notice Builds SwapVM programs + Aqua-backed orders for the Baywatch market maker.
/// @dev Inherits SharedOpcodes so it shares the EXACT opcode-index layout of SharedAquaRouter,
///      making emitted bytecode portable to the router. The base-curve opcode is the concept seam
///      (XYC here; swap in PeggedSwap / XYCConcentrate for a pegged-pair variant later).
contract LpStrategy is SharedOpcodes {
    using ProgramBuilder for Program;

    constructor(address aqua) SharedOpcodes(aqua) {}

    /// @notice Minimal x*y=k program: base curve + a unique salt. (M2 first-swap slice.)
    function buildXYCProgram(uint64 salt) external pure returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(salt))
        );
    }

    /// @notice Adaptive XYC program: _loadParamsXD (oracle-driven spread, stale-safe) wrapping the curve.
    /// @dev _loadParamsXD must come FIRST — it wraps the rest of the program via ctx.runLoop().
    function buildAdaptiveXYCProgram(address oracle, uint32 maxAgeSeconds, uint32 maxSpreadBps, uint64 salt)
        external
        pure
        returns (bytes memory)
    {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(ParamLoad._loadParamsXD, ParamLoadArgsBuilder.build(oracle, maxAgeSeconds, maxSpreadBps)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(salt))
        );
    }

    /// @notice Full Baywatch program: circuit breaker (guard) -> global spread -> per-taker toll -> curve.
    /// @dev Order matters: the breaker runs first as a pre-swap guard; the two spread opcodes each wrap
    ///      the remainder via ctx.runLoop() so their surcharges compound onto the curve output.
    struct BaywatchParams {
        address oracle;
        uint32 maxAgeSeconds;
        uint32 maxSpreadBps;
        uint32 maxTollBps;
        uint8 staleTier;
        uint64 salt;
    }

    function buildBaywatchProgram(BaywatchParams memory a) external pure returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(DepegCircuitBreaker._depegCircuitBreaker, DepegCircuitBreakerArgsBuilder.build(a.oracle, a.maxAgeSeconds, a.staleTier)),
            p.build(ParamLoad._loadParamsXD, ParamLoadArgsBuilder.build(a.oracle, a.maxAgeSeconds, a.maxSpreadBps)),
            p.build(ToxicFlowToll._toxicFlowToll, ToxicFlowTollArgsBuilder.build(a.oracle, a.maxAgeSeconds, a.maxTollBps)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(a.salt))
        );
    }

    /// @notice Wrap program bytecode into an Aqua-backed maker order (no signature; Aqua virtual balances).
    function createOrder(address maker, bytes memory program) external pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }
}
