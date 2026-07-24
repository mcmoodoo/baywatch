// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";
import { LpStrategy } from "../src/LpStrategy.sol";
import { ParamOracle } from "../src/ParamOracle.sol";
import { MockTaker } from "./utils/MockTaker.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @notice The shared param spine: an agent posts a spread to ParamOracle; _loadParamsXD reads it each
///         swap and reprices with NO re-ship; stale data fails safe to max-defense; quote == swap.
contract ParamSpineTest is Test {
    uint256 constant INIT = 1_000_000e18; // deep, balanced reserves so price impact << spread effect
    uint256 constant SWAP = 1e18;
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9; // 50% fail-safe ceiling
    uint32 constant SPREAD_10 = 0.1e9;  // 10%

    Aqua aqua;
    SharedAquaRouter router;
    LpStrategy lp;
    ParamOracle oracle;
    TokenMock tokenA;
    TokenMock tokenB;
    MockTaker taker;
    address maker;
    uint256 makerPk = 0x1234;

    ISwapVM.Order order;
    bytes32 orderHash;
    bytes takerData;

    function setUp() public {
        aqua = new Aqua();
        router = new SharedAquaRouter(address(aqua), address(0), address(this), "SharedAquaVM", "1.0.0");
        lp = new LpStrategy(address(aqua));
        oracle = new ParamOracle(address(this)); // this test stands in for the off-chain agent (poster)
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        maker = vm.addr(makerPk);
        taker = new MockTaker(aqua, router, address(this));

        // adaptive program: _loadParamsXD(oracle, maxAge, maxSpread) -> XYC -> salt
        bytes memory program = lp.buildAdaptiveXYCProgram(address(oracle), MAX_AGE, MAX_SPREAD, uint64(uint256(keccak256("m3"))));
        order = lp.createOrder(maker, program);
        orderHash = router.hash(order);

        tokenA.mint(maker, INIT);
        tokenB.mint(maker, INIT);
        vm.prank(maker); tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker); tokenB.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), dynamic([address(tokenA), address(tokenB)]), dynamic([INIT, INIT]));

        takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker), isExactIn: true, shouldUnwrapWeth: false, isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false, useTransferFromAndAquaPush: false, threshold: "", to: address(0), deadline: 0,
            hasPreTransferInCallback: true, hasPreTransferOutCallback: false,
            preTransferInHookData: "", postTransferInHookData: "", preTransferOutHookData: "", postTransferOutHookData: "",
            preTransferInCallbackData: "", preTransferOutCallbackData: "", instructionsArgs: "", signature: ""
        }));
    }

    function _quoteOut() internal returns (uint256 amountOut) {
        (, amountOut, ) = router.quote(order, address(tokenA), address(tokenB), SWAP, takerData);
    }

    function test_paramFlip_repricesNextSwap_noReship() public {
        oracle.setParams(orderHash, 0);
        uint256 out0 = _quoteOut();

        // single setParams tx flips the spread; the next quote/swap reprices with NO re-ship
        oracle.setParams(orderHash, SPREAD_10);
        uint256 out1 = _quoteOut();

        assertLt(out1, out0, "spread up -> less output");
        assertApproxEqRel(out1, out0 * 9 / 10, 0.01e18, "~10% spread");

        // quote == swap: executing now (spread 10%, reserves still pristine) matches the quote exactly
        tokenA.mint(address(taker), SWAP);
        (, uint256 outSwap) = taker.swap(order, address(tokenA), address(tokenB), SWAP, takerData);
        assertEq(outSwap, out1, "quote == swap");

        console2.log("out0 (0% spread) :", out0);
        console2.log("out1 (10% spread):", out1);
        console2.log("swap out         :", outSwap);
    }

    function test_staleness_failsSafeToMaxDefense() public {
        oracle.setParams(orderHash, SPREAD_10);
        uint256 outFresh = _quoteOut();

        // warp beyond maxAge -> data stale -> opcode applies MAX_SPREAD (50%) defensively
        vm.warp(block.timestamp + MAX_AGE + 1);
        uint256 outStale = _quoteOut();

        assertLt(outStale, outFresh, "stale -> more defensive (less output)");
        // (1 - 0.50) / (1 - 0.10) = 5/9
        assertApproxEqRel(outStale, outFresh * 5 / 9, 0.02e18, "~50% defensive spread");

        console2.log("outFresh (10%)     :", outFresh);
        console2.log("outStale (50% safe):", outStale);
    }
}
