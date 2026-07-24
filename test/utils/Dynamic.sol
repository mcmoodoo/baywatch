// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Vendored from swap-vm v0.0.6 test/utils/Dynamic.sol — fixed-size array -> dynamic array helpers.

function dynamic(uint256[2] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](2);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(address[2] memory arr) pure returns (address[] memory res) {
    res = new address[](2);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}
