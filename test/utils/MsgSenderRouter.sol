// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Adapted from @uniswap/v4-core src/test/PoolSwapTest.sol, with one addition: the router implements
// Uniswap's official IMsgSender pattern (a transient locker captured at swap() entry), so hooks can
// recover the ORIGINAL swapper — exactly what the Universal Router does in production (Dispatcher's
// msgSender() returning the lock initiator). This is the trusted-router leg of BaywatchV4Hook's identity
// resolution; assertion require-chains from the original test router are dropped, settle/take kept 1:1.

import { CurrencyLibrary, Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolTestBase } from "@uniswap/v4-core/src/test/PoolTestBase.sol";
import { CurrencySettler } from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import { IMsgSender } from "../../src/v4/IMsgSender.sol";

contract MsgSenderRouter is PoolTestBase, IMsgSender {
    using CurrencySettler for Currency;

    address private _locker;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    /// @notice The original initiator of the in-flight swap (Universal Router's msgSender() semantics).
    function msgSender() external view returns (address) {
        return _locker;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        _locker = msg.sender;
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData))), (BalanceDelta)
        );
        _locker = address(0);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (deltaAfter0 < 0) data.key.currency0.settle(manager, data.sender, uint256(-deltaAfter0), false);
        if (deltaAfter1 < 0) data.key.currency1.settle(manager, data.sender, uint256(-deltaAfter1), false);
        if (deltaAfter0 > 0) data.key.currency0.take(manager, data.sender, uint256(deltaAfter0), false);
        if (deltaAfter1 > 0) data.key.currency1.take(manager, data.sender, uint256(deltaAfter1), false);

        return abi.encode(delta);
    }
}
