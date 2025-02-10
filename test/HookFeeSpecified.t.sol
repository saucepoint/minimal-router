// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {HookFeeSpecified} from "../src/examples/HookFeeSpecified.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {MinimalRouter} from "../src/MinimalRouter.sol";

contract HookFeeSpecifiedTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookFeeSpecified hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    MinimalRouter minRouter;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        minRouter = new MinimalRouter(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(minRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(minRouter), type(uint256).max);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("HookFeeSpecified.sol:HookFeeSpecified", constructorArgs, flags);
        hook = HookFeeSpecified(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function test_swap(bool zeroForOne, bool exactInput) public {
        // Perform a test swap //
        BalanceDelta result = minRouter.swap(key, zeroForOne, exactInput, 1e18, ZERO_BYTES);

        if (zeroForOne) {
            assertLt(result.amount0(), 0);
            assertGt(result.amount1(), 0);
        } else {
            assertGt(result.amount0(), 0);
            assertLt(result.amount1(), 0);
        }
    }

    function test_swap_zeroForOne_exactInput() public {
        // hook holds no fees
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        
        // Perform a test swap //
        BalanceDelta result = minRouter.swap(key, true, true, 1e18, ZERO_BYTES);
        
        assertLt(result.amount0(), 0);
        assertGt(result.amount1(), 0);

        // fee taken on currency0, the specified token
        assertGt(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function test_swap_oneForZero_exactInput() public {
        // hook holds no fees
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        
        // Perform a test swap //
        BalanceDelta result = minRouter.swap(key, false, true, 1e18, ZERO_BYTES);
        
        assertGt(result.amount0(), 0);
        assertLt(result.amount1(), 0);

        // fee taken on currency1, the specified token
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertGt(currency1.balanceOf(address(hook)), 0);
    }

    function test_swap_zeroForOne_exactOutput() public {
        // hook holds no fees
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        
        // Perform a test swap //
        BalanceDelta result = minRouter.swap(key, true, false, 1e18, ZERO_BYTES);
        
        assertLt(result.amount0(), 0);
        assertGt(result.amount1(), 0);

        // fee taken on currency1, the specified token
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertGt(currency1.balanceOf(address(hook)), 0);
    }

    function test_swap_oneForZero_exactOutput() public {
        // hook holds no fees
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        
        // Perform a test swap //
        BalanceDelta result = minRouter.swap(key, false, false, 1e18, ZERO_BYTES);
        
        assertGt(result.amount0(), 0);
        assertLt(result.amount1(), 0);

        // fee taken on currency0, the specified token
        assertGt(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }
}
