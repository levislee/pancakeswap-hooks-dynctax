// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/pool-cl/CLTaxHook.sol";

contract FindSalt is Script {
    function findSaltForAddress(
        address factory,
        address poolManager,
        address buyReceiver,
        address sellReceiver,
        address targetAddress
    ) external view {
        bytes memory creationCode = abi.encodePacked(
            type(CLTaxHook).creationCode,
            abi.encode(poolManager, buyReceiver, sellReceiver)
        );
        bytes32 codeHash = keccak256(creationCode);
        
        // Try to find the salt within a reasonable range
        for (uint256 i = 0; i < 50000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(uint160(uint256(keccak256(
                abi.encodePacked(
                    bytes1(0xff),
                    factory,
                    salt,
                    codeHash
                )
            ))));
            
            if (predicted == targetAddress) {
                console.log("=== Salt Found ===");
                console.log("Target Address:", targetAddress);
                console.log("Salt (uint256):", i);
                console.log("Salt (hex):");
                console.logBytes32(bytes32(i));
                return;
            }
        }
        
        console.log("[FAIL] Salt not found within range 0-99999");
        console.log("Target Address:", targetAddress);
    }
}