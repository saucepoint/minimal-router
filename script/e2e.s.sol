// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/PositionManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

import {HookMiner} from "../test/utils/HookMiner.sol";
import {HookFee} from "../src/examples/HookFee.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";

contract EndToEndScript is Script, Constants, Config {
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;
    using CurrencyLibrary for Currency;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
    uint24 lpFee = 5000; // 0.50%
    int24 tickSpacing = 60;

    // starting price of the pool, in sqrtPriceX96
    uint160 startingPrice = 79228162514264337593543950336; // floor(sqrt(1) * 2^96)

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 100e18;
    uint256 public token1Amount = 100e18;

    // range of the position
    int24 tickLower = -600; // must be a multiple of tickSpacing
    int24 tickUpper = 600;
    /////////////////////////////////////

    // forge script script/e2e.s.sol \
    // --rpc-url https://mainnet.base.org \
    // --sig "run(bool,bool,bool,bool,bool)" true true true true true
    // --etherscan-api-key $BASE_SEPOLIA_ETHERSCAN_API_KEY --verify
    // --private-key $TEMP_PK
    function run(bool deployMinRouter, bool deployMockERC20, bool deployHook, bool initializePool, bool addLiquidity)
        external
    {
        PoolKey memory poolKey;
        HookFee hookFee;
        MinimalRouter minRouter;

        if (deployMinRouter) {
            vm.broadcast();
            minRouter = new MinimalRouter(POOLMANAGER);
        } else {
            // TODO set to address once its deployed
            minRouter = MinimalRouter(address(0x0));
        }

        if (deployHook) {
            hookFee = deployHookFee();
        } else {
            // TODO set to address once its deployed
            hookFee = HookFee(address(0x0));
        }

        if (deployMockERC20) {
            vm.startBroadcast();
            MockERC20 tokenA = new MockERC20("MockTokenA", "MOCKA", 18);
            MockERC20 tokenB = new MockERC20("MockTokenB", "MOCKB", 18);

            // Mint balance
            tokenA.mint(msg.sender, 10_000e18);
            tokenB.mint(msg.sender, 10_000e18);

            // approve addresses
            tokenApprovals(IERC20(address(tokenA)), IERC20(address(tokenB)));
            tokenA.approve(address(minRouter), type(uint256).max);
            tokenB.approve(address(minRouter), type(uint256).max);
            vm.stopBroadcast();

            // tokens should be sorted
            (currency0, currency1) = uint160(address(tokenA)) < uint160(address(tokenB))
                ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
                : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

            poolKey = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: lpFee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(hookFee))
            });
        } else {
            // TODO set to address once its deployed
            // tokens should be sorted
            poolKey = PoolKey({
                currency0: Currency.wrap(address(0x0)),
                currency1: Currency.wrap(address(0x0)),
                fee: lpFee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(hookFee))
            });
        }

        if (initializePool) {
            vm.broadcast();
            POOLMANAGER.initialize(poolKey, startingPrice);
        }

        if (addLiquidity) {
            addLiquidityPOSM(poolKey);
        }

        bytes memory hookData = new bytes(0);
        vm.startBroadcast();
        minRouter.swap(poolKey, false, false, 1e18, hookData);
        minRouter.swap(poolKey, false, true, 1e18, hookData);
        minRouter.swap(poolKey, true, false, 1e18, hookData);
        minRouter.swap(poolKey, true, true, 1e18, hookData);
        vm.stopBroadcast();
    }

    function deployHookFee() internal returns (HookFee) {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOLMANAGER);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(HookFee).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        HookFee _hookFee = new HookFee{salt: salt}(IPoolManager(POOLMANAGER));
        require(address(_hookFee) == hookAddress, "HookFeeScript: hook address mismatch");
        return _hookFee;
    }

    function addLiquidityPOSM(PoolKey memory key) internal {
        (uint160 sqrtPriceX96,,,) = POOLMANAGER.getSlot0(key.toId());

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        // slippage limits
        uint256 amount0Max = token0Amount + 1 wei;
        uint256 amount1Max = token1Amount + 1 wei;

        vm.startBroadcast();
        IPositionManager(address(posm)).mint(
            key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, msg.sender, block.timestamp + 60, ""
        );
        vm.stopBroadcast();
    }

    /// @dev helper function for encoding mint liquidity operation
    /// @dev does NOT encode SWEEP, developers should take care when minting liquidity on an ETH pair
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        return (actions, params);
    }

    function tokenApprovals(IERC20 _token0, IERC20 _token1) public {
        if (!currency0.isAddressZero()) {
            _token0.approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(address(_token0), address(posm), type(uint160).max, type(uint48).max);
        }
        if (!currency1.isAddressZero()) {
            _token1.approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(address(_token1), address(posm), type(uint160).max, type(uint48).max);
        }
    }
}
