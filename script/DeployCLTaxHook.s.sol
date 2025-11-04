// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {CLTaxHook} from "src/pool-cl/CLTaxHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

/// @notice Deploy script for CLTaxHook on BSC testnet
contract DeployCLTaxHook is Script {
    function run() external {
        // Use env var PRIVATE_KEY for the deployer
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Constructor params aligned with updated CLTaxHook
        // PoolManager (BSC testnet example)
        ICLPoolManager poolManager = ICLPoolManager(vm.parseAddress("0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b"));

        // Target token for buy/sell direction classification
        address targetToken = vm.parseAddress("0x1111111111111111111111111111111111111111"); // placeholder non-zero

        // Buy fee and receivers
        address buyReceiver = vm.parseAddress("0x2059facb1da1fba830b4bfbc2d59fcd5e4b4df7c");
        uint24 buyTaxBps = 0; // default 0%

        // Sell fee baseline and receivers (sell logic TBD; baseline needed for ctor)
        address sellReceiver = vm.parseAddress("0x25e981503a710325b1c9df5a8e44ed425f1f7e3b");
        address sellBurn = vm.parseAddress("0x0000000000000000000000000000000000000000");
        uint24 sellTaxBps = 300; // default 3%

        // Price recording window
        uint32 recordInterval = 3600; // default 1h

        vm.startBroadcast(pk);
        CLTaxHook hook = new CLTaxHook(
            poolManager,
            targetToken,
            buyReceiver,
            sellReceiver,
            sellBurn,
            buyTaxBps,
            sellTaxBps,
            recordInterval
        );
        vm.stopBroadcast();

        console2.log("CLTaxHook deployed at:", address(hook));
        console2.log("Deployer:", deployer);
    }
}