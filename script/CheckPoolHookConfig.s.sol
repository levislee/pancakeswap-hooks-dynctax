// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ParametersHelper} from "infinity-core/src/libraries/math/ParametersHelper.sol";

/// @notice 检查池子的 Hook 权限位图配置
contract CheckPoolHookConfig is Script {
    using ParametersHelper for bytes32;
    
    // CL Hook 偏移量常量
    uint8 constant HOOKS_BEFORE_SWAP_OFFSET = 6;
    uint8 constant HOOKS_AFTER_SWAP_OFFSET = 7;
    uint8 constant HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET = 10;

    function run() external view {
        // BSC 测试网的 ICLPoolManager 地址
        address poolManagerAddr = 0x969D90ac74a1A5228B66440F8bd7a1d2225B33F3;
        ICLPoolManager poolManager = ICLPoolManager(poolManagerAddr);
        
        // 你的 CLTaxHook 地址
        address hookAddress = 0x31ee7CF5123ea626BC89ede6abF38A1264A5Bcf3;
        
        console.log("=== Pool Hook Configuration Check ===");
        console.log("PoolManager:", poolManagerAddr);
        console.log("Hook Address:", hookAddress);
        
        // 从 Hook 合约获取声明的权限位图
        IHooks hook = IHooks(hookAddress);
        uint16 hookDeclaredBitmap;
        
        try hook.getHooksRegistrationBitmap() returns (uint16 bitmap) {
            hookDeclaredBitmap = bitmap;
            console.log("Hook declared bitmap:", hookDeclaredBitmap);
            console.log("Hook declared bitmap (binary):", _toBinaryString(hookDeclaredBitmap, 16));
        } catch {
            console.log("Failed to get hook registration bitmap from contract");
            return;
        }
        
        // 分析声明的权限
        console.log("\n=== Hook Declared Permissions ===");
        console.log("beforeSwap:", (hookDeclaredBitmap >> HOOKS_BEFORE_SWAP_OFFSET) & 1 == 1);
        console.log("afterSwap:", (hookDeclaredBitmap >> HOOKS_AFTER_SWAP_OFFSET) & 1 == 1);
        console.log("beforeSwapReturnsDelta:", (hookDeclaredBitmap >> HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) & 1 == 1);
        
        // 注意：要检查具体池子的配置，需要知道池子的 PoolKey
        // 这里我们只能检查 Hook 合约本身的声明
        console.log("\n=== Next Steps ===");
        console.log("To check a specific pool configuration, you need:");
        console.log("1. The pool's PoolKey (currency0, currency1, fee, parameters)");
        console.log("2. Call poolManager.getSlot0(poolId) to get pool state");
        console.log("3. Extract parameters.getHooksRegistrationBitmap() from PoolKey");
        console.log("4. Compare with hook declared bitmap");
        
        console.log("\n=== Troubleshooting Guide ===");
        console.log("If swap fails with hook enabled:");
        console.log("1. Verify pool parameters bitmap matches hook declared bitmap");
        console.log("2. Check if hook functions revert (add events/logs to debug)");
        console.log("3. Ensure hook has sufficient permissions for vault operations");
        console.log("4. Verify token approvals and balances");
    }

    /// @notice 直接检查一个 bytes32 parameters 的 hooks 位图，并与 Hook 声明比对
    function checkParams(bytes32 parameters, address hookAddress) external view {
        IHooks hook = IHooks(hookAddress);
        uint16 declared;
        try hook.getHooksRegistrationBitmap() returns (uint16 b) { declared = b; } catch {
            console.log("Failed to read hook declared bitmap");
            return;
        }

        uint16 inParams = parameters.getHooksRegistrationBitmap();
        console.log("=== Parameters vs Hook Declared Bitmap ===");
        console.log("Params bitmap:", inParams);
        console.log("Hook declared:", declared);
        console.log("Match:", inParams == declared);

        console.log("\nOffsets:");
        console.log("beforeSwap (6):", ((inParams >> HOOKS_BEFORE_SWAP_OFFSET) & 1) == 1);
        console.log("afterSwap (7):", ((inParams >> HOOKS_AFTER_SWAP_OFFSET) & 1) == 1);
        console.log("beforeSwapReturnsDelta (10):", ((inParams >> HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) & 1) == 1);
    }

    /// @notice 用输入的四元组检查位图匹配（前端创建池时的参数）
    function checkWithInputs(
        address currency0,
        address currency1,
        uint24 fee,
        bytes32 parameters,
        address hookAddress
    ) external view {
        IHooks hook = IHooks(hookAddress);
        uint16 declared;
        try hook.getHooksRegistrationBitmap() returns (uint16 b) { declared = b; } catch {
            console.log("Failed to read hook declared bitmap");
            return;
        }

        uint16 inParams = parameters.getHooksRegistrationBitmap();
        console.log("=== Inputs Check ===");
        console.log("currency0:", currency0);
        console.log("currency1:", currency1);
        console.log("fee:", fee);
        console.log("hook:", hookAddress);
        console.log("params bitmap:", inParams);
        console.log("declared bitmap:", declared);
        console.log("Match:", inParams == declared);
    }
    
    function _toBinaryString(uint256 value, uint256 bits) internal pure returns (string memory) {
        bytes memory buffer = new bytes(bits);
        for (uint256 i = 0; i < bits; i++) {
            buffer[bits - 1 - i] = ((value >> i) & 1) == 1 ? bytes1("1") : bytes1("0");
        }
        return string(buffer);
    }
}