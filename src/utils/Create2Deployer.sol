// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal CREATE2 deployer/factory
contract Create2Deployer {
    event Deployed(address addr, bytes32 salt);

    /// @notice Deploy a contract using CREATE2
    /// @param creationCode the creation bytecode including constructor args
    /// @param salt the CREATE2 salt
    /// @return addr deployed address
    function deploy(bytes memory creationCode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            if iszero(addr) { revert(0, 0) }
        }
        emit Deployed(addr, salt);
    }

    /// @notice Compute the CREATE2 address for given creationCode and salt
    function computeAddress(bytes memory creationCode, bytes32 salt) external view returns (address addr) {
        bytes32 codeHash = keccak256(creationCode);
        bytes32 data = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash));
        addr = address(uint160(uint256(data)));
    }
}