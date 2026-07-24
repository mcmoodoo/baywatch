// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";
import { LpStrategy } from "../src/LpStrategy.sol";
import { MockTaker } from "../test/utils/MockTaker.sol";

/// @notice One "tick" of live flow: executes a small batch of trades on BOTH the defended and naïve
///         pools (identical flow), then writes ui/laststep.json with each trade's outputs. The server
///         accumulates reserves/edge from these. Sharks buy aUSD (informed, directional); tourists trade
///         both ways smaller. Defended swaps are wrapped in try/catch so the depeg breaker (HALT) blocks
///         the defended pool without crashing the tick — the naïve pool keeps taking the toxic flow.
///         Env: FLOW_STEP (uint, required), FLOW_MODE ("normal"|"attack"), FLOW_N (uint, default 3).
contract FlowStep is Script {
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9;
    uint32 constant MAX_TOLL = 0.5e9;

    struct Cfg {
        LpStrategy lp;
        address maker;
        TokenMock tokenA;
        TokenMock tokenB;
        address[] takers;
        uint256 numTourists;
        uint256 numSharks;
        ISwapVM.Order defOrder;
        ISwapVM.Order naiveOrder;
    }

    function run() external {
        Cfg memory c = _load();
        uint256 step = vm.envUint("FLOW_STEP");
        string memory mode = vm.envOr("FLOW_MODE", string("normal"));
        uint256 nTrades = vm.envOr("FLOW_N", uint256(3));
        bool attack = keccak256(bytes(mode)) == keccak256(bytes("attack"));
        // Sharks trade WITH the current trend (informed flow); the server oscillates it so reserves stay
        // bounded (accumulate then distribute) instead of one-directionally draining a pool.
        bool trendUp = keccak256(bytes(vm.envOr("FLOW_TREND", string("up")))) == keccak256(bytes("up"));
        // When the defended pool is halted, its router won't route trades to it (the on-chain depeg
        // breaker is the enforcement backstop); skip the doomed swap so the tick stays fast.
        bool defBlocked = keccak256(bytes(vm.envOr("FLOW_DEF_BLOCKED", string("0")))) == keccak256(bytes("1"));

        string memory trades = "";
        vm.startBroadcast(PK);
        for (uint256 i = 0; i < nTrades; i++) {
            uint256 s = uint256(keccak256(abi.encode(step, i)));
            bool shark = (s % 10) < (attack ? 8 : 3);
            address taker = shark
                ? c.takers[c.numTourists + (s % c.numSharks)]
                : c.takers[s % c.numTourists];
            // Sharks trade with the trend; tourists random direction, smaller size.
            bool buyA = shark ? trendUp : (((s >> 8) % 2) == 0);
            TokenMock tin = buyA ? c.tokenB : c.tokenA;
            TokenMock tout = buyA ? c.tokenA : c.tokenB;
            uint256 amount = shark ? (3_000e18 + (s % 8) * 500e18) : (100e18 + (s % 20) * 80e18);

            (uint256 outDef, bool defOk) = defBlocked ? (uint256(0), false) : _trySwap(c.defOrder, MockTaker(taker), tin, tout, amount);
            (uint256 outNaive, bool naiveOk) = _trySwap(c.naiveOrder, MockTaker(taker), tin, tout, amount);

            string memory t = string.concat(
                '{"taker":"', vm.toString(taker),
                '","shark":', shark ? "true" : "false",
                ',"tin":"', buyA ? "B" : "A",
                '","amountIn":"', vm.toString(amount),
                '","outDef":"', vm.toString(outDef),
                '","defOk":', defOk ? "true" : "false",
                ',"outNaive":"', vm.toString(outNaive),
                '","naiveOk":', naiveOk ? "true" : "false", "}"
            );
            trades = i == 0 ? t : string.concat(trades, ",", t);
        }
        vm.stopBroadcast();

        vm.writeFile("./ui/laststep.json", string.concat(
            '{"step":', vm.toString(step),
            ',"mode":"', mode,
            '","block":', vm.toString(block.number),
            ',"trades":[', trades, "]}"
        ));
    }

    function _load() internal returns (Cfg memory c) {
        string memory j = vm.readFile("./ui/desk.json");
        c.lp = LpStrategy(vm.parseJsonAddress(j, ".lp"));
        c.maker = vm.parseJsonAddress(j, ".maker");
        c.tokenA = TokenMock(vm.parseJsonAddress(j, ".tokenA"));
        c.tokenB = TokenMock(vm.parseJsonAddress(j, ".tokenB"));
        c.takers = vm.parseJsonAddressArray(j, ".takers");
        c.numTourists = vm.parseJsonUint(j, ".numTourists");
        c.numSharks = vm.parseJsonUint(j, ".numSharks");
        address oracle = vm.parseJsonAddress(j, ".oracle");
        uint64 defSalt = uint64(vm.parseJsonUint(j, ".defendedSalt"));
        uint64 naiveSalt = uint64(vm.parseJsonUint(j, ".naiveSalt"));
        c.defOrder = c.lp.createOrder(c.maker, c.lp.buildBaywatchProgram(LpStrategy.BaywatchParams({
            oracle: oracle, maxAgeSeconds: MAX_AGE, maxSpreadBps: MAX_SPREAD, maxTollBps: MAX_TOLL, staleTier: 0, salt: defSalt
        })));
        c.naiveOrder = c.lp.createOrder(c.maker, c.lp.buildXYCProgram(naiveSalt));
    }

    function _trySwap(ISwapVM.Order memory order, MockTaker taker, TokenMock tin, TokenMock tout, uint256 amount)
        internal
        returns (uint256 outAmt, bool ok)
    {
        bytes memory td = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker), isExactIn: true, shouldUnwrapWeth: false, isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false, useTransferFromAndAquaPush: false, threshold: "", to: address(0), deadline: 0,
            hasPreTransferInCallback: true, hasPreTransferOutCallback: false,
            preTransferInHookData: "", postTransferInHookData: "", preTransferOutHookData: "", preTransferOutCallbackData: "",
            preTransferInCallbackData: "", postTransferOutHookData: "", instructionsArgs: "", signature: ""
        }));
        try taker.swap(order, address(tin), address(tout), amount, td) returns (uint256, uint256 o) {
            return (o, true);
        } catch {
            return (0, false);
        }
    }
}
