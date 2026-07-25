// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { BaywatchV4Hook } from "../src/v4/BaywatchV4Hook.sol";
import { MsgSenderRouter } from "../test/utils/MsgSenderRouter.sol";
import { HookMiner } from "./utils/HookMiner.sol";

/// @notice Stand up a REAL Uniswap v4 pool defended by BaywatchV4Hook, reading the SAME ParamOracle the Aqua
///         desk uses (from ui/desk.json) — one Graph-fetched signal, two protocols. State vars keep each
///         function's stack shallow (v4-core forces the legacy pipeline).
contract DeployV4 is Script {
    using PoolIdLibrary for PoolKey;

    uint256 constant PK       = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // anvil[0] == desk poster
    uint256 constant TOURIST  = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // anvil[1]
    uint256 constant SHARK    = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // anvil[2]
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint32  constant MAX_AGE  = 300;
    uint24  constant MAX_FEE  = 500_000;
    uint24  constant MAX_TOLL = 500_000;
    uint24  constant NAIVE_FEE = 3000;
    uint160 constant SQRT1    = 79228162514264337593543950336;
    int24   constant SPACING  = 60;
    int256  constant LIQ      = 1e21;
    uint256 constant FUND     = 1_000_000e18;

    PoolManager manager;
    BaywatchV4Hook hook;
    MsgSenderRouter router;
    PoolModifyLiquidityTest lp;
    Currency c0;
    Currency c1;
    PoolKey defKey;
    PoolKey naiveKey;
    address oracle;

    function run() external {
        string memory dj = vm.readFile("./ui/desk.json");
        oracle = vm.parseJsonAddress(dj, ".oracle");
        address ta = vm.parseJsonAddress(dj, ".tokenA");
        address tb = vm.parseJsonAddress(dj, ".tokenB");
        (c0, c1) = ta < tb ? (Currency.wrap(ta), Currency.wrap(tb)) : (Currency.wrap(tb), Currency.wrap(ta));
        _deploy();
        _seed();
        _fund(TOURIST);
        _fund(SHARK);
        _write();
    }

    function _deploy() internal {
        address me = vm.addr(PK);
        vm.startBroadcast(PK);
        manager = new PoolManager(me);
        bytes memory args = abi.encode(IPoolManager(address(manager)), oracle, MAX_AGE, MAX_FEE, MAX_TOLL, uint8(0), me);
        (address ha, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, uint160(Hooks.BEFORE_SWAP_FLAG), type(BaywatchV4Hook).creationCode, args);
        hook = new BaywatchV4Hook{salt: salt}(IPoolManager(address(manager)), oracle, MAX_AGE, MAX_FEE, MAX_TOLL, 0, me);
        require(address(hook) == ha, "hook addr mismatch");
        router = new MsgSenderRouter(manager);
        lp = new PoolModifyLiquidityTest(manager);
        hook.setTrustedRouter(address(router), true);
        defKey   = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(hook)));
        naiveKey = PoolKey(c0, c1, NAIVE_FEE, SPACING, IHooks(address(0)));
        manager.initialize(defKey, SQRT1);
        manager.initialize(naiveKey, SQRT1);
        vm.stopBroadcast();
    }

    function _seed() internal {
        address me = vm.addr(PK);
        vm.startBroadcast(PK);
        TokenMock(Currency.unwrap(c0)).mint(me, FUND * 4);
        TokenMock(Currency.unwrap(c1)).mint(me, FUND * 4);
        TokenMock(Currency.unwrap(c0)).approve(address(lp), type(uint256).max);
        TokenMock(Currency.unwrap(c1)).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(defKey,   ModifyLiquidityParams(-1200, 1200, LIQ, bytes32(0)), "");
        lp.modifyLiquidity(naiveKey, ModifyLiquidityParams(-1200, 1200, LIQ, bytes32(0)), "");
        vm.stopBroadcast();
    }

    function _fund(uint256 pk) internal {
        address t = vm.addr(pk);
        vm.broadcast(PK); TokenMock(Currency.unwrap(c0)).mint(t, FUND);
        vm.broadcast(PK); TokenMock(Currency.unwrap(c1)).mint(t, FUND);
        vm.broadcast(pk); TokenMock(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        vm.broadcast(pk); TokenMock(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
    }

    function _write() internal {
        string memory o = "v4";
        vm.serializeAddress(o, "manager", address(manager));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "lpRouter", address(lp));
        vm.serializeAddress(o, "oracle", oracle);
        vm.serializeAddress(o, "currency0", Currency.unwrap(c0));
        vm.serializeAddress(o, "currency1", Currency.unwrap(c1));
        vm.serializeBytes32(o, "defendedPoolId", PoolId.unwrap(defKey.toId()));
        vm.serializeBytes32(o, "naivePoolId", PoolId.unwrap(naiveKey.toId()));
        vm.serializeAddress(o, "tourist", vm.addr(TOURIST));
        string memory json = vm.serializeAddress(o, "shark", vm.addr(SHARK));
        vm.writeJson(json, "./ui/v4.json");
        console2.log("v4 deployed. hook:", address(hook));
        console2.log("wrote ui/v4.json");
    }
}
