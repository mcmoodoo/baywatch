// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ParamOracle } from "../src/ParamOracle.sol";
import { MsgSenderRouter } from "../test/utils/MsgSenderRouter.sol";

/// @notice Prove the live v4 pool is defended by the SAME oracle: post a market spread + a per-taker toll for
///         the shark (keyed by the v4 PoolId), run the shark and a tourist through the identical swap, and
///         assert the shark is surcharged on-chain by the hook's dynamic fee.
contract VerifyV4 is Script {
    uint256 constant POSTER  = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant TOURIST = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant SHARK   = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    int24   constant SPACING = 60;
    uint256 constant AMT     = 1e18;

    function run() external {
        _post();
        uint256 t = _swap(TOURIST);
        uint256 s = _swap(SHARK);
        console2.log("=== v4 pool defended by the SAME Graph signal ===");
        console2.log("tourist out (spread only):  ", t);
        console2.log("shark out   (spread + toll):", s);
        require(s < t, "FAIL: shark not surcharged on v4");
        console2.log("shark surcharged vs tourist (bps):", (t - s) * 10_000 / t);
        console2.log("PASS: one oracle -> Uniswap v4 hook -> per-taker dynamic fee on-chain.");
    }

    function _post() internal {
        string memory j = vm.readFile("./ui/v4.json");
        address oracle = vm.parseJsonAddress(j, ".oracle");
        bytes32 defId = vm.parseJsonBytes32(j, ".defendedPoolId");
        address shark = vm.parseJsonAddress(j, ".shark");
        vm.startBroadcast(POSTER);
        ParamOracle(oracle).setParams(defId, 10_000_000);       // 1% market-index spread
        ParamOracle(oracle).setToll(defId, shark, 36_300_000);  // 3.63% reputation toll
        vm.stopBroadcast();
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

    function _swap(uint256 pk) internal returns (uint256) {
        string memory j = vm.readFile("./ui/v4.json");
        address router = vm.parseJsonAddress(j, ".router");
        address c1 = vm.parseJsonAddress(j, ".currency1");
        address who = vm.addr(pk);
        uint256 before = TokenMock(c1).balanceOf(who);
        vm.broadcast(pk);
        MsgSenderRouter(router).swap(_key(), SwapParams(true, -int256(AMT), TickMath.MIN_SQRT_PRICE + 1), "");
        return TokenMock(c1).balanceOf(who) - before;
    }
}
