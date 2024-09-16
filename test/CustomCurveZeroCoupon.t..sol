// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CustomCurveZeroCoupon} from "../src/CustomCurveZeroCoupon.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract CustomCurveZeroCouponTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    CustomCurveZeroCoupon hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("CustomCurveZeroCoupon.sol", abi.encode(manager), hookAddress);
        hook = CustomCurveZeroCoupon(hookAddress);

        // Initialize the contract
        uint256 maturityDate = block.timestamp + 365 days;
        uint256 faceValue = 1000e18;
        uint256 yieldRate = 500; // 5%

        hook.initialize(maturityDate, faceValue, yieldRate);

        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add some initial liquidity through the custom `addLiquidity` function
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            hookAddress,
            1000 ether
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            hookAddress,
            1000 ether
        );

        hook.addLiquidity(key, 1000e18);
    }

    // Helper function to compute K
    function getK() public view returns (uint256) {
        uint token0ClaimID = CurrencyLibrary.toId(currency0);
        uint token1ClaimID = CurrencyLibrary.toId(currency1);

        uint256 reserve0 = manager.balanceOf(address(hook), token0ClaimID);
        uint256 reserve1 = manager.balanceOf(address(hook), token1ClaimID);

        return reserve0 * reserve1;
    }

    function test_K_value_after_swap() public {
        uint256 initialK = getK();

        // Perform a swap
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 newK = getK();

        // Log the K values
        emit log_named_uint("Initial K", initialK);
        emit log_named_uint("New K", newK);

        // Assert K has changed due to custom pricing
        assertTrue(newK != initialK, "K should change after swap due to custom pricing");
    }

    function test_K_and_exchange_rate_over_time() public {
        // Get initial exchange rate and K
        uint256 initialExchangeRate = hook.getExchangeRate();
        uint256 initialK = getK();

        // Log initial values
        emit log_named_uint("Initial Exchange Rate", initialExchangeRate);
        emit log_named_uint("Initial K", initialK);

        // Advance time by 6 months
        vm.warp(block.timestamp + 182 days);

        uint256 exchangeRateAfter6Months = hook.getExchangeRate();
        uint256 KAfter6Months = getK();

        emit log_named_uint("Exchange Rate After 6 Months", exchangeRateAfter6Months);
        emit log_named_uint("K After 6 Months", KAfter6Months);

        // Advance time to maturity
        vm.warp(hook.maturityDate());

        uint256 exchangeRateAtMaturity = hook.getExchangeRate();
        uint256 KAtMaturity = getK();

        emit log_named_uint("Exchange Rate At Maturity", exchangeRateAtMaturity);
        emit log_named_uint("K At Maturity", KAtMaturity);

        // Assert that the exchange rate reaches face value at maturity
        assertEq(exchangeRateAtMaturity, hook.faceValue() * 1e18, "Exchange rate should be face value at maturity");
    }
}