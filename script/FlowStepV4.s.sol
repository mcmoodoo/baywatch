// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MsgSenderRouter } from "../test/utils/MsgSenderRouter.sol";

/// @notice One Desk tick on the live v4 pool: run a tourist and a shark through the identical swap so the
///         server can read the on-chain surcharge the hook applied. Direction alternates (FLOW_DIR) to keep
///         the pool centered over many ticks. Writes ui/laststep-v4.json.
contract FlowStepV4 is Script {
    uint256 constant TOURIST = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // anvil[1]
    uint256 constant SHARK   = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // anvil[2]
    int24   constant SPACING = 60;
    uint256 constant AMT     = 1e18;

    function run() external {
        bool dir = vm.envOr("FLOW_DIR", uint256(0)) == 1;
        uint256 tOut = _swap(TOURIST, dir);
        uint256 sOut = _swap(SHARK, dir);
        string memory o = "v4s";
        vm.serializeUint(o, "touristOut", tOut);
        vm.serializeUint(o, "sharkOut", sOut);
        string memory j = vm.serializeBool(o, "dir", dir);
        vm.writeJson(j, "./ui/laststep-v4.json");
    }

    function _key() internal view returns (PoolKey memory) {
        string memory j = vm.readFile("./ui/v4.json");
        return PoolKey(
            Currency.wrap(vm.parseJsonAddress(j, ".currency0")),
            Currency.wrap(vm.parseJsonAddress(j, ".currency1")),
            LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING,
            IHooks(vm.parseJsonAddress(j, ".hook"))
        );
    }

    function _swap(uint256 pk, bool dir) internal returns (uint256) {
        string memory j = vm.readFile("./ui/v4.json");
        address router = vm.parseJsonAddress(j, ".router");
        address outTok = dir ? vm.parseJsonAddress(j, ".currency1") : vm.parseJsonAddress(j, ".currency0");
        address who = vm.addr(pk);
        uint160 lim = dir ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 before = TokenMock(outTok).balanceOf(who);
        vm.broadcast(pk);
        MsgSenderRouter(router).swap(_key(), SwapParams(dir, -int256(AMT), lim), "");
        return TokenMock(outTok).balanceOf(who) - before;
    }
}
