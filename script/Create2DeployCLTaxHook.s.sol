// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {CLTaxHook} from "src/pool-cl/CLTaxHook.sol";
import {Create2Deployer} from "src/utils/Create2Deployer.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

/// @notice CREATE2 deploy script for CLTaxHook
contract Create2DeployCLTaxHook is Script {
    /// @notice Deploy factory via normal CREATE once, record its address
    function deployFactory() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        Create2Deployer factory = new Create2Deployer();
        vm.stopBroadcast();
        console2.log("Create2Deployer deployed at:", address(factory));
    }

    /// @notice Deploy CLTaxHook via CREATE2 using an existing factory
    function deployCL(
        address factoryAddr,
        address poolManager,
        address targetToken,
        address buyReceiver,
        address sellReceiver,
        address sellBurn,
        uint24 buyTaxBps,
        uint24 sellTaxBps,
        uint32 recordInterval,
        bytes32 salt
    ) external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Create2Deployer factory = Create2Deployer(factoryAddr);

        bytes memory creationCode = abi.encodePacked(
            type(CLTaxHook).creationCode,
            abi.encode(
                ICLPoolManager(poolManager),
                targetToken,
                buyReceiver,
                sellReceiver,
                sellBurn,
                buyTaxBps,
                sellTaxBps,
                recordInterval
            )
        );

        address computed = factory.computeAddress(creationCode, salt);

        vm.startBroadcast(pk);
        address deployed = factory.deploy(creationCode, salt);
        vm.stopBroadcast();

        console2.log("Computed address:", computed);
        console2.log("Deployed address:", deployed);
        require(deployed == computed, "CREATE2 address mismatch");
    }
}