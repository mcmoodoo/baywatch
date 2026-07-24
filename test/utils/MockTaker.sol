// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Vendored from swap-vm v0.0.6 test/mocks/MockTaker.sol (import paths adjusted to node_modules).
// A taker contract: on preTransferInCallback it approves Aqua and pushes tokenIn to settle the swap.

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ITakerCallbacks } from "@1inch/swap-vm/src/interfaces/ITakerCallbacks.sol";
import { SwapVM, ISwapVM } from "@1inch/swap-vm/src/SwapVM.sol";

contract MockTaker is ITakerCallbacks {
    Aqua public immutable AQUA;
    SwapVM public immutable SWAPVM;
    address public immutable owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlySwapVM() {
        require(msg.sender == address(SWAPVM), "Not the SwapVM");
        _;
    }

    constructor(Aqua aqua, SwapVM swapVM, address owner_) {
        AQUA = aqua;
        SWAPVM = swapVM;
        owner = owner_;
    }

    function swap(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) public onlyOwner returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = SWAPVM.swap(order, tokenIn, tokenOut, amount, takerTraitsAndData);
    }

    function preTransferInCallback(
        address maker,
        address /* taker */,
        address tokenIn,
        address /* tokenOut */,
        uint256 amountIn,
        uint256 /* amountOut */,
        bytes32 orderHash,
        bytes calldata /* takerData */
    ) public virtual onlySwapVM {
        ERC20(tokenIn).approve(address(AQUA), amountIn);
        AQUA.push(maker, address(SWAPVM), orderHash, tokenIn, amountIn);
    }

    function preTransferOutCallback(
        address, address, address, address, uint256, uint256, bytes32, bytes calldata
    ) public virtual onlySwapVM {}
}
