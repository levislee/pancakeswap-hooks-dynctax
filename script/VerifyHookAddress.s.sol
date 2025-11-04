// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/// @notice 验证 Hook 地址是否满足 PancakeSwap Hook 机制的地址位编码要求
contract VerifyHookAddress is Script {
    // CL Hook 偏移量常量（来自 ICLHooks.sol）
    uint8 constant HOOKS_BEFORE_SWAP_OFFSET = 6;
    uint8 constant HOOKS_AFTER_SWAP_OFFSET = 7;
    uint8 constant HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET = 10;

    function run() external view {
        // 默认示例地址（可使用 check(address) 传入你自己的地址）
        address hookAddress = 0x31ee7CF5123ea626BC89ede6abF38A1264A5Bcf3;
        _verify(hookAddress);
    }

    /// @notice 通过参数传入要验证的 Hook 地址
    function check(address hookAddress) external view {
        _verify(hookAddress);
    }

    function _verify(address hookAddress) internal view {
        console.log("=== CLTaxHook Address Bit Encoding Verification ===");
        console.log("Hook Address:", hookAddress);
        console.log("Address (hex):", vm.toString(hookAddress));

        // 将地址转换为 uint160 进行位操作
        uint160 addr = uint160(hookAddress);

        // 检查各个位是否设置
        bool beforeSwapBit = (addr >> HOOKS_BEFORE_SWAP_OFFSET) & 1 == 1;
        bool afterSwapBit = (addr >> HOOKS_AFTER_SWAP_OFFSET) & 1 == 1;
        bool beforeSwapReturnsDeltaBit = (addr >> HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) & 1 == 1;

        console.log("\n=== Address Bit Check Results ===");
        console.log("beforeSwap (bit 6):", beforeSwapBit);
        console.log("afterSwap (bit 7):", afterSwapBit);
        console.log("beforeSwapReturnsDelta (bit 10):", beforeSwapReturnsDeltaBit);

        // CLTaxHook required bitmap: beforeSwap=true, afterSwap=true, beforeSwapReturnsDelta=true
        bool isValidAddress = beforeSwapBit && afterSwapBit && beforeSwapReturnsDeltaBit;

        console.log("\n=== Verification Results ===");
        if (isValidAddress) {
            console.log("[PASS] Address satisfies CLTaxHook bit encoding requirements");
        } else {
            console.log("[FAIL] Address does NOT satisfy CLTaxHook bit encoding requirements");
            console.log("Required bits: beforeSwap(6)=1, afterSwap(7)=1, beforeSwapReturnsDelta(10)=1");
        }

        // Show required bitmap pattern
        uint16 requiredBitmap = uint16((1 << HOOKS_BEFORE_SWAP_OFFSET) |
                                      (1 << HOOKS_AFTER_SWAP_OFFSET) |
                                      (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET));
        console.log("Required bitmap (binary):", _toBinaryString(requiredBitmap, 16));
        console.log("Current address low 16 bits (binary):", _toBinaryString(uint16(addr), 16));

        // Calculate address mask requirements
        console.log("\n=== Address Mask Requirements ===");
        console.log("Address must satisfy: (address & 0x%s) == 0x%s",
                   _toHexString(requiredBitmap, 4),
                   _toHexString(requiredBitmap, 4));
        console.log("Current address mask result: 0x%s", _toHexString(uint16(addr) & requiredBitmap, 4));
    }

    function _toBinaryString(uint256 value, uint256 bits) internal pure returns (string memory) {
        bytes memory buffer = new bytes(bits);
        for (uint256 i = 0; i < bits; i++) {
            buffer[bits - 1 - i] = ((value >> i) & 1) == 1 ? bytes1("1") : bytes1("0");
        }
        return string(buffer);
    }

    function _toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length);
        for (uint256 i = 2 * length; i > 0; --i) {
            buffer[i - 1] = bytes1(uint8(value & 0xf) < 10 ?
                                  uint8(value & 0xf) + 48 :
                                  uint8(value & 0xf) + 87);
            value >>= 4;
        }
        return string(buffer);
    }
}