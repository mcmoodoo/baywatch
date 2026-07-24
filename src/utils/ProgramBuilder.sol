// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Adapted from swap-vm v0.0.6 test/utils/ProgramBuilder.sol (relocated to src/ because LpStrategy uses it).
// Resolves an instruction function pointer to its opcode byte index and emits [opcode, argsLen, args].

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";

struct Program {
    function(Context memory, bytes calldata) internal[] opcodes;
}

library ProgramBuilder {
    using SafeCast for uint256;

    error OpcodeNotFound();

    function init(function(Context memory, bytes calldata) internal[] memory opcodes) internal pure returns (Program memory) {
        return Program({ opcodes: opcodes });
    }

    function build(Program memory self, function(Context memory, bytes calldata) internal instruction) internal pure returns (bytes memory) {
        return build(self, instruction, "");
    }

    function build(Program memory self, function(Context memory, bytes calldata) internal instruction, bytes memory args) internal pure returns (bytes memory) {
        uint8 opcode = findOpcode(self, instruction);
        return abi.encodePacked(opcode, args.length.toUint8(), args);
    }

    function findOpcode(Program memory self, function(Context memory, bytes calldata) internal targetOpcode) internal pure returns (uint8) {
        for (uint256 i = 0; i < self.opcodes.length; i++) {
            if (self.opcodes[i] == targetOpcode) {
                return i.toUint8();
            }
        }
        revert OpcodeNotFound();
    }
}
