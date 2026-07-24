// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";

/// @dev Exposes the internal opcode table length so we can assert the append worked at runtime.
contract OpcodeExposer is SharedAquaRouter {
    constructor(address aqua, address weth, address owner) SharedAquaRouter(aqua, weth, owner, "SharedAquaVM", "1.0.0") {}

    function opcodeCount() external pure returns (uint256) {
        return _opcodes().length;
    }
}

contract SharedOpcodesTest is Test {
    function test_routerDeploysAndAppendsOpcode() public {
        OpcodeExposer router = new OpcodeExposer(address(0xA90A), address(0xBEEF), address(this));
        assertGt(address(router).code.length, 0, "router has no code");
        // v1.0.1 AquaOpcodes base = 34 effective opcodes (0..33). We appended 3 -> 37.
        assertEq(router.opcodeCount(), 37, "append did not yield 34 base + 3 custom");
    }
}
