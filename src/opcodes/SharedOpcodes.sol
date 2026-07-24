// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Faithful superset of the latest AquaOpcodes table (swap-vm v1.0.1): every upstream opcode index is
// preserved 1:1, then our three market-making opcodes are APPENDED at the end (ops 34/35/36) using the
// same static-array+length trick upstream uses. Append-only rule: never reorder existing indices.

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { AquaOpcodes } from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "@1inch/swap-vm/src/instructions/XYCConcentrate.sol";
import { Decay } from "@1inch/swap-vm/src/instructions/Decay.sol";
import { Fee } from "@1inch/swap-vm/src/instructions/Fee.sol";
import { Extruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";
import { PeggedSwap } from "@1inch/swap-vm/src/instructions/PeggedSwap.sol";
import { ParamLoad } from "../instructions/ParamLoad.sol";
import { ToxicFlowToll } from "../instructions/ToxicFlowToll.sol";
import { DepegCircuitBreaker } from "../instructions/DepegCircuitBreaker.sol";

/// @title SharedOpcodes
/// @notice The latest AquaOpcodes table + our appended market-making opcodes. Shared base for the strategy.
contract SharedOpcodes is AquaOpcodes, ParamLoad, ToxicFlowToll, DepegCircuitBreaker {
    constructor(address aqua) AquaOpcodes(aqua) {}

    /// @dev Same construction as AquaOpcodes._opcodes(): a static array whose index-0 slot is overwritten
    ///      with the dynamic length, dropping it from the result. Base opcodes 0..33 mirror v1.0.1 exactly
    ///      (including `_onlyTxOriginTokenBalanceNonZero`); ours are appended at 34/35/36.
    function _opcodes() internal pure virtual override returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[38] memory instructions = [
            _notInstruction,
            // Debug - reserved (core infrastructure)
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // Controls - control flow
            Controls._jump,
            Controls._jumpIfTokenIn,
            Controls._jumpIfTokenOut,
            Controls._deadline,
            Controls._onlyTakerTokenBalanceNonZero,
            Controls._onlyTakerTokenBalanceGte,
            Controls._onlyTakerTokenSupplyShareGte,
            // XYCSwap
            XYCSwap._xycSwapXD,
            // XYCConcentrate
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            // Decay
            Decay._decayXD,
            Controls._salt,
            Fee._flatFeeAmountInXD,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            Fee._protocolFeeAmountInXD,
            Fee._aquaProtocolFeeAmountInXD,
            Fee._dynamicProtocolFeeAmountInXD,
            Fee._aquaDynamicProtocolFeeAmountInXD,
            PeggedSwap._peggedSwapGrowPriceRange2D,
            Extruction._extruction,
            Controls._onlyTxOriginTokenBalanceNonZero,   // op 33 (added upstream in v1.0.1)
            // ----- appended market-making opcodes -----
            ParamLoad._loadParamsXD,                     // op 34
            ToxicFlowToll._toxicFlowToll,                // op 35
            DepegCircuitBreaker._depegCircuitBreaker     // op 36
        ];

        uint256 instructionsArrayLength = instructions.length - 1;
        assembly ("memory-safe") {
            result := instructions
            mstore(result, instructionsArrayLength)
        }
    }
}
