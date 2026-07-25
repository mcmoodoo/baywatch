// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal CREATE2 salt miner for Uniswap v4 hooks. A v4 hook must be deployed to an address whose
///         low 14 bits encode its permissions, so we brute-force a salt until the CREATE2 address matches the
///         desired flags. Vendored equivalent of Uniswap v4-periphery test/utils/HookMiner.sol.
library HookMiner {
    uint160 constant FLAG_MASK = uint160((1 << 14) - 1);
    uint256 constant MAX_LOOP = 200_000;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hookAddress = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: no salt found");
    }
}
