// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";

import { SharedOpcodes } from "../opcodes/SharedOpcodes.sol";

/// @title SharedAquaRouter
/// @notice Our custom router: real SwapVM + Aqua accounting + SharedOpcodes (AquaOpcodes + appended custom opcode).
/// @dev Mirrors swap-vm v0.0.6 AquaSwapVMRouter, swapping AquaOpcodes -> SharedOpcodes.
contract SharedAquaRouter is Simulator, SwapVM, SharedOpcodes {
    constructor(address aqua, address weth, address owner, string memory name, string memory version)
        SwapVM(aqua, weth, owner, name, version)
        SharedOpcodes(aqua)
    {}

    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
