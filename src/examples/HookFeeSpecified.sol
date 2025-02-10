// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract HookFeeSpecified is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    uint256 public constant HOOK_FEE_PERCENTAGE = 0.03e18; // 3% fee

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        bool exactInput = params.amountSpecified < 0;
        bool specifiedIsZero = params.zeroForOne == exactInput;

        uint256 swapAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount = FixedPointMathLib.mulWadDown(swapAmount, HOOK_FEE_PERCENTAGE);

        // always take a hook fee on the specified token
        if (specifiedIsZero) {
            key.currency0.take(poolManager, address(this), feeAmount, false);
        } else {
            key.currency1.take(poolManager, address(this), feeAmount, false);
        }

        // fee is always on the specified currency (top 128 bits)
        BeforeSwapDelta returnDelta = toBeforeSwapDelta(int128(uint128(feeAmount)), 0);

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
