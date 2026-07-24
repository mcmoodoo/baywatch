// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { CoreInvariants } from "@1inch/swap-vm/test/invariants/CoreInvariants.t.sol";

import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";
import { LpStrategy } from "../src/LpStrategy.sol";
import { ParamOracle } from "../src/ParamOracle.sol";
import { MockTaker } from "./utils/MockTaker.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @notice Proves the FULL Baywatch program (circuit breaker -> global spread -> per-taker toll -> curve)
///         preserves swap-vm's CoreInvariants. Risk is NORMAL (breaker passes through) and the toll is
///         UNIFORM across the harness's quote-taker (this contract) and swap-taker (MockTaker) so the
///         taker-dependent toll doesn't spuriously break quote==swap — the toll's per-taker
///         DISCRIMINATION is covered separately in BaywatchOpcodes.t.sol.
contract BaywatchInvariants is CoreInvariants {
    uint256 constant INIT = 1_000_000e18;
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9;
    uint32 constant MAX_TOLL = 0.5e9;

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

    function setUp() public {
        aqua = new Aqua();
        router = new SharedAquaRouter(address(aqua), address(0), address(this), "SharedAquaVM", "1.0.0");
        lp = new LpStrategy(address(aqua));
        oracle = new ParamOracle(address(this));
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        maker = vm.addr(makerPk);
        taker = new MockTaker(aqua, router, address(this));

        bytes memory program = lp.buildBaywatchProgram(LpStrategy.BaywatchParams({
            oracle: address(oracle),
            maxAgeSeconds: MAX_AGE,
            maxSpreadBps: MAX_SPREAD,
            maxTollBps: MAX_TOLL,
            staleTier: 0, // NORMAL
            salt: uint64(uint256(keccak256("baywatch-inv")))
        }));
        order = lp.createOrder(maker, program);
        orderHash = router.hash(order);

        tokenA.mint(maker, INIT);
        tokenB.mint(maker, INIT);
        vm.prank(maker); tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker); tokenB.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), dynamic([address(tokenA), address(tokenB)]), dynamic([INIT, INIT]));

        // Fresh NORMAL risk + zero global spread; toll posted per-test.
        oracle.setParams(orderHash, 0);
        oracle.setRisk(orderHash, 0, address(0)); // NORMAL
    }

    function _executeSwap(
        SwapVM, ISwapVM.Order memory o, address tokenIn, address tokenOut, uint256 amount, bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        TokenMock(tokenIn).mint(address(taker), amount * 10);
        (amountIn, amountOut) = taker.swap(o, tokenIn, tokenOut, amount, takerData);
    }

    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker), isExactIn: isExactIn, shouldUnwrapWeth: false, isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false, useTransferFromAndAquaPush: false, threshold: "", to: address(0), deadline: 0,
            hasPreTransferInCallback: true, hasPreTransferOutCallback: false,
            preTransferInHookData: "", postTransferInHookData: "", preTransferOutHookData: "", postTransferOutHookData: "",
            preTransferInCallbackData: "", preTransferOutCallbackData: "", instructionsArgs: "", signature: ""
        }));
    }

    /// @dev Uniform toll for BOTH the quote-taker (this contract) and the swap-taker (MockTaker).
    function _setUniformToll(uint32 tollBps) internal {
        oracle.setToll(orderHash, address(this), tollBps);
        oracle.setToll(orderHash, address(taker), tollBps);
    }

    function _runAllInvariants() internal {
        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _takerData(true);
        config.exactOutTakerData = _takerData(false);
        assertAllInvariantsWithConfig(router, order, address(tokenA), address(tokenB), config);
    }

    function test_baywatchInvariants_zeroToll() public {
        _setUniformToll(0);
        _runAllInvariants();
    }

    function test_baywatchInvariants_uniformToll10pct() public {
        _setUniformToll(0.1e9);
        _runAllInvariants();
    }
}
