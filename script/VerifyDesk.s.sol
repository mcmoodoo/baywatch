// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";
import { LpStrategy } from "../src/LpStrategy.sol";

/// @notice Radar closed-loop proof: reads ui/desk.json, rebuilds the DEFENDED order, and quotes the same
///         trade for a bound shark (a cross-venue-toxic address) vs a tourist AFTER the agent posted its
///         Radar-derived spread + per-taker tolls. Proves the causal chain end-to-end:
///           standardized DEX-AMM subgraph -> Radar markout -> ParamOracle -> on-chain reprice.
///         Read-only: forge script script/VerifyDesk.s.sol --rpc-url http://localhost:8545
contract VerifyDesk is Script {
    uint256 constant AMT = 1_000e18;
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9;
    uint32 constant MAX_TOLL = 0.5e9;

    function run() external {
        string memory j = vm.readFile("./ui/desk.json");
        SharedAquaRouter router = SharedAquaRouter(payable(vm.parseJsonAddress(j, ".router")));
        LpStrategy lp = LpStrategy(vm.parseJsonAddress(j, ".lp"));
        address oracle = vm.parseJsonAddress(j, ".oracle");
        address maker = vm.parseJsonAddress(j, ".maker");
        address tokenA = vm.parseJsonAddress(j, ".tokenA");
        address tokenB = vm.parseJsonAddress(j, ".tokenB");
        address[] memory takers = vm.parseJsonAddressArray(j, ".takers");
        uint256 numTourists = vm.parseJsonUint(j, ".numTourists");
        uint64 salt = uint64(vm.parseJsonUint(j, ".defendedSalt"));
        bytes32 expectedHash = vm.parseJsonBytes32(j, ".defendedOrderHash");

        bytes memory program = lp.buildBaywatchProgram(LpStrategy.BaywatchParams({
            oracle: oracle, maxAgeSeconds: MAX_AGE, maxSpreadBps: MAX_SPREAD,
            maxTollBps: MAX_TOLL, staleTier: 0, salt: salt
        }));
        ISwapVM.Order memory order = lp.createOrder(maker, program);
        require(router.hash(order) == expectedHash, "order mismatch");

        // buy A (tokenB in, tokenA out); same trade for every taker.
        uint256 outTourist = _quote(router, order, tokenB, tokenA, takers[0]);

        console2.log("=== Radar closed loop: same defended pool, same trade, different takers ===");
        console2.log("tourist out (spread only):        ", outTourist);
        uint256 nSharks = takers.length - numTourists;
        for (uint256 i = 0; i < nSharks; i++) {
            address shark = takers[numTourists + i];
            uint256 outShark = _quote(router, order, tokenB, tokenA, shark);
            console2.log("bound shark out (spread + toll):  ", outShark);
            require(outShark < outTourist, "FAIL: bound shark not surcharged by the Radar-driven toll");
            console2.log("  -> shark surcharged vs tourist by (bps):", (outTourist - outShark) * 10000 / outTourist);
        }
        console2.log("PASS: cross-protocol toxicity -> ParamOracle -> per-taker on-chain reprice.");
    }

    function _quote(SharedAquaRouter router, ISwapVM.Order memory order, address tin, address tout, address taker)
        internal
        returns (uint256 out)
    {
        bytes memory td = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker, isExactIn: true, shouldUnwrapWeth: false, isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false, useTransferFromAndAquaPush: false, threshold: "", to: address(0), deadline: 0,
            hasPreTransferInCallback: true, hasPreTransferOutCallback: false,
            preTransferInHookData: "", postTransferInHookData: "", preTransferOutHookData: "", postTransferOutHookData: "",
            preTransferInCallbackData: "", preTransferOutCallbackData: "", instructionsArgs: "", signature: ""
        }));
        vm.prank(taker);
        (, out, ) = router.quote(order, tin, tout, AMT, td);
    }
}
