// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ParamOracle } from "../src/ParamOracle.sol";
import { BaywatchV4Hook } from "../src/v4/BaywatchV4Hook.sol";
import { MsgSenderRouter } from "./utils/MsgSenderRouter.sol";

/// @notice The dual-venue proof: the SAME ParamOracle + Graph-fetched signal that defends the Aqua pool
///         defends a real Uniswap v4 pool through BaywatchV4Hook — market index -> dynamic fee, cross-venue
///         reputation -> per-swapper surcharge (via the official IMsgSender pattern), regime -> breaker.
contract BaywatchV4HookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint32 constant MAX_AGE = 300;
    uint24 constant MAX_FEE_PIPS = 500_000;  // 50% fail-safe ceiling (mirrors MAX_SPREAD 0.5e9)
    uint24 constant MAX_TOLL_PIPS = 500_000; // 50% toll cap (mirrors MAX_TOLL 0.5e9)
    uint8 constant TIER_NORMAL = 0;
    uint8 constant TIER_DEFENSIVE = 1;
    uint8 constant TIER_HALT = 2;
    uint256 constant SWAP_AMOUNT = 1e18;

    address constant TOURIST = address(0x7001);
    address constant SHARK = address(0x5001);

    PoolManager manager;
    ParamOracle oracle;
    MsgSenderRouter router;
    PoolModifyLiquidityTest lpRouter;
    BaywatchV4Hook hook;
    TokenMock token0;
    TokenMock token1;
    PoolKey key;
    bytes32 poolId;

    function setUp() public {
        manager = new PoolManager(address(this));
        oracle = new ParamOracle(address(this)); // test acts as the agent (poster)
        router = new MsgSenderRouter(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        TokenMock a = new TokenMock("Token A", "TKA");
        TokenMock b = new TokenMock("Token B", "TKB");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        // Hook address must carry exactly the BEFORE_SWAP permission in its low 14 bits.
        address hookAddr = address(uint160(0x1000000000000000000000000000000000000000) | uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "src/v4/BaywatchV4Hook.sol:BaywatchV4Hook",
            abi.encode(manager, address(oracle), MAX_AGE, MAX_FEE_PIPS, MAX_TOLL_PIPS, TIER_NORMAL, address(this)),
            hookAddr
        );
        hook = BaywatchV4Hook(hookAddr);
        hook.setTrustedRouter(address(router), true);

        // Dynamic-fee pool at 1:1, defended by the hook.
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        manager.initialize(key, 79228162514264337593543950336); // sqrt(1) * 2^96
        poolId = PoolId.unwrap(key.toId());

        // Seed deep liquidity around the mid so fee differences dominate price impact.
        token0.mint(address(this), 1e27);
        token1.mint(address(this), 1e27);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)), "");

        // Fund takers on both legs and approve the router.
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? TOURIST : SHARK;
            token0.mint(who, 100e18);
            token1.mint(who, 100e18);
            vm.startPrank(who);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Exact-in swap through the IMsgSender router as `who`; returns output received.
    function _swapOut(address who, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        TokenMock tokenOut = zeroForOne ? token1 : token0;
        uint256 before = tokenOut.balanceOf(who);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(who);
        router.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        return tokenOut.balanceOf(who) - before;
    }

    /// The money test: same pool, same trade, same block — the shark pays the reputation toll on top of
    /// the market spread, the tourist pays only the spread. One oracle write, venue #2 defended.
    function test_sharkSurchargedVsTourist() public {
        oracle.setParams(poolId, 10_000_000);        // 1% market spread (1e9 scale)
        oracle.setToll(poolId, SHARK, 36_300_000);   // 3.63% reputation toll (matches the Radar demo numbers)

        uint256 outTourist = _swapOut(TOURIST, true, SWAP_AMOUNT);
        uint256 outShark = _swapOut(SHARK, true, SWAP_AMOUNT);

        assertLt(outShark, outTourist, "shark must receive less than tourist");
        // Expected fee ratio: tourist 1.00%, shark 1.00% + 3.63% = 4.63%.
        uint256 expected = (outTourist * (1_000_000 - 46_300)) / (1_000_000 - 10_000);
        assertApproxEqRel(outShark, expected, 1e14, "surcharge should equal the posted toll");
        console2.log("tourist out:", outTourist);
        console2.log("shark   out:", outShark);
        console2.log("surcharge (bps of tourist):", ((outTourist - outShark) * 10_000) / outTourist);
    }

    /// Market index -> global dynamic fee: everyone pays the spread, scaled exactly as posted.
    function test_marketSpreadAppliesToAll() public {
        oracle.setParams(poolId, 0);
        uint256 outFree = _swapOut(TOURIST, true, SWAP_AMOUNT);

        oracle.setParams(poolId, 30_000_000); // 3%
        uint256 outSpread = _swapOut(TOURIST, true, SWAP_AMOUNT);

        uint256 expected = (outFree * (1_000_000 - 30_000)) / 1_000_000;
        assertApproxEqRel(outSpread, expected, 1e14, "3% dynamic fee should bite exactly");
    }

    /// Stale oracle -> spread fails SAFE to the maximum defensive fee (dead agent = fortress mode).
    function test_staleSpread_failsSafeToMaxFee() public {
        oracle.setParams(poolId, 10_000_000);
        uint256 outFresh = _swapOut(TOURIST, true, SWAP_AMOUNT);

        vm.warp(block.timestamp + MAX_AGE + 1);
        uint256 outStale = _swapOut(TOURIST, true, SWAP_AMOUNT);

        assertLt(outStale, outFresh, "stale data must widen, not tighten");
        // ~50% fee vs ~1% fee on near-flat liquidity.
        uint256 expected = (outFresh * (1_000_000 - MAX_FEE_PIPS)) / (1_000_000 - 10_000);
        assertApproxEqRel(outStale, expected, 1e14, "fail-safe = MAX_FEE_PIPS");
    }

    /// Stale toll -> fails OPEN: the shark pays only the (re-freshened) spread, same as the tourist.
    function test_staleToll_failsOpen() public {
        oracle.setToll(poolId, SHARK, 36_300_000);
        vm.warp(block.timestamp + MAX_AGE + 1);
        oracle.setParams(poolId, 10_000_000); // spread fresh again; toll left stale

        uint256 outTourist = _swapOut(TOURIST, true, SWAP_AMOUNT);
        uint256 outShark = _swapOut(SHARK, true, SWAP_AMOUNT);
        assertApproxEqRel(outShark, outTourist, 1e14, "stale toll must not surcharge");
    }

    /// HALT regime reverts every swap.
    function test_haltRegimeReverts() public {
        oracle.setParams(poolId, 10_000_000);
        oracle.setRisk(poolId, TIER_HALT, address(0));
        vm.prank(TOURIST);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -int256(SWAP_AMOUNT), TickMath.MIN_SQRT_PRICE + 1), "");
    }

    /// DEFENSIVE regime: pool refuses to RECEIVE the at-risk token, still lets takers buy it out.
    function test_defensiveRegimeIsOneDirectional() public {
        oracle.setParams(poolId, 10_000_000);
        oracle.setRisk(poolId, TIER_DEFENSIVE, address(token0));

        // Selling risk token INTO the pool (zeroForOne: pool receives token0) -> rejected.
        vm.prank(TOURIST);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -int256(SWAP_AMOUNT), TickMath.MIN_SQRT_PRICE + 1), "");

        // Buying the risk token OUT of the pool (de-risking the LPs) -> allowed.
        uint256 out = _swapOut(TOURIST, false, SWAP_AMOUNT);
        assertGt(out, 0, "de-risking direction must stay open");
    }

    /// Identity resolution: through a trusted IMsgSender router the SHARK is recognized and tolled;
    /// through an untrusted router the caller contract is the identity, so the shark hides — and the
    /// defense answer is to toll the untrusted router itself once IT earns a reputation.
    function test_identityResolution_trustedVsUntrustedRouter() public {
        oracle.setParams(poolId, 10_000_000);
        oracle.setToll(poolId, SHARK, 36_300_000);

        MsgSenderRouter rogue = new MsgSenderRouter(manager); // NOT allowlisted
        vm.startPrank(SHARK);
        token0.approve(address(rogue), type(uint256).max);
        token1.approve(address(rogue), type(uint256).max);
        vm.stopPrank();

        // Via trusted router: shark resolved -> tolled (less output than tourist).
        uint256 outSharkTrusted = _swapOut(SHARK, true, SWAP_AMOUNT);
        uint256 outTourist = _swapOut(TOURIST, true, SWAP_AMOUNT);
        assertLt(outSharkTrusted, outTourist, "trusted path resolves and tolls the shark");

        // Via untrusted router: identity = the router contract, shark's toll not applied...
        uint256 t1Before = token1.balanceOf(SHARK);
        vm.prank(SHARK);
        rogue.swap(key, SwapParams(true, -int256(SWAP_AMOUNT), TickMath.MIN_SQRT_PRICE + 1), "");
        uint256 outSharkRogue = token1.balanceOf(SHARK) - t1Before;
        assertGt(outSharkRogue, outSharkTrusted, "shark escapes the personal toll behind an unknown router");

        // ...but the router address is a first-class identity: toll IT and everyone it fronts pays.
        oracle.setToll(poolId, address(rogue), 36_300_000);
        t1Before = token1.balanceOf(SHARK);
        vm.prank(SHARK);
        rogue.swap(key, SwapParams(true, -int256(SWAP_AMOUNT), TickMath.MIN_SQRT_PRICE + 1), "");
        uint256 outRogueTolled = token1.balanceOf(SHARK) - t1Before;
        assertLt(outRogueTolled, outSharkRogue, "tolling the rogue router restores the surcharge");
    }
}
