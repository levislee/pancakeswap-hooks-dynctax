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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

    /// @notice 价格记录管理员，仅该地址可手动设置上次价格
    address public priceAdmin;

    /// @notice 暂存一次卖出交易的税额拆分，供 afterSwap 精确执行转账
    struct PendingSellFee { Currency inputCurrency; uint256 recvAmount; uint256 burnAmount; }
    mapping(address => mapping(PoolId => PendingSellFee)) private _pendingSellFee; // sender => poolId => pending

    constructor(
        ICLPoolManager _poolManager,
        address _targetToken,
        address _buyFeeReceiver,
        address _sellFeeReceiver,
        address _sellBurnAddress,
        uint24 _buyTaxBps,
        uint24 _sellTaxBps,
        uint32 _recordInterval,
        address _priceAdmin
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

        // 默认价格管理员为传入地址，否则回退为部署者
        priceAdmin = _priceAdmin == address(0) ? msg.sender : _priceAdmin;
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
    function _beforeSwap(address sender, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
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
        bool isSell = (Currency.unwrap(inputCurrency) == targetToken);

        // 买入：仅当费率>0时收取
        if (isBuy && buyTaxBps > 0) {
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

        // 卖出：根据当前价格与上次记录价格计算亏损比例，按规则扣减
        if (isSell) {
            PoolId id = key.toId();
            PriceRecord storage rec = priceRecordByPoolId[id];
            uint256 lastPrice = rec.lastPriceE18;
            // 若无历史价格，或当前价格高于历史价格，则不扣卖出税
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
            if (lastPrice == 0 || sqrtPriceX96 == 0) {
                return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }

            // 计算当前价格（考虑双方 decimals，返回 1e18 标度）
            uint256 Q192 = FixedPoint96.Q96 * FixedPoint96.Q96;
            uint256 sqrtSquared = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            uint256 currPrice;
            address token0 = Currency.unwrap(key.currency0);
            address token1 = Currency.unwrap(key.currency1);
            uint8 dec0 = _decimalsSafe(token0);
            uint8 dec1 = _decimalsSafe(token1);
            if (token1 == targetToken) {
                (uint256 numFactor, uint256 denFactor) = _decimalAdjust(dec0, dec1);
                currPrice = FullMath.mulDiv(sqrtSquared, numFactor * 1e18, Q192 * denFactor);
            } else if (token0 == targetToken) {
                (uint256 numFactor, uint256 denFactor) = _decimalAdjust(dec1, dec0);
                currPrice = FullMath.mulDiv(Q192, numFactor * 1e18, sqrtSquared * denFactor);
            } else {
                return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }

            if (currPrice > lastPrice) {
                // 价格上涨，不收卖出税
                return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }

            // 亏损比例（bps）。<=3%：扣 3% 给接收地址；>3%：3% 给接收地址，超出部分给销毁地址
            uint256 lossBps = FullMath.mulDiv((lastPrice - currPrice), 10000, lastPrice);
            uint256 recvBps = 300; // 固定 3%
            uint256 burnBps = lossBps > recvBps ? (lossBps - recvBps) : 0;
            uint256 totalBps = recvBps + burnBps; // 总扣减比例

            // 税基为 |amountSpecified|
            uint256 amtAbs = uint256(amt < 0 ? -amt : amt);
            uint256 recvAmt = FullMath.mulDiv(amtAbs, recvBps, 10000);
            uint256 burnAmt = burnBps == 0 ? 0 : FullMath.mulDiv(amtAbs, burnBps, 10000);
            uint256 totalAmt = recvAmt + burnAmt;

            // 暂存拆分，afterSwap 执行实际转账
            _pendingSellFee[sender][id] = PendingSellFee({ inputCurrency: inputCurrency, recvAmount: recvAmt, burnAmount: burnAmt });

            // 返回输入侧正向 delta 以在余额层面扣减
            int128 specifiedDelta = 0;
            int128 unspecifiedDelta = 0;
            if (isExactInput) {
                specifiedDelta = int128(int256(totalAmt));
            } else {
                unspecifiedDelta = int128(int256(totalAmt));
            }
            BeforeSwapDelta delta = toBeforeSwapDelta(specifiedDelta, unspecifiedDelta);
            return (this.beforeSwap.selector, delta, 0);
        }

        // 既不是买入也不是卖出（异常），不做处理
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice 在 swap 后执行税款直接转账：通过 vault.take 将输入侧税款以 ERC20 直接转入接收地址
    /// @dev 为确保钩子地址拥有可提取余额，beforeSwap 已返回正向税额 delta，CLHooks.afterSwap 会将该 delta 计入 hook，之后本方法 take 即可转出
    function _afterSwap(
        address sender,
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
        bool isSell = (Currency.unwrap(inputCurrency) == targetToken);

        if (isBuy && buyTaxBps > 0) {
            // 计算税额（与 beforeSwap 相同的税基：|amountSpecified|）
            uint256 amtAbs = uint256(amt < 0 ? -amt : amt);
            uint256 tax = (amtAbs * uint256(buyTaxBps)) / 10000;
            if (tax > 0) {
                // 买入：直接 ERC20 转账到买入手续费地址
                vault.take(inputCurrency, buyFeeReceiver, tax);
            }
        } else if (isSell) {
            // 卖出：读取暂存的拆分并执行转账
            PoolId id = key.toId();
            PendingSellFee memory pend = _pendingSellFee[sender][id];
            if (pend.recvAmount > 0 || pend.burnAmount > 0) {
                if (pend.recvAmount > 0) {
                    vault.take(pend.inputCurrency, sellFeeReceiver, pend.recvAmount);
                }
                if (pend.burnAmount > 0) {
                    vault.take(pend.inputCurrency, sellBurnAddress, pend.burnAmount);
                }
                delete _pendingSellFee[sender][id];
            }
        }

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

        // 目标 token 的价格（以另一侧 token 计价，考虑双方 decimals，返回 1e18 标度）
        uint256 priceE18;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint8 dec0 = _decimalsSafe(token0);
        uint8 dec1 = _decimalsSafe(token1);
        if (token1 == targetToken) {
            (uint256 numFactor, uint256 denFactor) = _decimalAdjust(dec0, dec1);
            priceE18 = FullMath.mulDiv(sqrtSquared, numFactor * 1e18, Q192 * denFactor);
        } else if (token0 == targetToken) {
            (uint256 numFactor, uint256 denFactor) = _decimalAdjust(dec1, dec0);
            priceE18 = FullMath.mulDiv(Q192, numFactor * 1e18, sqrtSquared * denFactor);
        } else {
            return; // 安全检查：不应到达
        }

        rec.lastTime = block.timestamp;
        rec.lastPriceE18 = priceE18;
    }

    /// @notice 手动设置某池的最近一次价格（1e18 标度），lastTime 记为当前区块时间
    /// @dev 仅允许 priceAdmin 调用
    function setLastPriceE18(PoolKey calldata key, uint256 priceE18) external {
        require(msg.sender == priceAdmin, "not priceAdmin");
        PoolId id = key.toId();
        PriceRecord storage rec = priceRecordByPoolId[id];
        rec.lastTime = block.timestamp;
        rec.lastPriceE18 = priceE18;
    }

    /// @notice 更换价格管理员
    function setPriceAdmin(address newAdmin) external {
        require(msg.sender == priceAdmin, "not priceAdmin");
        require(newAdmin != address(0), "admin=0");
        priceAdmin = newAdmin;
    }

    /// @notice 查看指定池的当前价格（1e18 标度）以及上一次记录的历史价格
    /// @dev 若池不包含目标 token 或 slot0 未初始化，当前价格返回 0
    function getCurrentAndLastPrice(PoolKey calldata key)
        external
        view
        returns (uint256 currentPriceE18, uint256 lastPriceE18)
    {
        PoolId id = key.toId();
        PriceRecord storage rec = priceRecordByPoolId[id];
        lastPriceE18 = rec.lastPriceE18;

        bool hasTarget = (Currency.unwrap(key.currency0) == targetToken) || (Currency.unwrap(key.currency1) == targetToken);
        if (!hasTarget) {
            return (0, lastPriceE18);
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) {
            return (0, lastPriceE18);
        }

        uint256 Q192 = FixedPoint96.Q96 * FixedPoint96.Q96;
        uint256 sqrtSquared = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint8 dec0 = _decimalsSafe(token0);
        uint8 dec1 = _decimalsSafe(token1);
        if (token1 == targetToken) {
            (uint256 numFactor, uint256 denFactor) = _decimalAdjust(dec0, dec1);
            currentPriceE18 = FullMath.mulDiv(sqrtSquared, numFactor * 1e18, Q192 * denFactor);
        } else {
            // currency0 == targetToken
            (uint256 numFactor, uint256 denFactor) = _decimalAdjust(dec1, dec0);
            currentPriceE18 = FullMath.mulDiv(Q192, numFactor * 1e18, sqrtSquared * denFactor);
        }

        return (currentPriceE18, lastPriceE18);
    }

    /// @dev 安全获取 token 的 decimals，失败则回退为 18
    function _decimalsSafe(address token) internal view returns (uint8 d) {
        d = 18;
        if (token == address(0)) return d;
        try IERC20Metadata(token).decimals() returns (uint8 dd) {
            d = dd;
        } catch {}
    }

    /// @dev 根据两个 decimals 生成乘除因子，使得整体效果为乘以 10^(decA - decB)
    function _decimalAdjust(uint8 decA, uint8 decB) internal pure returns (uint256 numFactor, uint256 denFactor) {
        if (decA >= decB) {
            numFactor = _pow10(decA - decB);
            denFactor = 1;
        } else {
            numFactor = 1;
            denFactor = _pow10(decB - decA);
        }
    }

    /// @dev 10 的幂
    function _pow10(uint8 n) internal pure returns (uint256) {
        uint256 r = 1;
        for (uint8 i = 0; i < n; i++) {
            r *= 10;
        }
        return r;
    }
}
