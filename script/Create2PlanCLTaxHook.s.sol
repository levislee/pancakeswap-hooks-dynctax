// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {CLTaxHook} from "src/pool-cl/CLTaxHook.sol";

/// @notice Plan script: enumerate CREATE2 salt to find an address satisfying mask 0x04c0 on low 16 bits
contract Create2PlanCLTaxHook is Script {
    uint16 constant REQUIRED_MASK = 0x04c0; // bit6=1, bit7=1, bit10=1

    /// @notice Basic planning: iterate salt from 0..limit and print the first match
    function plan(
        address factory,
        address poolManager,
        address buyReceiver,
        address sellReceiver,
        uint256 limit
    ) external view {
        bytes memory creationCode = abi.encodePacked(
            type(CLTaxHook).creationCode,
            abi.encode(poolManager, buyReceiver, sellReceiver)
        );

        (bytes32 salt, address target) = findSalt(factory, creationCode, 0, limit);

        console.log("=== CREATE2 Planning Result ===");
        if (target == address(0)) {
            console.log("[FAIL] No matching address found within limit.");
            console.log("Factory:", factory);
            console.log("Limit:", limit);
            return;
        }
        console.log("[OK] Found matching address:");
        console.log("Factory:", factory);
        console.log("CLTaxHook Address:", target);
        console.log("Salt:", uint256(salt));
        console.log("Low16 bits:", uint16(uint160(target)));
        console.log("Mask result:", uint16(uint160(target)) & REQUIRED_MASK);
        console.log("Mask required:", REQUIRED_MASK);
    }

    /// @notice Advanced planning: set start and limit
    function planFrom(
        address factory,
        address poolManager,
        address buyReceiver,
        address sellReceiver,
        uint256 start,
        uint256 limit
    ) external view {
        bytes memory creationCode = abi.encodePacked(
            type(CLTaxHook).creationCode,
            abi.encode(poolManager, buyReceiver, sellReceiver)
        );
        (bytes32 salt, address target) = findSalt(factory, creationCode, start, limit);
        console.log("=== CREATE2 Planning Result (start/limit) ===");
        if (target == address(0)) {
            console.log("[FAIL] No matching address found within range.");
            console.log("Factory:", factory);
            console.log("Range:", start, "..", start + limit);
            return;
        }
        console.log("[OK] Found matching address:");
        console.log("Factory:", factory);
        console.log("CLTaxHook Address:", target);
        console.log("Salt:", uint256(salt));
        console.log("Low16 bits:", uint16(uint160(target)));
        console.log("Mask result:", uint16(uint160(target)) & REQUIRED_MASK);
        console.log("Mask required:", REQUIRED_MASK);
    }

    function findSalt(
        address factory,
        bytes memory creationCode,
        uint256 start,
        uint256 limit
    ) internal pure returns (bytes32 salt, address target) {
        bytes32 codeHash = keccak256(creationCode);
        for (uint256 i = start; i < start + limit; ++i) {
            bytes32 s = bytes32(i);
            address addr = computeCreate2(factory, s, codeHash);
            if ((uint16(uint160(addr)) & REQUIRED_MASK) == REQUIRED_MASK) {
                return (s, addr);
            }
        }
        return (bytes32(0), address(0));
    }

    function computeCreate2(
        address factory,
        bytes32 salt,
        bytes32 codeHash
    ) internal pure returns (address addr) {
        bytes32 data = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, codeHash));
        addr = address(uint160(uint256(data)));
    }
}