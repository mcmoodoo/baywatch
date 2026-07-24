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
import { MockTaker } from "./utils/MockTaker.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @notice First real on-chain swap through OUR SharedAquaRouter: ship XYC liquidity into Aqua,
///         then a taker swaps and we assert real ERC-20 movement + Aqua reserve conservation.
contract FirstSwapTest is Test {
    uint256 constant INIT_A = 1000e18;
    uint256 constant INIT_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 100e18;

    Aqua aqua;
    SharedAquaRouter router;
    LpStrategy lp;
    TokenMock tokenA;
    TokenMock tokenB;
    MockTaker taker;
    address maker;
    uint256 makerPk = 0x1234;

    function setUp() public {
        aqua = new Aqua();
        router = new SharedAquaRouter(address(aqua), address(0), address(this), "SharedAquaVM", "1.0.0");
        lp = new LpStrategy(address(aqua));
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        maker = vm.addr(makerPk);
        taker = new MockTaker(aqua, router, address(this));
    }

    function test_firstOnchainSwap_exactIn() public {
        // 1. Build program + Aqua-backed order via the shared LpStrategy.
        bytes memory program = lp.buildXYCProgram(uint64(uint256(keccak256("salt1"))));
        ISwapVM.Order memory order = lp.createOrder(maker, program);
        bytes32 orderHash = router.hash(order);

        // 2. Ship liquidity into Aqua (maker funds, one approval per token).
        tokenA.mint(maker, INIT_A);
        tokenB.mint(maker, INIT_B);
        vm.prank(maker); tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker); tokenB.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(
            address(router),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([INIT_A, INIT_B])
        );
        assertEq(strategyHash, orderHash, "strategyHash == orderHash");

        // 3. Taker swaps A->B (exact in), settling via Aqua push in the callback.
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
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
        tokenA.mint(address(taker), SWAP_AMOUNT);

        uint256 takerA0 = tokenA.balanceOf(address(taker));
        uint256 takerB0 = tokenB.balanceOf(address(taker));
        (uint256 mA0, uint256 mB0) = aqua.safeBalances(maker, address(router), orderHash, address(tokenA), address(tokenB));

        (uint256 amountIn, uint256 amountOut) = taker.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);

        uint256 takerA1 = tokenA.balanceOf(address(taker));
        uint256 takerB1 = tokenB.balanceOf(address(taker));
        (uint256 mA1, uint256 mB1) = aqua.safeBalances(maker, address(router), orderHash, address(tokenA), address(tokenB));

        // 4. Assert real token movement + XYC conservation (no fee in this program).
        assertEq(amountIn, SWAP_AMOUNT, "exact-in amountIn");
        assertGt(amountOut, 0, "produced output");
        assertEq(takerA0 - takerA1, amountIn, "taker paid tokenA");
        assertEq(takerB1 - takerB0, amountOut, "taker received tokenB");
        assertEq(mA1 - mA0, amountIn, "maker reserve A += amountIn");
        assertEq(mB0 - mB1, amountOut, "maker reserve B -= amountOut");

        console2.log("amountIn :", amountIn);
        console2.log("amountOut:", amountOut);
        console2.log("maker reserves A/B:", mA1, mB1);
    }
}
