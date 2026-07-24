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
import { DepegCircuitBreaker } from "../src/instructions/DepegCircuitBreaker.sol";
import { MockTaker } from "./utils/MockTaker.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @notice Behavioral tests for the Baywatch opcodes: per-taker toll DISCRIMINATION ("two takers, same
///         pool, two prices") and the depeg circuit breaker (NORMAL / DEFENSIVE / HALT).
contract BaywatchOpcodesTest is Test {
    uint256 constant INIT = 1_000_000e18;
    uint256 constant AMT = 1_000e18;
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9;
    uint32 constant MAX_TOLL = 0.5e9;
    uint8 constant NORMAL = 0;
    uint8 constant DEFENSIVE = 1;
    uint8 constant HALT = 2;

    Aqua aqua;
    SharedAquaRouter router;
    LpStrategy lp;
    ParamOracle oracle;
    TokenMock tokenA;
    TokenMock tokenB;
    MockTaker clean;   // unflagged taker
    MockTaker toxic;   // flagged taker
    address maker;
    uint256 makerPk = 0x1234;

    ISwapVM.Order order;
    bytes32 orderHash;

    function setUp() public {
        aqua = new Aqua();
        router = new SharedAquaRouter(address(aqua), address(0), address(this), "SharedAquaVM", "1.0.0");
        lp = new LpStrategy(address(aqua));
        oracle = new ParamOracle(address(this));
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        maker = vm.addr(makerPk);
        clean = new MockTaker(aqua, router, address(this));
        toxic = new MockTaker(aqua, router, address(this));

        bytes memory program = lp.buildBaywatchProgram(LpStrategy.BaywatchParams({
            oracle: address(oracle), maxAgeSeconds: MAX_AGE, maxSpreadBps: MAX_SPREAD,
            maxTollBps: MAX_TOLL, staleTier: NORMAL, salt: uint64(uint256(keccak256("baywatch-beh")))
        }));
        order = lp.createOrder(maker, program);
        orderHash = router.hash(order);

        tokenA.mint(maker, INIT);
        tokenB.mint(maker, INIT);
        vm.prank(maker); tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker); tokenB.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), dynamic([address(tokenA), address(tokenB)]), dynamic([INIT, INIT]));

        oracle.setParams(orderHash, 0);         // zero global spread — isolate the toll
        oracle.setRisk(orderHash, NORMAL, address(0));
    }

    function _takerData(address t) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: t, isExactIn: true, shouldUnwrapWeth: false, isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false, useTransferFromAndAquaPush: false, threshold: "", to: address(0), deadline: 0,
            hasPreTransferInCallback: true, hasPreTransferOutCallback: false,
            preTransferInHookData: "", postTransferInHookData: "", preTransferOutHookData: "", postTransferOutHookData: "",
            preTransferInCallbackData: "", preTransferOutCallbackData: "", instructionsArgs: "", signature: ""
        }));
    }

    function _quoteOut(MockTaker t, address tin, address tout) internal returns (uint256 out) {
        vm.prank(address(t));
        (, out, ) = router.quote(order, tin, tout, AMT, _takerData(address(t)));
    }

    function _swapOut(MockTaker t, address tin, address tout) internal returns (uint256 out) {
        TokenMock(tin).mint(address(t), AMT);
        (, out) = t.swap(order, tin, tout, AMT, _takerData(address(t)));
    }

    // ----- per-taker toll: two takers, same pool, two prices -----

    function test_toll_twoTakersTwoPrices() public {
        oracle.setToll(orderHash, address(toxic), 0.1e9); // 10% toll on the flagged taker

        // Compared as quotes at the SAME pool state (exact, no reserve drift).
        uint256 outClean = _quoteOut(clean, address(tokenA), address(tokenB));
        uint256 outToxic = _quoteOut(toxic, address(tokenA), address(tokenB));

        assertLt(outToxic, outClean, "flagged taker must get less output");
        assertApproxEqRel(outToxic, outClean * 9 / 10, 0.01e18, "~10% toll");
        console2.log("clean out:", outClean);
        console2.log("toxic out:", outToxic);
    }

    function test_toll_quoteEqualsSwap_sameTaker() public {
        oracle.setToll(orderHash, address(toxic), 0.1e9);
        uint256 q = _quoteOut(toxic, address(tokenA), address(tokenB));
        uint256 s = _swapOut(toxic, address(tokenA), address(tokenB));
        assertEq(s, q, "quote == swap for the same taker");
    }

    function test_toll_failsOpenWhenStale() public {
        oracle.setToll(orderHash, address(toxic), 0.1e9);
        vm.warp(block.timestamp + MAX_AGE + 1); // toll stale -> fails OPEN (no surcharge)
        uint256 outClean = _quoteOut(clean, address(tokenA), address(tokenB));
        uint256 outToxic = _quoteOut(toxic, address(tokenA), address(tokenB));
        assertEq(outToxic, outClean, "stale toll must not surcharge");
    }

    // ----- circuit breaker -----

    function test_breaker_haltRevertsAllSwaps() public {
        oracle.setRisk(orderHash, HALT, address(0));
        TokenMock(tokenA).mint(address(clean), AMT);
        vm.expectRevert(abi.encodeWithSelector(DepegCircuitBreaker.DepegHalted.selector, orderHash));
        clean.swap(order, address(tokenA), address(tokenB), AMT, _takerData(address(clean)));
    }

    function test_breaker_defensiveIsOneDirectional() public {
        // tokenB is the at-risk leg: swaps that GROW maker exposure to tokenB (tokenIn == tokenB) revert;
        // swaps that REDUCE it (taker buys tokenB off the pool) are allowed.
        oracle.setRisk(orderHash, DEFENSIVE, address(tokenB));

        // rejected: taker sells tokenB into the pool (pool receives tokenB)
        TokenMock(tokenB).mint(address(clean), AMT);
        vm.expectRevert(abi.encodeWithSelector(DepegCircuitBreaker.DepegDefensiveRejected.selector, orderHash, address(tokenB)));
        clean.swap(order, address(tokenB), address(tokenA), AMT, _takerData(address(clean)));

        // allowed: taker buys tokenB off the pool (tokenIn == tokenA)
        uint256 out = _swapOut(clean, address(tokenA), address(tokenB));
        assertGt(out, 0, "de-risking direction must be allowed");
    }

    function test_breaker_normalPasses() public {
        oracle.setRisk(orderHash, NORMAL, address(0));
        uint256 out = _swapOut(clean, address(tokenA), address(tokenB));
        assertGt(out, 0, "NORMAL must pass through");
    }
}
