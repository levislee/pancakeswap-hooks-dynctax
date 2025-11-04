// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";

/// @notice CLTaxHook: 在 swap 前按方向收取税费并返回 delta 以扣减输入
/// 买入（zeroForOne=true）扣 2% 到 buyReceiver，卖出（zeroForOne=false）扣 3% 到 sellReceiver
/// 注意：该版本仅返回 BeforeSwapDelta 扣减输入，不修改 LP 费，也不实现额外的钩子
contract CLTaxHook is CLBaseHook {
    /// @notice 目标 token，仅当池中包含该 token 才处理交易
    address public immutable targetToken;

    /// @notice 买入手续费（bps），默认 0%；买入手续费接收地址
    uint24 public buyTaxBps; // 默认 0
    address public buyFeeReceiver;

    /// @notice 卖出手续费基数（bps），默认 3%；卖出手续费接收地址与销毁地址（卖出逻辑暂未实现）
    uint24 public sellTaxBps; // 默认 300 (3%)
    address public sellFeeReceiver;
    address public sellBurnAddress;

    /// @notice 价格记录窗口（秒），默认 3600；按池维度的最近记录
    uint32 public recordInterval; // 默认 3600s
    struct PriceRecord { uint256 lastTime; uint256 lastPriceE18; }
    mapping(PoolId => PriceRecord) public priceRecordByPoolId;

    constructor(
        ICLPoolManager _poolManager,
        address _targetToken,
        address _buyFeeReceiver,
        address _sellFeeReceiver,
        address _sellBurnAddress,
        uint24 _buyTaxBps,
        uint24 _sellTaxBps,
        uint32 _recordInterval
    ) CLBaseHook(_poolManager) {
        require(_targetToken != address(0), "target=0");
        require(_buyFeeReceiver != address(0), "buyRecv=0");
        require(_sellFeeReceiver != address(0), "sellRecv=0");
        targetToken = _targetToken;

        buyFeeReceiver = _buyFeeReceiver;
        sellFeeReceiver = _sellFeeReceiver;
        sellBurnAddress = _sellBurnAddress; // 可为 0

        buyTaxBps = _buyTaxBps; // 若为 0 则不收买入税
        sellTaxBps = _sellTaxBps == 0 ? 300 : _sellTaxBps; // 默认 3%
        recordInterval = _recordInterval == 0 ? 3600 : _recordInterval; // 默认 3600s
    }

    /// @dev 仅启用 beforeSwap，并允许返回 delta（扣减输入）。其他回调全部关闭。
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @notice 在 swap 前计算税费并通过 BeforeSwapDelta 扣减输入侧金额（输入侧返回正向 delta，减少入池数量）
    /// @dev Infinity 语义：amountSpecified < 0 为 exact input，> 0 为 exact output；指定币种的判定：params.zeroForOne == (params.amountSpecified < 0) 则 specified 为 currency0，否则为 currency1
    /// 返回 lpFeeOverride=0，不覆盖池费率；实际 ERC20 税款转账在 afterSwap 中通过 vault.take 执行
    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 只处理包含目标 token 的池
        bool hasTarget = (Currency.unwrap(key.currency0) == targetToken) || (Currency.unwrap(key.currency1) == targetToken);
        if (!hasTarget) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Infinity 语义：amountSpecified < 0 为 exact input，> 0 为 exact output
        int256 amt = int256(params.amountSpecified);
        if (amt == 0) {
            // amountSpecified == 0（异常），不做处理
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 指定币种是否为 currency0
        bool specifiedIsToken0 = (params.zeroForOne == (params.amountSpecified < 0));

        // 输入侧币种与 delta 位置映射
        bool isExactInput = (amt < 0);

        // 输入/输出币种
        Currency inputCurrency = isExactInput
            ? (specifiedIsToken0 ? key.currency0 : key.currency1)
            : (specifiedIsToken0 ? key.currency1 : key.currency0);
        Currency outputCurrency = isExactInput
            ? (specifiedIsToken0 ? key.currency1 : key.currency0)
            : (specifiedIsToken0 ? key.currency0 : key.currency1);

        // 目标 token 的买/卖方向：输出为目标 token => 买入；输入为目标 token => 卖出
        bool isBuy = (Currency.unwrap(outputCurrency) == targetToken);
        // bool isSell = (Currency.unwrap(inputCurrency) == targetToken);

        // 仅实现买入逻辑：买入且费率>0才收取
        if (!isBuy || buyTaxBps == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 计算税额（基于“输入侧”），税基为 |amountSpecified|
        uint256 amtAbs = uint256(amt < 0 ? -amt : amt);
        uint256 tax = (amtAbs * uint256(buyTaxBps)) / 10000;

        // 对应 delta：在输入侧做正向返回（表示从用户支付中划出给 hook 的税款）
        int128 specifiedDelta = 0;
        int128 unspecifiedDelta = 0;
        if (isExactInput) {
            // exact input：输入侧为 specified；返回正向税额以减少入池数量
            specifiedDelta = int128(int256(tax));
        } else {
            // exact output：输入侧为 unspecified；返回正向税额以在 afterSwap 阶段向用户额外收取
            unspecifiedDelta = int128(int256(tax));
        }

        BeforeSwapDelta delta = toBeforeSwapDelta(specifiedDelta, unspecifiedDelta);
        return (this.beforeSwap.selector, delta, 0);
    }

    /// @notice 在 swap 后执行税款直接转账：通过 vault.take 将输入侧税款以 ERC20 直接转入接收地址
    /// @dev 为确保钩子地址拥有可提取余额，beforeSwap 已返回正向税额 delta，CLHooks.afterSwap 会将该 delta 计入 hook，之后本方法 take 即可转出
    function _afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // 只处理包含目标 token 的池
        bool hasTarget = (Currency.unwrap(key.currency0) == targetToken) || (Currency.unwrap(key.currency1) == targetToken);
        if (!hasTarget) {
            return (this.afterSwap.selector, 0);
        }

        int256 amt = int256(params.amountSpecified);
        if (amt == 0) {
            return (this.afterSwap.selector, 0);
        }
        bool specifiedIsToken0 = (params.zeroForOne == (params.amountSpecified < 0));
        bool isExactInput = (amt < 0);

        // 输入/输出币种
        Currency inputCurrency = isExactInput
            ? (specifiedIsToken0 ? key.currency0 : key.currency1)
            : (specifiedIsToken0 ? key.currency1 : key.currency0);
        Currency outputCurrency = isExactInput
            ? (specifiedIsToken0 ? key.currency1 : key.currency0)
            : (specifiedIsToken0 ? key.currency0 : key.currency1);

        // 是否为“买入目标 token”
        bool isBuy = (Currency.unwrap(outputCurrency) == targetToken);

        // 计算税额（与 beforeSwap 相同的税基：|amountSpecified|）
        uint256 amtAbs = uint256(amt < 0 ? -amt : amt);
        uint256 tax = isBuy ? (amtAbs * uint256(buyTaxBps)) / 10000 : 0;
        if (tax == 0) {
            return (this.afterSwap.selector, 0);
        }
        // 买入：直接 ERC20 转账到买入手续费地址
        vault.take(inputCurrency, buyFeeReceiver, tax);

        // 价格记录：满足窗口则更新为目标 token 在另一侧 token 的价格（1e18 标度）
        _updateTargetPriceIfNeeded(key);

        // 不需要返回 afterSwap delta（未启用 returnsDelta），返回 0
        return (this.afterSwap.selector, 0);
    }

    function _updateTargetPriceIfNeeded(PoolKey calldata key) internal {
        PoolId id = key.toId();
        PriceRecord storage rec = priceRecordByPoolId[id];
        if (recordInterval == 0) return;
        if (block.timestamp - rec.lastTime < recordInterval) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return;

        // Q192 = Q96 * Q96
        uint256 Q192 = FixedPoint96.Q96 * FixedPoint96.Q96;
        uint256 sqrtSquared = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

        // 目标 token 的价格（以另一侧 token 计价，1e18 标度）
        uint256 priceE18;
        if (Currency.unwrap(key.currency1) == targetToken) {
            // price = (sqrt^2 / Q192) * 1e18
            priceE18 = FullMath.mulDiv(sqrtSquared, 1e18, Q192);
        } else if (Currency.unwrap(key.currency0) == targetToken) {
            // price = (Q192 / sqrt^2) * 1e18
            priceE18 = FullMath.mulDiv(Q192, 1e18, sqrtSquared);
        } else {
            return; // 安全检查：不应到达
        }

        rec.lastTime = block.timestamp;
        rec.lastPriceE18 = priceE18;
    }
}
