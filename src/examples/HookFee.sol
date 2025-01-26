// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract HookFee is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    uint256 public constant HOOK_FEE_PERCENTAGE = 0.03e18; // 3% fee

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        bool exactInput = params.amountSpecified < 0;
        bool specifiedIsZero = params.zeroForOne == exactInput;

        uint256 feeAmount;
        if (exactInput && specifiedIsZero) {
            // fee on the currency1 as output
            feeAmount = FixedPointMathLib.mulWadDown(uint256(int256(delta.amount1())), HOOK_FEE_PERCENTAGE);
        } else if (exactInput && !specifiedIsZero) {
            // fee on the currency0 as output
            feeAmount = FixedPointMathLib.mulWadDown(uint256(int256(delta.amount0())), HOOK_FEE_PERCENTAGE);
        } else if (!exactInput && specifiedIsZero) {
            // fee on currency1 as input
            feeAmount = FixedPointMathLib.mulWadDown(uint256(int256(-delta.amount1())), HOOK_FEE_PERCENTAGE);
        } else if (!exactInput && !specifiedIsZero) {
            // fee on currency0 as input
            feeAmount = FixedPointMathLib.mulWadDown(uint256(int256(-delta.amount0())), HOOK_FEE_PERCENTAGE);
        }

        // taking a hook fee on the unspecified token
        if (specifiedIsZero) {
            key.currency1.take(poolManager, address(this), feeAmount, false);
        } else {
            key.currency0.take(poolManager, address(this), feeAmount, false);
        }

        // by returning the amount the amount the hook has taken, PoolManager will apply the hook's delta to the swapper's delta
        return (BaseHook.afterSwap.selector, int128(int256(feeAmount)));
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // -- Fee charged on unspecified after swap -- //
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
