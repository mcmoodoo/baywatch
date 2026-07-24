// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";
import { LpStrategy } from "../src/LpStrategy.sol";
import { ParamOracle } from "../src/ParamOracle.sol";
import { MockTaker } from "../test/utils/MockTaker.sol";
import { dynamic } from "../test/utils/Dynamic.sol";

/// @notice Deploys the two-pool "Desk": a DEFENDED order (full Baywatch program: breaker+spread+toll+XYC)
///         and a NAÏVE order (plain XYC) with identical reserves, plus pre-funded tourist/shark takers.
///         The flow engine routes identical trades to both so the PnL divergence = what the defense earned.
///         Writes ui/desk.json for the server. Run with --broadcast.
contract DeployDesk is Script {
    uint256 constant INIT = 1_000_000e18;            // reserve per token, per pool
    uint256 constant PREFUND = 100_000_000e18;       // per taker, per token (so FlowStep never mints)
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9;
    uint32 constant MAX_TOLL = 0.5e9;
    uint64 constant SALT_DEF = uint64(uint256(keccak256("desk-defended")));
    uint64 constant SALT_NAIVE = uint64(uint256(keccak256("desk-naive")));
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant NUM_TOURISTS = 3;
    uint256 constant NUM_SHARKS = 2;

    function run() external {
        address me = vm.addr(PK);
        vm.startBroadcast(PK);

        Aqua aqua = new Aqua();
        SharedAquaRouter router = new SharedAquaRouter(address(aqua), address(0), me, "SharedAquaVM", "1.0.0");
        LpStrategy lp = new LpStrategy(address(aqua));
        ParamOracle oracle = new ParamOracle(me);
        TokenMock tokenA = new TokenMock("Baywatch USD", "aUSD");
        TokenMock tokenB = new TokenMock("Base USD", "bUSD");

        tokenA.mint(me, INIT * 2);
        tokenB.mint(me, INIT * 2);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);

        // DEFENDED order: full Baywatch program.
        bytes memory defProg = lp.buildBaywatchProgram(LpStrategy.BaywatchParams({
            oracle: address(oracle), maxAgeSeconds: MAX_AGE, maxSpreadBps: MAX_SPREAD,
            maxTollBps: MAX_TOLL, staleTier: 0, salt: SALT_DEF
        }));
        ISwapVM.Order memory defOrder = lp.createOrder(me, defProg);
        bytes32 defHash = router.hash(defOrder);
        aqua.ship(address(router), abi.encode(defOrder), dynamic([address(tokenA), address(tokenB)]), dynamic([INIT, INIT]));

        // NAÏVE order: plain x*y=k, no defense.
        bytes memory naiveProg = lp.buildXYCProgram(SALT_NAIVE);
        ISwapVM.Order memory naiveOrder = lp.createOrder(me, naiveProg);
        bytes32 naiveHash = router.hash(naiveOrder);
        aqua.ship(address(router), abi.encode(naiveOrder), dynamic([address(tokenA), address(tokenB)]), dynamic([INIT, INIT]));

        // Clean NORMAL baseline for the defended pool (no toll yet; the agent posts tolls live).
        oracle.setParams(defHash, 0);
        oracle.setRisk(defHash, 0, address(0));

        // Takers: tourists first, then sharks. Pre-funded so FlowStep only broadcasts swaps.
        uint256 n = NUM_TOURISTS + NUM_SHARKS;
        address[] memory takers = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            MockTaker t = new MockTaker(aqua, router, me);
            tokenA.mint(address(t), PREFUND);
            tokenB.mint(address(t), PREFUND);
            takers[i] = address(t);
        }

        vm.stopBroadcast();

        string memory o = "desk";
        vm.serializeString(o, "rpc", "http://localhost:8545");
        vm.serializeUint(o, "posterPk", PK);
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "lp", address(lp));
        vm.serializeAddress(o, "oracle", address(oracle));
        vm.serializeAddress(o, "maker", me);
        vm.serializeAddress(o, "tokenA", address(tokenA));
        vm.serializeAddress(o, "tokenB", address(tokenB));
        vm.serializeUint(o, "initReserve", INIT);
        vm.serializeUint(o, "maxAge", MAX_AGE);
        vm.serializeUint(o, "maxSpread", MAX_SPREAD);
        vm.serializeUint(o, "maxToll", MAX_TOLL);
        vm.serializeBytes32(o, "defendedOrderHash", defHash);
        vm.serializeUint(o, "defendedSalt", SALT_DEF);
        vm.serializeBytes32(o, "naiveOrderHash", naiveHash);
        vm.serializeUint(o, "naiveSalt", SALT_NAIVE);
        vm.serializeUint(o, "numTourists", NUM_TOURISTS);
        vm.serializeUint(o, "numSharks", NUM_SHARKS);
        string memory json = vm.serializeAddress(o, "takers", takers);
        vm.writeJson(json, "./ui/desk.json");

        console2.log("desk deployed. defended / naive orderHash:");
        console2.logBytes32(defHash);
        console2.logBytes32(naiveHash);
        console2.log("wrote ui/desk.json");
    }
}
