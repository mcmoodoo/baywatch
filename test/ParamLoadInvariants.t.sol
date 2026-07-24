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

/// @notice Plugs the custom `_loadParamsXD` opcode into swap-vm's own CoreInvariants harness.
///         Proves the opcode preserves all core invariants (quote==swap, symmetry, additivity,
///         monotonicity, rounding-favors-maker, balance-sufficiency) across three spread regimes:
///         zero spread (opcode transparent), an active 10% spread, and stale-data max-defense.
/// @dev Aqua-backed mode (our product): reserves shipped into Aqua, swaps driven by MockTaker.
contract ParamLoadInvariants is CoreInvariants {
    uint256 constant INIT = 1_000_000e18; // deep balanced pool: price ~1, clean numerics
    uint32 constant MAX_AGE = 300;
    uint32 constant MAX_SPREAD = 0.5e9; // 50% fail-safe ceiling

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
        oracle = new ParamOracle(address(this)); // test contract stands in for the agent (poster)
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        maker = vm.addr(makerPk);
        taker = new MockTaker(aqua, router, address(this)); // owner = test contract

        bytes memory program =
            lp.buildAdaptiveXYCProgram(address(oracle), MAX_AGE, MAX_SPREAD, uint64(uint256(keccak256("inv"))));
        order = lp.createOrder(maker, program);
        orderHash = router.hash(order);

        tokenA.mint(maker, INIT);
        tokenB.mint(maker, INIT);
        vm.prank(maker); tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker); tokenB.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), dynamic([address(tokenA), address(tokenB)]), dynamic([INIT, INIT]));
    }

    /// @dev CoreInvariants hook: execute a real swap via MockTaker (test contract is its owner).
    function _executeSwap(
        SwapVM, /* swapVM (== router) */
        ISwapVM.Order memory o,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        TokenMock(tokenIn).mint(address(taker), amount * 10);
        (amountIn, amountOut) = taker.swap(o, tokenIn, tokenOut, amount, takerData);
    }

    function _takerData(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function _runAllInvariants() internal {
        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _takerData(true);
        config.exactOutTakerData = _takerData(false);
        assertAllInvariantsWithConfig(router, order, address(tokenA), address(tokenB), config);
    }

    function test_invariants_zeroSpread() public {
        oracle.setParams(orderHash, 0);
        _runAllInvariants();
    }

    function test_invariants_activeTenPercentSpread() public {
        oracle.setParams(orderHash, 0.1e9);
        _runAllInvariants();
    }

    function test_invariants_staleFailsafeMaxSpread() public {
        oracle.setParams(orderHash, 0.1e9);
        vm.warp(block.timestamp + MAX_AGE + 1); // data now stale -> opcode applies MAX_SPREAD defensively
        _runAllInvariants();
    }
}
